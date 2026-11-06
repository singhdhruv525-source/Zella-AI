-- BM2 seating (tests/tables/run.sh): combinations, sections and attributes, blocks, the seating board's states, staff
-- actions and the waitlist. The AI's tool (zella_ai_booking) and the board use the same engine. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select '5f000000-0000-0000-0000-0000000000c1', 'Seating Grill', i.id, 'America/New_York', true, 'active' from industries i where i.slug = 'restaurant';
insert into business_hours (business_id, weekday, opens, closes) select '5f000000-0000-0000-0000-0000000000c1', d, '00:00', '23:59' from generate_series(0, 6) d;
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('5f100000-0000-0000-0000-0000000000c1', '5f000000-0000-0000-0000-0000000000c1', 'Ava', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules) values
  ('5f100000-0000-0000-0000-0000000000c1', 'You are the host of Seating Grill.', '{}', '{}', '{"default_minutes": 90}');
insert into auth.users (id, email, email_confirmed_at) values ('5f300000-0000-0000-0000-0000000000c1', 'host@grill.test', now()), ('5f300000-0000-0000-0000-0000000000c2', 'viewer@grill.test', now());
insert into profiles (id, first_name, last_name) values ('5f300000-0000-0000-0000-0000000000c1', 'Hana', 'Host') on conflict (id) do nothing;
insert into business_members (business_id, user_id, role, status) values ('5f000000-0000-0000-0000-0000000000c1', '5f300000-0000-0000-0000-0000000000c1', 'manager', 'active'),
  ('5f000000-0000-0000-0000-0000000000c1', '5f300000-0000-0000-0000-0000000000c2', 'viewer', 'active');
create function pg_temp.at(hhmm text) returns timestamptz language sql as $$ select (((now() at time zone 'America/New_York')::date + 2)::text || ' ' || hhmm)::timestamp at time zone 'America/New_York' $$;
create function pg_temp.tid(n text) returns uuid language sql as $$ select id from restaurant_tables where business_id = '5f000000-0000-0000-0000-0000000000c1' and name = n $$;
create function pg_temp.names(ids uuid[]) returns text language sql as $$ select string_agg(name, '+' order by name) from restaurant_tables where id = any (ids) $$;
create function pg_temp.ai(action text, args jsonb) returns jsonb language sql as $$ select public.zella_ai_booking(null, '5f000000-0000-0000-0000-0000000000c1', action, args) $$;
create function pg_temp.book(party int, hhmm text, who text, seating text default null) returns jsonb language sql as $$
  select pg_temp.ai('book', jsonb_strip_nulls(jsonb_build_object('start', pg_temp.at(hhmm)::text, 'party_size', party, 'seating', seating, 'first_name', who, 'last_name', 'Guest',
    'phone', '+1212555' || lpad((abs(hashtext(who)) % 10000)::text, 4, '0'), 'title', 'Dinner', 'confirmed', true))) $$;
create function pg_temp.act(action text, args jsonb) returns jsonb language plpgsql as $$
declare r jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-0000000000c1","role":"authenticated","aal":"aal1"}', true);
  set local role authenticated; r := public.zella_table_action('5f000000-0000-0000-0000-0000000000c1', action, args); reset role; return r;
end $$;
create function pg_temp.board(p_at timestamptz default now()) returns jsonb language plpgsql as $$
declare r jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-0000000000c1","role":"authenticated","aal":"aal1"}', true);
  set local role authenticated; r := public.zella_table_board('5f000000-0000-0000-0000-0000000000c1', p_at); reset role; return r;
end $$;
create function pg_temp.state(b jsonb, n text) returns text language sql as $$ select e ->> 'state' from jsonb_array_elements(b -> 'tables') e where e ->> 'name' = n $$;

-- the manager sets up: three two-tops that may be joined (T01+T02 seats 3-4; all three seat 5-6), a lone two-top,
-- an accessible four-top, a patio four-top
select set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-0000000000c1","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
select public.zella_save_tables('5f000000-0000-0000-0000-0000000000c1', '[
  {"name":"T01","max_party":2},{"name":"T02","max_party":2},{"name":"T03","max_party":2},
  {"name":"T04","max_party":2},
  {"name":"T05","min_party":2,"max_party":4,"attributes":["accessible"]},
  {"name":"P01","section":"Patio","min_party":2,"max_party":4,"attributes":["outdoor"]}]');
select public.zella_save_combinations('5f000000-0000-0000-0000-0000000000c1', jsonb_build_array(
  jsonb_build_object('table_ids', jsonb_build_array(pg_temp.tid('T01'), pg_temp.tid('T02')), 'min_party', 3, 'max_party', 4),
  jsonb_build_object('table_ids', jsonb_build_array(pg_temp.tid('T01'), pg_temp.tid('T02'), pg_temp.tid('T03')), 'min_party', 5, 'max_party', 6)));
reset role;
select set_config('request.jwt.claims', '', false);

