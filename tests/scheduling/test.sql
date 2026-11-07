-- Release 2 (sql/zella_scheduling.sql) on an ISOLATED copy of the production schema (tests/scheduling/run.sh).
-- Synthetic people only (ids c8…); everything is rolled back. Times are days ahead of now, in a UTC business.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('c8000000-0000-0000-0000-00000000000a', 'own@r2.test', now()), ('c8000000-0000-0000-0000-00000000000b', 'mgr@r2.test', now()),
 ('c8000000-0000-0000-0000-00000000000c', 'staff@r2.test', now()), ('c8000000-0000-0000-0000-00000000000d', 'view@r2.test', now()),
 ('c8000000-0000-0000-0000-00000000000e', 'other@r2.test', now());
insert into public.profiles (id) select id from auth.users where email like '%@r2.test' on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('c8000000-0000-0000-0000-0000000000a1', 'R2 Cool Air', 'UTC', true, 'active', (select id from public.industries where slug = 'hvac' limit 1)),
 ('c8000000-0000-0000-0000-0000000000b1', 'R2 Other', 'UTC', true, 'active', (select id from public.industries where slug = 'hvac' limit 1));
insert into public.business_members (business_id, user_id, role, status)
select b::uuid, u::uuid, r, 'active' from (values
 ('c8000000-0000-0000-0000-0000000000a1', 'c8000000-0000-0000-0000-00000000000a', 'owner'), ('c8000000-0000-0000-0000-0000000000a1', 'c8000000-0000-0000-0000-00000000000b', 'manager'),
 ('c8000000-0000-0000-0000-0000000000a1', 'c8000000-0000-0000-0000-00000000000c', 'staff'), ('c8000000-0000-0000-0000-0000000000a1', 'c8000000-0000-0000-0000-00000000000d', 'viewer'),
 ('c8000000-0000-0000-0000-0000000000b1', 'c8000000-0000-0000-0000-00000000000e', 'owner')) v(b, u, r);
insert into public.staff_members (id, business_id, name, is_active) values
 ('c8000000-0000-0000-0000-0000000005a1', 'c8000000-0000-0000-0000-0000000000a1', 'Tech Ana', true),
 ('c8000000-0000-0000-0000-0000000005a2', 'c8000000-0000-0000-0000-0000000000a1', 'Tech Ben', true),
 ('c8000000-0000-0000-0000-0000000005a3', 'c8000000-0000-0000-0000-0000000000a1', 'Tech Cal', true),
 ('c8000000-0000-0000-0000-0000000005b1', 'c8000000-0000-0000-0000-0000000000b1', 'Elsewhere Eve', true);
insert into public.customers (id, business_id, first_name, last_name, phone) values
 ('c8000000-0000-0000-0000-0000000001a1', 'c8000000-0000-0000-0000-0000000000a1', 'Pat', 'Homeowner', '+15125550801'),
 ('c8000000-0000-0000-0000-0000000001b1', 'c8000000-0000-0000-0000-0000000000b1', 'Xena', 'Elsewhere', '+15125550802');
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, true) $$;
-- run p_sql and require it to fail with p_code (in the message or as the SQLSTATE); success is a test failure
create or replace function pg_temp.expect(p_sql text, p_code text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_code in sqlerrm) = 0 and sqlstate <> p_code then raise; end if;
    return;
  end;
  raise exception 'EXPECTED_FAILURE_DID_NOT_HAPPEN (%): %', p_code, p_sql;
end $$;
-- a time d days ahead at hh:mm UTC
create or replace function pg_temp.at(d int, hm text) returns timestamptz language sql as $$ select (current_date + d + hm::time) at time zone 'UTC' $$;
create temp table ids (k text primary key, val uuid) on commit drop;
grant all on ids to authenticated, anon;
-- book as the signed-in user; returns the id
create or replace function pg_temp.book(p_title text, p_start timestamptz, p_minutes int, p_res uuid[] default null, p_staff uuid default null, p_party int default null, p_crew uuid[] default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, resource_ids, staff_id, party_size, crew_staff_ids)
  values ('c8000000-0000-0000-0000-0000000000a1', 'c8000000-0000-0000-0000-0000000001a1', p_title, p_start, p_start + make_interval(mins => p_minutes), 'UTC', 'scheduled',
          p_res, p_staff, p_party, p_crew) returning id into v;
  return v;
