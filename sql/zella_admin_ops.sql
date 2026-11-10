-- Zella - Super Admin operations: Voice & numbers, Messaging, Automations (2026-10-29). Safe to re-run.
-- Adds functions only (no tables, no changed rows). Each function:
--   * runs for a signed-in platform admin whose role has the named permission (zella_admin_can), never for anyone else;
--   * filters and pages in the database (lists return { total, rows }, at most 100 rows a call);
--   * leaves message bodies, transcripts and recordings out of lists. Detail calls return content only to admins whose
--     role can manage that channel (telephony.manage / comms.manage), and every content view is written to audit_logs;
--   * writes every change to audit_logs with the admin, the target, before/after and the reason given.
-- Nothing here calls a provider, sends a message or places a call. Retries put the original reminder or task back in
-- the queue: the normal sender re-checks consent, opt-outs, quiet hours and the business, and the per-message dedupe
-- key stops anything already sent or delivered from going twice.
-- Rollback: drop the functions named zella_admin_* below.

-- ---------------------------------------------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_admin_require(p_permission text) returns uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_admin_can(p_permission) then raise exception 'NOT_ALLOWED'; end if;
  return auth.uid();
end $$;

create or replace function public.zella_admin_audit(p_action text, p_entity_type text, p_entity_id uuid, p_business_id uuid,
                                                   p_old jsonb, p_new jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), p_action, p_entity_type, p_entity_id, p_old, p_new);
$$;

-- Numbers and addresses as admins see them in lists: enough to recognise, not to copy.
create or replace function public.zella_admin_mask(p text) returns text
language sql immutable set search_path = '' as $$
  select case when p is null or p = '' then null
              when p like '%@%' then left(split_part(p, '@', 1), 1) || '…@' || split_part(p, '@', 2)
              else '…' || right(regexp_replace(p, '\D', '', 'g'), 4) end;
$$;

create or replace function public.zella_admin_reason(p_reason text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  return left(trim(p_reason), 300);
end $$;

revoke all on function public.zella_admin_require(text), public.zella_admin_audit(text, text, uuid, uuid, jsonb, jsonb),
  public.zella_admin_reason(text) from public, anon, authenticated;
revoke all on function public.zella_admin_mask(text) from public, anon;

-- Business and industry choices for the filters on these pages (names and state only).
create or replace function public.zella_admin_business_options()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_admin_require('businesses.view');
  return jsonb_build_object(
    'businesses', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'industry_id', b.industry_id,
        'state', case when b.cancelled_at is not null then 'cancelled' when b.suspended_at is not null then 'suspended'
                      when coalesce(b.is_active, false) then 'active' else 'setup' end) order by b.name) from public.businesses b), '[]'::jsonb),
    'industries', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) order by i.name) from public.industries i), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Voice & numbers
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_admin_voice_overview(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now());
begin
  perform public.zella_admin_require('businesses.view');
  select jsonb_build_object(
    'inbound', count(*) filter (where direction = 'inbound'),
    'outbound', count(*) filter (where direction = 'outbound'),
    'in_progress', count(*) filter (where status in ('initiated', 'ringing', 'answered') and ended_at is null and created_at > now() - interval '2 hours'),
    'completed', count(*) filter (where status = 'completed'),
    'failed', count(*) filter (where status = 'failed'),
    'missed', count(*) filter (where status = 'missed'),
    'answered', count(*) filter (where answered_at is not null or status = 'completed'),
    'avg_seconds', round(avg(duration_seconds) filter (where duration_seconds > 0)),
    'transfers_failed', count(*) filter (where transfer_status in ('failed', 'no_one_available')))
    into r from public.calls where created_at >= v_from and created_at < v_to;
  return r || jsonb_build_object(
    'from', v_from, 'to', v_to,
    'answer_rate', case when (r ->> 'inbound')::int > 0
                        then round(100.0 * (select count(*) from public.calls where direction = 'inbound' and created_at >= v_from and created_at < v_to
                                                                       and (answered_at is not null or status = 'completed')) / (r ->> 'inbound')::int, 1) end,
    'numbers_active', (select count(*) from public.business_phone_numbers where status = 'active'),
    'numbers_paused', (select count(*) from public.business_phone_numbers where status = 'paused'),
    'numbers_without_vapi', (select count(*) from public.business_phone_numbers where status = 'active' and vapi_phone_number_id is null),
    'providers', coalesce((select jsonb_agg(jsonb_build_object('provider', provider, 'ok', ok, 'detail', left(detail, 200), 'checked_at', checked_at,
                                                               'last_ok_at', last_ok_at, 'failures', consecutive_failures) order by provider)
                             from public.provider_health where provider in ('vapi', 'telnyx')), '[]'::jsonb),
    'checks_live', public.zella_provider_checks_live(),
    'calls_live', coalesce(public.zella_setting('calls_live', 'false'::jsonb) = 'true'::jsonb, false));
end $$;

create or replace function public.zella_admin_numbers(p_q text default null, p_status text default null, p_business uuid default null,
                                                     p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(regexp_replace(coalesce(p_q, ''), '[^0-9A-Za-z +@.-]', '', 'g'), ''); v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select n.*, b.name as business_name, b.timezone, b.suspended_at, b.cancelled_at, b.is_active as business_active,
             (select jsonb_build_object('id', a.id, 'name', a.name, 'status', a.status) from public.ai_agents a
               where a.business_id = n.business_id and a.agent_type = 'receptionist' order by a.is_default desc, a.created_at limit 1) as agent
        from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
       where (p_status is null or n.status = p_status)
         and (p_business is null or n.business_id = p_business)
         and (v_q is null or n.e164 like '%' || regexp_replace(v_q, '\D', '', 'g') || '%' and regexp_replace(v_q, '\D', '', 'g') <> ''
              or b.name ilike '%' || v_q || '%' or coalesce(n.label, '') ilike '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'e164', f.e164, 'country_code', '+' || substring(f.e164 from 2 for case when f.e164 like '+1%' or f.e164 like '+7%' then 1 else 2 end),
        'label', f.label, 'status', f.status, 'vapi_linked', f.vapi_phone_number_id is not null, 'vapi_phone_number_id', f.vapi_phone_number_id,
        'business_id', f.business_id, 'business_name', f.business_name,
        'business_state', case when f.cancelled_at is not null then 'cancelled' when f.suspended_at is not null then 'suspended'
                               when coalesce(f.business_active, false) then 'active' else 'setup' end,
        'agent', f.agent, 'created_at', f.created_at,
        'calls_30d', (select count(*) from public.calls c where c.business_id = f.business_id
                       and (c.to_number = f.e164 or c.from_number = f.e164) and c.created_at > now() - interval '30 days'),
        'last_call_at', (select max(c.created_at) from public.calls c where c.business_id = f.business_id and (c.to_number = f.e164 or c.from_number = f.e164)))
        order by f.created_at desc) from (select * from f order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f), '[]'::jsonb)));
end $$;

