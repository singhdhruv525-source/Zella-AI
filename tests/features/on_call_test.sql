-- On-call rota (staging only). Business A (New York) is closed today (a holiday closure), so every call is after hours.
\i ../voice-reliability/fixture.sql
delete from public.on_call_shifts; delete from public.on_call_settings; delete from public.business_members; delete from public.business_closures;
insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'vapi-pn-A');
insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'R', 'receptionist', true);
insert into ai_agent_configs (agent_id, escalation_rules) values
  ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "+15550101111", "emergency_enabled": true, "emergency_keywords": ["flood"]}');
insert into business_closures (business_id, starts_on, ends_on, label)
  values ('aaaaaaaa-0000-4000-8000-000000000001', (now() at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date, 'Test holiday');
insert into staff_members (id, business_id, name, phone, is_active) values
  ('5aaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Sam', '(555) 020-0001', true),
  ('5aaaaaaa-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'Alex', '+15550200002', true),
  ('5aaaaaaa-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'No Phone', null, true),
  ('5aaaaaaa-0000-4000-8000-000000000004', 'aaaaaaaa-0000-4000-8000-000000000001', 'Gone', '+15550200004', false),
  ('5bbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', 'Other biz', '+15550200009', true);
insert into business_members (business_id, user_id, role, status) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000001', 'owner', 'active'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', 'active'),
  ('bbbbbbbb-0000-4000-8000-000000000002', '0bbbbbbb-0000-4000-8000-000000000001', 'owner', 'active');

do $$
declare r jsonb; v_id uuid; v_err text; A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  act text; owner text := '0aaaaaaa-0000-4000-8000-000000000001';
begin
  perform zella_record_call_status('oc-1', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', now(), null);
  r := zella_transfer_destination('oc-1', null, null, null);
  assert r ->> 'reason' = 'closed', 'before ' || r::text;
  raise notice 'PASS closed and nobody on call: transfer refused as before (reason closed)';

  -- the owner sets up the rota (as a signed-in user)
  perform set_config('request.jwt.claim.sub', owner, true);
  perform zella_on_call_settings_save(A, true, 'after_hours');
  -- a weekly shift on today's weekday covering the whole day except the last minute
  v_id := zella_on_call_save(A, jsonb_build_object('staff_id', '5aaaaaaa-0000-4000-8000-000000000001', 'kind', 'weekly',
            'weekday', extract(dow from now() at time zone 'America/New_York'), 'starts', '00:00', 'ends', '23:59'));
  r := zella_on_call_list(A);
  assert r #>> '{now,name}' = 'Sam' and jsonb_array_length(r -> 'shifts') = 1 and (r ->> 'can_edit')::boolean, r::text;
  assert r::text not like '%5550200001%', 'list must not expose phone numbers';
  raise notice 'PASS owner saved a weekly shift; the rota shows Sam on call now without showing any phone number';
  perform set_config('request.jwt.claim.sub', '', true);

  r := zella_transfer_destination('oc-1', null, null, null);
  assert (r ->> 'ok')::boolean and r ->> 'number' = '+15550200001' and (r ->> 'on_call')::boolean, 'after_hours ' || r::text;
  raise notice 'PASS after hours, transfer goes to the on-call person (%), not the daytime number', r ->> 'number';
  r := zella_ai_voice('oc-1', A, 'rules', '{}');
  assert (r ->> 'can_transfer')::boolean, 'rules ' || r::text;
  r := zella_ai_voice('oc-1', A, 'transfer', '{"reason": "wants a person"}');
  assert r ->> 'status' = 'transfer', 'ai transfer ' || r::text;
  raise notice 'PASS the assistant is told it can transfer after hours and asks for the transfer';

  -- cover beats the weekly rota
  perform set_config('request.jwt.claim.sub', owner, true);
  perform zella_on_call_save(A, jsonb_build_object('staff_id', '5aaaaaaa-0000-4000-8000-000000000002', 'kind', 'cover',
            'starts_at', now() - interval '1 hour', 'ends_at', now() + interval '1 hour', 'note', 'Sam is off sick'));
  perform set_config('request.jwt.claim.sub', '', true);
  r := zella_transfer_destination('oc-1', null, null, null);
  assert r ->> 'number' = '+15550200002', 'cover ' || r::text;
  raise notice 'PASS one-off cover (Alex) beats the weekly rota';

  -- emergencies only: an ordinary after-hours transfer is refused, an emergency reaches the on-call person
  perform set_config('request.jwt.claim.sub', owner, true);
  perform zella_on_call_settings_save(A, true, 'emergencies_only');
  perform set_config('request.jwt.claim.sub', '', true);
  perform zella_record_call_status('oc-2', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230002', 'inbound', now(), null);
  r := zella_ai_voice('oc-2', A, 'transfer', '{"reason": "wants a person"}');
  assert r ->> 'status' <> 'transfer', 'emerg-only ai transfer ' || r::text;
  r := zella_transfer_destination('oc-2', null, null, null);
  assert r ->> 'reason' = 'closed', 'emerg-only ordinary ' || r::text;
  r := zella_ai_voice('oc-2', A, 'emergency', '{"summary": "Basement flooding"}');
  assert r ->> 'status' = 'transfer', 'emergency ' || r::text;
  r := zella_transfer_destination('oc-2', null, null, null);
  assert (r ->> 'ok')::boolean and r ->> 'number' = '+15550200002', 'emergency dest ' || r::text;
  raise notice 'PASS emergencies only: ordinary after-hours callers get the usual message, an emergency goes to the on-call person';

  -- rota switched off: back to the old behaviour
  perform set_config('request.jwt.claim.sub', owner, true);
  perform zella_on_call_settings_save(A, false, 'after_hours');
  perform set_config('request.jwt.claim.sub', '', true);
  r := zella_transfer_destination('oc-1', null, null, null);
  assert r ->> 'reason' = 'closed', 'off ' || r::text;
  raise notice 'PASS rota switched off: after-hours transfers refused exactly as before';

  -- during opening hours nothing changes
  perform set_config('request.jwt.claim.sub', owner, true);
  perform zella_on_call_settings_save(A, true, 'after_hours');
  perform set_config('request.jwt.claim.sub', '', true);
  delete from business_closures where business_id = A;
  r := zella_transfer_destination('oc-1', null, null, null);
  assert r ->> 'number' = '+15550101111' and not r ? 'on_call', 'open ' || r::text;
  raise notice 'PASS while open, transfers still go to the normal number';
end $$;

-- overnight shifts, inactive staff, staff without a phone (zella_on_call_now at fixed times; 2026-11-02 is a Monday)
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; owner text := '0aaaaaaa-0000-4000-8000-000000000001';
begin
  delete from on_call_shifts;
  perform set_config('request.jwt.claim.sub', owner, true);
  perform zella_on_call_save(A, '{"staff_id": "5aaaaaaa-0000-4000-8000-000000000001", "kind": "weekly", "weekday": 1, "starts": "18:00", "ends": "08:00"}');
  perform set_config('request.jwt.claim.sub', '', true);
  assert zella_on_call_now(A, '2026-11-02 19:00 America/New_York') ->> 'name' = 'Sam';
  assert zella_on_call_now(A, '2026-11-03 03:00 America/New_York') ->> 'name' = 'Sam';
  assert not zella_on_call_now(A, '2026-11-03 09:00 America/New_York') ? 'name';
  assert not zella_on_call_now(A, '2026-11-02 17:00 America/New_York') ? 'name';
  raise notice 'PASS an overnight shift (Mon 18:00-08:00) covers Monday evening and early Tuesday, not Tuesday morning';
  update staff_members set is_active = false where id = '5aaaaaaa-0000-4000-8000-000000000001';
  assert not zella_on_call_now(A, '2026-11-02 19:00 America/New_York') ? 'name';
  update staff_members set is_active = true, phone = 'n/a' where id = '5aaaaaaa-0000-4000-8000-000000000001';
  assert not zella_on_call_now(A, '2026-11-02 19:00 America/New_York') ? 'name';
  update staff_members set phone = '(555) 020-0001' where id = '5aaaaaaa-0000-4000-8000-000000000001';
  raise notice 'PASS deactivated staff, or staff whose number is not valid, are never put through';
end $$;

-- permissions and input checks
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; v_err text;
  function_calls text[] := array[
    $q$select zella_on_call_save('aaaaaaaa-0000-4000-8000-000000000001', '{"staff_id": "5aaaaaaa-0000-4000-8000-000000000001", "kind": "weekly", "weekday": 2, "starts": "18:00", "ends": "08:00"}')$q$,
    $q$select zella_on_call_settings_save('aaaaaaaa-0000-4000-8000-000000000001', true, 'after_hours')$q$];
  s text;
begin
  -- a staff member (not a manager) and another business's owner cannot change the rota
  foreach s in array function_calls loop
    perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000002', true);
    begin execute s; v_err := null; exception when others then v_err := sqlerrm; end;
    assert v_err = 'NOT_ALLOWED', 'staff ' || coalesce(v_err, 'allowed');
    perform set_config('request.jwt.claim.sub', '0bbbbbbb-0000-4000-8000-000000000001', true);
    begin execute s; v_err := null; exception when others then v_err := sqlerrm; end;
    assert v_err = 'NOT_ALLOWED', 'other owner ' || coalesce(v_err, 'allowed');
  end loop;
  begin perform zella_on_call_list(A); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED', 'other owner list';
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000002', true);
  assert not (zella_on_call_list(A) ->> 'can_edit')::boolean;
  raise notice 'PASS only owners, admins and managers of the business change the rota; staff can see it; other businesses cannot';

  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_on_call_save(A, '{"staff_id": "5bbbbbbb-0000-4000-8000-000000000001", "kind": "weekly", "weekday": 1, "starts": "18:00", "ends": "08:00"}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_STAFF', 'cross-business staff ' || coalesce(v_err, 'allowed');
  begin perform zella_on_call_save(A, '{"staff_id": "5aaaaaaa-0000-4000-8000-000000000003", "kind": "weekly", "weekday": 1, "starts": "18:00", "ends": "08:00"}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'STAFF_NEEDS_PHONE', 'no phone ' || coalesce(v_err, 'allowed');
  begin perform zella_on_call_save(A, '{"staff_id": "5aaaaaaa-0000-4000-8000-000000000001", "kind": "weekly", "weekday": 9, "starts": "18:00", "ends": "08:00"}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_TIMES', 'weekday 9 ' || coalesce(v_err, 'allowed');
  begin perform zella_on_call_save(A, '{"staff_id": "5aaaaaaa-0000-4000-8000-000000000001", "kind": "cover", "starts_at": "2026-12-26", "ends_at": "2026-12-24"}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_TIMES', 'backwards cover ' || coalesce(v_err, 'allowed');
  begin perform zella_on_call_save(A, '{"staff_id": "5aaaaaaa-0000-4000-8000-000000000001", "kind": "cover", "starts_at": "tomorrow-ish", "ends_at": "2026-12-24"}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_TIMES', 'bad text ' || coalesce(v_err, 'allowed');
  begin perform zella_on_call_settings_save(A, true, 'always'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_SCOPE';
  raise notice 'PASS staff from another business, staff without a phone, impossible days and backwards or unreadable dates are refused';
  perform set_config('request.jwt.claim.sub', '', true);
  assert (select bool_and(value::text = 'true') from jsonb_each(zella_on_call_status())), zella_on_call_status()::text;
  raise notice 'PASS status: tables, assistant rule and transfer routing all in place';
end $$;

-- fixed mismatch: with nobody on call, an emergency the assistant was told to transfer is no longer refused as "closed"
do $$
declare r jsonb; A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
begin
  delete from on_call_settings;
  insert into business_closures (business_id, starts_on, ends_on, label)
    values (A, (now() at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date, 'Test holiday');
  perform zella_record_call_status('oc-3', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', now(), null);
  r := zella_ai_voice('oc-3', A, 'emergency', '{"summary": "Gas smell"}');
  assert r ->> 'status' = 'transfer', 'ai ' || r::text;
  r := zella_transfer_destination('oc-3', null, null, null);
  assert (r ->> 'ok')::boolean and r ->> 'number' = '+15550101111', 'dest ' || r::text;
  r := zella_transfer_destination('oc-1', null, null, null);
  assert r ->> 'reason' = 'closed', 'ordinary ' || r::text;
  raise notice 'PASS after hours with no rota: an emergency the assistant is transferring reaches the normal number; ordinary calls are still refused';
end $$;
