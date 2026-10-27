-- Spam protection + voice reliability on one staging database (run on both migration orders by spam_compat.sh).
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; r jsonb; t jsonb; n int; v text;
begin
  assert (select count(*) from jsonb_each(public.zella_voice_reliability_status()) where value = 'true'::jsonb) = 12, 'patches';
  assert to_regprocedure('public.zella_caller_context_base(uuid, text)') is not null, 'spam replaced zella_caller_context';
  raise notice 'PASS all 12 voice-reliability patches in place and spam''s zella_caller_context replacement present';

  insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', A, 'R', 'receptionist', true) on conflict do nothing;
  insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "+15550101111", "transfer_open_hours_only": false}') on conflict do nothing;
  insert into calls (business_id, direction, status, external_call_id, from_number, started_at) values (A, 'inbound', 'answered', 'sp-ok', '+15551230001', now()), (A, 'inbound', 'answered', 'sp-blk', '+15559990666', now());

  -- an ordinary caller is still put through
  t := public.zella_transfer_destination('sp-ok', '+15550001000', 'pn-A', '+15551230001');
  assert t ->> 'ok' = 'true' and t ->> 'number' = '+15550101111', 'ordinary transfer: ' || t::text;
  -- a caller on the business's call block list: screened by spam protection, and no transfer number
  insert into spam_list_entries (business_id, list, channel, value_type, value, reason) values (A, 'block', 'call', 'phone', public.zella_digits('+15559990666'), 'test');
  r := public.zella_ai_voice('sp-blk', A, 'rules', '{"caller_number": "+15559990666"}');
  assert (r -> 'caller' -> 'screening' ->> 'decision') in ('blocked', 'restricted', 'screened'), 'screening decision: ' || coalesce(r -> 'caller' ->> 'screening', 'none');
  t := public.zella_transfer_destination('sp-blk', '+15550001000', 'pn-A', '+15559990666');
  assert coalesce(t ->> 'ok', 'false') = 'false' and t ->> 'number' is null and t ->> 'reason' = 'screened', 'blocked transfer: ' || t::text;
  raise notice 'PASS blocked caller: screened by spam protection, transfer refused with no number; ordinary caller still transferred';

  -- the AI tool gateway: a blocked caller can't book; an ordinary caller still can (with confirmation)
  r := public.zella_ai_tool('sp-blk', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T15:00:00Z", "first_name": "X", "phone": "+15559990666", "caller_number": "+15559990666"}');
  assert r ->> 'status' = 'screened' and (select count(*) from appointments where start_time = '2026-11-02T15:00:00Z') = 0, 'blocked caller booked: ' || r::text;
  for v in select unnest(array['check_availability', 'find_my_appointments', 'lookup_caller', 'update_caller', 'take_message']) loop
    assert public.zella_ai_tool('sp-blk', A, v, '{"confirmed": true}') ->> 'status' = 'screened', 'blocked caller used ' || v;
  end loop;
  assert public.zella_ai_tool('sp-blk', A, 'report_emergency', '{"summary": "smoke in the building"}') ->> 'status' <> 'screened', 'emergency refused';
  raise notice 'PASS screened caller: every tool refused by the server (not only the model told), emergency still goes through';
  -- a time spam protection keeps as a request (booking-channel block) is never announced as booked
  insert into spam_list_entries (business_id, list, channel, value_type, value, reason) values (A, 'block', 'booking', 'phone', public.zella_digits('+15551230077'), 'test');
  insert into calls (business_id, direction, status, external_call_id, from_number, started_at) values (A, 'inbound', 'answered', 'sp-req', '+15551230077', now());
  r := public.zella_ai_tool('sp-req', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T17:00:00Z", "first_name": "Q", "phone": "+15551230077", "caller_number": "+15551230077"}');
  assert r ->> 'status' = 'requested' and (select booking_state from appointments where start_time = '2026-11-02T17:00:00Z') = 'requested', 'kept as request: ' || r::text;
  raise notice 'PASS booking kept as a request by spam protection: assistant told "request", not "booked"';
  r := public.zella_ai_tool('sp-ok', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T16:00:00Z", "first_name": "Ana", "phone": "+15551230001", "caller_number": "+15551230001"}');
  assert r ->> 'status' = 'booked', 'ordinary booking: ' || r::text;
  raise notice 'PASS ordinary caller still booked (with confirmation)';

  -- call status and the end-of-call record still work with spam's calls trigger in place, once per call
  perform public.zella_record_call_status('sp-st', 'ringing', '+15550001000', 'pn-A', '+15551230009', 'inbound', now() - interval '1 minute', null);
  perform public.zella_record_call_status('sp-st', 'ended', '+15550001000', 'pn-A', '+15551230009', 'inbound', now(), 'customer-ended-call');
  perform public.zella_record_call_status('sp-st', 'in-progress', '+15550001000', 'pn-A', '+15551230009', 'inbound', now() - interval '30 seconds', null);
  select count(*), max(metadata ->> 'provider_status') into n, v from calls where external_call_id = 'sp-st';
  assert n = 1 and v = 'ended' and (select ended_at is not null and answered_at is null from calls where external_call_id = 'sp-st'), 'status rows ' || n || ' ' || v;
  raise notice 'PASS status events with spam''s call trigger: one row, ended recorded, late in-progress ignored';

  -- the signature check is independent of spam protection
  assert to_regprocedure('public.zella_vapi_authenticate(text, jsonb)') is not null;
  raise notice 'PASS zella_vapi_authenticate present alongside spam protection';
end $$;
