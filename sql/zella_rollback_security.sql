-- Harden new inbound tokens without changing existing addresses; protect call content.
begin;
alter table public.businesses alter column inbound_email_token set default encode(extensions.gen_random_bytes(16), 'hex');
CREATE OR REPLACE FUNCTION public.zella_receive_inbound_email(p_key text, p_message jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_secret text; m jsonb := p_message;
  v_mid text; v_from text; v_to text; v_biz uuid; v_name text; v_subject text; v_body text; v_irt text;
  v_cust uuid; v_cname text; v_conv uuid; v_prev uuid; v_cat text; v_auto boolean; v_emid uuid; v_known boolean;
  v_prio text; v_title text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('result', 'not_configured'); end if;
  if p_key is null or encode(sha256(convert_to(p_key, 'utf8')), 'hex') <> encode(sha256(convert_to(v_secret, 'utf8')), 'hex') then return jsonb_build_object('result', 'unauthorized'); end if;
  if m is null or jsonb_typeof(m) <> 'object' then return jsonb_build_object('result', 'ignored'); end if;

  v_mid := nullif(left(trim(coalesce(m ->> 'message_id', '')), 300), '');
  v_from := lower(substring(coalesce(m ->> 'from', '') from '([A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
  v_irt := nullif(left(trim(coalesce(m ->> 'in_reply_to', '')), 300), '');
  v_subject := left(regexp_replace(coalesce(m ->> 'subject', ''), '[\r\n]+', ' ', 'g'), 300);
  v_body := left(coalesce(m ->> 'text', ''), 20000);
  v_auto := coalesce((m ->> 'auto_submitted')::boolean, false);
  if v_mid is null or v_from is null then return jsonb_build_object('result', 'ignored'); end if;

  select b.id, b.name, lower(a) into v_biz, v_name, v_to
    from jsonb_array_elements_text(case when jsonb_typeof(m -> 'to') = 'array' then m -> 'to' when jsonb_typeof(m -> 'to') = 'string' then jsonb_build_array(m ->> 'to') else '[]'::jsonb end) a
    join public.businesses b on b.inbound_email_token = substring(lower(a) from '(?:^|[<[:space:]])([a-z0-9]{12}|[a-f0-9]{32})@')
   where b.suspended_at is null and b.cancelled_at is null limit 1;
  if v_biz is null then return jsonb_build_object('result', 'no_business'); end if;

  if exists (select 1 from public.email_messages e where e.business_id = v_biz and e.direction = 'inbound' and e.external_message_id = v_mid) then
    return jsonb_build_object('result', 'duplicate');
  end if;
  if not public.zella_rate_limit('inbound_email:' || v_biz::text, 300, 3600) then return jsonb_build_object('result', 'rate_limited'); end if;

  select m2.customer_id into v_cust from public.zella_match_customer(v_biz, null, v_from) m2 where m2.certainty = 'exact' limit 1;
  v_known := v_cust is not null;
  if v_known then select trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_cname from public.customers where id = v_cust; end if;
  v_cname := coalesce(nullif(v_cname, ''), v_from);

  if v_irt is not null then
    select e.conversation_id into v_prev from public.email_messages e where e.business_id = v_biz and e.external_message_id = v_irt and e.conversation_id is not null limit 1;
  end if;
  v_conv := v_prev;
  if v_conv is null and v_cust is not null then
    select c.id into v_conv from public.conversations c where c.business_id = v_biz and c.customer_id = v_cust and c.channel = 'email' and c.status <> 'closed' order by c.last_message_at desc nulls last limit 1;
  end if;
  if v_conv is null then
    insert into public.conversations (business_id, customer_id, channel, status, subject, ai_handled)
    values (v_biz, v_cust, 'email', 'open', nullif(v_subject, ''), false) returning id into v_conv;
  end if;

  v_cat := public.zella_classify_email(v_subject, v_body, v_auto);

  insert into public.email_messages (business_id, customer_id, conversation_id, direction, status, from_email, to_email, subject, body_text, external_message_id, sent_at, metadata)
  values (v_biz, v_cust, v_conv, 'inbound', 'received', v_from, v_to, nullif(v_subject, ''), v_body, v_mid, now(),
          jsonb_build_object('category', v_cat, 'known_customer', v_known)) returning id into v_emid;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, external_message_id, metadata)
  values (v_conv, 'customer', 'text', left(v_body, 5000), v_mid, jsonb_build_object('category', v_cat, 'subject', v_subject, 'email_message_id', v_emid));

  if v_cat = 'auto_reply' then
    return jsonb_build_object('result', 'saved', 'category', v_cat);
  end if;
  if v_cat = 'unsubscribe' then
    perform public.zella_record_consent(v_biz, 'email', 'opted_out', 'email_link', v_cust, null, v_from, 'marketing', 'reply');
    if v_cust is not null then
      update public.customers set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'unsubscribed', updated_at = now() where id = v_cust and (not coalesce(do_not_email, false) or email_suppressed_reason is null);
    end if;
    perform public.zella_notify_owners(v_biz, 'email_unsubscribed', v_cname || ' unsubscribed', 'They will not get marketing emails any more.', 'info', 'inbox');
    return jsonb_build_object('result', 'saved', 'category', v_cat, 'unsubscribed', true);
  end if;

  v_prio := case when v_cat in ('complaint', 'cancel') then 'high' else 'normal' end;
  update public.conversations set status = 'open', priority = case when v_prio = 'high' then 'high' else priority end, updated_at = now() where id = v_conv;
  v_title := case v_cat
    when 'complaint' then 'Complaint by email from ' || v_cname
    when 'cancel' then v_cname || ' wants to cancel'
    when 'reschedule' then v_cname || ' wants a different time'
    when 'confirm' then v_cname || ' confirmed by email'
    else 'New email from ' || v_cname end;
  perform public.zella_notify_owners(v_biz, 'customer_email', v_title,
    left(coalesce(nullif(v_subject, ''), '(no subject)') || ': ' || regexp_replace(v_body, '\s+', ' ', 'g'), 300) || case when v_known then '' else ' (sender is not in your customer list)' end,
    case when v_cat = 'complaint' then 'urgent' else 'info' end, 'inbox');
  return jsonb_build_object('result', 'saved', 'category', v_cat, 'known_customer', v_known, 'conversation_id', v_conv);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_receive_inbound_email_signed(p_key text, p_message jsonb, p_sig jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  if public.zella_resend_signature_ok(p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') = 'bad' then
    return jsonb_build_object('result', 'unauthorized');
  end if;
  return public.zella_receive_inbound_email(p_key, p_message);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reconcile()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_found integer := 0; v_ids uuid[]; v_k text;
begin
  v_ids := '{}';
  for r in select a.business_id, count(*) n from public.appointments a
            where a.status in ('scheduled', 'confirmed') and a.start_time > now() and a.created_at < now() - interval '1 hour' and a.external_event_id is null
              and exists (select 1 from public.calendar_connections cc where cc.business_id = a.business_id and cc.status = 'active')
              and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status in ('pending', 'in_progress'))
              and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status = 'failed' and q.created_at > now() - interval '1 day')
            group by a.business_id loop
    insert into public.calendar_sync_queue (business_id, appointment_id, action, status, due_at)
    select a.business_id, a.id, 'upsert', 'pending', now() from public.appointments a
     where a.business_id = r.business_id and a.status in ('scheduled', 'confirmed') and a.start_time > now() and a.created_at < now() - interval '1 hour' and a.external_event_id is null
       and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status in ('pending', 'in_progress'))
       and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status = 'failed' and q.created_at > now() - interval '1 day');
    perform public.zella_platform_alert('reconcile_calendar', 'Appointments were missing from the calendar', r.n || ' appointments were sent to the calendar again.', 'info', r.business_id, 'daily');
    v_ids := v_ids || r.business_id; v_found := v_found + 1;
  end loop;
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Nothing missing now' where kind = 'reconcile_calendar' and status <> 'resolved' and not (business_id = any (v_ids));

  for v_k in select unnest(array['sms', 'email']) loop
    v_ids := '{}';
    for r in execute format('select business_id, count(*) n from public.%I where direction = ''outbound'' and status = ''queued'' and created_at < now() - interval ''30 minutes'' group by business_id', case v_k when 'sms' then 'sms_messages' else 'email_messages' end) loop
      perform public.zella_platform_alert('reconcile_' || v_k || '_stuck', r.n || ' ' || v_k || ' messages are stuck in the queue', 'Queued for over 30 minutes. Check the ' || v_k || ' sending workflow and the live switch.', 'warning', r.business_id, 'daily');
      v_ids := v_ids || r.business_id; v_found := v_found + 1;
    end loop;
    update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Queue is clear' where kind = 'reconcile_' || v_k || '_stuck' and status <> 'resolved' and not (business_id = any (v_ids));
  end loop;

  v_ids := '{}';
  for r in select business_id, count(*) n from public.knowledge_items where status = 'processing' and updated_at < now() - interval '1 hour' group by business_id loop
    perform public.zella_platform_alert('reconcile_knowledge_stuck', r.n || ' knowledge items are not getting published', 'Processing for over an hour. Check the Knowledge workflow.', 'warning', r.business_id, 'daily');
    v_ids := v_ids || r.business_id; v_found := v_found + 1;
  end loop;
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Nothing waiting' where kind = 'reconcile_knowledge_stuck' and status <> 'resolved' and not (business_id = any (v_ids));

  for r in select a.business_id, count(*) n from public.appointments a join public.businesses b on b.id = a.business_id and b.suspended_at is null and b.cancelled_at is null
            where a.status in ('scheduled', 'confirmed') and coalesce(a.end_time, a.start_time) < now() - interval '1 day' group by a.business_id loop
    continue when exists (select 1 from public.staff_notifications s where s.business_id = r.business_id and s.kind = 'appointments_need_outcome' and s.created_at > now() - interval '3 days');
    perform public.zella_notify_owners(r.business_id, 'appointments_need_outcome', r.n || ' past appointment' || case when r.n = 1 then ' needs' else 's need' end || ' an outcome',
      'Mark them completed or no-show so reports and follow-ups are right.', 'info', 'appointments');
    v_found := v_found + 1;
  end loop;
  return v_found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reconcile_call(p_provider_call_id text, p_status_code integer, p_call jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.calls; j jsonb := case when jsonb_typeof(p_call) = 'object' then p_call else '{}'::jsonb end;
  v_start timestamptz; v_end timestamptz; v_secs integer; v_res text;
  ts text;
begin
  select * into c from public.calls where external_call_id = p_provider_call_id;
  if c.id is null then return 'unknown_call'; end if;
  if c.outcome_at is not null then return 'already_final'; end if;
  if p_status_code = 404 then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status',
             case when coalesce((metadata ->> 'reconcile_attempts')::integer, 0) >= 6 then 'not_found' else 'retry' end) where id = c.id;
    return 'not_found';
  end if;
  if p_status_code is null or p_status_code < 200 or p_status_code >= 300 then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'provider_error', 'reconcile_error', p_status_code) where id = c.id;
    return 'provider_error';
  end if;
  if j ->> 'id' is distinct from p_provider_call_id then return 'mismatch'; end if;     -- never apply another call's data
  if j ->> 'status' is distinct from 'ended' then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'not_ended', 'provider_status_seen', left(j ->> 'status', 30)) where id = c.id;
    return 'not_ended';
  end if;
  begin v_start := nullif(j ->> 'startedAt', '')::timestamptz; exception when others then v_start := null; end;
  begin v_end := nullif(j ->> 'endedAt', '')::timestamptz; exception when others then v_end := null; end;
  v_secs := case when v_start is not null and v_end is not null and v_end >= v_start then extract(epoch from (v_end - v_start))::integer end;
  v_res := public.zella_record_inbound_call(p_provider_call_id,
    j #>> '{phoneNumber,number}', left(j ->> 'phoneNumberId', 100), j #>> '{customer,number}', v_start, v_end, v_secs,
    left(coalesce(j ->> 'endedReason', ''), 80),
    left(coalesce(j #>> '{analysis,summary}', j ->> 'summary', ''), 1500),
    case when coalesce(j #>> '{artifact,recordingUrl}', j ->> 'recordingUrl', '') ~ '^https://' then left(coalesce(j #>> '{artifact,recordingUrl}', j ->> 'recordingUrl'), 1000) end,
    left(coalesce(j #>> '{artifact,transcript}', j ->> 'transcript', ''), 60000),
    coalesce((j #>> '{analysis,structuredData,callback_requested}')::boolean, false));
  update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'reconciled', 'reconciled_at', now()) where id = c.id;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reconcile_call_usage(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v jsonb; n_new integer := 0; n_adj integer := 0; n_retry integer := 0; n_esc integer := 0; n_missing integer := 0; n_mismatch integer := 0;
        v_lim integer := greatest(1, least(coalesce(p_limit, 200), 1000));
begin
  -- a. ended AI calls with no usage yet, and recorded calls whose provider duration changed since
  for r in select c.id from public.calls c
            where c.ai_handled and c.ended_at is not null and c.ended_at < now() - interval '10 minutes' and coalesce(c.metadata ->> 'awaiting_report', 'false') <> 'true'
              and (not exists (select 1 from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id and u.entry_kind = 'usage')
                   or c.duration_seconds is distinct from (select sum(u.duration_seconds)::int from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id))
              and not exists (select 1 from public.usage_processing_issues i where i.call_id = c.id and i.status = 'escalated')
            order by c.ended_at limit v_lim loop
    begin
      v := public.zella_process_call_usage(r.id, 'reconcile');
      if v ->> 'result' = 'recorded' then n_new := n_new + 1; elsif v ->> 'result' = 'adjusted' then n_adj := n_adj + 1;
      elsif v ->> 'result' = 'missing_duration' then n_missing := n_missing + 1; end if;
    exception when others then
      perform public.zella_usage_open_issue((select business_id from public.calls where id = r.id), r.id, 'processing_failed', sqlerrm);
    end;
  end loop;
  -- b. failed processing: retried with a growing wait, at most 5 times, then escalated once
  for r in select * from public.usage_processing_issues i where i.status = 'open' and i.kind = 'processing_failed' and i.next_attempt_at <= now()
            order by i.next_attempt_at limit v_lim for update skip locked loop
    if r.attempts >= 5 then
      update public.usage_processing_issues set status = 'escalated', escalated_at = now(), updated_at = now() where id = r.id;
      perform public.zella_platform_alert('usage_processing_failed', 'Calling usage could not be recorded', 'A call''s usage failed 5 times: ' || left(coalesce(r.last_error, ''), 200),
                                          'warning', r.business_id, 'usage-failed:' || to_char(now(), 'YYYY-MM-DD'));
      n_esc := n_esc + 1; continue;
    end if;
    update public.usage_processing_issues set attempts = attempts + 1, next_attempt_at = now() + make_interval(mins => 15 * power(2, r.attempts)::int), updated_at = now() where id = r.id;
    begin
      v := public.zella_process_call_usage(r.call_id, 'retry');
      n_retry := n_retry + 1;
    exception when others then
      update public.usage_processing_issues set last_error = left(sqlerrm, 300) where id = r.id;
    end;
  end loop;
  -- c. calls the provider never sent a duration for: listed (not estimated), escalated once after a day
  for r in select i.* from public.usage_processing_issues i where i.status = 'open' and i.kind in ('missing_duration', 'invalid_duration') and i.created_at < now() - interval '24 hours' loop
    update public.usage_processing_issues set status = 'escalated', escalated_at = now(), updated_at = now() where id = r.id;
    perform public.zella_platform_alert('usage_missing_duration', 'Calls without a provider duration', 'At least one call has had no usable duration for a day and is not counted.',
                                        'warning', r.business_id, 'usage-duration:' || to_char(now(), 'YYYY-MM-DD'));
    n_esc := n_esc + 1;
  end loop;
  -- d. ledger vs calls over the last 35 days, per business, for calls that have usage recorded (calls with none are
  --    handled by a.; calls with an issue are tracked one by one): one open issue per business until it matches again
  for r in select c.business_id, sum(c.duration_seconds) as call_secs,
                  sum((select coalesce(sum(u.duration_seconds), 0) from public.usage_records u where u.usage_type = 'ai_call' and u.status = 'recorded' and u.call_id = c.id)) as ledger_secs
             from public.calls c
            where c.ai_handled and c.ended_at >= now() - interval '35 days' and c.ended_at < now() - interval '1 hour' and c.duration_seconds is not null
              and exists (select 1 from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id and u.entry_kind = 'usage')
            group by c.business_id loop
    if r.call_secs is distinct from r.ledger_secs then
      perform public.zella_usage_open_issue(r.business_id, null, 'summary_mismatch', 'Calls total ' || r.call_secs || ' s, ledger ' || r.ledger_secs || ' s (last 35 days).',
                                            jsonb_build_object('call_seconds', r.call_secs, 'ledger_seconds', r.ledger_secs));
      n_mismatch := n_mismatch + 1;
    else
      update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'matches', updated_at = now()
       where business_id = r.business_id and call_id is null and kind = 'summary_mismatch' and status <> 'resolved';
    end if;
  end loop;
  return jsonb_build_object('recorded', n_new, 'adjusted', n_adj, 'retried', n_retry, 'escalated', n_esc, 'missing_duration', n_missing, 'mismatches', n_mismatch);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_activation_test(p_business_id uuid, p_ok boolean, p_detail text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into public.activation_tests (business_id, ok, detail) values (p_business_id, p_ok, left(p_detail, 300));
$function$
;
CREATE OR REPLACE FUNCTION public.zella_call_content(p_call_id uuid)
RETURNS TABLE(recording_url text, transcript text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE mfa_ok boolean;
BEGIN
  -- The live MFA migration may be present even when restoring an older baseline.
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND to_regprocedure('public.zella_mfa_satisfied()') IS NOT NULL THEN
    EXECUTE 'SELECT public.zella_mfa_satisfied()' INTO mfa_ok;
    IF mfa_ok IS NOT TRUE THEN RETURN; END IF;
  END IF;
  RETURN QUERY SELECT c.recording_url, c.transcript FROM public.calls c
  WHERE c.id = p_call_id
    AND (auth.role() = 'service_role' OR (public.is_business_member(c.business_id)
    AND public.zella_module_on(c.business_id, 'calls')
    AND public.zella_has_role(c.business_id, ARRAY['owner', 'admin', 'manager'])));
END;
$function$;
REVOKE ALL ON FUNCTION public.zella_call_content(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.zella_call_content(uuid) TO authenticated, service_role;
revoke SELECT on public.calls from authenticated;
grant SELECT (id, business_id, customer_id, conversation_id, direction, status, from_number, to_number, started_at, answered_at, ended_at, duration_seconds, ai_handled, external_call_id, metadata, created_at, updated_at, needs_human, escalation_reason, escalated_at, escalation_resolved_at, escalation_resolved_by, summary, transfer_status, failure_reason, failure_context, assigned_to, outcome, outcome_note, outcome_at, escalation_acknowledged_at, escalation_acknowledged_by, escalation_reminded_at) on public.calls to authenticated;
create or replace view public.calls_view with (security_invoker=true) as  SELECT id,
    business_id,
    customer_id,
    conversation_id,
    direction,
    status,
    from_number,
    to_number,
    started_at,
    answered_at,
    ended_at,
    duration_seconds,
    ai_handled,
    external_call_id,
    metadata,
    created_at,
    updated_at,
    needs_human,
    escalation_reason,
    escalated_at,
    escalation_resolved_at,
    escalation_resolved_by,
    summary,
    transfer_status,
    failure_reason,
    failure_context,
    assigned_to,
    outcome,
    outcome_note,
    outcome_at,
    escalation_acknowledged_at,
    escalation_acknowledged_by,
    escalation_reminded_at,
    content.recording_url,
    content.transcript
   FROM public.calls c
   LEFT JOIN LATERAL public.zella_call_content(c.id) content ON true;
commit;
