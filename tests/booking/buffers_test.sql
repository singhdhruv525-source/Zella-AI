-- Regression tests for sql/zella_booking_buffers.sql on an isolated copy (tests/booking/run.sh). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;
set timezone = 'UTC';

-- A: a salon without staff (one calendar), open all day, 15-minute buffer. B: a salon with two stylists.
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.n, i.id, 'UTC', true, 'active' from industries i,
  (values ('eb000000-0000-0000-0000-00000000000a', 'Buffer Salon A'), ('eb000000-0000-0000-0000-00000000000b', 'Buffer Salon B')) v(id, n)
 where i.slug = 'beauty-salon';
insert into business_hours (business_id, weekday, opens, closes)
select b, d, '00:00', '23:59' from generate_series(0, 6) d, unnest(array['eb000000-0000-0000-0000-00000000000a', 'eb000000-0000-0000-0000-00000000000b']::uuid[]) b;
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values
  ('eb100000-0000-0000-0000-00000000000a', 'eb000000-0000-0000-0000-00000000000a', 'Ava', 'receptionist', 'active', true),
  ('eb100000-0000-0000-0000-00000000000b', 'eb000000-0000-0000-0000-00000000000b', 'Ava', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, appointment_rules) values
  ('eb100000-0000-0000-0000-00000000000a', '{"buffer_minutes": 15}'), ('eb100000-0000-0000-0000-00000000000b', '{"buffer_minutes": 15}');
insert into staff_members (id, business_id, name, is_active, working_hours) select v.id::uuid, 'eb000000-0000-0000-0000-00000000000b', v.n, true, '{}'::jsonb
  from (values ('eb200000-0000-0000-0000-000000000001', 'Kim'), ('eb200000-0000-0000-0000-000000000002', 'Lee')) v(id, n);
create temp table t_day as select (date_trunc('day', now()) + interval '2 days')::timestamptz d;
grant select on t_day to authenticated;

-- B1: availability keeps the buffer on both sides
do $$ declare d timestamptz := (select d from t_day); a uuid; s timestamptz[]; begin
  a := public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'Cut', d + interval '10 hours', 30);
  select array_agg(slot_start) into s from public.zella_available_slots('eb000000-0000-0000-0000-00000000000a', d + interval '9 hours', d + interval '12 hours', 30, null, 15, 50);
  assert not (d + interval '10 hours 30 minutes' = any (s)), '10:30 offered right after a 10:00-10:30 booking with a 15-minute buffer';
  assert not (d + interval '9 hours 30 minutes' = any (s)), '9:30-10:00 offered, leaving no gap before 10:00';
  assert d + interval '10 hours 45 minutes' = any (s) and d + interval '9 hours 15 minutes' = any (s), 'times outside the buffer missing: ' || s::text;
  raise notice 'PASS B1 times next to a booking are held back by the buffer on both sides; times outside it are offered';
end $$;

-- B1: booking, AI booking and rescheduling into the buffer are refused
do $$ declare d timestamptz := (select d from t_day); r jsonb; other uuid; begin
  begin perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'Cut', d + interval '10 hours 30 minutes', 30); raise exception 'booked inside the buffer';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  r := public.zella_ai_booking(null, 'eb000000-0000-0000-0000-00000000000a', 'book', jsonb_build_object('start', (d + interval '10 hours 40 minutes')::text, 'first_name', 'Ana', 'phone', '+15550002222', 'confirmed', true));
  assert r ->> 'status' not in ('booked', 'requested'), 'AI booked inside the buffer: ' || r::text;
  other := public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'Colour', d + interval '14 hours', 30);
  begin perform public.zella_reschedule_appointment(other, d + interval '10 hours 35 minutes', null, 'test'); raise exception 'rescheduled into the buffer';
  exception when raise_exception then if sqlerrm not in ('SLOT_TAKEN', 'SLOT_UNAVAILABLE', 'NOT_AVAILABLE') and sqlerrm not like '%SLOT%' then raise; end if; end;
  perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'Cut', d + interval '10 hours 45 minutes', 30);
  raise notice 'PASS B1 booking, AI booking and rescheduling inside the buffer are refused; just outside it books';
end $$;

-- B2: the table guard, for writes that skip the booking functions (the CRM forms)
insert into auth.users (id, email, email_confirmed_at) values ('eb300000-0000-0000-0000-000000000001', 'staff@buffer.test', now());
insert into business_members (business_id, user_id, role, status) values
  ('eb000000-0000-0000-0000-00000000000a', 'eb300000-0000-0000-0000-000000000001', 'staff', 'active'),
  ('eb000000-0000-0000-0000-00000000000b', 'eb300000-0000-0000-0000-000000000001', 'staff', 'active');