-- six people: two two-tops can't; three combinable two-tops can; tables in a combination aren't used again
do $$ declare r jsonb; begin
  r := pg_temp.book(6, '19:00', 'Patel');
  assert r ->> 'status' = 'booked' and pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) = 'T01+T02+T03', 'six: ' || r::text;
  r := pg_temp.book(4, '19:00', 'Lee');
  assert r ->> 'status' = 'booked' and pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) = 'T05', 'four: ' || r::text;
  r := pg_temp.book(4, '19:00', 'Kim');
  assert r ->> 'status' = 'booked' and pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) = 'P01', 'second four: ' || r::text;
  r := pg_temp.book(4, '19:00', 'Ng');   -- T04 alone seats 2 and can't be combined: refused
  assert r ->> 'status' = 'unavailable', 'four seated on a two-top: ' || r::text;
  r := pg_temp.book(2, '19:00', 'Ray');
  assert r ->> 'status' = 'booked' and pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) = 'T04', 'two: ' || r::text;
  raise notice 'PASS six people get the allowed three-table combination (never two two-tops); its tables are not reused; a four never lands on a lone two-top';
end $$;

-- seating preferences: patio and accessible are honoured or the time is not offered
do $$ declare r jsonb; begin
  r := pg_temp.ai('availability', jsonb_build_object('date', (pg_temp.at('19:00') at time zone 'America/New_York')::date::text, 'days', 1, 'party_size', 3, 'seating', 'patio'));
  assert not exists (select 1 from jsonb_array_elements(r -> 'slots') x where (x ->> 'start')::timestamptz between pg_temp.at('17:30') and pg_temp.at('20:00')), 'patio offered while P01 is taken: ' || r::text;
  r := pg_temp.book(3, '21:00', 'Out', 'patio');
  assert pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) = 'P01', 'patio: ' || r::text;
  r := pg_temp.book(2, '21:00', 'Wheel', 'accessible');
  assert pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) = 'T05', 'accessible: ' || r::text;
  raise notice 'PASS a patio or accessible request is seated only at a matching table, and times when none is free are not offered';
end $$;

-- blocks: refused if they would displace a reservation; otherwise the table is unavailable for that time
do $$ declare r jsonb; begin
  begin perform pg_temp.act('block', jsonb_build_object('table_id', pg_temp.tid('T04'), 'starts_at', pg_temp.at('18:00'), 'ends_at', pg_temp.at('22:00'), 'reason', 'Wobbly leg'));
    raise exception 'a block displaced a reservation';
  exception when raise_exception then if sqlerrm <> 'TABLE_HAS_RESERVATIONS' then raise; end if; end;
  perform pg_temp.act('block', jsonb_build_object('table_id', pg_temp.tid('T04'), 'starts_at', pg_temp.at('12:00'), 'ends_at', pg_temp.at('15:00'), 'reason', 'Wobbly leg'));
  r := pg_temp.book(2, '13:00', 'Lunch');
  assert pg_temp.names((select table_ids from appointments where id = (r ->> 'appointment_id')::uuid)) <> 'T04', 'blocked table used';
  raise notice 'PASS a block never displaces a reservation; a blocked table is not used';
end $$;

