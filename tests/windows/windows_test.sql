-- BM1 arrival windows (tests/windows/run.sh). Through zella_ai_booking, the function the receptionist's
-- check_availability and book_appointment tools call. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.name, i.id, 'America/Chicago', true, 'active' from (values ('5d000000-0000-0000-0000-00000000000a', 'Window Plumbing', 'plumbing'), ('5d000000-0000-0000-0000-00000000000b', 'Exact Plumbing', 'plumbing'), ('5d000000-0000-0000-0000-00000000000c', 'Two Tech HVAC', 'hvac')) v(id, name, slug)
  join industries i on i.slug = v.slug;
insert into business_hours (business_id, weekday, opens, closes) select b, d, '08:00', '16:00' from generate_series(0, 6) d,
  (values ('5d000000-0000-0000-0000-00000000000a'::uuid), ('5d000000-0000-0000-0000-00000000000b'::uuid), ('5d000000-0000-0000-0000-00000000000c'::uuid)) x(b);
insert into ai_agents (id, business_id, name, agent_type, status, is_default) select ('5d1' || substr(b::text, 4))::uuid, b, 'Ava', 'receptionist', 'active', true
  from (values ('5d000000-0000-0000-0000-00000000000a'::uuid), ('5d000000-0000-0000-0000-00000000000b'::uuid), ('5d000000-0000-0000-0000-00000000000c'::uuid)) x(b);
insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules) values
  ('5d100000-0000-0000-0000-00000000000a', 'You are the receptionist of Window Plumbing.', '{}', '{}', '{"arrival_window_minutes": 120}'),
  ('5d100000-0000-0000-0000-00000000000b', 'You are the receptionist of Exact Plumbing.', '{}', '{}', '{"default_minutes": 60}'),
  ('5d100000-0000-0000-0000-00000000000c', 'You are the receptionist of Two Tech HVAC.', '{}', '{}', '{"arrival_window_minutes": 240}');
insert into staff_members (business_id, name, is_active) values ('5d000000-0000-0000-0000-00000000000c', 'Tech One', true), ('5d000000-0000-0000-0000-00000000000c', 'Tech Two', true);
create temp table t (k text primary key, v jsonb);
create function pg_temp.day() returns text language sql as $$ select ((now() at time zone 'America/Chicago')::date + 2)::text $$;
create function pg_temp.local(ts text) returns text language sql as $$ select to_char((ts::timestamptz) at time zone 'America/Chicago', 'HH24:MI') $$;

do $$ declare r jsonb; begin
  r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000b', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
  assert r #>> '{slots,0,say}' like '% at 8:00 AM' and r #>> '{slots,1,say}' like '% at 8:30 AM', 'exact times changed: ' || r::text;
  raise notice 'PASS no window set: exact times, as before (8:00, 8:30, ...)';
end $$;

do $$ declare r jsonb; s text[]; begin
  r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
  select array_agg(pg_temp.local(x ->> 'start') order by x ->> 'start') into s from jsonb_array_elements(r -> 'slots') x;
  assert s = array['08:00', '10:00', '12:00', '14:00'], 'windows: ' || coalesce(s::text, 'none') || ' ' || r::text;
  assert r #>> '{slots,0,say}' like '% between 8:00 AM and 10:00 AM', 'said: ' || (r #>> '{slots,0,say}');
  insert into t values ('first', r -> 'slots' -> 0);
  raise notice 'PASS 2-hour windows: 8-10, 10-12, 12-2, 2-4 from opening, never overlapping, said as "between 8:00 AM and 10:00 AM"';
end $$;

do $$ declare r jsonb; a record; begin
  r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000a', 'book', jsonb_build_object('start', (select v ->> 'start' from t where k = 'first'),
         'first_name', 'Pat', 'last_name', 'Lee', 'phone', '+15125556001', 'title', 'Leaking tap', 'confirmed', true));
  assert r ->> 'status' = 'booked', 'not booked: ' || r::text;
  assert r ->> 'say' like 'Booked for % between 8:00 AM and 10:00 AM. The team arrives within that window.%', 'said: ' || (r ->> 'say');
  select * into a from appointments where id = (r ->> 'appointment_id')::uuid;
  assert a.end_time - a.start_time = interval '2 hours', 'window not held: ' || (a.end_time - a.start_time)::text;
  r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
  assert pg_temp.local(r #>> '{slots,0,start}') = '10:00', 'booked window still offered: ' || r::text;
  r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000a', 'book', jsonb_build_object('start', (select v ->> 'start' from t where k = 'first'),
         'first_name', 'Sam', 'last_name', 'Diaz', 'phone', '+15125556002', 'title', 'Drain', 'confirmed', true));
  assert r ->> 'status' = 'unavailable' and r #>> '{slots,0,say}' like '%between%', 'the same window booked twice: ' || r::text;
  raise notice 'PASS booking holds the whole window, the caller is told the team arrives within it, and the window is not offered or booked again';