end $$;
grant execute on function pg_temp.book(text, timestamptz, int, uuid[], uuid, int, uuid[]) to authenticated;

-- ===================================================== resources: who may set them up
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000b');   -- manager
do $$ begin
  insert into ids values ('chair1', public.zella_resource_save('c8000000-0000-0000-0000-0000000000a1', null, 'Chair 1', 'chair', 1, 15));
  insert into ids values ('chair2', public.zella_resource_save('c8000000-0000-0000-0000-0000000000a1', null, 'Chair 2', 'chair', 1, 0, null, 1));
  insert into ids values ('kennel', public.zella_resource_save('c8000000-0000-0000-0000-0000000000a1', null, 'Kennel room', 'space', 2, 0));
  insert into ids values ('van', public.zella_resource_save('c8000000-0000-0000-0000-0000000000a1', null, 'Van 2', 'vehicle', 1, 0));
  perform pg_temp.expect('select public.zella_resource_save(''c8000000-0000-0000-0000-0000000000a1'', null, ''chair 1'', ''chair'')', '23505');   -- same name
  perform pg_temp.expect('select public.zella_resource_save(''c8000000-0000-0000-0000-0000000000a1'', null, ''Lift'', ''spaceship'')', 'resources_kind');
  perform pg_temp.expect('select public.zella_resource_save(''c8000000-0000-0000-0000-0000000000a1'', null, ''Huge'', ''room'', 0)', 'resources_capacity');
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');   -- staff
do $$ begin
  perform pg_temp.expect('select public.zella_resource_save(''c8000000-0000-0000-0000-0000000000a1'', null, ''Staff chair'', ''chair'')', 'NOT_ALLOWED');
  perform pg_temp.expect('select public.zella_resource_needs_save(''c8000000-0000-0000-0000-0000000000a1'', ''[]'')', 'NOT_ALLOWED');
  perform pg_temp.expect('insert into public.resources (business_id, name, kind) values (''c8000000-0000-0000-0000-0000000000a1'', ''Direct'', ''room'')', '42501');
  assert (select count(*) from public.resources where business_id = 'c8000000-0000-0000-0000-0000000000a1') = 4, 'staff read the four resources';
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000e');   -- another business's owner
do $$ begin
  perform pg_temp.expect(format('select public.zella_resource_save(%L, %L, ''Mine now'', ''chair'')', 'c8000000-0000-0000-0000-0000000000a1', (select val from ids where k = 'chair1')), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_resource_save(%L, %L, ''Mine now'', ''chair'')', 'c8000000-0000-0000-0000-0000000000b1', (select val from ids where k = 'chair1')), 'NOT_FOUND');
  assert (select count(*) from public.resources where business_id = 'c8000000-0000-0000-0000-0000000000a1') = 0, 'another business sees no resources';
  perform pg_temp.expect('select public.zella_resource_day(''c8000000-0000-0000-0000-0000000000a1'', current_date)', 'NOT_ALLOWED');
end $$;
reset role;
select 'PASS resources: managers set them up (names unique, kinds and capacity checked); staff only read; no direct writes; another business sees and changes nothing';

-- ===================================================== no double-booking of a resource
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');   -- staff book
do $$ declare c1 uuid := (select val from ids where k = 'chair1'); c2 uuid := (select val from ids where k = 'chair2'); v uuid; begin
  insert into ids values ('a1', pg_temp.book('Cut', pg_temp.at(2, '10:00'), 60, array[c1]));
  perform pg_temp.expect(format('select pg_temp.book(''Cut 2'', %L, 30, array[%L]::uuid[])', pg_temp.at(2, '10:30'), c1), 'SLOT_TAKEN');                     -- overlaps
  perform pg_temp.expect(format('select pg_temp.book(''Cut 3'', %L, 30, array[%L]::uuid[])', pg_temp.at(2, '11:05'), c1), 'SLOT_TAKEN');                     -- inside its 15-minute buffer
  insert into ids values ('a2', pg_temp.book('Cut 4', pg_temp.at(2, '11:15'), 30, array[c1]));                                                               -- after the buffer
  insert into ids values ('a3', pg_temp.book('Cut 5', pg_temp.at(2, '10:30'), 30, array[c2]));                                                               -- another chair
  -- moving a booking onto a taken chair is refused too; cancelling frees it
  perform pg_temp.expect(format('update public.appointments set start_time = %L, end_time = %L where id = %L', pg_temp.at(2, '10:15'), pg_temp.at(2, '10:45'), (select val from ids where k = 'a3'))
                         || format('; update public.appointments set resource_ids = array[%L]::uuid[] where id = %L', c1, (select val from ids where k = 'a3')), 'SLOT_TAKEN');
  update public.appointments set status = 'cancelled' where id = (select val from ids where k = 'a1');
  v := pg_temp.book('Cut 6', pg_temp.at(2, '10:00'), 30, array[c1]);
  assert v is not null, 'a cancelled booking frees its chair';
  -- the same chair twice in one booking counts once
  v := pg_temp.book('Cut 7', pg_temp.at(3, '09:00'), 30, array[c1, c1]);
  assert (select resource_ids = array[c1] from public.appointments where id = v), 'duplicate ids are folded: ' || (select resource_ids::text from public.appointments where id = v);
  -- a past visit (history, an import) never clashes
  update public.appointments set start_time = now() - interval '3 hours', end_time = now() - interval '2 hours' where id = v;
  v := pg_temp.book('Old 2', now() - interval '3 hours', 30, array[c1]);
  assert v is not null, 'past visits are recorded whatever they overlap';
end $$;
reset role;
select 'PASS a resource takes one booking at a time, keeps its buffer free, and frees up when a booking is cancelled; moves are checked too; past visits never clash';

-- ===================================================== capacity, blocks, inactive and foreign resources
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');
do $$ declare kn uuid := (select val from ids where k = 'kennel'); van uuid := (select val from ids where k = 'van'); v uuid; begin
  perform pg_temp.book('Stay A', pg_temp.at(4, '09:00'), 240, array[kn]);
  perform pg_temp.book('Stay B', pg_temp.at(4, '10:00'), 240, array[kn]);                                                           -- capacity 2: two fit
  perform pg_temp.expect(format('select pg_temp.book(''Stay C'', %L, 60, array[%L]::uuid[])', pg_temp.at(4, '11:00'), kn), 'SLOT_TAKEN');   -- a third doesn't
  perform pg_temp.expect(format('select pg_temp.book(''Group'', %L, 60, array[%L]::uuid[], null, 2)', pg_temp.at(4, '08:30'), kn), 'SLOT_TAKEN');   -- a party of 2 next to one stay
  v := pg_temp.book('Group ok', pg_temp.at(5, '08:00'), 60, array[kn], null, 2);   -- a party of 2 alone fits
  perform pg_temp.expect(format('select pg_temp.book(''Group 3'', %L, 60, array[%L]::uuid[], null, 3)', pg_temp.at(6, '08:00'), kn), 'SLOT_TAKEN');   -- more than it holds
  -- a block (maintenance) on the van
  insert into public.blocked_times (business_id, title, start_time, end_time, resource_id) values ('c8000000-0000-0000-0000-0000000000a1', 'Van service', pg_temp.at(4, '08:00'), pg_temp.at(4, '17:00'), van);
  perform pg_temp.expect(format('select pg_temp.book(''Job'', %L, 60, array[%L]::uuid[])', pg_temp.at(4, '12:00'), van), 'SLOT_TAKEN');
  v := pg_temp.book('Job later', pg_temp.at(4, '17:00'), 60, array[van]);
  -- another business's resource: neither on a booking nor on a block
  perform pg_temp.expect(format('select pg_temp.book(''Sneaky'', %L, 60, array[%L]::uuid[])', pg_temp.at(7, '08:00'), 'c8000000-0000-0000-0000-0000000009b1'), 'TENANT_MISMATCH');
end $$;
reset role;
insert into public.resources (id, business_id, name, kind) values ('c8000000-0000-0000-0000-0000000009b1', 'c8000000-0000-0000-0000-0000000000b1', 'Their chair', 'chair');
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');
do $$ begin
  perform pg_temp.expect(format('select pg_temp.book(''Sneaky'', %L, 60, array[%L]::uuid[])', pg_temp.at(7, '08:00'), 'c8000000-0000-0000-0000-0000000009b1'), 'TENANT_MISMATCH');
  perform pg_temp.expect(format('insert into public.blocked_times (business_id, title, start_time, end_time, resource_id) values (%L, ''x'', %L, %L, %L)',
    'c8000000-0000-0000-0000-0000000000a1', pg_temp.at(7, '08:00'), pg_temp.at(7, '09:00'), 'c8000000-0000-0000-0000-0000000009b1'), 'TENANT_MISMATCH');
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000b');
do $$ declare c2 uuid := (select val from ids where k = 'chair2'); begin
  perform public.zella_resource_save('c8000000-0000-0000-0000-0000000000a1', c2, 'Chair 2', 'chair', 1, 0, null, 1, false);   -- out of use
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');
do $$ begin
  perform pg_temp.expect(format('select pg_temp.book(''Cut'', %L, 30, array[%L]::uuid[])', pg_temp.at(8, '09:00'), (select val from ids where k = 'chair2')), 'SLOT_TAKEN');
end $$;
reset role;
select 'PASS shared resources take as many people as they hold; blocks and resources out of use refuse bookings; another business''s resource is refused on bookings and blocks';

-- ===================================================== services that need a resource get one picked
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000b');
do $$ begin
  perform public.zella_resource_save('c8000000-0000-0000-0000-0000000000a1', (select val from ids where k = 'chair2'), 'Chair 2', 'chair', 1, 0, null, 1, true);   -- back in use
  assert public.zella_resource_needs_save('c8000000-0000-0000-0000-0000000000a1', '[{"service": "colour", "kind": "chair"}]') = 1, 'one need saved';
  perform pg_temp.expect('select public.zella_resource_needs_save(''c8000000-0000-0000-0000-0000000000a1'', ''[{"service": "x", "kind": "chair"}]'')', 'resource_needs_service_len');
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');
do $$ declare v1 uuid; v2 uuid; begin
  v1 := pg_temp.book('Colour - Ana', pg_temp.at(9, '10:00'), 60);
  v2 := pg_temp.book('Full colour', pg_temp.at(9, '10:00'), 60);
  assert (select cardinality(resource_ids) = 1 from public.appointments where id = v1) and (select cardinality(resource_ids) = 1 from public.appointments where id = v2), 'each colour got a chair';
  assert (select resource_ids from public.appointments where id = v1) <> (select resource_ids from public.appointments where id = v2), 'and not the same chair';
  perform pg_temp.expect(format('select pg_temp.book(''Colour again'', %L, 60)', pg_temp.at(9, '10:30')), 'SLOT_TAKEN');   -- both chairs taken
  v1 := pg_temp.book('Consultation', pg_temp.at(9, '10:30'), 30);   -- a service with no needs isn't affected
  assert (select resource_ids is null from public.appointments where id = v1), 'no needs, no resources';
end $$;
reset role;
select 'PASS a service that needs a chair gets a free one picked (never the same one twice), and is refused when none is free; other services are unaffected';

-- ===================================================== crews: nobody on two jobs at once
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');
do $$ declare ana uuid := 'c8000000-0000-0000-0000-0000000005a1'; ben uuid := 'c8000000-0000-0000-0000-0000000005a2'; cal uuid := 'c8000000-0000-0000-0000-0000000005a3'; v uuid; begin
  insert into ids values ('jobA', pg_temp.book('Install', pg_temp.at(10, '09:00'), 180, null, ana, null, array[ben]));
  perform pg_temp.expect(format('select pg_temp.book(''Repair'', %L, 60, null, %L)', pg_temp.at(10, '10:00'), ben), 'SLOT_TAKEN');                       -- Ben leads elsewhere while on Ana's crew
  perform pg_temp.expect(format('select pg_temp.book(''Repair'', %L, 60, null, %L, null, array[%L]::uuid[])', pg_temp.at(10, '10:00'), cal, ben), 'SLOT_TAKEN');   -- Ben on two crews
  perform pg_temp.expect(format('select pg_temp.book(''Repair'', %L, 60, null, %L, null, array[%L]::uuid[])', pg_temp.at(10, '10:00'), cal, ana), 'SLOT_TAKEN');   -- the lead on another crew
  v := pg_temp.book('Repair', pg_temp.at(10, '12:00'), 60, null, cal, null, array[ben]);   -- after the install
  v := pg_temp.book('Lead in own crew', pg_temp.at(11, '09:00'), 60, null, cal, null, array[cal]);
  assert (select crew_staff_ids is null from public.appointments where id = v), 'the lead is not also crew';
  perform pg_temp.expect(format('select pg_temp.book(''Foreign crew'', %L, 60, null, %L, null, array[%L]::uuid[])', pg_temp.at(12, '09:00'), cal, 'c8000000-0000-0000-0000-0000000005b1'), 'TENANT_MISMATCH');
end $$;
reset role;
select 'PASS crews: nobody leads or crews two overlapping jobs, the lead is never also crew, and people from another business are refused';

-- ===================================================== dispatch
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');
do $$ declare j uuid := (select val from ids where k = 'jobA'); u uuid; b jsonb; r uuid; begin
  u := pg_temp.book('Unassigned check', pg_temp.at(10, '10:00'), 60);
  b := public.zella_dispatch_board('c8000000-0000-0000-0000-0000000000a1', current_date + 10);
  assert jsonb_array_length(b -> 'technicians') = 3, 'three technicians: ' || (b -> 'technicians')::text;
  assert (select count(*) from jsonb_array_elements(b -> 'jobs') e where e ->> 'status' = 'unassigned') = 1, 'one unassigned job';
  assert (select e ->> 'status' from jsonb_array_elements(b -> 'jobs') e where (e ->> 'id')::uuid = j) = 'assigned', 'the install is assigned';
  -- the 10:00 job: Ana leads the install then and Ben is on its crew, so only Cal is free
  perform pg_temp.expect(format('select public.zella_dispatch_assign(%L, %L, null)', u, 'c8000000-0000-0000-0000-0000000005a1'), 'SLOT_TAKEN');
  perform pg_temp.expect(format('select public.zella_dispatch_assign(%L, %L, null)', u, 'c8000000-0000-0000-0000-0000000005a2'), 'SLOT_TAKEN');
  perform pg_temp.expect(format('select public.zella_dispatch_assign(%L, %L, array[%L]::uuid[])', u, 'c8000000-0000-0000-0000-0000000005a3', 'c8000000-0000-0000-0000-0000000005a2'), 'SLOT_TAKEN');
  perform public.zella_dispatch_assign(u, 'c8000000-0000-0000-0000-0000000005a3', null);
  assert (select staff_id = 'c8000000-0000-0000-0000-0000000005a3' from public.appointments where id = u), 'assigned to Cal';
  -- move along with what the screen showed
  perform pg_temp.expect(format('select public.zella_dispatch_status(%L, ''en_route'', ''on_site'')', j), 'CHANGED');
  perform pg_temp.expect(format('select public.zella_dispatch_status(%L, ''assigned'', ''completed'')', j), 'BAD_STEP');
  perform public.zella_dispatch_status(j, 'assigned', 'en_route');
  perform public.zella_dispatch_status(j, 'en_route', 'on_site');
  perform public.zella_dispatch_checklist(j, '[{"label": "Photos of the unit", "required": true}, {"label": "Filter swapped"}]');
  perform pg_temp.expect(format('select public.zella_dispatch_status(%L, ''on_site'', ''completed'')', j), 'CHECKLIST_INCOMPLETE');
  perform public.zella_dispatch_checklist(j, '[{"label": "Photos of the unit", "required": true, "done": true}, {"label": "Filter swapped"}]');
  perform public.zella_dispatch_status(j, 'on_site', 'paused', 'Waiting for a part');
  perform public.zella_dispatch_status(j, 'paused', 'needs_return');
  assert (select status = 'completed' from public.appointments where id = j), 'a finished job is a completed appointment';
  assert (select en_route_at is not null and on_site_at is not null and finished_at is not null and note = 'Waiting for a part' from public.job_dispatch where appointment_id = j), 'times and note kept';
  r := public.zella_dispatch_return_visit(j, pg_temp.at(13, '09:00'), 60, null, 'Fit the part');
  assert (select return_of = j and status = 'assigned' from public.job_dispatch where appointment_id = r), 'the return visit is linked to the job';
  assert (select staff_id = 'c8000000-0000-0000-0000-0000000005a1' and status = 'scheduled' from public.appointments where id = r), 'same lead, booked';
  b := public.zella_dispatch_board('c8000000-0000-0000-0000-0000000000a1', current_date + 10);
  assert (select (e ->> 'returns')::int = 1 and e ->> 'status' = 'needs_return' from jsonb_array_elements(b -> 'jobs') e where (e ->> 'id')::uuid = j), 'the board shows it needs a return, booked once';
  perform pg_temp.expect(format('select public.zella_dispatch_status(%L, ''needs_return'', ''on_site'')', j), 'BAD_STEP');   -- finished stays finished
  perform pg_temp.expect(format('select public.zella_dispatch_return_visit(%L, now() - interval ''1 day'', 60)', j), 'BAD_DATE');
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000d');   -- viewer
do $$ begin
  assert jsonb_array_length(public.zella_dispatch_board('c8000000-0000-0000-0000-0000000000a1', current_date + 10) -> 'jobs') >= 2, 'viewers see the board';
  assert not (public.zella_dispatch_board('c8000000-0000-0000-0000-0000000000a1', current_date + 10) ->> 'can_work')::boolean, 'and are told they can''t change it';
  perform pg_temp.expect(format('select public.zella_dispatch_status(%L, ''assigned'', ''en_route'')', (select val from ids where k = 'a2')), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_dispatch_assign(%L, null)', (select val from ids where k = 'a2')), 'NOT_ALLOWED');
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000e');   -- another business
do $$ begin
  perform pg_temp.expect('select public.zella_dispatch_board(''c8000000-0000-0000-0000-0000000000a1'', current_date)', 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_dispatch_checklist(%L, ''[]'')', (select val from ids where k = 'jobA')), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_dispatch_return_visit(%L, now() + interval ''2 days'', 60)', (select val from ids where k = 'jobA')), 'NOT_ALLOWED');
  assert (select count(*) from public.job_dispatch where business_id = 'c8000000-0000-0000-0000-0000000000a1') = 0, 'another business reads no dispatch rows';
end $$;
reset role;
select 'PASS dispatch: the board shows technicians, assigned and unassigned jobs; steps follow the screen (CHANGED) and the order (BAD_STEP); required checklist items before completing; return visits linked; viewers and other businesses change nothing';

-- ===================================================== recurring plans
set local role authenticated;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000b');   -- manager
do $$ declare p uuid; g jsonb; n int; wd int := extract(dow from current_date + 14)::int; begin
  -- every 2 weeks, starting two weeks out, at 08:00 with Cal
  p := public.zella_recurring_save('c8000000-0000-0000-0000-0000000000a1', null, jsonb_build_object('title', 'Filter service', 'customer_id', 'c8000000-0000-0000-0000-0000000001a1',
        'frequency', 'weekly', 'interval_count', 2, 'weekday', wd, 'start_at', '08:00', 'duration_minutes', 60, 'staff_id', 'c8000000-0000-0000-0000-0000000005a3',
        'starts_on', current_date + 14));
  insert into ids values ('plan', p);
  -- Cal is already busy on the second date: that one must be skipped, not forced
  perform pg_temp.book('Cal busy', pg_temp.at(28, '08:30'), 60, null, 'c8000000-0000-0000-0000-0000000005a3');
  g := public.zella_recurring_generate('c8000000-0000-0000-0000-0000000000a1', p, current_date + 60);
  assert (g ->> 'booked')::int = 3 and (g ->> 'skipped')::int = 1, 'days 14, 42, 56 booked and day 28 skipped: ' || g::text;
  assert (select reason like 'That time is taken%' from public.recurring_visits where plan_id = p and occurs_on = current_date + 28), 'the skip says why';
  g := public.zella_recurring_generate('c8000000-0000-0000-0000-0000000000a1', p, current_date + 60);
  assert (g ->> 'booked')::int = 0 and (g ->> 'skipped')::int = 0, 'running it again books nothing twice: ' || g::text;
  select count(*) into n from public.appointments a where a.metadata ->> 'recurring_plan_id' = p::text and a.booking_state = 'tentative' and a.hold_expires_at is null
     and coalesce((a.metadata ->> 'planned')::boolean, false) and a.staff_id = 'c8000000-0000-0000-0000-0000000005a3';
  assert n = 3, 'three planned visits, held but not confirmed: ' || n;
  assert not exists (select 1 from public.followup_tasks f join public.appointments a on a.id = f.appointment_id where a.metadata ->> 'recurring_plan_id' = p::text),
    'no customer message is queued for planned visits';
  -- monthly on the 15th, every 3 months
  p := public.zella_recurring_save('c8000000-0000-0000-0000-0000000000a1', null, jsonb_build_object('title', 'Quarterly check', 'frequency', 'monthly', 'interval_count', 3,
        'month_day', 15, 'start_at', '13:00', 'starts_on', date_trunc('month', current_date)::date));
  perform pg_temp.expect('select public.zella_recurring_save(''c8000000-0000-0000-0000-0000000000a1'', null, ''{"title": "Bad", "frequency": "weekly", "start_at": "09:00", "starts_on": "2030-01-01"}'')', 'recurring_plans_day');
  perform pg_temp.expect(format('select public.zella_recurring_save(%L, null, %L)', 'c8000000-0000-0000-0000-0000000000a1',
    jsonb_build_object('title', 'Theirs', 'frequency', 'weekly', 'weekday', 1, 'start_at', '09:00', 'starts_on', current_date, 'customer_id', 'c8000000-0000-0000-0000-0000000001b1')), 'NOT_VALID');
end $$;
select pg_temp.as_user('c8000000-0000-0000-0000-00000000000c');   -- staff
do $$ begin
  perform pg_temp.expect('select public.zella_recurring_generate(''c8000000-0000-0000-0000-0000000000a1'')', 'NOT_ALLOWED');
  perform pg_temp.expect('select public.zella_recurring_save(''c8000000-0000-0000-0000-0000000000a1'', null, ''{}'')', 'NOT_ALLOWED');
end $$;
reset role;
-- the dates themselves (server key)
set local role service_role;
do $$ declare p public.recurring_plans; d date[]; begin
  select * into p from public.recurring_plans where title = 'Quarterly check';
  d := array(select public.zella_recurring_dates(p, date '2026-01-01', date '2026-12-31'));
  assert d = array[date '2026-01-15', date '2026-04-15', date '2026-07-15', date '2026-10-15'] or p.starts_on > date '2026-01-01', 'quarterly dates: ' || d::text;
  p.starts_on := date '2026-01-01'; p.frequency := 'monthly'; p.interval_count := 3; p.month_day := 15;
  d := array(select public.zella_recurring_dates(p, date '2026-01-01', date '2026-12-31'));
  assert d = array[date '2026-01-15', date '2026-04-15', date '2026-07-15', date '2026-10-15'], 'every 3 months on the 15th: ' || d::text;
  p.frequency := 'weekly'; p.month_day := null; p.weekday := 2; p.interval_count := 2; p.starts_on := date '2026-03-04';   -- a Wednesday; first Tuesday after is the 10th
  d := array(select public.zella_recurring_dates(p, date '2026-03-01', date '2026-04-15'));
  assert d = array[date '2026-03-10', date '2026-03-24', date '2026-04-07'], 'every other Tuesday from the first after the start: ' || d::text;
  p.ends_on := date '2026-03-30';
  d := array(select public.zella_recurring_dates(p, date '2026-03-01', date '2026-04-15'));
  assert d = array[date '2026-03-10', date '2026-03-24'], 'and stops at the end date: ' || d::text;
end $$;
reset role;
select 'PASS recurring plans: dates for every N weeks or months; generating books each date once, skips clashes with the reason, and saves planned visits that queue no customer messages; managers only; other businesses'' customers refused';

-- ===================================================== anon and audit
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ begin
  perform pg_temp.expect('select 1 from public.resources', '42501');
  perform pg_temp.expect('select public.zella_dispatch_board(''c8000000-0000-0000-0000-0000000000a1'', current_date)', '42501');
  perform pg_temp.expect('select public.zella_recurring_generate(''c8000000-0000-0000-0000-0000000000a1'')', '42501');
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from (values ('resource_added'), ('resource_updated'), ('resource_needs_saved'), ('job_assigned'), ('job_status'), ('job_return_booked'),
                                           ('recurring_plan_added'), ('recurring_generated')) e(action)
                      where not exists (select 1 from public.audit_logs l where l.action = e.action and l.business_id = 'c8000000-0000-0000-0000-0000000000a1')),
    'every kind of change is in the audit log';
end $$;
select 'PASS anon gets nothing; every kind of change is in the audit log';
rollback;