-- Releasing a number from Zella: only a paused number, with a typed reason. The number stays with the carrier
-- (Telnyx / Vapi); releasing it there is done in their dashboards, which this says.
create or replace function public.zella_admin_number_release(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n public.business_phone_numbers; v_reason text := public.zella_admin_reason(p_reason); v_recent int;
begin
  perform public.zella_admin_require('telephony.manage');
  select * into n from public.business_phone_numbers where id = p_id for update;
  if n.id is null then raise exception 'NOT_FOUND'; end if;
  if n.status <> 'paused' then raise exception 'PAUSE_FIRST'; end if;
  select count(*) into v_recent from public.calls where business_id = n.business_id and (to_number = n.e164 or from_number = n.e164)
     and created_at > now() - interval '24 hours';
  if v_recent > 0 then raise exception 'RECENT_CALLS'; end if;
  delete from public.business_phone_numbers where id = n.id;
  perform public.zella_admin_audit('telephony.number_released', 'phone_number', n.id, n.business_id,
    jsonb_build_object('e164', n.e164, 'status', n.status, 'vapi_phone_number_id', n.vapi_phone_number_id, 'label', n.label),
    jsonb_build_object('reason', v_reason));
  return jsonb_build_object('released', true, 'e164', n.e164);
end $$;

create or replace function public.zella_admin_calls(p_from timestamptz default null, p_to timestamptz default null, p_business uuid default null,
                                                   p_direction text default null, p_status text default null, p_outcome text default null,
                                                   p_failed_only boolean default false, p_q text default null,
                                                   p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100); v_digits text := nullif(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '');
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select c.* from public.calls c
       where c.created_at >= coalesce(p_from, now() - interval '30 days') and c.created_at < coalesce(p_to, now() + interval '1 minute')
         and (p_business is null or c.business_id = p_business)
         and (p_direction is null or c.direction = p_direction)
         and (p_status is null or c.status = p_status)
         and (p_outcome is null or c.outcome = p_outcome)
         and (not coalesce(p_failed_only, false) or c.status = 'failed' or c.failure_reason is not null or c.transfer_status in ('failed', 'no_one_available'))
         and (v_digits is null or length(v_digits) < 4 or regexp_replace(coalesce(c.from_number, ''), '\D', '', 'g') like '%' || v_digits || '%'
              or regexp_replace(coalesce(c.to_number, ''), '\D', '', 'g') like '%' || v_digits || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'created_at', f.created_at, 'business_id', f.business_id, 'business_name', b.name,
        'direction', f.direction, 'status', f.status, 'caller', public.zella_admin_mask(case when f.direction = 'inbound' then f.from_number else f.to_number end),
        'number', case when f.direction = 'inbound' then f.to_number else f.from_number end,
        'agent', (select a.name from public.ai_agents a where a.business_id = f.business_id and a.agent_type = 'receptionist' order by a.is_default desc limit 1),
        'ai_handled', f.ai_handled, 'duration_seconds', f.duration_seconds, 'outcome', f.outcome, 'transfer_status', f.transfer_status,
        'has_recording', f.recording_url is not null, 'has_transcript', f.transcript is not null, 'failure_reason', f.failure_reason,
        'needs_human', f.needs_human) order by f.created_at desc)
      from (select * from f order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f
      join public.businesses b on b.id = f.business_id), '[]'::jsonb)));
end $$;

-- One call. Transcript, summary and recording link only for admins who can manage telephony, and each such view is
-- recorded in the audit log.
create or replace function public.zella_admin_call_detail(p_call_id uuid, p_with_content boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.calls; v_content boolean;
begin
  perform public.zella_admin_require('businesses.view');
  select * into c from public.calls where id = p_call_id;
  if c.id is null then raise exception 'NOT_FOUND'; end if;
  v_content := coalesce(p_with_content, false) and public.zella_admin_can('telephony.manage');
  if v_content then
    perform public.zella_admin_audit('admin.call_content_viewed', 'call', c.id, c.business_id, null, jsonb_build_object('transcript', c.transcript is not null, 'recording', c.recording_url is not null));
  end if;
  return jsonb_build_object(
    'call', jsonb_build_object('id', c.id, 'business_id', c.business_id, 'business_name', (select name from public.businesses where id = c.business_id),
      'direction', c.direction, 'status', c.status, 'from', public.zella_admin_mask(c.from_number), 'to', public.zella_admin_mask(c.to_number),
      'number', case when c.direction = 'inbound' then c.to_number else c.from_number end,
      'created_at', c.created_at, 'started_at', c.started_at, 'answered_at', c.answered_at, 'ended_at', c.ended_at, 'duration_seconds', c.duration_seconds,
      'ai_handled', c.ai_handled, 'outcome', c.outcome, 'outcome_note', c.outcome_note, 'transfer_status', c.transfer_status,
      'needs_human', c.needs_human, 'escalation_reason', c.escalation_reason, 'escalated_at', c.escalated_at, 'escalation_resolved_at', c.escalation_resolved_at,
      'failure_reason', c.failure_reason, 'failure_context', c.failure_context, 'provider_call_id', c.external_call_id,
      'has_recording', c.recording_url is not null, 'has_transcript', c.transcript is not null),
    'content_allowed', public.zella_admin_can('telephony.manage'),
    'content', case when v_content then jsonb_build_object('summary', c.summary, 'transcript', c.transcript, 'recording_url', c.recording_url) end,
    'tools', coalesce((select jsonb_agg(jsonb_build_object('tool', t.tool, 'status', t.status, 'result', t.result_status, 'verified', t.verified,
                                                           'error', left(t.error, 160), 'at', t.created_at) order by t.created_at)
                         from public.ai_tool_calls t where t.business_id = c.business_id and c.external_call_id is not null
                          and t.provider_call_id = c.external_call_id), '[]'::jsonb),
    'callbacks', coalesce((select jsonb_agg(jsonb_build_object('status', k.status, 'reason', k.reason, 'due_at', k.due_at, 'outcome', k.outcome) order by k.created_at)
                             from public.callbacks k where k.call_id = c.id), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('kind', m.kind, 'status', m.status, 'after_hours', m.after_hours, 'at', m.created_at) order by m.created_at)
                            from public.call_messages m where m.call_id = c.id), '[]'::jsonb),
    'usage', coalesce((select jsonb_agg(jsonb_build_object('kind', u.entry_kind, 'billable_seconds', u.billable_seconds, 'status', u.status, 'at', u.created_at) order by u.created_at)
                         from public.usage_records u where u.call_id = c.id), '[]'::jsonb));
end $$;

