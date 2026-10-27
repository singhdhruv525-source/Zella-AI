insert into business_phone_numbers (business_id, e164, vapi_phone_number_id, label) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'vapi-pn-A', 'Main'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'vapi-pn-B', 'Main');
insert into platform_settings (key, value) values ('call_reconcile_live', 'true') on conflict (key) do update set value = 'true';
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; c record; r text; j jsonb; t0 timestamptz := now() - interval '3 minutes';
begin
  -- status updates create the call at once and apply each step once, in order
  r := zella_record_call_status('vc-1', 'ringing', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0, null);
  assert r = 'recorded' and (select count(*) from calls where external_call_id = 'vc-1') = 1, 'ringing ' || r;
  r := zella_record_call_status('vc-1', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0 + interval '2 seconds', null);
  assert r = 'recorded';
  r := zella_record_call_status('vc-1', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0 + interval '2 seconds', null);
  assert r = 'duplicate', 'dup ' || r;
  r := zella_record_call_status('vc-1', 'ringing', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0, null);
  assert r = 'duplicate', 'late ' || r;
  select * into c from calls where external_call_id = 'vc-1';
  assert c.business_id = A and c.status = 'answered' and c.answered_at = t0 + interval '2 seconds' and c.started_at = t0, 'row ' || row_to_json(c)::text;
  raise notice 'PASS status updates: call recorded from the first event; repeats and late events ignored; provider times kept';

  -- unknown number: nothing is created, nothing guessed
  r := zella_record_call_status('vc-x', 'in-progress', '+15559999999', 'vapi-pn-unknown', '+15551230001', 'inbound', t0, null);
  assert r = 'unknown_business' and not exists (select 1 from calls where external_call_id = 'vc-x'), r;
  raise notice 'PASS unregistered number: no call row, no business guessed';

  -- ended, then the report is lost: the call stays, with the provider end time, waiting to be reconciled
  r := zella_record_call_status('vc-1', 'ended', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0 + interval '95 seconds', 'customer-ended-call');
  select * into c from calls where external_call_id = 'vc-1';
  assert c.ended_at = t0 + interval '95 seconds' and c.metadata ->> 'awaiting_report' = 'true' and c.duration_seconds is null and c.outcome is null, 'ended ' || row_to_json(c)::text;
  raise notice 'PASS ended without report: end time from the provider, no invented duration or outcome';
  update calls set ended_at = now() - interval '11 minutes', updated_at = now() - interval '11 minutes' where external_call_id = 'vc-1';
  assert zella_call_reconcile_waiting() = 1, 'waiting';
  j := zella_calls_to_reconcile(10);
  assert jsonb_array_length(j) = 1 and j -> 0 ->> 'provider_call_id' = 'vc-1', j::text;
  assert jsonb_array_length(zella_calls_to_reconcile(10)) = 0 and zella_call_reconcile_waiting() = 0, 'claimed once';
  raise notice 'PASS reconciliation lists the call once (claimed, retried later with a growing wait)';
  -- provider answers: wrong id is refused, not-ended is left, ended is recorded with provider data
  assert zella_reconcile_call('vc-1', 200, '{"id": "other-call", "status": "ended"}') = 'mismatch';
  assert zella_reconcile_call('vc-1', 500, null) = 'provider_error';
  r := zella_reconcile_call('vc-1', 200, jsonb_build_object('id', 'vc-1', 'status', 'ended', 'startedAt', t0, 'endedAt', t0 + interval '95 seconds',
         'endedReason', 'customer-ended-call', 'phoneNumber', jsonb_build_object('number', '+15550001000'), 'customer', jsonb_build_object('number', '+15551230001'),
         'analysis', jsonb_build_object('summary', 'Asked about opening hours.'), 'artifact', jsonb_build_object('transcript', 'AI: Hello. Caller: When are you open?')));
  select * into c from calls where external_call_id = 'vc-1';
  assert r = 'recorded' and c.duration_seconds = 95 and c.outcome = 'resolved' and c.summary = 'Asked about opening hours.' and c.transcript like 'AI: Hello%'
     and c.metadata ->> 'reconcile_status' = 'reconciled' and c.metadata ->> 'ended_at_source' = 'provider', 'reconciled ' || row_to_json(c)::text;
  assert (select count(*) from calls where external_call_id = 'vc-1') = 1;
  raise notice 'PASS reconciled from the provider record: real duration (95 s), summary, transcript; still one row';
  -- the late original report now arrives: ignored, nothing duplicated
  r := zella_record_inbound_call('vc-1', '+15550001000', 'vapi-pn-A', '+15551230001', t0, t0 + interval '95 seconds', 95, 'customer-ended-call', 'x', null, 'y', false);
  assert r = 'ignored' and (select summary from calls where external_call_id = 'vc-1') = 'Asked about opening hours.', 'late report ' || r;
  raise notice 'PASS a late or repeated end-of-call report changes nothing';

  -- a report with no duration no longer records 0 seconds
  perform zella_record_call_status('vc-2', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230002', 'inbound', t0, null);
  perform zella_record_inbound_call('vc-2', '+15550001000', 'vapi-pn-A', '+15551230002', t0, null, null, 'customer-ended-call', 'Booked.', null, null, false);
  select * into c from calls where external_call_id = 'vc-2';
  assert c.duration_seconds is null and c.metadata ->> 'ended_at_source' = 'received_time', 'no duration ' || row_to_json(c)::text;
  raise notice 'PASS missing duration stays empty; an estimated end time is labelled received_time';

  -- transfer outcome comes from the provider's ended reason
  perform zella_record_call_status('vc-3', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0, null);
  perform zella_record_call_status('vc-3', 'forwarding', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0 + interval '30 seconds', null);
  assert (select transfer_status from calls where external_call_id = 'vc-3') = 'attempted';
  perform zella_record_inbound_call('vc-3', '+15550001000', 'vapi-pn-A', '+15551230001', t0, t0 + interval '60 seconds', 60, 'assistant-forwarded-call', 'Transferred', null, null, false);
  assert (select transfer_status from calls where external_call_id = 'vc-3') = 'connected';
  perform zella_record_call_status('vc-4', 'forwarding', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0, null);
  perform zella_record_inbound_call('vc-4', '+15550001000', 'vapi-pn-A', '+15551230001', t0, t0 + interval '40 seconds', 40, 'twilio-failed-to-connect-call', 'Transfer failed', null, null, false);
  assert (select transfer_status from calls where external_call_id = 'vc-4') = 'failed';
  raise notice 'PASS transfer outcome: forwarded -> connected; any other ending after an attempt -> failed (feeds the repeated-failure alert)';

  -- a status update and the first tool call racing for the same call still make one row
  perform zella_record_call_status('vc-5', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', t0, null);
  perform zella_ai_voice('vc-5', A, 'rules', '{"caller_number": "+15551230001"}');
  assert (select count(*) from calls where external_call_id = 'vc-5') = 1;
  raise notice 'PASS status update + tool call for the same call share one row';

  -- outbound status updates are left to the outbound flow
  assert zella_record_call_status('vc-out', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'outbound', t0, null) = 'ignored_outbound';
  -- a future or ancient timestamp from the provider is not trusted
  perform zella_record_call_status('vc-6', 'in-progress', '+15550001000', 'vapi-pn-A', '+15551230001', 'inbound', now() + interval '2 days', null);
  assert (select answered_at from calls where external_call_id = 'vc-6') is null;
  raise notice 'PASS outbound ignored; implausible provider timestamps not stored';
end $$;
