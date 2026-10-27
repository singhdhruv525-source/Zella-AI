do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; B uuid := 'bbbbbbbb-0000-4000-8000-000000000002'; r jsonb; r2 jsonb; n int; v_id uuid;
begin
  -- confirmation is still required before booking
  r := public.zella_ai_tool('call-r1', A, 'book_appointment', '{"start": "2026-11-02T17:00:00Z", "first_name": "Ana", "phone": "+15551230001"}');
  assert r ->> 'status' = 'need_confirmation' and (select count(*) from appointments where start_time = '2026-11-02T17:00:00Z') = 0, 'confirmation: ' || r::text;
  raise notice 'PASS caller confirmation still required (no booking without confirmed=true)';
  -- business hours still enforced (Sunday, and 8pm on a weekday)
  r := public.zella_ai_tool('call-r2', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-01T15:00:00Z", "first_name": "Ana", "phone": "+15551230001"}');
  r2 := public.zella_ai_tool('call-r3', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-03T01:00:00Z", "first_name": "Ana", "phone": "+15551230001"}');
  assert r ->> 'status' = 'unavailable' and r2 ->> 'status' = 'unavailable', 'hours: ' || r::text || r2::text;
  raise notice 'PASS business hours still enforced (Sunday and 8 pm refused, alternatives offered: %)', jsonb_array_length(r -> 'slots');
  -- sequential retry after completion returns the same result, no second appointment
  r := public.zella_ai_tool('call-r4', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T18:00:00Z", "first_name": "Ana", "phone": "+15551230001"}');
  r2 := public.zella_ai_tool('call-r4', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T18:00:00Z", "first_name": "Ana", "phone": "+15551230001"}');
  assert r ->> 'status' = 'booked' and r2 ->> 'status' = 'booked' and r2 ->> 'repeated' = 'true' and r ->> 'appointment_id' = r2 ->> 'appointment_id', 'retry: ' || r2::text;
  assert (select count(*) from appointments where start_time = '2026-11-02T18:00:00Z') = 1;
  raise notice 'PASS retry after completion returns the first result (same appointment id)';
  -- a refused attempt, retried, is refused again (consistent), and nothing is created
  r := public.zella_ai_tool('call-r5', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T18:00:00Z", "first_name": "Ben", "phone": "+15551230002"}');
  r2 := public.zella_ai_tool('call-r5', A, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T18:00:00Z", "first_name": "Ben", "phone": "+15551230002"}');
  assert r ->> 'status' = 'unavailable' and r2 ->> 'status' = 'unavailable' and (select count(*) from appointments where start_time = '2026-11-02T18:00:00Z') = 1, 'refused retry';
  raise notice 'PASS a refused attempt retried is refused again, nothing created';
  -- an expired hold does not block; a live hold does
  insert into appointments (business_id, title, start_time, end_time, booking_state, hold_expires_at) values
    (A, 'old hold', '2026-11-02T19:00:00Z', '2026-11-02T19:30:00Z', 'tentative', now() - interval '1 minute'),
    (A, 'live hold', '2026-11-02T19:30:00Z', '2026-11-02T20:00:00Z', 'tentative', now() + interval '10 minutes');
  v_id := public.zella_book_appointment(A, null, 'x', '2026-11-02T19:00:00Z', 30, null, null, null);
  begin perform public.zella_book_appointment(A, null, 'y', '2026-11-02T19:30:00Z', 30, null, null, null); raise exception 'live hold ignored';
  exception when others then assert sqlerrm = 'SLOT_TAKEN', sqlerrm; end;
  raise notice 'PASS hold rules unchanged (expired hold frees the slot, live hold blocks it)';
  -- a requested (unconfirmed) appointment still does not block, as before
  insert into appointments (business_id, title, start_time, end_time, booking_state) values (A, 'req', '2026-11-02T20:00:00Z', '2026-11-02T20:30:00Z', 'requested');
  perform public.zella_book_appointment(A, null, 'z', '2026-11-02T20:00:00Z', 30, null, null, null);
  raise notice 'PASS requested appointments still do not block a slot (unchanged behaviour)';
  -- another business's calendar is independent, and its lock doesn't interfere
  perform public.zella_book_appointment(B, null, 'other', '2026-11-02T18:00:00Z', 30, null, null, null);
  assert (select count(*) from appointments where business_id = B) = 1;
  raise notice 'PASS businesses are independent (same time at another business books fine)';
  -- staff bookings straight into the CRM table are unchanged (deliberate double booking still possible)
  insert into appointments (business_id, title, start_time, end_time) values (A, 'staff overbook', '2026-11-02T18:00:00Z', '2026-11-02T18:30:00Z');
  raise notice 'PASS staff direct inserts unchanged (CRM can still double-book on purpose)';
  -- the patched duplicate-request lock is per business: the same key at another business is not blocked or reused
  r := public.zella_ai_tool('call-r4', B, 'book_appointment', '{"confirmed": true, "start": "2026-11-02T21:00:00Z", "first_name": "Cy", "phone": "+15551230003"}');
  assert coalesce(r ->> 'repeated', 'false') = 'false', 'cross-business reuse: ' || r::text;
  raise notice 'PASS a saved result is never reused for another business (status %)', r ->> 'status';
end $$;