-- Call routing for one business: who a caller is put through to. The same rules the phone assistant reads
-- (zella_transfer_destination).
create or replace function public.zella_admin_routing_get(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_agent uuid;
begin
  perform public.zella_admin_require('businesses.view');
  select ag.id, coalesce(cfg.escalation_rules, '{}'::jsonb) into v_agent, r
    from public.ai_agents ag left join public.ai_agent_configs cfg on cfg.agent_id = ag.id
   where ag.business_id = p_business_id and ag.is_default limit 1;
  return jsonb_build_object('business_id', p_business_id, 'has_agent', v_agent is not null,
    'timezone', (select timezone from public.businesses where id = p_business_id),
    'transfer_enabled', coalesce((r ->> 'transfer_enabled')::boolean, true),
    'transfer_number', coalesce(nullif(r ->> 'transfer_number', ''), nullif(r #>> '{transfer_to,phone}', '')),
    'fallback_number', nullif(r ->> 'fallback_number', ''),
    'transfer_route', coalesce(nullif(r ->> 'transfer_route', ''), 'primary'),
    'transfer_open_hours_only', coalesce((r ->> 'transfer_open_hours_only')::boolean, true),
    'on_call', (select jsonb_build_object('enabled', s.enabled, 'scope', s.scope) from public.on_call_settings s where s.business_id = p_business_id),
    'has_hours', exists (select 1 from public.business_hours h where h.business_id = p_business_id));
end $$;

create or replace function public.zella_admin_routing_save(p_business_id uuid, p_rules jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); v_cfg uuid; v_old jsonb; v_new jsonb; v_num text; v_fb text;
begin
  perform public.zella_admin_require('telephony.manage');
  if jsonb_typeof(p_rules) <> 'object' then raise exception 'INVALID_RULES'; end if;
  select cfg.id, coalesce(cfg.escalation_rules, '{}'::jsonb) into v_cfg, v_old
    from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id
   where ag.business_id = p_business_id and ag.is_default limit 1;
  if v_cfg is null then raise exception 'NO_RECEPTIONIST'; end if;
  v_num := nullif(trim(coalesce(p_rules ->> 'transfer_number', '')), '');
  v_fb := nullif(trim(coalesce(p_rules ->> 'fallback_number', '')), '');
  if v_num is not null and public.zella_normalize_e164(v_num) is null then raise exception 'INVALID_TRANSFER_NUMBER'; end if;
  if v_fb is not null and public.zella_normalize_e164(v_fb) is null then raise exception 'INVALID_FALLBACK_NUMBER'; end if;
  if coalesce(p_rules ->> 'transfer_route', 'primary') not in ('primary', 'fallback') then raise exception 'INVALID_ROUTE'; end if;
  if p_rules ->> 'transfer_route' = 'fallback' and v_fb is null then raise exception 'FALLBACK_NEEDS_NUMBER'; end if;
  v_new := v_old
    || jsonb_build_object('transfer_enabled', coalesce((p_rules ->> 'transfer_enabled')::boolean, true),
                          'transfer_number', coalesce(public.zella_normalize_e164(v_num), ''),
                          'fallback_number', coalesce(public.zella_normalize_e164(v_fb), ''),
                          'transfer_route', coalesce(p_rules ->> 'transfer_route', 'primary'),
                          'transfer_open_hours_only', coalesce((p_rules ->> 'transfer_open_hours_only')::boolean, true));
  update public.ai_agent_configs set escalation_rules = v_new, updated_at = now() where id = v_cfg;
  perform public.zella_admin_audit('telephony.routing_updated', 'business', p_business_id, p_business_id,
    jsonb_build_object('transfer_enabled', v_old -> 'transfer_enabled', 'transfer_number', public.zella_admin_mask(v_old ->> 'transfer_number'),
                       'fallback_number', public.zella_admin_mask(v_old ->> 'fallback_number'), 'transfer_route', v_old -> 'transfer_route', 'open_hours_only', v_old -> 'transfer_open_hours_only'),
    jsonb_build_object('transfer_enabled', v_new -> 'transfer_enabled', 'transfer_number', public.zella_admin_mask(v_new ->> 'transfer_number'),
                       'fallback_number', public.zella_admin_mask(v_new ->> 'fallback_number'), 'transfer_route', v_new -> 'transfer_route', 'open_hours_only', v_new -> 'transfer_open_hours_only', 'reason', v_reason));
  return public.zella_admin_routing_get(p_business_id);
end $$;

-- Alerts from real records only. Each has a link target the page understands.
create or replace function public.zella_admin_voice_alerts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; r record;
begin
  perform public.zella_admin_require('businesses.view');
  for r in select provider, detail, consecutive_failures, checked_at from public.provider_health where provider in ('vapi', 'telnyx') and not ok loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'urgent', 'kind', 'provider_down', 'title', initcap(r.provider) || ' connection check failing',
      'detail', coalesce(left(r.detail, 200), '') || ' (' || r.consecutive_failures || ' in a row)', 'at', r.checked_at, 'link', 'providers'));
  end loop;
  for r in select n.e164, b.name from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
            where n.status = 'active' and (b.suspended_at is not null or b.cancelled_at is not null) loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'kind', 'number_on_closed_business', 'title', 'Active number on a suspended or cancelled business',
      'detail', r.e164 || ' (' || r.name || ')', 'link', 'numbers'));
  end loop;
  for r in select n.e164, b.name from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
            where n.status = 'active' and n.vapi_phone_number_id is null loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'kind', 'number_not_linked', 'title', 'Number not linked to Vapi',
      'detail', r.e164 || ' (' || r.name || ') has no Vapi phone number id, so calls to it can''t be matched to the business.', 'link', 'numbers'));
  end loop;
  for r in select b.id, b.name, count(*) total, count(*) filter (where c.status = 'failed' or c.failure_reason is not null) failed
             from public.calls c join public.businesses b on b.id = c.business_id
            where c.created_at > now() - interval '24 hours' group by b.id, b.name
           having count(*) >= 5 and count(*) filter (where c.status = 'failed' or c.failure_reason is not null) * 4 >= count(*) loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'kind', 'high_failure_rate', 'title', 'High call failure rate',
      'detail', r.name || ': ' || r.failed || ' of ' || r.total || ' calls failed in 24 hours', 'business_id', r.id, 'link', 'calls'));
  end loop;
  for r in select b.id, b.name from public.businesses b
            where b.cancelled_at is null and exists (select 1 from public.business_phone_numbers n where n.business_id = b.id and n.status = 'active')
              and not exists (select 1 from public.ai_agents a where a.business_id = b.id and a.agent_type = 'receptionist') loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'kind', 'agent_missing', 'title', 'Number with no AI receptionist',
      'detail', r.name || ' has an active number but no receptionist to answer it.', 'business_id', r.id, 'link', 'numbers'));
  end loop;
  out := out || coalesce((select jsonb_agg(jsonb_build_object('severity', a.severity, 'kind', a.kind, 'title', a.title, 'detail', left(a.detail, 300),
                                                               'at', a.last_seen_at, 'business_id', a.business_id, 'alert_id', a.id, 'link', 'calls'))
                            from public.platform_alerts a where a.status <> 'resolved'
                             and a.kind in ('transfer_failures', 'call_volume_spike', 'stuck_calls', 'call_verification', 'vapi_webhook', 'calls_unverified')), '[]'::jsonb);
  return out;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Messaging
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_admin_messaging_overview(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now()); s jsonb; e jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  select jsonb_build_object('outbound', count(*) filter (where direction = 'outbound'), 'inbound', count(*) filter (where direction = 'inbound'),
      'sent', count(*) filter (where direction = 'outbound' and status in ('sent', 'delivered')), 'delivered', count(*) filter (where status = 'delivered'),
      'failed', count(*) filter (where status = 'failed'), 'queued', count(*) filter (where status = 'queued'), 'test_mode', count(*) filter (where status = 'dry_run'),
      'blocked', count(*) filter (where status = 'blocked'))
    into s from public.sms_messages where created_at >= v_from and created_at < v_to;
  select jsonb_build_object('outbound', count(*) filter (where direction = 'outbound'), 'inbound', count(*) filter (where direction = 'inbound'),
      'accepted', count(*) filter (where direction = 'outbound' and status in ('sent', 'delivered')), 'delivered', count(*) filter (where status = 'delivered'),
      'failed', count(*) filter (where status = 'failed'), 'queued', count(*) filter (where status = 'queued'), 'test_mode', count(*) filter (where status = 'dry_run'),
      'blocked', count(*) filter (where status = 'blocked'))
    into e from public.email_messages where created_at >= v_from and created_at < v_to;
  return jsonb_build_object('from', v_from, 'to', v_to, 'sms', s, 'email', e,
    'sms_delivery_rate', case when (s ->> 'sent')::int > 0 then round(100.0 * (s ->> 'delivered')::int / (s ->> 'sent')::int, 1) end,
    'email_events', coalesce((select jsonb_object_agg(type, n) from (select type, count(*) n from public.email_events where created_at >= v_from and created_at < v_to group by type) x), '{}'::jsonb),
    'waiting', jsonb_build_object(
      'reminders_due', (select count(*) from public.appointment_reminders where status = 'pending' and due_at <= now()),
      'followups_due', (select count(*) from public.followup_tasks where status = 'pending' and channel in ('sms', 'email') and due_at <= now()),
      'reminders_failed_7d', (select count(*) from public.appointment_reminders where status = 'failed' and created_at > now() - interval '7 days'),
      'followups_failed_7d', (select count(*) from public.followup_tasks where status = 'failed' and channel in ('sms', 'email') and updated_at > now() - interval '7 days')),
    'live', jsonb_build_object('sms', coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false),
                               'email', coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false),
                               'sms_sender_set', coalesce(public.zella_setting('sms_from_number', '""'::jsonb) #>> '{}', '') <> '',
                               'email_sender_set', coalesce(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}', '') <> '',
                               'marketing_texts', coalesce(public.zella_setting('sms_marketing_allowed', 'false'::jsonb) = 'true'::jsonb, false)),
    'providers', coalesce((select jsonb_agg(jsonb_build_object('provider', provider, 'ok', ok, 'detail', left(detail, 200), 'checked_at', checked_at,
                                                               'last_ok_at', last_ok_at, 'failures', consecutive_failures) order by provider)
                             from public.provider_health where provider in ('telnyx', 'resend')), '[]'::jsonb),
    'checks_live', public.zella_provider_checks_live());
end $$;

create or replace function public.zella_admin_messages(p_channel text, p_from timestamptz default null, p_to timestamptz default null, p_business uuid default null,
                                                      p_status text default null, p_direction text default null, p_kind text default null, p_q text default null,
                                                      p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100); v_q text := nullif(lower(trim(coalesce(p_q, ''))), '');
        v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now() + interval '1 minute');