select set_config('request.jwt.claims', '{"sub":"eb300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare d timestamptz := (select d from t_day); v uuid; begin
  begin
    insert into appointments (business_id, title, start_time, end_time, timezone, status) values ('eb000000-0000-0000-0000-00000000000a', 'CRM', d + interval '11 hours 20 minutes', d + interval '11 hours 50 minutes', 'UTC', 'scheduled');
    raise exception 'CRM booking inside the buffer accepted';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  insert into appointments (business_id, title, start_time, end_time, timezone, status, metadata)
  values ('eb000000-0000-0000-0000-00000000000a', 'CRM anyway', d + interval '11 hours 20 minutes', d + interval '11 hours 50 minutes', 'UTC', 'scheduled', '{"allow_overlap": true}') returning id into v;
  assert (select not (metadata ? 'allow_overlap') and conflict_note like 'Booked over another appointment by the team%' from appointments where id = v), 'override not recorded';
  -- a status change on that booking is never refused
  update appointments set status = 'confirmed' where id = v;
  raise notice 'PASS B2 a CRM booking into the buffer is refused; "book anyway" by staff is allowed, consumed and recorded; status changes pass';
end $$;
reset role;
select set_config('request.jwt.claims', '', false);   -- server code from here on
do $$ declare d timestamptz := (select d from t_day); begin
  -- server code (no signed-in person) can't use the override
  begin
    insert into appointments (business_id, title, start_time, end_time, timezone, status, metadata) values ('eb000000-0000-0000-0000-00000000000a', 'X', d + interval '10 hours 5 minutes', d + interval '10 hours 20 minutes', 'UTC', 'scheduled', '{"allow_overlap": true}');
    raise exception 'override used without a signed-in team member';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  -- a cancelled booking frees its time and its buffer
  update appointments set status = 'cancelled' where business_id = 'eb000000-0000-0000-0000-00000000000a' and title in ('Cut', 'CRM anyway');
  assert exists (select 1 from public.zella_available_slots('eb000000-0000-0000-0000-00000000000a', d + interval '10 hours 30 minutes', d + interval '10 hours 30 minutes', 30, null, 5, 1)), 'cancelled booking still holds its time';
  -- requested (not yet confirmed) appointments don't hold a time
  insert into appointments (business_id, title, start_time, end_time, timezone, status, booking_state) values ('eb000000-0000-0000-0000-00000000000a', 'Req', d + interval '16 hours', d + interval '16 hours 30 minutes', 'UTC', 'scheduled', 'requested');
  perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'Cut', d + interval '16 hours', 30);
  raise notice 'PASS B2 server writes cannot use the override; cancelled and requested bookings hold no time';
end $$;

-- staff rules: the buffer is per stylist; an unassigned booking claims no one
do $$ declare d timestamptz := (select d from t_day); begin
  perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000b', null, 'Kim 10', d + interval '10 hours', 30, 'eb200000-0000-0000-0000-000000000001');
  perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000b', null, 'Lee 10', d + interval '10 hours', 30, 'eb200000-0000-0000-0000-000000000002');
  begin perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000b', null, 'Kim 1030', d + interval '10 hours 30 minutes', 30, 'eb200000-0000-0000-0000-000000000001'); raise exception 'same stylist inside the buffer';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  begin insert into appointments (business_id, title, start_time, end_time, timezone, status, staff_id) values ('eb000000-0000-0000-0000-00000000000b', 'Kim direct', d + interval '10 hours 35 minutes', d + interval '11 hours', 'UTC', 'scheduled', 'eb200000-0000-0000-0000-000000000001');
    raise exception 'direct write for the same stylist inside the buffer';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  insert into appointments (business_id, title, start_time, end_time, timezone, status) values ('eb000000-0000-0000-0000-00000000000b', 'Unassigned', d + interval '10 hours', d + interval '10 hours 30 minutes', 'UTC', 'scheduled');
  -- moving Lee's booking onto Kim at the same time is a conflict
  begin update appointments set staff_id = 'eb200000-0000-0000-0000-000000000001' where title = 'Lee 10'; raise exception 'reassigned onto a busy stylist';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  raise notice 'PASS staff: the buffer is per stylist, another stylist is free, reassigning onto a busy stylist is refused, unassigned claims no one';
end $$;

-- buffer 0: back to back is fine
do $$ declare d timestamptz := (select d from t_day); begin
  update ai_agent_configs set appointment_rules = '{"buffer_minutes": 0}' where agent_id = 'eb100000-0000-0000-0000-00000000000a';
  perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'B2B 1', d + interval '18 hours', 30);
  perform public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'B2B 2', d + interval '18 hours 30 minutes', 30);
  update ai_agent_configs set appointment_rules = '{"buffer_minutes": 15}' where agent_id = 'eb100000-0000-0000-0000-00000000000a';
  raise notice 'PASS with no buffer, back-to-back bookings are allowed (and existing ones are untouched when the buffer changes)';
end $$;

-- history: two visits that are already over may overlap (recorded afterwards, or imported)
do $$ begin
  insert into appointments (business_id, title, start_time, end_time, timezone, status) values
    ('eb000000-0000-0000-0000-00000000000a', 'Past 1', now() - interval '3 hours', now() - interval '2 hours', 'UTC', 'scheduled'),
    ('eb000000-0000-0000-0000-00000000000a', 'Past 2', now() - interval '3 hours', now() - interval '2 hours', 'UTC', 'scheduled');
  raise notice 'PASS visits that are already over are never refused (history and imports)';
end $$;
