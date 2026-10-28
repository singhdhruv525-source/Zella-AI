-- Zella - public status page and uptime alerts (2026-10-28). Safe to re-run.
-- Needs sql/zella_run_all.sql (platform_incidents, platform_alerts, zella_platform_alert, zella_resolve_platform_alerts),
-- the provider checks (provider_health, zella_provider_checks_live) and sql/zella_dispatcher.sql (n8n_dispatch_state).
--
-- 1. zella_public_status(): what the public page /status shows, readable without signing in. Only the state of each
--    part of Zella (phone assistant, texts, email, automations, app) and the incidents a Zella admin chose to publish,
--    with the public wording they wrote. No business, customer, provider error text or internal detail ever.
-- 2. zella_check_uptime() (every 15 minutes, with the other timed jobs): two alerts the existing checks don't give.
--      - the provider checks themselves stopped (no result for 6 hours while they are switched on): n8n is probably down;
--      - a workflow that keeps being called without its queue going down (the dispatcher backed off): n8n isn't working it.
--    Both are urgent platform alerts (emailed to admins by Zella - Admin Alerts) and resolve themselves when fixed.
-- Rollback: drop function public.zella_public_status(), public.zella_check_uptime(), public.zella_set_incident_public(uuid, boolean, text);
--   alter table public.platform_incidents drop column is_public, drop column public_message, drop column component;

alter table public.platform_incidents add column if not exists is_public boolean not null default false;
alter table public.platform_incidents add column if not exists public_message text check (public_message is null or length(public_message) <= 500);
alter table public.platform_incidents add column if not exists component text check (component is null or component in ('phone', 'texts', 'email', 'automations', 'app'));

-- A Zella admin publishes an incident on the status page (or takes it off), with words written for the public.
create or replace function public.zella_set_incident_public(p_incident_id uuid, p_public boolean, p_message text, p_component text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_msg text := nullif(trim(regexp_replace(coalesce(p_message, ''), '\s+', ' ', 'g')), '');
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if p_public and (v_msg is null or length(v_msg) < 10) then raise exception 'PUBLIC_MESSAGE_REQUIRED'; end if;
  if v_msg is not null and length(v_msg) > 500 then raise exception 'PUBLIC_MESSAGE_TOO_LONG'; end if;
  if p_component is not null and p_component not in ('phone', 'texts', 'email', 'automations', 'app') then raise exception 'UNKNOWN_COMPONENT'; end if;
  update public.platform_incidents set is_public = coalesce(p_public, false), public_message = v_msg, component = p_component where id = p_incident_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  return true;
end $$;
revoke all on function public.zella_set_incident_public(uuid, boolean, text, text) from public, anon;
grant execute on function public.zella_set_incident_public(uuid, boolean, text, text) to authenticated;

create or replace function public.zella_public_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_checks boolean := public.zella_provider_checks_live();
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
  v_components jsonb := '[]'::jsonb; v_incidents jsonb; v_state text; h record; c record; v_rank int := 0;
  rank_of constant jsonb := '{"operational": 0, "unknown": 0, "degraded": 1, "outage": 2}';
begin
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
    when v_n8n then 'operational' else 'unknown' end;
  v_components := v_components || jsonb_build_object('key', 'automations', 'label', 'Reminders and follow-ups', 'state', v_state);
  -- answering this at all means the app and its database are up
  v_components := v_components || jsonb_build_object('key', 'app', 'label', 'Zella app', 'state', 'operational');

  -- a published open incident marks its part as at least degraded
  for c in select distinct i.component from public.platform_incidents i where i.is_public and i.status = 'open' and i.component is not null loop
    select coalesce(jsonb_agg(case when x ->> 'key' = c.component and x ->> 'state' in ('operational', 'unknown') then x || '{"state": "degraded"}'::jsonb else x end), '[]'::jsonb)
      into v_components from jsonb_array_elements(v_components) x;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('title', i.title, 'message', i.public_message, 'status', i.status, 'component', i.component,
           'started_at', i.created_at, 'resolved_at', i.resolved_at) order by (i.status = 'open') desc, i.created_at desc), '[]'::jsonb) into v_incidents
    from (select * from public.platform_incidents where is_public and (status = 'open' or resolved_at > now() - interval '14 days')
           order by created_at desc limit 20) i;

  select max((rank_of ->> (x ->> 'state'))::int) into v_rank from jsonb_array_elements(v_components) x;
  if exists (select 1 from public.platform_incidents where is_public and status = 'open') then v_rank := greatest(v_rank, 1); end if;
  return jsonb_build_object('overall', case v_rank when 2 then 'outage' when 1 then 'degraded' else 'operational' end,
    'components', v_components, 'incidents', v_incidents, 'generated_at', now());
end $$;
revoke all on function public.zella_public_status() from public;
grant execute on function public.zella_public_status() to anon, authenticated, service_role;

create or replace function public.zella_check_uptime() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_last timestamptz; v_stuck text[]; v_since timestamptz;
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
begin
  -- 1. the connection checks stopped
  select max(checked_at) into v_last from public.provider_health;
  select min(updated_at) into v_since from public.platform_settings where key = 'provider_checks_live';
  if public.zella_provider_checks_live() and coalesce(v_last, v_since, now()) < now() - interval '6 hours' then
    perform public.zella_platform_alert('automation_heartbeat', 'The automation engine looks down',
      'No connection check has come back for 6 hours (last: ' || coalesce(to_char(v_last at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never')
      || '). n8n may be down or the Connection Tests workflow switched off.', 'urgent', null, 'heartbeat');
  else
    perform public.zella_resolve_platform_alerts('automation_heartbeat', null, 'heartbeat', 'Connection checks are coming back again');
  end if;
  -- 2. work keeps waiting although n8n is called
  select coalesce(array_agg(workflow order by workflow), '{}') into v_stuck from public.n8n_dispatch_state
   where workflow <> '_kick' and consecutive_same >= 12 and last_count > 0 and last_triggered_at > now() - interval '30 minutes';
  if v_n8n and cardinality(v_stuck) > 0 then
    perform public.zella_platform_alert('automation_stalled', 'Automations are not being worked',
      'n8n keeps being called but these queues are not going down: ' || array_to_string(v_stuck, ', ') || '. Check the workflows are published and their credentials work.',
      'urgent', null, 'stalled', jsonb_build_object('workflows', to_jsonb(v_stuck)));
  else
    perform public.zella_resolve_platform_alerts('automation_stalled', null, 'stalled', 'Queues are moving again');
  end if;
  return jsonb_build_object('heartbeat_last', v_last, 'stalled', to_jsonb(v_stuck));
end $$;
revoke all on function public.zella_check_uptime() from public, anon, authenticated;
grant execute on function public.zella_check_uptime() to service_role;
