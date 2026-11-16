-- Zella Voice: store and show n8n's HTTP answer per workflow (docs/ADMIN_AUDIT_2026-11-16.md OPS-17).
-- zella_dispatch_n8n handed work to n8n with net.http_post and threw the request id away, so an unpublished workflow
-- (404) or a wrong secret (401) still showed "Last handed over" on Automations.
--   1. n8n_dispatch_state gets last_request_id (the request just sent), response_request_id, last_status_code,
--      last_response_at and last_error (the answer to the last request that has one). No payload is stored.
--   2. zella_dispatch_n8n keeps the request id, and on its next run reads that request's net._http_response (pg_net
--      fills it after the request, so it is never waited for). 401 or 403 raise one urgent n8n_dispatch_refused alert
--      for all workflows (dedupe n8n_secret); 404 raises a warning for that workflow; a later 2xx resolves them.
--      Everything else is the production body unchanged: same counts, switch, address and secret checks, back off
--      and result. Production's version is the one patched on 15 Nov 2026 by sql/zella_email_delivery.sql (the
--      retired owner emails line), never sql/baseline. Archived first; any other version stops the file.
--   3. zella_admin_dispatch_responses(): businesses.view, the answer per workflow for the Automations page.
-- No effect while the zella_dispatch job is off (production, 16 Nov 2026).
-- Rollback: sql/rollback/zella_dispatch_response_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_dispatch_n8n()'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null or to_regclass('public.n8n_dispatch_state') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = '4333da07a5c57d91aa8f018e75368345' then          -- production's version (after zella_email_delivery.sql): archive it
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_dispatch_response', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> '080309d80bc02fcea61b6d10a185fa8f' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
end $$;

alter table public.n8n_dispatch_state
  add column if not exists last_request_id bigint,
  add column if not exists response_request_id bigint,
  add column if not exists last_status_code integer,
  add column if not exists last_response_at timestamptz,
  add column if not exists last_error text;

CREATE OR REPLACE FUNCTION public.zella_dispatch_n8n()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_base text := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '');
  v_on boolean := coalesce(public.zella_setting('n8n_dispatch_enabled', 'false'::jsonb) = 'true'::jsonb, false);
  v_secret text; w record; n integer; st public.n8n_dispatch_state; v_same integer; v_res jsonb := '{}'::jsonb; v_spam integer := 0; v_reconcile integer := 0; v_reviews integer := 0;
  v_req bigint; v_resp jsonb; v_code integer; prev public.n8n_dispatch_state;
  v_text_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'reply_confirmed', 'reply_reschedule', 'reply_help', 'waitlist_offer', 'cross_sell'];
  v_email_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'cross_sell'];
