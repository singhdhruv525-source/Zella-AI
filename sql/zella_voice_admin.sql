-- Zella Voice: the Voice page shows refused Vapi requests, the switches calls depend on, a missed call alert and the
-- voice alerts that are really raised (docs/ADMIN_AUDIT_2026-11-16.md COM-09, COM-13, UI-14, COM-08).
--   1. vapi_refusals: an hourly counter of Vapi requests that failed the sign in check, by message type, reason and the
--      auth header NAMES present. Never a value, a payload or content. One row per hour and combination (an upsert),
--      and every input is reduced to a short known list, so a flood of refusals can't grow the table. Rows older than
--      30 days are removed as new ones arrive. Server only (row security on, no policies).
--   2. zella_vapi_refusal_record(type, header names, reason): service role only; voice-rules calls it, best effort,
--      without waiting, when it refuses a request.
--   3. zella_admin_voice_overview: every key it returned, plus auth_mode, refusals_24h, last_refusal_at and switches
--      {calls_live, enforcement_calls, vapi_auth_mode, jobs: the timed jobs that run the call sweeps, verification and
--      usage reconcile, on or off, with their recorded intent}. Read only.
--   4. zella_admin_voice_alerts: adds missed_call_rate (at least 5 inbound calls in 24 hours with 25% or more missed,
--      warning, per business, with the call filter) and vapi_refused (refusals in the last hour, warning), both
--      computed on read so they need no timed job; and lists the voice alert kinds that are really raised
--      (repeated_transfer_failures, call_volume_spike, ai_call_failure, agent_failures, agent_sync_failed,
--      call_not_summarized) instead of five that nothing raises.
-- Both functions are archived first and must match production's versions (16 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_voice_admin_rollback.sql
begin;

do $$
declare s text; d text; want jsonb := jsonb_build_object(
  'public.zella_admin_voice_overview(timestamp with time zone,timestamp with time zone)', jsonb_build_array('f2eb6462c0ff90296786252005b50d4f', 'beb55e2f313319dce5322d40561aab19'),
  'public.zella_admin_voice_alerts()', jsonb_build_array('54adf47cf26d62aab4249243e730c548', 'f95f44a16b688f867175b5e9b4fe30fb'));