end $$;

-- two technicians: a window can be booked once per technician, never twice for the same one
do $$ declare r jsonb; ids uuid[] := '{}'; st uuid[]; begin
  for i in 1..3 loop
    r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000c', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
    if i < 3 then assert pg_temp.local(r #>> '{slots,0,start}') = '08:00', 'window ' || i || ': ' || r::text; end if;
    r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000c', 'book', jsonb_build_object('start', ((pg_temp.day() || ' 08:00')::timestamp at time zone 'America/Chicago')::text,
           'first_name', 'Caller', 'last_name', i::text, 'phone', '+1512555700' || i, 'title', 'AC', 'confirmed', true));
    if r ? 'appointment_id' and r ->> 'status' = 'booked' then ids := ids || (r ->> 'appointment_id')::uuid; end if;
  end loop;
  select array_agg(staff_id) into st from appointments where id = any (ids);
  assert cardinality(ids) = 2, 'expected two bookings for two technicians, got ' || cardinality(ids) || ' ' || r::text;
  assert st[1] is not null and st[2] is not null and st[1] <> st[2], 'not one per technician: ' || coalesce(st::text, 'none');
  -- the alternatives leave out the full 8-12 window on that day and offer its 12-4
  assert r ->> 'status' = 'unavailable', 'third booking of 8-12: ' || r::text;
  assert not exists (select 1 from jsonb_array_elements(r -> 'slots') x where (x ->> 'start')::timestamptz = (pg_temp.day() || ' 08:00')::timestamp at time zone 'America/Chicago'), 'full window offered again: ' || r::text;
  assert exists (select 1 from jsonb_array_elements(r -> 'slots') x where (x ->> 'start')::timestamptz = (pg_temp.day() || ' 12:00')::timestamp at time zone 'America/Chicago'), 'same-day 12-4 not offered: ' || r::text;
  raise notice 'PASS two technicians: the 8-12 window is booked once for each, a third caller is offered 12-4';
end $$;

-- the other rules still hold: a holiday, and booking switched off
insert into business_closures (business_id, starts_on, ends_on, label) values ('5d000000-0000-0000-0000-00000000000a', pg_temp.day()::date, pg_temp.day()::date, 'Closed');
do $$ declare r jsonb; begin
  r := public.zella_ai_booking(null, '5d000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
  assert jsonb_array_length(r -> 'slots') = 0, 'windows on a holiday: ' || r::text;
  raise notice 'PASS a holiday offers no windows';
end $$;

-- rescheduling and "find my appointments" say windows
delete from business_closures where business_id = '5d000000-0000-0000-0000-00000000000a';
insert into calls (business_id, direction, status, from_number, external_call_id, ai_handled) values ('5d000000-0000-0000-0000-00000000000a', 'inbound', 'answered', '+15125556001', 'win-call-1', true);
do $$ declare r jsonb; a uuid; begin
  r := public.zella_ai_manage_booking('win-call-1', '5d000000-0000-0000-0000-00000000000a', 'find', '{"caller_number": "+15125556001"}');
  assert r::text like '%between 8:00 AM and 10:00 AM%', 'find: ' || r::text;
  a := (r #>> '{appointments,0,appointment_id}')::uuid;
  r := public.zella_ai_manage_booking('win-call-1', '5d000000-0000-0000-0000-00000000000a', 'reschedule', jsonb_build_object('caller_number', '+15125556001', 'appointment_id', a,
         'start', ((pg_temp.day() || ' 12:00')::timestamp at time zone 'America/Chicago')::text, 'confirmed', true));
  assert r ->> 'say' like '%between 12:00 PM and 2:00 PM%', 'reschedule: ' || r::text;
  assert (select end_time - start_time from appointments where id = a) = interval '2 hours', 'window length lost on reschedule';
  raise notice 'PASS find and reschedule speak in windows, and a rescheduled job keeps its whole window';
end $$;