begin
  if not v_on then return jsonb_build_object('skipped', 'switched_off'); end if;
  if v_base is null then return jsonb_build_object('skipped', 'no_base_url'); end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_n8n_secret' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('skipped', 'no_secret'); end if;
  if to_regprocedure('public.zella_spam_work_waiting()') is not null then
    begin execute 'select public.zella_spam_work_waiting()' into v_spam; exception when others then v_spam := 0; end;
  end if;
  if to_regprocedure('public.zella_call_reconcile_waiting()') is not null then
    begin execute 'select public.zella_call_reconcile_waiting()' into v_reconcile; exception when others then v_reconcile := 0; end;
  end if;

  if to_regprocedure('public.zella_review_work_waiting()') is not null then
    begin execute 'select public.zella_review_work_waiting()' into v_reviews; exception when others then v_reviews := 0; end;
  end if;

  -- n8n's answer to each workflow's previous hand over. pg_net fills net._http_response after the request is sent, so
  -- it is read here, on the next run, never waited for. 401 or 403 (wrong secret, one alert for all
  -- workflows) and 404 (that workflow isn't published) raise an alert; a later success resolves them. Columns are read through to_jsonb so any pg_net version works.
  if to_regclass('net._http_response') is not null then
    for prev in select * from public.n8n_dispatch_state where last_request_id is not null and response_request_id is distinct from last_request_id loop
      begin
        execute 'select to_jsonb(r) from net._http_response r where r.id = $1' into v_resp using prev.last_request_id;
      exception when others then v_resp := null;
      end;
      continue when v_resp is null;
      v_code := case when coalesce(v_resp ->> 'status_code', '') ~ '^[0-9]{1,3}$' then (v_resp ->> 'status_code')::integer end;
      update public.n8n_dispatch_state set response_request_id = prev.last_request_id, last_status_code = v_code,
             last_response_at = coalesce(case when v_resp ->> 'created' is not null then (v_resp ->> 'created')::timestamptz end, now()),
             last_error = left(coalesce(nullif(v_resp ->> 'error_msg', ''), case when (v_resp ->> 'timed_out') = 'true' then 'Timed out' end), 200)
       where workflow = prev.workflow;
      if v_code in (401, 403, 404) then
        perform public.zella_platform_alert('n8n_dispatch_refused',
          case when v_code = 404 then 'n8n has no published workflow for ' || prev.workflow else 'n8n refused the dispatcher (wrong secret?)' end,
          'n8n answered ' || v_code || ' when the dispatcher handed over ' || prev.workflow || '.',
          case when v_code = 404 then 'warning' else 'urgent' end, null, case when v_code = 404 then prev.workflow else 'n8n_secret' end,
          jsonb_build_object('workflow', prev.workflow, 'status_code', v_code));
      elsif v_code between 200 and 299 then
        update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'n8n answered ' || v_code
         where kind = 'n8n_dispatch_refused' and dedupe_key in (prev.workflow, 'n8n_secret') and status <> 'resolved';
      end if;
    end loop;
  end if;

  for w in select * from (values ('event-router'), ('sms-sender'), ('email-sender'), ('followup-texts'), ('followup-emails'), ('owner-emails'), ('outbound-calls'), ('knowledge-sync'), ('calendar-sync'), ('connection-tests'), ('meta-leads'), ('meta-sender'), ('meta-health'), ('website-crawl'), ('staff-sms'), ('call-intel'), ('admin-alerts'), ('spam-response'), ('call-reconcile'), ('review-replies')) as t(name) loop
    n := case w.name
      when 'event-router' then (select count(*) from public.automation_events
         where (status = 'received' and coalesce(next_attempt_at, now()) <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes'))
      when 'sms-sender' then (select count(*) from public.appointment_reminders where status = 'pending' and channel = 'sms' and due_at <= now())
      when 'email-sender' then (select count(*) from public.appointment_reminders where status = 'pending' and channel = 'email' and due_at <= now())
      when 'followup-texts' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'sms' and due_at <= now() and kind = any (v_text_kinds))
      when 'followup-emails' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'email' and due_at <= now() and kind = any (v_email_kinds))
      when 'outbound-calls' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'call' and due_at <= now())
         + (select count(*) from public.callbacks where status in ('scheduled', 'retry_scheduled', 'due') and due_at <= now() and auto_call
              and (locked_at is null or locked_at < now() - interval '15 minutes'))
      when 'knowledge-sync' then (select count(*) from public.knowledge_items where status = 'processing')
         + case when coalesce(public.zella_setting('knowledge_ai_live', 'false'::jsonb) = 'true'::jsonb, false)
                then (select count(*) from public.knowledge_gaps where status = 'open' and suggested_at is null and suggestion_attempts < 3) else 0 end
      when 'call-intel' then case when coalesce(public.zella_setting('call_intel_live', 'false'::jsonb) = 'true'::jsonb, false)
         then (select count(*) from public.call_insights where (status = 'pending' and attempts < 3) or (status = 'processing' and claimed_at < now() - interval '15 minutes')) else 0 end
      when 'calendar-sync' then case when public.zella_calendar_live()
         then (select count(*) from public.calendar_sync_queue where status = 'pending' and due_at <= now())
            + (select count(*) from public.calendar_connections where status = 'active' and busy_refresh_due_at <= now()) else 0 end
      when 'connection-tests' then case when public.zella_provider_checks_live()
         then (select count(*) from unnest(array['telnyx', 'vapi', 'resend']) p where not exists (select 1 from public.provider_health h where h.provider = p
                 and (coalesce(h.checked_at, 'epoch') > now() - interval '3 hours' or coalesce(h.claimed_at, 'epoch') > now() - interval '10 minutes'))) else 0 end
      when 'meta-leads' then (select count(*) from public.meta_events where kind = 'lead'
         and ((status = 'pending' and next_try_at <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes')))
      when 'meta-sender' then (select count(*) from public.meta_outbox where (status = 'queued' and next_try_at <= now()) or (status = 'sending' and claimed_at < now() - interval '10 minutes'))
      when 'meta-health' then (select count(*) from public.meta_connections where status in ('connected', 'error') and next_check_at <= now())
      when 'website-crawl' then case when public.zella_website_crawl_live()
         then (select count(*) from public.website_pages wp join public.website_sources ws on ws.id = wp.source_id and ws.status = 'active'
                where wp.status in ('approved', 'broken', 'missing') and wp.next_fetch_at <= now() and (wp.claimed_at is null or wp.claimed_at < now() - interval '10 minutes'))
            + (select count(*) from public.website_sources where status = 'active' and next_discovery_at <= now()) else 0 end
      when 'staff-sms' then case when coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false)
         then (select count(*) from public.staff_notifications where created_at > now() - interval '6 hours'
                 and (sms_status = 'pending' or (sms_status = 'sending' and sms_claimed_at < now() - interval '15 minutes'))) else 0 end
      when 'admin-alerts' then case when coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false)
                                     and nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '') is not null
         then (select count(*) from public.platform_alerts s where s.status = 'open' and (s.notified_at is null
                     or (s.meta ? 'email_claimed_at' and not s.meta ? 'emailed_at'
                         and s.notified_at < now() - interval '15 minutes'
                         and coalesce((s.meta ->> 'email_attempts')::int, 0) < 2))) else 0 end
      when 'spam-response' then coalesce(v_spam, 0)
      when 'call-reconcile' then coalesce(v_reconcile, 0)
      when 'review-replies' then coalesce(v_reviews, 0)
      when 'owner-emails (retired)' then (select count(*) from public.staff_notifications s join public.businesses b on b.id = s.business_id
         where b.suspended_at is null and b.cancelled_at is null
           and (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes')))
      else 0 end;
    if n = 0 then
      update public.n8n_dispatch_state set last_count = 0, consecutive_same = 0 where workflow = w.name;
      continue;
    end if;

    insert into public.n8n_dispatch_state (workflow) values (w.name) on conflict do nothing;
    select * into st from public.n8n_dispatch_state where workflow = w.name;
    if st.last_triggered_at > now() - interval '8 seconds' then continue; end if;
    v_same := case when n >= st.last_count and st.last_triggered_at > now() - interval '10 minutes' then st.consecutive_same + 1 else 0 end;
    if v_same >= 12 and st.last_triggered_at > now() - interval '15 minutes' then
      update public.n8n_dispatch_state set last_count = n, consecutive_same = v_same where workflow = w.name;
      v_res := v_res || jsonb_build_object(w.name, 'backed_off');
      continue;
    end if;

    v_req := net.http_post(url := v_base || '/webhook/zella/run/' || w.name,
                          headers := jsonb_build_object('Content-Type', 'application/json', 'X-Zella-Secret', v_secret),
                          body := '{}'::jsonb, timeout_milliseconds := 5000);
    update public.n8n_dispatch_state set last_triggered_at = now(), last_count = n, consecutive_same = v_same, triggers_total = triggers_total + 1,
           last_request_id = v_req where workflow = w.name;
    v_res := v_res || jsonb_build_object(w.name, n);
  end loop;
  return v_res;
end $function$;

create or replace function public.zella_admin_dispatch_responses()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_admin_require('businesses.view');
  return coalesce((select jsonb_agg(jsonb_build_object('workflow', workflow, 'last_triggered_at', last_triggered_at,
                     'status_code', last_status_code, 'answered_at', last_response_at, 'error', last_error,
                     'waiting', last_request_id is not null and response_request_id is distinct from last_request_id) order by workflow)
                     from public.n8n_dispatch_state where workflow <> '_kick'), '[]'::jsonb);
end $$;
revoke all on function public.zella_admin_dispatch_responses() from public, anon;
grant execute on function public.zella_admin_dispatch_responses() to authenticated, service_role;

commit;
