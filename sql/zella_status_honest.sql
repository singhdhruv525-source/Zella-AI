-- Zella Voice: the public status page says only what is actually checked (docs/ADMIN_AUDIT_2026-11-16.md OPS-01, OPS-02).
-- zella_public_status() ranked "unknown" with "working", so with every check switched off (production, 16 Nov 2026)
-- /status still said "Everything is working". And "Reminders and follow ups" read Working whenever the n8n address
-- was set, even with the zella_dispatch job off and the dispatch switch unset (the dispatcher treats unset as off).
-- Now:
--   * the overall line is "partial" (shown as "Not every part is checked right now") when nothing is wrong but at
--     least one part isn't checked; "operational" only when every part is checked and working;
--   * automations are Working only when the n8n address is set, n8n_dispatch_enabled is true, and the zella_dispatch
--     timed job is switched on and finished a run in the last 10 minutes; otherwise unknown (alerts still win).
-- Nothing else changes: same parts, labels, incidents and permissions. The web app shows "partial"; the old app shows
-- "Status not available yet" for it, so either deploy order is safe.
-- The function is archived first and must match production exactly (16 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_status_honest_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_public_status()'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'bbc92fb383690bf1799048a7fa2615bb' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_status_honest', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> '9bace44cf5ad3c2b7790650a54e48b98' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_public_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_checks boolean := public.zella_provider_checks_live();
  -- automations count as working only when the dispatcher can actually call n8n: the address is set, the switch is on
  -- (the dispatcher treats a missing switch as off), and its timed job is switched on and finished a run lately
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'false'::jsonb) = 'true'::jsonb, false);
  v_dispatching boolean := false;
  v_components jsonb := '[]'::jsonb; v_incidents jsonb; v_state text; h record; c record; v_rank int := 0; v_unknown boolean;
  rank_of constant jsonb := '{"operational": 0, "unknown": 0, "degraded": 1, "outage": 2}';
begin
  begin
    select exists (select 1 from cron.job j join cron.job_run_details r on r.jobid = j.jobid
                    where j.jobname = 'zella_dispatch' and j.active and r.status = 'succeeded' and r.end_time > now() - interval '10 minutes')
      into v_dispatching;
  exception when others then v_dispatching := false;   -- no scheduler here: nothing is dispatching
  end;
  for c in select * from (values ('phone', 'Phone assistant', 'vapi'), ('texts', 'Text messages', 'telnyx'), ('email', 'Email', 'resend')) as t(key, label, provider) loop
    select * into h from public.provider_health where provider = c.provider;
    v_state := case
      when not v_checks or h.provider is null or h.checked_at is null or h.checked_at < now() - interval '6 hours' then 'unknown'
      when h.ok then 'operational'
      when h.consecutive_failures >= 2 then 'outage'
      else 'degraded' end;
    v_components := v_components || jsonb_build_object('key', c.key, 'label', c.label, 'state', v_state,
      'checked_at', case when v_state <> 'unknown' then h.checked_at end);
  end loop;
  v_state := case
    when exists (select 1 from public.platform_alerts a where a.status <> 'resolved' and a.kind in ('automation_heartbeat', 'automation_stalled')) then 'outage'
    when exists (select 1 from public.platform_alerts a where a.status <> 'resolved' and a.kind = 'queue_backlog') then 'degraded'
    when v_n8n and v_dispatching then 'operational' else 'unknown' end;
  v_components := v_components || jsonb_build_object('key', 'automations', 'label', 'Reminders and follow ups', 'state', v_state);
  v_components := v_components || jsonb_build_object('key', 'app', 'label', 'Zella Voice app', 'state', 'operational');

  for c in select distinct i.component from public.platform_incidents i where i.is_public and i.status = 'open' and i.component is not null loop
    select coalesce(jsonb_agg(case when x ->> 'key' = c.component and x ->> 'state' in ('operational', 'unknown') then x || '{"state": "degraded"}'::jsonb else x end), '[]'::jsonb)
      into v_components from jsonb_array_elements(v_components) x;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('message', i.public_message, 'status', i.status, 'component', i.component,
           'started_at', i.created_at, 'resolved_at', i.resolved_at) order by (i.status = 'open') desc, i.created_at desc), '[]'::jsonb) into v_incidents
    from (select * from public.platform_incidents where is_public and (status = 'open' or resolved_at > now() - interval '14 days')
           order by created_at desc limit 20) i;

  select max((rank_of ->> (x ->> 'state'))::int), bool_or(x ->> 'state' = 'unknown') into v_rank, v_unknown from jsonb_array_elements(v_components) x;
  if exists (select 1 from public.platform_incidents where is_public and status = 'open') then v_rank := greatest(v_rank, 1); end if;
  -- "Everything is working" only when every part is checked and working; a part nobody checks makes it "partial"
  return jsonb_build_object('overall', case v_rank when 2 then 'outage' when 1 then 'degraded' else case when v_unknown then 'partial' else 'operational' end end,
    'components', v_components, 'incidents', v_incidents, 'generated_at', now());
end $function$;

commit;