begin
  perform public.zella_admin_require('businesses.view');
  if p_channel = 'sms' then
    return (with f as (
        select m.*, case when m.metadata ? 'reminder_id' then 'reminder' when m.metadata ? 'task_id' then 'follow_up'
                         when m.metadata ? 'notification_id' then 'staff_alert' when m.direction = 'inbound' then 'inbound' else 'other' end as kind
          from public.sms_messages m
         where m.created_at >= v_from and m.created_at < v_to and (p_business is null or m.business_id = p_business)
           and (p_status is null or m.status = p_status) and (p_direction is null or m.direction = p_direction)
           and (v_q is null or length(regexp_replace(v_q, '\D', '', 'g')) >= 4 and (regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g') like '%' || regexp_replace(v_q, '\D', '', 'g') || '%'
                or regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g') like '%' || regexp_replace(v_q, '\D', '', 'g') || '%')
                or m.external_message_id = p_q)),
      g as (select * from f where p_kind is null or kind = p_kind)
      select jsonb_build_object('total', (select count(*) from g), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'id', g.id, 'created_at', g.created_at, 'business_id', g.business_id, 'business_name', b.name, 'direction', g.direction, 'status', g.status,
          'to', public.zella_admin_mask(g.to_number), 'from', public.zella_admin_mask(g.from_number), 'kind', g.kind,
          'provider_id', g.external_message_id, 'conversation_id', g.conversation_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,
          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc)
        from (select * from g order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));
  elsif p_channel = 'email' then
    return (with f as (
        select m.*, case when m.metadata ? 'reminder_id' then 'reminder' when m.metadata ? 'task_id' then 'follow_up'
                         when m.metadata ? 'notification_id' then 'owner_email' when m.direction = 'inbound' then 'inbound' else 'other' end as kind
          from public.email_messages m
         where m.created_at >= v_from and m.created_at < v_to and (p_business is null or m.business_id = p_business)
           and (p_status is null or m.status = p_status) and (p_direction is null or m.direction = p_direction)
           and (v_q is null or lower(coalesce(m.to_email, '')) = v_q or lower(coalesce(m.from_email, '')) = v_q
                or lower(coalesce(m.subject, '')) like '%' || v_q || '%' or m.external_message_id = p_q)),
      g as (select * from f where p_kind is null or kind = p_kind)
      select jsonb_build_object('total', (select count(*) from g), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'id', g.id, 'created_at', g.created_at, 'business_id', g.business_id, 'business_name', b.name, 'direction', g.direction, 'status', g.status,
          'to', public.zella_admin_mask(g.to_email), 'from', g.from_email, 'subject', left(g.subject, 120), 'kind', g.kind,
          'provider_id', g.external_message_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,
          'last_event', (select ev.type from public.email_events ev where ev.email_message_id = g.id order by ev.created_at desc limit 1),
          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc)
        from (select * from g order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));
  end if;
  raise exception 'INVALID_CHANNEL';
end $$;

-- Why a failed message can or can't be sent again. Retrying means putting its reminder or follow-up back in the queue.
create or replace function public.zella_admin_message_retry_check(p_channel text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_status text; v_dir text; v_meta jsonb; v_biz uuid; rem record; task record;
begin
  if p_channel = 'sms' then select status, direction, metadata, business_id into v_status, v_dir, v_meta, v_biz from public.sms_messages where id = p_id;
  elsif p_channel = 'email' then select status, direction, metadata, business_id into v_status, v_dir, v_meta, v_biz from public.email_messages where id = p_id;
  else return jsonb_build_object('ok', false, 'why', 'Unknown channel.'); end if;
  if v_status is null then return jsonb_build_object('ok', false, 'why', 'Message not found.'); end if;
  if v_dir <> 'outbound' then return jsonb_build_object('ok', false, 'why', 'Only messages Zella sent can be retried.'); end if;
  if v_status <> 'failed' then return jsonb_build_object('ok', false, 'why', case v_status
      when 'delivered' then 'It was delivered. Sending it again would be a duplicate.'
      when 'sent' then 'The provider accepted it. Sending it again would be a duplicate.'
      when 'queued' then 'It is already waiting to be sent.'
      when 'dry_run' then 'It was recorded in test mode (sending is off). Turn sending on; nothing failed.'
      when 'blocked' then 'It was blocked on purpose (no consent, opt-out or spam rule). Retrying would ignore that.'
      else 'Only failed messages can be retried.' end); end if;
  if exists (select 1 from public.businesses b where b.id = v_biz and (b.suspended_at is not null or b.cancelled_at is not null)) then
    return jsonb_build_object('ok', false, 'why', 'The business is suspended or cancelled.'); end if;
  if v_meta ? 'reminder_id' then
    select r.*, a.status as appt_status, a.start_time into rem from public.appointment_reminders r join public.appointments a on a.id = r.appointment_id
     where r.id = (v_meta ->> 'reminder_id')::uuid;
    if rem.id is null then return jsonb_build_object('ok', false, 'why', 'Its reminder no longer exists.'); end if;
    if rem.status <> 'failed' then return jsonb_build_object('ok', false, 'why', 'Its reminder is ' || rem.status || ', not failed.'); end if;
    if rem.appt_status in ('cancelled', 'completed', 'no_show') then return jsonb_build_object('ok', false, 'why', 'The appointment is ' || rem.appt_status || '.'); end if;
    if rem.start_time <= now() then return jsonb_build_object('ok', false, 'why', 'The appointment has already started; a reminder now would be wrong.'); end if;
    if rem.attempts >= 5 then return jsonb_build_object('ok', false, 'why', 'It has already been tried ' || rem.attempts || ' times.'); end if;
    return jsonb_build_object('ok', true, 'source', 'reminder', 'source_id', rem.id, 'attempts', rem.attempts);
  elsif v_meta ? 'task_id' then
    select * into task from public.followup_tasks where id = (v_meta ->> 'task_id')::uuid;
    if task.id is null then return jsonb_build_object('ok', false, 'why', 'Its follow-up no longer exists.'); end if;
    if task.status <> 'failed' then return jsonb_build_object('ok', false, 'why', 'Its follow-up is ' || task.status || ', not failed.'); end if;
    if task.updated_at < now() - interval '7 days' then return jsonb_build_object('ok', false, 'why', 'It failed more than 7 days ago; it is no longer timely.'); end if;
    return jsonb_build_object('ok', true, 'source', 'follow_up', 'source_id', task.id, 'attempts', task.attempts);
  end if;
  return jsonb_build_object('ok', false, 'why', 'It isn''t linked to a reminder or follow-up Zella can resend safely (for example a staff alert).');
end $$;

create or replace function public.zella_admin_message_detail(p_channel text, p_id uuid, p_with_content boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sms_messages; e public.email_messages; v_content boolean := coalesce(p_with_content, false) and public.zella_admin_can('comms.manage'); out jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  if p_channel = 'sms' then
    select * into s from public.sms_messages where id = p_id;
    if s.id is null then raise exception 'NOT_FOUND'; end if;
    out := jsonb_build_object('message', jsonb_build_object('id', s.id, 'business_id', s.business_id, 'business_name', (select name from public.businesses where id = s.business_id),
        'direction', s.direction, 'status', s.status, 'to', public.zella_admin_mask(s.to_number), 'from', public.zella_admin_mask(s.from_number),
        'provider_id', s.external_message_id, 'created_at', s.created_at, 'sent_at', s.sent_at, 'delivered_at', s.delivered_at, 'updated_at', s.updated_at,
        'conversation_id', s.conversation_id, 'customer_id', s.customer_id,
        'meta', s.metadata - 'body' - 'text'),
      'content', case when v_content then jsonb_build_object('body', s.message_body) end);
    if v_content then perform public.zella_admin_audit('admin.message_content_viewed', 'sms_message', s.id, s.business_id, null, null); end if;
  elsif p_channel = 'email' then
    select * into e from public.email_messages where id = p_id;
    if e.id is null then raise exception 'NOT_FOUND'; end if;
    out := jsonb_build_object('message', jsonb_build_object('id', e.id, 'business_id', e.business_id, 'business_name', (select name from public.businesses where id = e.business_id),
        'direction', e.direction, 'status', e.status, 'to', public.zella_admin_mask(e.to_email), 'from', e.from_email, 'subject', e.subject,
        'provider_id', e.external_message_id, 'created_at', e.created_at, 'sent_at', e.sent_at, 'delivered_at', e.delivered_at, 'updated_at', e.updated_at,
        'conversation_id', e.conversation_id, 'customer_id', e.customer_id, 'meta', e.metadata),
      'events', coalesce((select jsonb_agg(jsonb_build_object('type', ev.type, 'at', ev.created_at, 'detail', ev.detail - 'to' - 'from' - 'email') order by ev.created_at)
                            from public.email_events ev where ev.email_message_id = e.id), '[]'::jsonb),
      'content', case when v_content then jsonb_build_object('body', e.body_text) end);
    if v_content then perform public.zella_admin_audit('admin.message_content_viewed', 'email_message', e.id, e.business_id, null, null); end if;
  else raise exception 'INVALID_CHANNEL'; end if;
  return out || jsonb_build_object('content_allowed', public.zella_admin_can('comms.manage'), 'retry', public.zella_admin_message_retry_check(p_channel, p_id));
end $$;

create or replace function public.zella_admin_message_retry(p_channel text, p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); chk jsonb; v_biz uuid;
begin
  perform public.zella_admin_require('comms.manage');
  chk := public.zella_admin_message_retry_check(p_channel, p_id);
  if not (chk ->> 'ok')::boolean then raise exception 'NOT_RETRYABLE: %', chk ->> 'why'; end if;
  if chk ->> 'source' = 'reminder' then
    update public.appointment_reminders set status = 'pending', due_at = now(), error = null where id = (chk ->> 'source_id')::uuid and status = 'failed'
    returning business_id into v_biz;
  else
    update public.followup_tasks set status = 'pending', due_at = now(), max_attempts = greatest(max_attempts, attempts + 1), outcome = null,
           completed_at = null, updated_at = now() where id = (chk ->> 'source_id')::uuid and status = 'failed'
    returning business_id into v_biz;
  end if;
  if v_biz is null then raise exception 'NOT_RETRYABLE: it changed while you were looking; reload.'; end if;
  perform public.zella_admin_audit('comms.message_retried', p_channel || '_message', p_id, v_biz, jsonb_build_object('status', 'failed'),
    jsonb_build_object('requeued', chk ->> 'source', 'source_id', chk ->> 'source_id', 'reason', v_reason));
  return jsonb_build_object('requeued', true, 'source', chk ->> 'source');
end $$;

-- Templates: the platform defaults (no business) and per-industry versions. Business copies are listed read-only.
create or replace function public.zella_admin_template_variables(p_key text, p_channel text) returns text[]
language sql stable security definer set search_path = public as $$
  select array(select distinct v from (
      select (regexp_matches(coalesce(t.body, '') || ' ' || coalesce(t.subject, ''), '\{\{\s*([a-z_]+)\s*\}\}', 'g'))[1] v
        from public.message_templates t where t.key = p_key and t.channel = p_channel
      union all select unnest(array['first_name', 'business'])) x order by 1);
$$;

create or replace function public.zella_admin_templates(p_q text default null, p_channel text default null, p_scope text default 'platform',
                                                       p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(lower(trim(coalesce(p_q, ''))), ''); v_lim int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select t.*, i.name as industry_name, b.name as business_name from public.message_templates t
        left join public.industries i on i.id = t.industry_id left join public.businesses b on b.id = t.business_id
       where t.status = 'active' and (p_channel is null or t.channel = p_channel)
         and case coalesce(p_scope, 'platform') when 'platform' then t.business_id is null when 'business' then t.business_id is not null else true end
         and (v_q is null or t.key like '%' || v_q || '%' or lower(t.body) like '%' || v_q || '%' or lower(coalesce(t.subject, '')) like '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'can_edit', public.zella_admin_can('comms.manage'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'key', f.key, 'channel', f.channel, 'purpose', f.purpose, 'locale', f.locale,
          'subject', f.subject, 'body', f.body, 'version', f.version, 'status', f.status, 'created_at', f.created_at,
          'scope', case when f.business_id is not null then 'business' when f.industry_id is not null then 'industry' else 'platform' end,
          'industry_id', f.industry_id, 'industry_name', f.industry_name, 'business_id', f.business_id, 'business_name', f.business_name,
          'variables', public.zella_admin_template_variables(f.key, f.channel),
          'business_copies', (select count(*) from public.message_templates x where x.key = f.key and x.channel = f.channel and x.business_id is not null and x.status = 'active'))
          order by f.key, f.channel, f.industry_name nulls first)
        from (select * from f order by key, channel limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f), '[]'::jsonb)));