-- the board now: seat, depart, clear; held and reserved; a walk-in; the waitlist; who did it
do $$ declare r jsonb; b jsonb; v uuid; w uuid; begin
  -- a reservation starting in 20 minutes on T04, and a held one on T01 (both today)
  insert into appointments (business_id, title, start_time, end_time, timezone, status, party_size, booking_state, table_ids)
  values ('5f000000-0000-0000-0000-0000000000c1', 'Soon', date_trunc('minute', now()) + interval '20 minutes', date_trunc('minute', now()) + interval '110 minutes', 'America/New_York', 'scheduled', 2, 'confirmed', array[pg_temp.tid('T04')])
  returning id into v;
  insert into appointments (business_id, title, start_time, end_time, timezone, status, party_size, booking_state, hold_expires_at, table_ids)
  values ('5f000000-0000-0000-0000-0000000000c1', 'Holding', date_trunc('minute', now()) + interval '10 minutes', date_trunc('minute', now()) + interval '100 minutes', 'America/New_York', 'scheduled', 2, 'tentative', now() + interval '5 minutes', array[pg_temp.tid('T01')]);
  b := pg_temp.board();
  assert pg_temp.state(b, 'T04') = 'reserved' and pg_temp.state(b, 'T01') = 'held' and pg_temp.state(b, 'T02') = 'available', 'states: ' || (b -> 'tables')::text;
  -- a walk-in of 2 is seated now, not on the reserved or held tables
  r := pg_temp.act('walk_in', '{"party_size": 2, "name": "Jordan"}');
  assert pg_temp.names(array(select jsonb_array_elements_text(r -> 'tables'))::uuid[]) not in ('T04', 'T01'), 'walk-in on a promised table: ' || r::text;
  b := pg_temp.board();
  assert (b #>> '{summary,seated}')::int = 1, 'seated count: ' || (b -> 'summary')::text;
  -- the reservation arrives and is seated; it leaves; the table needs clearing until cleared
  perform pg_temp.act('seat', jsonb_build_object('appointment_id', v));
  assert pg_temp.state(pg_temp.board(), 'T04') = 'seated', 'not seated';
  perform pg_temp.act('depart', jsonb_build_object('appointment_id', v));
  assert pg_temp.state(pg_temp.board(), 'T04') = 'needs_clearing', 'not needs_clearing';
  begin perform pg_temp.act('walk_in', jsonb_build_object('party_size', 2, 'table_ids', jsonb_build_array(pg_temp.tid('T04')))); raise exception 'seated at an uncleared table';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  -- a party waits; clearing the table shows it fits
  r := pg_temp.act('waitlist_add', '{"party_size": 2, "name": "Taylor", "preferences": "quiet corner", "contact_ok": true}');
  w := (r ->> 'waitlist_id')::uuid;
  r := pg_temp.act('clear', jsonb_build_object('table_id', pg_temp.tid('T04')));
  assert r -> 'waitlist_fits' @> jsonb_build_array(jsonb_build_object('id', w)), 'waitlist match not shown: ' || r::text;
  b := pg_temp.board();
  assert pg_temp.state(b, 'T04') = 'available' and exists (select 1 from jsonb_array_elements(b -> 'waitlist') x where x ->> 'guest' = 'Taylor' and jsonb_array_length(x -> 'fits_now') > 0), 'board after clear: ' || b::text;
  r := pg_temp.act('walk_in', jsonb_build_object('party_size', 2, 'waitlist_id', w, 'table_ids', jsonb_build_array(pg_temp.tid('T04'))));
  assert (select status from waitlist_entries where id = w) = 'booked', 'waitlist party not marked seated';
  r := pg_temp.act('history', jsonb_build_object('table_id', pg_temp.tid('T04')));
  assert (r #>> '{events,0,by}') = 'Hana Host' and (select array_agg(e ->> 'action' order by e ->> 'at') from jsonb_array_elements(r -> 'events') e) @> array['seated', 'departed', 'cleared', 'walk_in_seated'], 'history: ' || r::text;
  raise notice 'PASS the board shows held, reserved, seated and needs-clearing tables; walk-ins avoid promised tables; a table can''t be reused until cleared; clearing shows the waiting party it fits; every action names who did it';
end $$;

-- a move onto a table already committed is refused, never silent; a viewer can't act
do $$ declare a1 uuid; a2 uuid; begin
  select id into a1 from appointments where business_id = '5f000000-0000-0000-0000-0000000000c1' and title = 'Dinner' and start_time = pg_temp.at('21:00') and table_ids = array[pg_temp.tid('P01')];
  select id into a2 from appointments where business_id = '5f000000-0000-0000-0000-0000000000c1' and title = 'Dinner' and start_time = pg_temp.at('21:00') and table_ids = array[pg_temp.tid('T05')];
  begin perform pg_temp.act('move', jsonb_build_object('appointment_id', a1, 'table_ids', jsonb_build_array(pg_temp.tid('T05')))); raise exception 'moved onto a taken table';
  exception when raise_exception then if sqlerrm <> 'SLOT_TAKEN' then raise; end if; end;
  assert (select table_ids from appointments where id = a2) = array[pg_temp.tid('T05')], 'the other reservation was displaced';
  begin perform pg_temp.act('move', jsonb_build_object('appointment_id', a1, 'table_ids', jsonb_build_array(pg_temp.tid('T02')))); raise exception 'party of 3 moved to a two-top';
  exception when raise_exception then if sqlerrm <> 'TABLES_DO_NOT_FIT' then raise; end if; end;
  perform set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-0000000000c2","role":"authenticated","aal":"aal1"}', true);
  set local role authenticated;
  begin perform public.zella_table_action('5f000000-0000-0000-0000-0000000000c1', 'clear', jsonb_build_object('table_id', pg_temp.tid('T02'))); raise exception 'a viewer acted';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  reset role;
  raise notice 'PASS a move onto a committed table is refused and the other booking is untouched; a move that doesn''t seat the party is refused; viewers can''t act';
end $$;

-- a configuration change that would unseat a future reservation is refused, with the list; nothing is saved
select set_config('request.jwt.claims', '{"sub":"5f300000-0000-0000-0000-0000000000c1","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare d text; begin
  begin perform public.zella_save_combinations('5f000000-0000-0000-0000-0000000000c1', jsonb_build_array(
          jsonb_build_object('table_ids', jsonb_build_array(pg_temp.tid('T01'), pg_temp.tid('T02')), 'min_party', 3, 'max_party', 4)));
    raise exception 'removing the combination Patel is booked on was accepted';
  exception when raise_exception then
    if sqlerrm <> 'AFFECTS_RESERVATIONS' then raise; end if;
    get stacked diagnostics d = pg_exception_detail;
    assert d like '%"party": 6%', 'affected list: ' || coalesce(d, 'none');
  end;
  assert (select count(*) from table_combinations where business_id = '5f000000-0000-0000-0000-0000000000c1' and active) = 2, 'the combination was switched off anyway';
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
do $$ begin raise notice 'PASS removing a combination a future party of 6 is booked on is refused with that booking listed; nothing changes until it is resolved'; end $$;
