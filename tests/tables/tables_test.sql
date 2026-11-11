-- BM2 tables (tests/tables/run.sh): the AI's booking tool (zella_ai_booking), the CRM's booking and reschedule
-- functions and a direct table write all seat reservations at tables. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.name, i.id, 'America/New_York', true, 'active' from (values ('5f000000-0000-0000-0000-00000000000a', 'Table Bistro'), ('5f000000-0000-0000-0000-00000000000b', 'No Tables Diner')) v(id, name)
  join industries i on i.slug = 'restaurant';
insert into business_hours (business_id, weekday, opens, closes) select b, d, '17:00', '22:00' from generate_series(0, 6) d,
  (values ('5f000000-0000-0000-0000-00000000000a'::uuid), ('5f000000-0000-0000-0000-00000000000b'::uuid)) x(b);
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values
  ('5f100000-0000-0000-0000-00000000000a', '5f000000-0000-0000-0000-00000000000a', 'Ava', 'receptionist', 'active', true),
  ('5f100000-0000-0000-0000-00000000000b', '5f000000-0000-0000-0000-00000000000b', 'Ava', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules) values
  ('5f100000-0000-0000-0000-00000000000a', 'You are the host of Table Bistro.', '{}', '{}', '{"default_minutes": 90, "max_party_ai": 6}'),
  ('5f100000-0000-0000-0000-00000000000b', 'You are the host of No Tables Diner.', '{}', '{}', '{"default_minutes": 60}');
insert into auth.users (id, email, email_confirmed_at) values ('5f300000-0000-0000-0000-000000000001', 'owner@bistro.test', now()), ('5f300000-0000-0000-0000-000000000002', 'staff@bistro.test', now());
insert into business_members (business_id, user_id, role, status) values ('5f000000-0000-0000-0000-00000000000a', '5f300000-0000-0000-0000-000000000001', 'owner', 'active'),
  ('5f000000-0000-0000-0000-00000000000a', '5f300000-0000-0000-0000-000000000002', 'staff', 'active');
create function pg_temp.day() returns text language sql as $$ select ((now() at time zone 'America/New_York')::date + 2)::text $$;
create function pg_temp.at(hhmm text) returns timestamptz language sql as $$ select (pg_temp.day() || ' ' || hhmm)::timestamp at time zone 'America/New_York' $$;
create function pg_temp.book(party int, hhmm text, who text) returns jsonb language sql as $$
  select public.zella_ai_booking(null, '5f000000-0000-0000-0000-00000000000a', 'book', jsonb_build_object('start', pg_temp.at(hhmm)::text, 'party_size', party,
           'first_name', who, 'last_name', 'Guest', 'phone', '+1212555' || lpad((abs(hashtext(who)) % 10000)::text, 4, '0'), 'title', 'Dinner', 'confirmed', true)) $$;