end $$;

-- Saving a platform or industry template makes a new version and archives the old one; business copies are never
-- touched. Variables must be ones this message type already supports.
create or replace function public.zella_admin_template_save(p_id uuid, p_subject text, p_body text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.message_templates; v_reason text := public.zella_admin_reason(p_reason); v_allowed text[]; v_bad text[]; v_new uuid;
        v_body text := trim(coalesce(p_body, '')); v_subject text := nullif(trim(coalesce(p_subject, '')), '');
begin
  perform public.zella_admin_require('comms.manage');
  select * into t from public.message_templates where id = p_id for update;
  if t.id is null or t.status <> 'active' then raise exception 'NOT_FOUND'; end if;
  if t.business_id is not null then raise exception 'BUSINESS_TEMPLATE'; end if;
  if length(v_body) < 1 or length(v_body) > 1600 then raise exception 'BODY_LENGTH'; end if;
  if t.channel = 'email' and v_subject is null then raise exception 'SUBJECT_REQUIRED'; end if;
  if v_body ~ '<script|javascript:' then raise exception 'BODY_TEXT'; end if;
  if t.channel = 'sms' and t.purpose = 'marketing' and v_body !~* 'stop' then raise exception 'SMS_NEEDS_STOP'; end if;
  v_allowed := public.zella_admin_template_variables(t.key, t.channel);
  select array_agg(distinct v) into v_bad from (select (regexp_matches(v_body || ' ' || coalesce(v_subject, ''), '\{\{\s*([^}]*?)\s*\}\}', 'g'))[1] v) x
   where not (v = any (v_allowed));
  if v_bad is not null then raise exception 'UNKNOWN_VARIABLES: %', array_to_string(v_bad, ', '); end if;
  if v_body = t.body and v_subject is not distinct from t.subject then raise exception 'NO_CHANGE'; end if;
  update public.message_templates set status = 'archived' where id = t.id;
  insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status, created_by)
  values (null, t.industry_id, t.key, t.channel, t.purpose, t.locale, case when t.channel = 'email' then v_subject end, v_body,
          (select coalesce(max(version), 0) + 1 from public.message_templates where business_id is null and industry_id is not distinct from t.industry_id
             and key = t.key and channel = t.channel and locale = t.locale), 'active', auth.uid())
  returning id into v_new;
  perform public.zella_admin_audit('comms.template_updated', 'message_template', v_new, null,
    jsonb_build_object('id', t.id, 'key', t.key, 'channel', t.channel, 'version', t.version, 'subject', t.subject, 'body', t.body),
    jsonb_build_object('key', t.key, 'channel', t.channel, 'subject', v_subject, 'body', v_body, 'reason', v_reason));
  return jsonb_build_object('id', v_new, 'key', t.key, 'channel', t.channel);
end $$;

create or replace function public.zella_admin_messaging_compliance()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_admin_require('businesses.view');
  return jsonb_build_object(
    'opt_outs', coalesce((select jsonb_object_agg(channel, n) from (select channel, count(*) n from public.contact_consents where status = 'opted_out' group by channel) x), '{}'::jsonb),
    'consents', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.contact_consents group by status) x), '{}'::jsonb),
    'blocked_30d', jsonb_build_object('sms', (select count(*) from public.sms_messages where status = 'blocked' and created_at > now() - interval '30 days'),
                                      'email', (select count(*) from public.email_messages where status = 'blocked' and created_at > now() - interval '30 days')),
    'suppressed_emails', (select count(*) from public.customers where coalesce(do_not_email, false)),
    'do_not_contact', (select count(*) from public.customers where coalesce(do_not_contact, false)),
    'marketing_texts_allowed', coalesce(public.zella_setting('sms_marketing_allowed', 'false'::jsonb) = 'true'::jsonb, false),
    'spam_blocks', (select count(*) from public.spam_list_entries where removed_at is null and channel in ('sms', 'email', 'all')));
end $$;

