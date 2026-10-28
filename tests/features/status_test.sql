-- Public status page and uptime alerts (staging only).
delete from public.provider_health; delete from public.platform_incidents; delete from public.platform_alerts; delete from public.n8n_dispatch_state;
delete from public.platform_admins;
insert into platform_admins (user_id, role, is_active) values ('0dddddd0-0000-4000-8000-000000000001', 'super_admin', true);
insert into platform_settings (key, value) values ('provider_checks_live', 'false'), ('n8n_base_url', '""') on conflict (key) do update set value = excluded.value;

do $$
declare r jsonb; v_id uuid; v_err text;
begin
  r := zella_public_status();
  assert r ->> 'overall' = 'operational' and (select count(*) from jsonb_array_elements(r -> 'components') x where x ->> 'state' = 'unknown') = 4, r::text;
  raise notice 'PASS before anything is monitored: the app shows as working and every other part as "not monitored yet", never as broken';

  update platform_settings set value = 'true' where key = 'provider_checks_live';
  update platform_settings set value = '"https://n8n.example"' where key = 'n8n_base_url';
  insert into provider_health (provider, ok, detail, checked_at, consecutive_failures) values
    ('vapi', true, 'ok', now() - interval '1 hour', 0), ('telnyx', false, 'HTTP 503 from api.telnyx.com secret detail', now() - interval '10 minutes', 3),
    ('resend', false, 'timeout', now() - interval '5 minutes', 1);
  r := zella_public_status();
  assert (select x ->> 'state' from jsonb_array_elements(r -> 'components') x where x ->> 'key' = 'phone') = 'operational';
  assert (select x ->> 'state' from jsonb_array_elements(r -> 'components') x where x ->> 'key' = 'texts') = 'outage';
  assert (select x ->> 'state' from jsonb_array_elements(r -> 'components') x where x ->> 'key' = 'email') = 'degraded';
  assert (select x ->> 'state' from jsonb_array_elements(r -> 'components') x where x ->> 'key' = 'automations') = 'operational';
  assert r ->> 'overall' = 'outage' and r::text not like '%secret detail%' and r::text not like '%503%', r::text;
  raise notice 'PASS provider checks become states (working / slow / down) without ever showing the provider''s error text';

  -- incidents: only published ones, with the public wording
  insert into platform_incidents (title, detail) values ('Telnyx outage in us-east', 'internal: carrier ticket #123') returning id into v_id;
  r := zella_public_status();
  assert jsonb_array_length(r -> 'incidents') = 0, 'unpublished incident shown';
  perform set_config('request.jwt.claim.sub', '0dddddd0-0000-4000-8000-000000000001', true);
  begin perform zella_set_incident_public(v_id, true, 'short'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'PUBLIC_MESSAGE_REQUIRED';
  perform zella_set_incident_public(v_id, true, 'Some text messages are delayed. We are working with our provider.', 'texts');
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_set_incident_public(v_id, false, null); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  perform set_config('request.jwt.claim.sub', '', true);
  r := zella_public_status();
  assert jsonb_array_length(r -> 'incidents') = 1 and r #>> '{incidents,0,message}' = 'Some text messages are delayed. We are working with our provider.'
     and r::text not like '%carrier ticket%', r::text;
  raise notice 'PASS only incidents a Zella admin published appear, with the public wording only; business users can''t publish';

  -- uptime: checks stopped for 6 hours -> urgent alert; back -> resolved
  update provider_health set checked_at = now() - interval '7 hours';
  perform zella_check_uptime();
  assert (select count(*) from platform_alerts where kind = 'automation_heartbeat' and status <> 'resolved' and severity = 'urgent') = 1;
  r := zella_public_status();
  assert (select x ->> 'state' from jsonb_array_elements(r -> 'components') x where x ->> 'key' = 'automations') = 'outage', r::text;
  update provider_health set checked_at = now();
  perform zella_check_uptime();
  assert (select count(*) from platform_alerts where kind = 'automation_heartbeat' and status <> 'resolved') = 0;
  raise notice 'PASS no connection check for 6 hours raises one urgent alert (and the status page shows reminders as down); it clears itself when checks return';

  -- a queue n8n isn't clearing
  insert into n8n_dispatch_state (workflow, last_triggered_at, last_count, consecutive_same) values ('followup-texts', now() - interval '1 minute', 7, 12), ('_kick', now(), 0, 50);
  r := zella_check_uptime();
  assert (select meta ->> 'workflows' from platform_alerts where kind = 'automation_stalled' and status <> 'resolved') = '["followup-texts"]', r::text;
  update n8n_dispatch_state set consecutive_same = 0, last_count = 0 where workflow = 'followup-texts';
  perform zella_check_uptime();
  assert (select count(*) from platform_alerts where kind = 'automation_stalled' and status <> 'resolved') = 0;
  raise notice 'PASS a queue n8n keeps being asked about but never clears raises an urgent alert naming it, and clears when it drains';

  -- switched off: no alert
  update platform_settings set value = 'false' where key = 'provider_checks_live';
  update provider_health set checked_at = now() - interval '2 days';
  perform zella_check_uptime();
  assert (select count(*) from platform_alerts where kind = 'automation_heartbeat' and status <> 'resolved') = 0;
  raise notice 'PASS while provider checks are switched off (as now), no heartbeat alert is raised';
end $$;

-- anyone can read it, even without signing in
set role anon;
select case when zella_public_status() ? 'overall' then 'PASS the status can be read without signing in' end;
reset role;
