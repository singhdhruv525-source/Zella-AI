insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'vapi-pn-A'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'vapi-pn-B');
insert into ai_agents (id, business_id, name, agent_type, is_default) values
  ('a0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'R', 'receptionist', true),
  ('b0000000-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-000000000002', 'R', 'receptionist', true);
insert into ai_agent_configs (agent_id, escalation_rules) values
  ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "(555) 010-1111", "transfer_open_hours_only": false}'),
  ('b0000000-0000-4000-8000-00000000000b', '{"transfer_number": "+15550102222", "transfer_open_hours_only": false}');
do $$
declare r jsonb;
begin
  perform zella_record_call_status('vt-1', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', now(), null);
  r := zella_transfer_destination('vt-1', '+15550001000', 'vapi-pn-A', '+15551230001');
  assert (r ->> 'ok')::boolean and r ->> 'number' = '+15550101111', r::text;
  assert (select transfer_status from calls where external_call_id = 'vt-1') = 'attempted';
  raise notice 'PASS destination = this business''s own transfer number, normalised to E.164 (%); call marked attempted', r ->> 'number';
  -- a call on A's line asking with B's number in the request still gets A's destination (the call record wins)
  r := zella_transfer_destination('vt-1', '+15550002000', 'vapi-pn-B', '+15551230001');
  assert r ->> 'number' = '+15550101111', 'cross ' || r::text;
  raise notice 'PASS the call''s own business decides; a different number in the request is ignored';
  -- unknown call on an unregistered line: refused
  r := zella_transfer_destination('vt-none', '+15559999999', null, '+15551230001');
  assert not (r ->> 'ok')::boolean and r ->> 'reason' = 'unknown_business' and r ->> 'number' is null, r::text;
  -- transfer switched off
  update ai_agent_configs set escalation_rules = escalation_rules || '{"transfer_enabled": false}' where agent_id = 'a0000000-0000-4000-8000-00000000000a';
  r := zella_transfer_destination('vt-1', null, null, null);
  assert r ->> 'reason' = 'transfer_off' and r ->> 'number' is null, r::text;
  -- no valid number configured
  update ai_agent_configs set escalation_rules = '{"transfer_number": "call Bob", "transfer_open_hours_only": false}' where agent_id = 'a0000000-0000-4000-8000-00000000000a';
  r := zella_transfer_destination('vt-1', null, null, null);
  assert r ->> 'reason' = 'no_valid_number', r::text;
  -- closed and the business only transfers during opening hours (Sunday-only hours, so closed on any other day)
  update ai_agent_configs set escalation_rules = '{"transfer_number": "+15550101111"}' where agent_id = 'a0000000-0000-4000-8000-00000000000a';
  insert into business_hours (business_id, weekday, opens, closes) select 'aaaaaaaa-0000-4000-8000-000000000001', 0, '00:00', '00:01';
  r := zella_transfer_destination('vt-1', null, null, null);
  assert r ->> 'reason' = 'closed' or extract(dow from now() at time zone 'America/New_York') = 0, r::text;
  -- the backup route is used when the business switched to it
  delete from business_hours;
  update ai_agent_configs set escalation_rules = '{"transfer_number": "+15550101111", "fallback_number": "+15550103333", "transfer_route": "fallback"}' where agent_id = 'a0000000-0000-4000-8000-00000000000a';
  r := zella_transfer_destination('vt-1', null, null, null);
  assert r ->> 'number' = '+15550103333', r::text;
  raise notice 'PASS refused when: unknown line, transfer off, no valid number, closed with hours-only; backup route honoured';
  -- the message never claims success ahead of time
  assert r ->> 'message' = 'Please hold while I connect you.';
  raise notice 'PASS spoken text is "please hold" (an attempt), never "you are connected"';
end $$;
-- the model is no longer told the number
select 'model text: ' || (r ->> 'say') || ' | number in result: ' || coalesce(r ->> 'transfer_number', 'none')
  from (select zella_ai_voice('vt-1', 'aaaaaaaa-0000-4000-8000-000000000001', 'transfer', '{}') r) x;