create or replace function public.zella_admin_messaging_alerts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; r record;
begin
  perform public.zella_admin_require('businesses.view');
  for r in select provider, detail, consecutive_failures, checked_at from public.provider_health where provider in ('telnyx', 'resend') and not ok loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'urgent', 'title', initcap(r.provider) || ' connection check failing', 'detail', left(r.detail, 200), 'at', r.checked_at, 'link', 'providers'));
  end loop;
  if coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false) and coalesce(public.zella_setting('sms_from_number', '""'::jsonb) #>> '{}', '') = '' then
    out := out || jsonb_build_array(jsonb_build_object('severity', 'urgent', 'title', 'Texts are on but no sender number is set', 'detail', 'Every text will fail until sms_from_number is set.', 'link', 'providers'));
  end if;
  if coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false) and coalesce(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}', '') = '' then
    out := out || jsonb_build_array(jsonb_build_object('severity', 'urgent', 'title', 'Emails are on but no sender address is set', 'detail', 'Every email will fail until email_from_address is set.', 'link', 'providers'));
  end if;
  for r in select 'sms' ch, count(*) total, count(*) filter (where status = 'failed') failed from public.sms_messages where direction = 'outbound' and created_at > now() - interval '24 hours'
           union all select 'email', count(*), count(*) filter (where status = 'failed') from public.email_messages where direction = 'outbound' and created_at > now() - interval '24 hours' loop
    if r.total >= 10 and r.failed * 5 >= r.total then
      out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'title', 'High ' || case when r.ch = 'sms' then 'text' else 'email' end || ' failure rate',
        'detail', r.failed || ' of ' || r.total || ' failed in 24 hours', 'link', r.ch));
    end if;
  end loop;
  if (select count(*) from public.appointment_reminders where status = 'pending' and due_at < now() - interval '30 minutes') > 0 then
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'title', 'Reminders not going out',
      'detail', (select count(*) from public.appointment_reminders where status = 'pending' and due_at < now() - interval '30 minutes') || ' reminders are more than 30 minutes overdue. The scheduler or n8n may be off.', 'link', 'scheduler'));
  end if;
  if (select count(*) from public.email_events where type in ('email.bounced', 'bounced') and created_at > now() - interval '7 days') >= 5 then
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'title', 'Repeated email bounces',
      'detail', (select count(*) from public.email_events where type in ('email.bounced', 'bounced') and created_at > now() - interval '7 days') || ' bounces in 7 days', 'link', 'email'));
  end if;
  out := out || coalesce((select jsonb_agg(jsonb_build_object('severity', a.severity, 'title', a.title, 'detail', left(a.detail, 300), 'at', a.last_seen_at,
                                                               'business_id', a.business_id, 'alert_id', a.id, 'link', 'sms'))
                            from public.platform_alerts a where a.status <> 'resolved' and a.kind in ('sms_failures', 'email_failures', 'message_failures', 'resend_webhook')), '[]'::jsonb);
  return out;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Automations
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_admin_automation_overview(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now()); w jsonb; r jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  select jsonb_build_object('succeeded', count(*) filter (where status = 'succeeded'), 'failed', count(*) filter (where status = 'failed'),
      'running', count(*) filter (where status = 'running'), 'avg_seconds', round(avg(extract(epoch from finished_at - started_at)) filter (where finished_at is not null)::numeric, 1),
      'needs_manual', count(*) filter (where needs_manual))
    into w from public.workflow_executions where started_at >= v_from and started_at < v_to;
  select jsonb_build_object('completed', count(*) filter (where status = 'completed'), 'failed', count(*) filter (where status = 'failed'),
      'running', count(*) filter (where status in ('running', 'queued', 'waiting')))
    into r from public.automation_runs where created_at >= v_from and created_at < v_to;
  return jsonb_build_object('from', v_from, 'to', v_to,
    'automations', (select jsonb_build_object('total', count(*), 'active', count(*) filter (where status = 'active'), 'paused', count(*) filter (where status = 'paused'),
                                              'disabled', count(*) filter (where status = 'disabled')) from public.automations),
    'workflows', w, 'runs', r,
    'waiting', jsonb_build_object('followups', (select count(*) from public.followup_tasks where status = 'pending'),
                                  'reminders', (select count(*) from public.appointment_reminders where status = 'pending'),
                                  'events', (select count(*) from public.automation_events where status in ('received', 'processing'))),
    'success_rate', case when (w ->> 'succeeded')::int + (w ->> 'failed')::int > 0
                         then round(100.0 * (w ->> 'succeeded')::int / ((w ->> 'succeeded')::int + (w ->> 'failed')::int), 1) end,
    'latest_failure', (select jsonb_build_object('at', started_at, 'workflow', workflow_key, 'error', left(error_message, 200))
                         from public.workflow_executions where status = 'failed' order by started_at desc limit 1),
    'dead_letters_open', (select count(*) from public.automation_dead_letters where status <> 'resolved'));
end $$;

create or replace function public.zella_admin_automations(p_q text default null, p_status text default null, p_trigger text default null,
                                                         p_business uuid default null, p_industry uuid default null,
                                                         p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(lower(trim(coalesce(p_q, ''))), ''); v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select a.*, b.name as business_name, b.industry_id, i.name as industry_name, b.is_active as business_live, b.suspended_at
        from public.automations a join public.businesses b on b.id = a.business_id left join public.industries i on i.id = b.industry_id
       where (p_status is null or a.status = p_status) and (p_trigger is null or a.trigger_type = p_trigger)
         and (p_business is null or a.business_id = p_business) and (p_industry is null or b.industry_id = p_industry)
         and (v_q is null or lower(a.name) like '%' || v_q || '%' or lower(b.name) like '%' || v_q || '%' or a.trigger_type like '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f),
      'triggers', (select coalesce(jsonb_agg(distinct trigger_type), '[]'::jsonb) from public.automations),
      'can_manage', public.zella_admin_can('integrations.manage'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'description', f.description, 'scope', 'business',
          'trigger_type', f.trigger_type, 'status', f.status, 'business_id', f.business_id, 'business_name', f.business_name,
          'industry_name', f.industry_name, 'business_live', coalesce(f.business_live, false), 'business_suspended', f.suspended_at is not null,
          'paused_by_suspension', f.paused_by_suspension, 'updated_at', f.updated_at, 'created_at', f.created_at,
          'runs', (select jsonb_build_object('total', count(*), 'failed', count(*) filter (where r.status = 'failed'), 'last_at', max(r.created_at),
                                             'last_status', (select r2.status from public.automation_runs r2 where r2.automation_id = f.id order by r2.created_at desc limit 1))
                     from public.automation_runs r where r.automation_id = f.id))
          order by f.business_name, f.name)
        from (select * from f order by business_name, name limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f), '[]'::jsonb)));
end $$;

-- The work an automation type puts in the queue: follow-ups and reminders for that business.
create or replace function public.zella_admin_automation_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.automations; v_kinds text[];
begin
  perform public.zella_admin_require('businesses.view');
  select * into a from public.automations where id = p_id;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  v_kinds := case a.trigger_type when 'appointment_followup' then array['post_appointment_follow_up'] when 'missed_call_follow_up' then array['missed_call_follow_up', 'callback_sms']
                                 when 'new_lead_callback' then array['lead_follow_up', 'lead_final_follow_up'] else array[a.trigger_type] end;
  return jsonb_build_object(
    'automation', jsonb_build_object('id', a.id, 'name', a.name, 'description', a.description, 'trigger_type', a.trigger_type, 'status', a.status,
      'trigger_config', a.trigger_config, 'actions', a.actions, 'conditions', a.conditions, 'paused_by_suspension', a.paused_by_suspension,
      'created_at', a.created_at, 'updated_at', a.updated_at, 'created_by', a.created_by,
      'business_id', a.business_id, 'business_name', (select name from public.businesses where id = a.business_id),
      'business_live', (select coalesce(is_active, false) from public.businesses where id = a.business_id)),
    'can_manage', public.zella_admin_can('integrations.manage'),
    'queue', jsonb_build_object(
      'followups', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.followup_tasks where business_id = a.business_id and kind = any (v_kinds) group by status) x),
      'reminders', case when a.trigger_type in ('appointment_reminder', 'appointment_confirmation')
                        then (select jsonb_object_agg(status, n) from (select status, count(*) n from public.appointment_reminders where business_id = a.business_id
                                                                        and kind = case when a.trigger_type = 'appointment_reminder' then 'reminder' else 'confirmation_request' end group by status) x) end),
    'runs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'created_at', r.created_at, 'completed_at', r.completed_at,
                                                           'error', left(r.error_message, 200), 'attempts', r.attempt_count) order by r.created_at desc)
                        from (select * from public.automation_runs where automation_id = a.id order by created_at desc limit 20) r), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('action', l.action, 'at', l.created_at, 'old', l.old_data, 'new', l.new_data) order by l.created_at desc)
                           from (select * from public.audit_logs where entity_id = a.id order by created_at desc limit 20) l), '[]'::jsonb));
end $$;