begin
  if to_regclass('public.zella_function_archive') is null or to_regprocedure('public.zella_admin_require(text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for s in select jsonb_object_keys(want) loop
    if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = want -> s ->> 0 then          -- production's version: archive it for the rollback
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_voice_admin', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> want -> s ->> 1 then      -- nor exactly this file's version (already applied)
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
  if to_regclass('public.vapi_refusals') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vapi_refusals' and column_name = 'header_names') then
    raise exception 'VERSION_MISMATCH: a different vapi_refusals table already exists';
  end if;
end $$;

create table if not exists public.vapi_refusals (
  hour timestamptz not null,
  message_type text not null,
  reason text not null,
  header_names text not null,
  count integer not null default 0,
  last_at timestamptz not null default now(),
  primary key (hour, message_type, reason, header_names)
);
create index if not exists vapi_refusals_last_idx on public.vapi_refusals (last_at);
alter table public.vapi_refusals enable row level security;
revoke all on table public.vapi_refusals from public, anon, authenticated;
grant all on table public.vapi_refusals to service_role;

create or replace function public.zella_vapi_refusal_record(p_message_type text, p_header_names text[], p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  -- every input is reduced to a short known list, so a flood can't create rows without end
  types constant text[] := array['assistant-request', 'tool-calls', 'transfer-destination-request', 'status-update', 'end-of-call-report',
    'conversation-update', 'speech-update', 'transcript', 'hang', 'function-call', 'user-interrupted', 'model-output', 'voice-input',
    'phone-call-control', 'knowledge-base-request', 'unknown'];
  reasons constant text[] := array['unauthenticated', 'bad_signature', 'expired', 'replayed', 'not_configured'];
  headers constant text[] := array['authorization', 'x-signature', 'x-timestamp'];
  v_type text := case when lower(p_message_type) = any (types) then lower(p_message_type) else 'other' end;
  v_reason text := case when lower(p_reason) = any (reasons) then lower(p_reason) else 'other' end;
  v_headers text := coalesce((select string_agg(h, ',' order by h) from (select distinct lower(x) h from unnest(coalesce(p_header_names, '{}'::text[])) x) y
                               where h = any (headers)), '');
begin
  insert into public.vapi_refusals (hour, message_type, reason, header_names, count, last_at)
  values (date_trunc('hour', now()), v_type, v_reason, v_headers, 1, now())
  on conflict (hour, message_type, reason, header_names) do update set count = vapi_refusals.count + 1, last_at = now();
  delete from public.vapi_refusals where hour < now() - interval '30 days';
end $$;
revoke all on function public.zella_vapi_refusal_record(text, text[], text) from public, anon, authenticated;
grant execute on function public.zella_vapi_refusal_record(text, text[], text) to service_role;

CREATE OR REPLACE FUNCTION public.zella_admin_voice_overview(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb; v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now());
  v_jobs jsonb := '{}'::jsonb; v_intents jsonb := '{}'::jsonb; v_refusals jsonb;
  -- the timed jobs that run the call sweeps, verification and usage reconcile (sql/zella_dispatcher.sql zella_run_schedule_group)
  call_jobs constant jsonb := '[{"name": "zella_jobs_every5", "runs": ["zella_sweep_stuck_calls", "zella_sweep_open_calls"]},
                                {"name": "zella_jobs_every15", "runs": ["zella_reconcile_call_usage"]},
                                {"name": "zella_jobs_hourly", "runs": ["zella_verify_calls"]}]'::jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  if to_regclass('cron.job') is not null then
    execute $q$select coalesce(jsonb_object_agg(jobname, active), '{}'::jsonb) from cron.job where jobname like 'zella%'$q$ into v_jobs;
  end if;
  if to_regclass('public.scheduled_job_intents') is not null then
    execute $q$select coalesce(jsonb_object_agg(job_name, intended), '{}'::jsonb) from public.scheduled_job_intents$q$ into v_intents;
  end if;
  select jsonb_build_object('n', coalesce(sum(count), 0), 'at', max(last_at)) into v_refusals from public.vapi_refusals where hour > now() - interval '24 hours';
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
    'calls_live', coalesce(public.zella_setting('calls_live', 'false'::jsonb) = 'true'::jsonb, false),
    -- refused Vapi requests (COM-09): counts only, never content
    'auth_mode', coalesce(nullif(public.zella_setting('vapi_auth_mode', '""'::jsonb) #>> '{}', ''), 'not set'),
    'refusals_24h', (v_refusals ->> 'n')::int, 'last_refusal_at', v_refusals -> 'at',
    -- the switches calls depend on (COM-13), read only
    'switches', jsonb_build_object(
      'calls_live', coalesce(public.zella_setting('calls_live', 'false'::jsonb) = 'true'::jsonb, false),
      'enforcement_calls', coalesce((public.zella_setting('usage_enforcement', '{}'::jsonb) ->> 'calls')::boolean, false),
      'vapi_auth_mode', coalesce(nullif(public.zella_setting('vapi_auth_mode', '""'::jsonb) #>> '{}', ''), 'not set'),
      'jobs', (select coalesce(jsonb_agg(j || jsonb_build_object('active', coalesce((v_jobs ->> (j ->> 'name'))::boolean, false), 'exists', v_jobs ? (j ->> 'name'),
                                                              'intended', v_intents ->> (j ->> 'name'))), '[]'::jsonb)
                 from jsonb_array_elements(call_jobs) j)));
end $function$;

CREATE OR REPLACE FUNCTION public.zella_admin_voice_alerts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare out jsonb := '[]'::jsonb; r record;
  -- missed call alert (UI-14, the owner decision's recommended answer): a business with at least this many inbound
  -- calls in the window, and at least this share of them missed
  missed_min_inbound constant integer := 5;
  missed_min_share constant numeric := 0.25;
  missed_window constant interval := interval '24 hours';
  -- refused Vapi requests in the last hour raise a warning (COM-09)
  refusal_window constant interval := interval '1 hour';
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
  for r in select b.id, b.name, count(*) inbound, count(*) filter (where c.status = 'missed') missed
             from public.calls c join public.businesses b on b.id = c.business_id
            where c.direction = 'inbound' and c.created_at > now() - missed_window group by b.id, b.name
           having count(*) >= missed_min_inbound and count(*) filter (where c.status = 'missed') >= missed_min_share * count(*) loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'kind', 'missed_call_rate', 'title', 'Many missed calls',
      'detail', r.name || ': ' || r.missed || ' of ' || r.inbound || ' inbound calls missed in 24 hours', 'business_id', r.id, 'link', 'calls',
      'filter', jsonb_build_object('status', 'missed', 'direction', 'inbound', 'days', 1, 'business_id', r.id)));
  end loop;
  for r in select sum(count) n, max(last_at) at, string_agg(distinct message_type, ', ') types from public.vapi_refusals where last_at > now() - refusal_window having sum(count) > 0 loop
    out := out || jsonb_build_array(jsonb_build_object('severity', 'warning', 'kind', 'vapi_refused', 'title', 'Vapi requests refused',
      'detail', r.n || ' Vapi ' || case when r.n = 1 then 'request' else 'requests' end || ' failed the sign in check in the last hour (' || r.types || '). Check the Vapi credential and the auth mode.',
      'at', r.at, 'link', 'providers'));
  end loop;
  out := out || coalesce((select jsonb_agg(jsonb_build_object('severity', a.severity, 'kind', a.kind, 'title', a.title, 'detail', left(a.detail, 300),
                                                               'at', a.last_seen_at, 'business_id', a.business_id, 'alert_id', a.id, 'link', 'calls'))
                            from public.platform_alerts a where a.status <> 'resolved'
                             and a.kind in ('repeated_transfer_failures', 'call_volume_spike', 'ai_call_failure', 'agent_failures', 'agent_sync_failed', 'call_not_summarized')), '[]'::jsonb);
  return out;
end $function$;

commit;