-- the owner saves the tables (staff can't)
select set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-000000000002","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ begin perform public.zella_save_tables('5f000000-0000-0000-0000-00000000000a', '[{"name":"T1","max_party":2}]'); raise exception 'staff saved tables';
exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
select public.zella_save_tables('5f000000-0000-0000-0000-00000000000a',
  '[{"name":"Two-top 1","max_party":2},{"name":"Two-top 2","max_party":2},{"name":"Four-top","min_party":2,"max_party":4},{"name":"Booth","min_party":4,"max_party":6}]');
reset role;
select set_config('request.jwt.claims', '', false);

do $$ declare r jsonb; begin
  r := public.zella_ai_booking(null, '5f000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
  assert r ->> 'status' = 'need_info' and r ->> 'say' like 'Ask how many people%', 'no party size asked: ' || r::text;
  r := public.zella_ai_booking(null, '5f000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1, 'party_size', 2));
  assert (r #>> '{slots,0,start}')::timestamptz = pg_temp.at('17:00'), 'first time: ' || r::text;
  assert not exists (select 1 from jsonb_array_elements(r -> 'slots') x where (x ->> 'start')::timestamptz > pg_temp.at('20:30')), 'a 90-minute table offered after 8:30 PM';
  raise notice 'PASS the AI asks how many people first, then offers times from opening; nothing that would run past closing';
end $$;

-- 7 PM: two couples, a four and a booth all at once; a fifth couple is refused, a party of 4 still has the booth taken
do $$ declare r jsonb; t text[]; begin
  r := pg_temp.book(2, '19:00', 'Ann');  assert r ->> 'status' = 'booked', 'Ann: ' || r::text;
  r := pg_temp.book(2, '19:00', 'Bob');  assert r ->> 'status' = 'booked', 'Bob: ' || r::text;
  r := pg_temp.book(4, '19:00', 'Cy');   assert r ->> 'status' = 'booked', 'Cy: ' || r::text;
  r := pg_temp.book(5, '19:00', 'Di');   assert r ->> 'status' = 'booked', 'Di: ' || r::text;
  select array_agg(t.name order by t.name) into t from appointments a join restaurant_tables t on t.id = any (a.table_ids) where a.business_id = '5f000000-0000-0000-0000-00000000000a';
  assert t = array['Booth', 'Four-top', 'Two-top 1', 'Two-top 2'], 'seating: ' || coalesce(t::text, 'none');
  r := pg_temp.book(2, '19:00', 'Eve');
  assert r ->> 'status' = 'unavailable', 'fifth party seated: ' || r::text;
  r := public.zella_ai_booking(null, '5f000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1, 'party_size', 2));
  assert not exists (select 1 from jsonb_array_elements(r -> 'slots') x where (x ->> 'start')::timestamptz between pg_temp.at('18:00') and pg_temp.at('20:00')), '7 PM-ish still offered for 2: ' || r::text;
  raise notice 'PASS four parties at 7 PM, each at the smallest table that fits (2, 2, 4 at the four-top, 5 in the booth); a fifth is refused and those times are no longer offered for 2';
end $$;

-- a party of 8 goes to the team; a party of 6 the booth would seat is fine another time
do $$ declare r jsonb; begin
  r := public.zella_ai_booking(null, '5f000000-0000-0000-0000-00000000000a', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1, 'party_size', 8));
  assert r ->> 'status' = 'large_party', 'large party: ' || r::text;
  r := public.zella_ai_tool(null, '5f000000-0000-0000-0000-00000000000a', 'book_appointment',
    jsonb_build_object('start', pg_temp.at('17:00'), 'party_size', 8, 'seating', 'accessible',
      'notes', 'Birthday celebration', 'first_name', 'Big', 'phone', '+12125550188', 'confirmed', true), null);
  assert r ->> 'status' = 'requested' and (select booking_state from appointments where id = (r ->> 'appointment_id')::uuid) = 'requested', 'party of 8 booked: ' || r::text;
  assert (select metadata ->> 'seating' = 'accessible' and party_size = 8
      and description like '%Birthday celebration%' and coalesce(cardinality(table_ids), 0) = 0
    from appointments where id = (r ->> 'appointment_id')::uuid), 'handoff lost seating, party, notes or assigned tables';
  r := pg_temp.book(6, '17:00', 'Six');
  assert r ->> 'status' = 'booked' and (select t.name from appointments a join restaurant_tables t on t.id = any (a.table_ids) where a.id = (r ->> 'appointment_id')::uuid) = 'Booth', 'party of 6: ' || r::text;
  raise notice 'PASS a party of 8 (over the AI limit of 6) is passed to the team as a request; a party of 6 is seated in the booth';
end $$;

-- the CRM books and moves through the same rules; a direct write is seated too
select set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare v uuid; b uuid; begin
  begin perform public.zella_book_appointment('5f000000-0000-0000-0000-00000000000a', null, 'Walk-in call', pg_temp.at('19:00'), 90, null, null, null); raise exception 'no party size accepted';
  exception when raise_exception then if sqlerrm <> 'PARTY_SIZE_REQUIRED' then raise; end if; end;
  begin perform public.zella_book_appointment('5f000000-0000-0000-0000-00000000000a', null, 'Walk-in call', pg_temp.at('19:30'), 90, null, 2, null); raise exception 'double seated';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  v := public.zella_book_appointment('5f000000-0000-0000-0000-00000000000a', null, 'Early', pg_temp.at('17:00'), 90, null, 2, null);
  -- move it to 7 PM: every two-top is taken then, so it is refused; to 9 PM: re-seated
  begin perform public.zella_reschedule_appointment(v, pg_temp.at('19:00'), null, 'staff'); raise exception 'moved onto a taken table';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  perform public.zella_reschedule_appointment(v, pg_temp.at('20:30'), null, 'staff');
  assert (select table_ids from appointments where id = v) is not null, 'not seated after the move';
  insert into appointments (business_id, title, start_time, end_time, timezone, status, party_size, booking_state)
  values ('5f000000-0000-0000-0000-00000000000a', 'Typed in', pg_temp.at('17:00'), pg_temp.at('18:30'), 'America/New_York', 'scheduled', 3, 'confirmed') returning id into b;
  assert (select t.name from appointments a join restaurant_tables t on t.id = any (a.table_ids) where a.id = b) = 'Four-top', 'direct write not seated';
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
do $$ begin raise notice 'PASS the CRM needs a party size, can''t double-seat, moves are re-seated or refused, and a reservation typed straight in is seated'; end $$;

-- a business without tables is unchanged
do $$ declare r jsonb; begin
  r := public.zella_ai_booking(null, '5f000000-0000-0000-0000-00000000000b', 'availability', jsonb_build_object('date', pg_temp.day(), 'days', 1));
  assert r ->> 'status' = 'slots' and jsonb_array_length(r -> 'slots') > 0, 'no-tables restaurant: ' || r::text;
  raise notice 'PASS a restaurant without tables books as before (no party size needed)';
end $$;