-- Pause, resume or archive one business's automation. Resuming starts real messages for that business, so it needs
-- the business to be live and not suspended.
create or replace function public.zella_admin_automation_set_status(p_id uuid, p_status text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.automations; v_reason text := public.zella_admin_reason(p_reason); b public.businesses;
begin
  perform public.zella_admin_require('integrations.manage');
  if p_status not in ('active', 'paused', 'disabled') then raise exception 'INVALID_STATUS'; end if;
  select * into a from public.automations where id = p_id for update;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  if a.status = p_status then raise exception 'NO_CHANGE'; end if;
  select * into b from public.businesses where id = a.business_id;
  if p_status = 'active' and (b.suspended_at is not null or b.cancelled_at is not null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if p_status = 'active' and not coalesce(b.is_active, false) then raise exception 'BUSINESS_NOT_LIVE'; end if;
  update public.automations set status = p_status, paused_by_suspension = false, updated_at = now() where id = a.id;
  perform public.zella_admin_audit('automation.' || case p_status when 'active' then 'resumed' when 'paused' then 'paused' else 'archived' end,
    'automation', a.id, a.business_id, jsonb_build_object('status', a.status), jsonb_build_object('status', p_status, 'reason', v_reason));
  return jsonb_build_object('id', a.id, 'status', p_status);
end $$;

-- A scoped stop: every active automation of one business is paused (nothing else on the platform changes).
create or replace function public.zella_admin_business_automations_pause(p_business_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); v_ids uuid[];
begin
  perform public.zella_admin_require('integrations.manage');
  with u as (update public.automations set status = 'paused', updated_at = now() where business_id = p_business_id and status = 'active' returning id)
  select array_agg(id) into v_ids from u;
  perform public.zella_admin_audit('automation.business_paused', 'business', p_business_id, p_business_id, null,
    jsonb_build_object('paused', coalesce(cardinality(v_ids), 0), 'reason', v_reason));
  return jsonb_build_object('paused', coalesce(cardinality(v_ids), 0));
end $$;

-- Runs: n8n workflow executions (each started by an event) and in-database automation runs, in one list.
create or replace function public.zella_admin_runs(p_status text default null, p_business uuid default null, p_q text default null,
                                                  p_from timestamptz default null, p_to timestamptz default null,
                                                  p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100); v_q text := nullif(lower(trim(coalesce(p_q, ''))), '');
        v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now() + interval '1 minute');
begin
  perform public.zella_admin_require('businesses.view');
  return (with u as (
      select 'workflow' as kind, w.id, w.business_id, w.workflow_key as name, w.status, w.started_at, w.finished_at, w.current_step as failed_step,
             w.error_category, left(w.error_message, 200) as error, w.retry_count as attempts, w.needs_manual, w.event_id
        from public.workflow_executions w where w.started_at >= v_from and w.started_at < v_to
      union all
      select 'run', r.id, r.business_id, a.name, case r.status when 'completed' then 'succeeded' when 'queued' then 'running' when 'waiting' then 'running' else r.status end,
             coalesce(r.started_at, r.created_at), r.completed_at, r.last_action_status, null, left(r.error_message, 200), r.attempt_count, false, null
        from public.automation_runs r join public.automations a on a.id = r.automation_id where r.created_at >= v_from and r.created_at < v_to),
    f as (select * from u where (p_status is null or status = p_status) and (p_business is null or business_id = p_business)
            and (v_q is null or lower(name) like '%' || v_q || '%' or lower(coalesce(error, '')) like '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', f.kind, 'id', f.id, 'name', f.name, 'business_id', f.business_id, 'business_name', b.name, 'status', f.status,
        'started_at', f.started_at, 'finished_at', f.finished_at, 'duration_seconds', round(extract(epoch from f.finished_at - f.started_at)::numeric, 1),
        'failed_step', case when f.status = 'failed' then f.failed_step end, 'error_category', f.error_category, 'error', f.error,
        'attempts', f.attempts, 'needs_manual', f.needs_manual) order by f.started_at desc)
      from (select * from f order by started_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f left join public.businesses b on b.id = f.business_id), '[]'::jsonb)));
end $$;

-- Whether a failed run can be started again without repeating something that already happened.
create or replace function public.zella_admin_run_retry_check(p_kind text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w public.workflow_executions; e public.automation_events; v_done int;
begin
  if p_kind <> 'workflow' then return jsonb_build_object('ok', false, 'why', 'In-database automation runs retry themselves on their own schedule.'); end if;
  select * into w from public.workflow_executions where id = p_id;
  if w.id is null then return jsonb_build_object('ok', false, 'why', 'Run not found.'); end if;
  if w.status <> 'failed' then return jsonb_build_object('ok', false, 'why', 'Only failed runs can be retried.'); end if;
  select count(*) into v_done from jsonb_array_elements(case when jsonb_typeof(w.steps) = 'array' then w.steps else '[]'::jsonb end) s
   where s ->> 'status' in ('succeeded', 'done', 'ok', 'sent');
  if v_done > 0 then return jsonb_build_object('ok', false, 'why', v_done || ' step(s) already succeeded (for example a message went out). Running it again could repeat them; fix the cause and handle the rest by hand.'); end if;
  if jsonb_typeof(w.provider_refs) = 'object' and w.provider_refs <> '{}'::jsonb then
    return jsonb_build_object('ok', false, 'why', 'A provider already received a request for this run, so it may have acted. Check the provider first.'); end if;
  if w.event_id is null then return jsonb_build_object('ok', false, 'why', 'It wasn''t started by a stored event, so there is nothing to replay.'); end if;
  select * into e from public.automation_events where id = w.event_id;
  if e.id is null then return jsonb_build_object('ok', false, 'why', 'Its event is no longer stored.'); end if;
  if e.status not in ('failed', 'rejected') then return jsonb_build_object('ok', false, 'why', 'Its event is ' || e.status || ', so it is already handled or waiting.'); end if;
  if exists (select 1 from public.workflow_executions x where x.event_id = w.event_id and x.status in ('running', 'succeeded') and x.id <> w.id) then
    return jsonb_build_object('ok', false, 'why', 'Another run of the same event already ran or is running.'); end if;
  return jsonb_build_object('ok', true, 'event_id', e.id);
end $$;

create or replace function public.zella_admin_run_detail(p_kind text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w public.workflow_executions; r public.automation_runs;
begin
  perform public.zella_admin_require('businesses.view');
  if p_kind = 'workflow' then
    select * into w from public.workflow_executions where id = p_id;
    if w.id is null then raise exception 'NOT_FOUND'; end if;
    return jsonb_build_object('kind', 'workflow', 'run', jsonb_build_object('id', w.id, 'name', w.workflow_key, 'version', w.workflow_version, 'status', w.status,
        'business_id', w.business_id, 'business_name', (select name from public.businesses where id = w.business_id), 'started_at', w.started_at, 'finished_at', w.finished_at,
        'current_step', w.current_step, 'error_category', w.error_category, 'error', w.error_message, 'attempts', w.retry_count, 'needs_manual', w.needs_manual,
        'correlation_id', w.correlation_id, 'providers_called', case when jsonb_typeof(w.provider_refs) = 'object' then (select jsonb_agg(k) from jsonb_object_keys(w.provider_refs) k) end),
      -- Step names, outcomes and timings only: step inputs and outputs can hold customer data.
      'steps', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(s ->> 'name', s ->> 'step'), 'status', s ->> 'status', 'at', coalesce(s ->> 'at', s ->> 'finished_at'),
                                                             'error', left(coalesce(s ->> 'error', ''), 200)))
                           from jsonb_array_elements(case when jsonb_typeof(w.steps) = 'array' then w.steps else '[]'::jsonb end) s), '[]'::jsonb),
      'event', (select jsonb_build_object('type', e.event_type, 'source', e.source, 'status', e.status, 'received_at', e.received_at, 'processed_at', e.processed_at,
                                          'attempts', e.attempts, 'error', left(e.error_message, 200)) from public.automation_events e where e.id = w.event_id),
      'dead_letter', (select jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'resolved_at', d.resolved_at)
                        from public.automation_dead_letters d where d.event_id = w.event_id order by d.created_at desc limit 1),
      'retry', public.zella_admin_run_retry_check('workflow', w.id));
  elsif p_kind = 'run' then
    select * into r from public.automation_runs where id = p_id;
    if r.id is null then raise exception 'NOT_FOUND'; end if;
    return jsonb_build_object('kind', 'run', 'run', jsonb_build_object('id', r.id, 'name', (select name from public.automations where id = r.automation_id), 'automation_id', r.automation_id,
        'status', r.status, 'business_id', r.business_id, 'business_name', (select name from public.businesses where id = r.business_id),
        'started_at', coalesce(r.started_at, r.created_at), 'finished_at', r.completed_at, 'current_step', r.current_action_index, 'last_action_status', r.last_action_status,
        'error', r.error_message, 'attempts', r.attempt_count, 'next_run_at', r.next_run_at),
      'steps', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(s ->> 'action', s ->> 'type', s ->> 'name'), 'status', s ->> 'status', 'at', s ->> 'at',
                                                             'error', left(coalesce(s ->> 'error', ''), 200)))
                           from jsonb_array_elements(case when jsonb_typeof(r.execution_log) = 'array' then r.execution_log else '[]'::jsonb end) s), '[]'::jsonb),
      'retry', public.zella_admin_run_retry_check('run', r.id));
  end if;
  raise exception 'INVALID_KIND';
end $$;

-- Replays the event a failed run started from, once: the event router claims it again; the original run stays as it was.
create or replace function public.zella_admin_run_retry(p_kind text, p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); chk jsonb; v_biz uuid;
begin
  perform public.zella_admin_require('integrations.manage');
  chk := public.zella_admin_run_retry_check(p_kind, p_id);
  if not (chk ->> 'ok')::boolean then raise exception 'NOT_RETRYABLE: %', chk ->> 'why'; end if;
  update public.automation_events set status = 'received', next_attempt_at = now(), claimed_at = null, error_category = null, error_message = null
   where id = (chk ->> 'event_id')::uuid and status in ('failed', 'rejected') returning business_id into v_biz;
  if v_biz is null then raise exception 'NOT_RETRYABLE: it changed while you were looking; reload.'; end if;
  perform public.zella_admin_audit('automation.run_retried', 'workflow_execution', p_id, v_biz, jsonb_build_object('status', 'failed'),
    jsonb_build_object('event_id', chk ->> 'event_id', 'reason', v_reason));
  return jsonb_build_object('requeued', true);
end $$;

-- Marks a failure as looked at: its dead letter is resolved (the run itself is never edited).
create or replace function public.zella_admin_run_reviewed(p_kind text, p_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_note text := public.zella_admin_reason(p_note); w public.workflow_executions; v_n int;
begin
  perform public.zella_admin_require('integrations.manage');
  if p_kind <> 'workflow' then raise exception 'INVALID_KIND'; end if;
  select * into w from public.workflow_executions where id = p_id;
  if w.id is null then raise exception 'NOT_FOUND'; end if;
  update public.automation_dead_letters set status = 'resolved', resolved_by = auth.uid(), resolved_at = now()
   where event_id = w.event_id and status <> 'resolved';
  get diagnostics v_n = row_count;
  if w.needs_manual then update public.workflow_executions set needs_manual = false where id = w.id; end if;
  perform public.zella_admin_audit('automation.failure_reviewed', 'workflow_execution', w.id, w.business_id, null, jsonb_build_object('dead_letters_resolved', v_n, 'note', v_note));
  return jsonb_build_object('reviewed', true, 'dead_letters_resolved', v_n);
end $$;

create or replace function public.zella_admin_automation_templates(p_q text default null, p_industry text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(lower(trim(coalesce(p_q, ''))), '');
begin
  perform public.zella_admin_require('businesses.view');
  return jsonb_build_object(
    'industries', (select coalesce(jsonb_agg(distinct industry_key), '[]'::jsonb) from public.industry_automation_presets),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'description', p.description, 'industry_key', p.industry_key,
        'trigger_type', p.trigger_type, 'settings', p.trigger_config, 'checklist_no', p.checklist_no,
        'in_use', (select count(*) from public.automations a where a.name = p.name),
        'active', (select count(*) from public.automations a where a.name = p.name and a.status = 'active')) order by p.industry_key, p.checklist_no nulls last, p.name)
      from public.industry_automation_presets p
     where (p_industry is null or p.industry_key = p_industry)
       and (v_q is null or lower(p.name) like '%' || v_q || '%' or lower(coalesce(p.description, '')) like '%' || v_q || '%')), '[]'::jsonb));
end $$;

create or replace function public.zella_admin_scheduler_health()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_jobs jsonb := '[]'::jsonb; v_secret boolean := false;
begin
  perform public.zella_admin_require('businesses.view');
  if to_regclass('cron.job') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('name', j.jobname, 'schedule', j.schedule, 'active', j.active,
                   'last_run', (select jsonb_build_object('status', d.status, 'at', d.end_time, 'message', left(d.return_message, 160))
                                  from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1),
                   'last_success', (select max(d.end_time) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'succeeded'),
                   'failures_24h', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' and d.start_time > now() - interval '24 hours'))
                   order by j.jobname), '[]'::jsonb) from cron.job j where j.jobname like 'zella%'$q$ into v_jobs;
  end if;
  if to_regclass('vault.secrets') is not null then
    execute $q$select exists (select 1 from vault.secrets where name = 'zella_n8n_secret')$q$ into v_secret;
  end if;
  return jsonb_build_object('jobs', v_jobs, 'n8n_secret_stored', v_secret,
    'n8n_address_set', coalesce(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}', '') <> '',
    'dispatch_switch', coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true),
    'dispatch', coalesce((select jsonb_agg(jsonb_build_object('workflow', workflow, 'last_triggered_at', last_triggered_at, 'waiting', last_count,
                                                              'stuck', consecutive_same >= 12, 'total', triggers_total) order by workflow)
                            from public.n8n_dispatch_state where workflow <> '_kick'), '[]'::jsonb),
    'overdue', jsonb_build_object('reminders', (select count(*) from public.appointment_reminders where status = 'pending' and due_at < now() - interval '15 minutes'),
                                  'followups', (select count(*) from public.followup_tasks where status = 'pending' and due_at < now() - interval '15 minutes'),
                                  'events', (select count(*) from public.automation_events where status = 'received' and coalesce(next_attempt_at, received_at) < now() - interval '15 minutes')),
    'failed_24h', jsonb_build_object('workflows', (select count(*) from public.workflow_executions where status = 'failed' and started_at > now() - interval '24 hours'),
                                     'events', (select count(*) from public.automation_events where status = 'failed' and received_at > now() - interval '24 hours')),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('severity', a.severity, 'kind', a.kind, 'title', a.title, 'detail', left(a.detail, 300), 'at', a.last_seen_at, 'business_id', a.business_id))
                          from public.platform_alerts a where a.status <> 'resolved'
                           and a.kind in ('scheduler_failed', 'automation_heartbeat', 'automation_stalled', 'queue_backlog', 'integration_disconnected', 'workflow_failed', 'dead_letter')), '[]'::jsonb));
end $$;

-- Who may call what: signed-in users only (each function checks the admin permission itself).
do $$
declare f text;
begin
  foreach f in array array[
    'zella_admin_business_options()', 'zella_admin_voice_overview(timestamptz,timestamptz)', 'zella_admin_numbers(text,text,uuid,integer,integer)', 'zella_admin_number_release(uuid,text)',
    'zella_admin_calls(timestamptz,timestamptz,uuid,text,text,text,boolean,text,integer,integer)', 'zella_admin_call_detail(uuid,boolean)',
    'zella_admin_routing_get(uuid)', 'zella_admin_routing_save(uuid,jsonb,text)', 'zella_admin_voice_alerts()',
    'zella_admin_messaging_overview(timestamptz,timestamptz)', 'zella_admin_messages(text,timestamptz,timestamptz,uuid,text,text,text,text,integer,integer)',
    'zella_admin_message_detail(text,uuid,boolean)', 'zella_admin_message_retry(text,uuid,text)', 'zella_admin_templates(text,text,text,integer,integer)',
    'zella_admin_template_save(uuid,text,text,text)', 'zella_admin_messaging_compliance()', 'zella_admin_messaging_alerts()',
    'zella_admin_automation_overview(timestamptz,timestamptz)', 'zella_admin_automations(text,text,text,uuid,uuid,integer,integer)',
    'zella_admin_automation_detail(uuid)', 'zella_admin_automation_set_status(uuid,text,text)', 'zella_admin_business_automations_pause(uuid,text)',
    'zella_admin_runs(text,uuid,text,timestamptz,timestamptz,integer,integer)', 'zella_admin_run_detail(text,uuid)', 'zella_admin_run_retry(text,uuid,text)',
    'zella_admin_run_reviewed(text,uuid,text)', 'zella_admin_automation_templates(text,text)', 'zella_admin_scheduler_health()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['zella_admin_message_retry_check(text,uuid)', 'zella_admin_run_retry_check(text,uuid)', 'zella_admin_template_variables(text,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
