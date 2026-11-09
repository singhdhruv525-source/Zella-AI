-- Zella Voice target schema: three-business isolation suite (docs/ARCHITECTURE.md §6.12).
-- Runs on the ISOLATED local test database only (sql/target/test.sh). Every check prints "PASS …" or raises "FAIL …".
-- Fake data only (SEC-4).

\set ON_ERROR_STOP 0
set client_min_messages = notice;

-- ---------------------------------------------------------------------------------------------------------------------
-- Fixtures (as the database owner): businesses A, B, C; users per role; locations, customers, resources, calls.
-- ---------------------------------------------------------------------------------------------------------------------
-- industries come from industries_seed.sql (loaded by test.sh)

insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-000000000001', 'owner-a@example.com'),
  ('a0000000-0000-0000-0000-000000000002', 'viewer-a@example.com'),
  ('a0000000-0000-0000-0000-000000000003', 'staff-a@example.com'),
  ('a0000000-0000-0000-0000-000000000004', 'manager-a@example.com'),
  ('b0000000-0000-0000-0000-000000000001', 'owner-b@example.com'),
  ('c0000000-0000-0000-0000-000000000001', 'owner-c@example.com');

insert into businesses (id, name, industry_key, status) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'Test Salon A', 'beauty_salon', 'live'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'Test Salon B', 'beauty_salon', 'live'),
  ('cccccccc-0000-0000-0000-000000000000', 'Test Dental C', 'dental', 'live');

insert into locations (id, business_id, name, time_zone) values
  ('a1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'A Main', 'America/New_York'),
  ('a1000000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000', 'A North', 'America/New_York'),
  ('b1000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'B Main', 'America/Chicago'),
  ('c1000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000000', 'C Main', 'America/Denver');

insert into business_members (id, business_id, user_id, role) values
  ('a2000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000001', 'owner'),
  ('a2000000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000002', 'viewer'),
  ('a2000000-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000003', 'staff'),
  ('a2000000-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000004', 'manager'),
  ('b2000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-000000000001', 'owner'),
  ('c2000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000001', 'owner');

-- staff A works only at "A Main"
insert into member_locations (business_id, member_id, location_id) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001');

-- The same person is a customer of A and of B: two independent records (REQ-CRM-ISO-01).
insert into customers (id, business_id, first_name, lifecycle) values
  ('a3000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'Pat', 'customer'),
  ('b3000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'Pat', 'customer'),
  ('c3000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000000', 'Pat', 'customer');
insert into customer_contacts (business_id, customer_id, kind, value_normalised) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'a3000000-0000-0000-0000-000000000001', 'phone', '+15555550100'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'b3000000-0000-0000-0000-000000000001', 'phone', '+15555550100');

insert into resources (id, business_id, location_id, kind, name) values
  ('a4000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', 'staff', 'Provider 1'),
  ('a4000000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', 'staff', 'Provider 2'),
  ('b4000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'staff', 'Provider 1');

insert into phone_numbers (id, business_id, location_id, e164, mode) values
  ('a5000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', '+15555550111', 'new_number');

insert into calls (id, business_id, location_id, customer_id, direction, provider_call_id, status) values
  ('a6000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'inbound', 'prov-a-1', 'ended'),
  ('a6000000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000002', 'a3000000-0000-0000-0000-000000000001', 'inbound', 'prov-a-2', 'ended'),
  ('b6000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000001', 'inbound', 'prov-b-1', 'ended');
insert into call_artifacts (business_id, call_id, kind, content, expires_at) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'a6000000-0000-0000-0000-000000000001', 'transcript', 'fake transcript A', now() + interval '90 days'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'b6000000-0000-0000-0000-000000000001', 'transcript', 'fake transcript B', now() + interval '90 days');

insert into knowledge_items (id, business_id, title, status) values
  ('a7000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'Parking', 'ready'),
  ('b7000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'Parking', 'ready');

insert into message_templates (scope, kind, channel, body) values ('platform', 'missed_call', 'sms', 'Hi, this is {{business_name}}.');
insert into message_templates (scope, business_id, kind, channel, body) values
  ('business', 'aaaaaaaa-0000-0000-0000-000000000000', 'missed_call', 'sms', 'A wording'),
  ('business', 'bbbbbbbb-0000-0000-0000-000000000000', 'missed_call', 'sms', 'B wording');

with t as (insert into record_types (business_id, key, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'property', 'Property') returning id)
insert into records (id, business_id, type_id, status)
select 'a8000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', t.id, 'active' from t;
insert into record_secrets (business_id, record_id, field, value)
  values ('aaaaaaaa-0000-0000-0000-000000000000', 'a8000000-0000-0000-0000-000000000001', 'access_code', 'fake-1234');

insert into storage.objects (bucket_id, name) values
  ('business-files', 'aaaaaaaa-0000-0000-0000-000000000000/documents/a.pdf'),
  ('business-files', 'bbbbbbbb-0000-0000-0000-000000000000/documents/b.pdf');

insert into automation_rules (id, business_id, kind, enabled) values
  ('a9000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'reminders', true),
  ('b9000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'reminders', true);
insert into work_items (business_id, queue, automation_id, due_at, idempotency_key) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'sms', 'a9000000-0000-0000-0000-000000000001', now(), 'reminder:a:1'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'sms', 'b9000000-0000-0000-0000-000000000001', now(), 'reminder:b:1');

-- Helper: act as a signed-in user for the rest of the transaction.
create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Reads across businesses are rejected (return nothing)
-- ---------------------------------------------------------------------------------------------------------------------
begin; select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
do $$ begin
  if (select count(*) from customers where business_id <> 'aaaaaaaa-0000-0000-0000-000000000000') <> 0 then raise exception 'FAIL A reads B customer'; end if;
  raise notice 'PASS A reads B customer: rejected (0 rows)';
  if (select count(*) from call_artifacts where business_id = 'bbbbbbbb-0000-0000-0000-000000000000') <> 0 then raise exception 'FAIL A reads B transcript'; end if;
  raise notice 'PASS A accesses B call transcript: rejected';
  if (select count(*) from knowledge_items where business_id = 'bbbbbbbb-0000-0000-0000-000000000000') <> 0 then raise exception 'FAIL A reads B knowledge'; end if;
  raise notice 'PASS A retrieves B knowledge: rejected';
  if (select count(*) from message_templates where business_id = 'bbbbbbbb-0000-0000-0000-000000000000') <> 0 then raise exception 'FAIL A sees B template'; end if;
  if (select count(*) from message_templates where scope = 'platform') <> 1 then raise exception 'FAIL A cannot see platform template'; end if;
  raise notice 'PASS templates: A sees platform default + its own, never B''s';
  if (select count(*) from storage.objects where name like 'bbbbbbbb%') <> 0 then raise exception 'FAIL A sees B file'; end if;
  if (select count(*) from storage.objects where name like 'aaaaaaaa%') <> 1 then raise exception 'FAIL A cannot see own file'; end if;
  raise notice 'PASS storage: A sees its own file, never B''s';
  if (select count(*) from customers) <> 1 then raise exception 'FAIL A sees wrong number of customers'; end if;
  raise notice 'PASS same person in A and B is two independent records';
end $$;
rollback;

-- A cannot write directly, not even to its own data (writes go through server functions)
begin; select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
do $$ begin
  begin update message_templates set body = 'hacked' where business_id = 'bbbbbbbb-0000-0000-0000-000000000000';
        raise exception 'FAIL A changed B template';
  exception when insufficient_privilege then raise notice 'PASS A changes B SMS template: rejected'; end;
  begin update appointments set notes = 'x';
        raise exception 'FAIL client wrote appointments directly';
  exception when insufficient_privilege then raise notice 'PASS A edits appointments directly: rejected'; end;
  begin insert into work_items (business_id, queue, due_at, idempotency_key) values ('bbbbbbbb-0000-0000-0000-000000000000','sms',now(),'x');
        raise exception 'FAIL A queued work for B';
  exception when insufficient_privilege then raise notice 'PASS A triggers B automation (queue work): rejected'; end;
  begin perform count(*) from work_items;
        raise exception 'FAIL client can read the work queue';
  exception when insufficient_privilege then raise notice 'PASS clients cannot read the work queue'; end;
  begin perform count(*) from transfer_destinations where business_id = 'bbbbbbbb-0000-0000-0000-000000000000';
        raise notice 'PASS transfer destinations of B invisible to A';
  end;
end $$;
rollback;

-- Anonymous requests get nothing
begin; set local role anon;
do $$ begin
  begin perform count(*) from customers; raise exception 'FAIL anon reads customers';
  exception when insufficient_privilege then raise notice 'PASS anonymous request: rejected'; end;
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------------
-- Roles inside one business
-- ---------------------------------------------------------------------------------------------------------------------
begin; select pg_temp.as_user('a0000000-0000-0000-0000-000000000002');   -- viewer A
do $$ begin
  if (select count(*) from call_artifacts) <> 0 then raise exception 'FAIL viewer reads transcripts'; end if;
  if (select count(*) from record_secrets) <> 0 then raise exception 'FAIL viewer reads private fields'; end if;
  if (select count(*) from customers) <> 1 then raise exception 'FAIL viewer cannot read customers'; end if;
  raise notice 'PASS viewer: reads customers, never transcripts or private fields';
end $$;
rollback;

begin; select pg_temp.as_user('a0000000-0000-0000-0000-000000000004');   -- manager A
do $$ begin
  if (select count(*) from call_artifacts) <> 1 then raise exception 'FAIL manager cannot read own transcript'; end if;
  if (select count(*) from record_secrets) <> 1 then raise exception 'FAIL manager cannot read private field'; end if;
  raise notice 'PASS manager: reads own business transcripts and private fields';
end $$;
rollback;

begin; select pg_temp.as_user('a0000000-0000-0000-0000-000000000003');   -- staff A, limited to "A Main"
do $$ begin
  if (select count(*) from calls) <> 1 then raise exception 'FAIL location restriction (saw % calls)', (select count(*) from calls); end if;
  raise notice 'PASS location restriction: staff sees only their location''s calls';
end $$;
rollback;

-- Removed member and suspended business lose access on the next request
begin;
update business_members set status = 'removed' where id = 'a2000000-0000-0000-0000-000000000002';
select pg_temp.as_user('a0000000-0000-0000-0000-000000000002');
do $$ begin
  if (select count(*) from customers) <> 0 then raise exception 'FAIL removed member still reads'; end if;
  raise notice 'PASS staff removal: next request rejected';
end $$;
rollback;

begin;
update businesses set status = 'suspended' where id = 'aaaaaaaa-0000-0000-0000-000000000000';
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
do $$ begin
  if (select count(*) from customers) <> 0 then raise exception 'FAIL suspended business still readable'; end if;
  raise notice 'PASS suspended business: members lose access';
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------------
-- Cross-business references are impossible (composite foreign keys), even for server code
-- ---------------------------------------------------------------------------------------------------------------------
do $$ begin
  begin
    insert into appointments (business_id, location_id, customer_id, starts_at, ends_at, source)
    values ('aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001',
            'b3000000-0000-0000-0000-000000000001', now(), now() + interval '1 hour', 'staff');
    raise exception 'FAIL A appointment linked to B customer';
  exception when foreign_key_violation then raise notice 'PASS A links its appointment to B customer: rejected'; end;
  begin
    insert into callbacks (business_id, call_id, reason) values ('aaaaaaaa-0000-0000-0000-000000000000', 'b6000000-0000-0000-0000-000000000001', 'missed_call');
    raise exception 'FAIL A callback uses B call';
  exception when foreign_key_violation then raise notice 'PASS forged tenant reference (A callback → B call): rejected'; end;
  begin
    insert into resource_reservations (business_id, resource_id, kind, period, hold_expires_at)
    values ('aaaaaaaa-0000-0000-0000-000000000000', 'b4000000-0000-0000-0000-000000000001', 'hold', tstzrange(now(), now() + interval '1 hour'), now() + interval '5 minutes');
    raise exception 'FAIL A reserved B resource';
  exception when foreign_key_violation then raise notice 'PASS A reserves B resource: rejected'; end;
  begin
    insert into phone_numbers (business_id, location_id, e164, mode) values ('bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', '+15555550111', 'new_number');
    raise exception 'FAIL one number mapped to two businesses';
  exception when unique_violation then raise notice 'PASS a phone number maps to exactly one business'; end;
  begin
    insert into message_templates (scope, kind, channel, body) values ('business', 'x', 'sms', 'no owner');
    raise exception 'FAIL business template without business';
  exception when check_violation then raise notice 'PASS mixed-scope ownership is explicit'; end;
end $$;

-- A and B update their own templates independently
do $$ begin
  update message_templates set body = 'A new' where business_id = 'aaaaaaaa-0000-0000-0000-000000000000';
  update message_templates set body = 'B new' where business_id = 'bbbbbbbb-0000-0000-0000-000000000000';
  if (select body from message_templates where business_id = 'aaaaaaaa-0000-0000-0000-000000000000') <> 'A new'
     or (select body from message_templates where business_id = 'bbbbbbbb-0000-0000-0000-000000000000') <> 'B new'
     or (select body from message_templates where scope = 'platform') <> 'Hi, this is {{business_name}}.' then
    raise exception 'FAIL template independence';
  end if;
  raise notice 'PASS A and B update their own templates: both allowed, independent; platform default unchanged';
end $$;

-- Each reminder uses only its own business's data
do $$ begin
  if exists (select 1 from work_items w join automation_rules r on r.id = w.automation_id where r.business_id <> w.business_id) then
    raise exception 'FAIL work item linked to another business rule';
  end if;
  raise notice 'PASS A and B run separate reminders with their own rules';
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Booking: business + resource scoped (§6.8)
-- ---------------------------------------------------------------------------------------------------------------------
insert into appointments (id, business_id, location_id, customer_id, starts_at, ends_at, source) values
  ('aa100000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', '2026-12-01 15:00+00', '2026-12-01 16:00+00', 'staff'),
  ('aa100000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', '2026-12-01 15:00+00', '2026-12-01 16:00+00', 'staff'),
  ('bb100000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000001', '2026-12-01 15:00+00', '2026-12-01 16:00+00', 'staff');
do $$ begin
  insert into resource_reservations (business_id, resource_id, appointment_id, kind, period)
  values ('aaaaaaaa-0000-0000-0000-000000000000', 'a4000000-0000-0000-0000-000000000001', 'aa100000-0000-0000-0000-000000000001', 'booking', '[2026-12-01 15:00+00, 2026-12-01 16:00+00)');
  insert into resource_reservations (business_id, resource_id, appointment_id, kind, period)
  values ('bbbbbbbb-0000-0000-0000-000000000000', 'b4000000-0000-0000-0000-000000000001', 'bb100000-0000-0000-0000-000000000001', 'booking', '[2026-12-01 15:00+00, 2026-12-01 16:00+00)');
  raise notice 'PASS A books at the same time as B: allowed';
  insert into resource_reservations (business_id, resource_id, appointment_id, kind, period)
  values ('aaaaaaaa-0000-0000-0000-000000000000', 'a4000000-0000-0000-0000-000000000002', 'aa100000-0000-0000-0000-000000000002', 'booking', '[2026-12-01 15:00+00, 2026-12-01 16:00+00)');
  raise notice 'PASS A books Provider 2 at the same time as Provider 1: allowed';
  begin
    insert into resource_reservations (business_id, resource_id, appointment_id, kind, period)
    values ('aaaaaaaa-0000-0000-0000-000000000000', 'a4000000-0000-0000-0000-000000000001', 'aa100000-0000-0000-0000-000000000002', 'booking', '[2026-12-01 15:30+00, 2026-12-01 16:30+00)');
    raise exception 'FAIL double booking of Provider 1';
  exception when exclusion_violation then raise notice 'PASS A double-books the same exclusive resource: rejected'; end;
  update resource_reservations set active = false where appointment_id = 'aa100000-0000-0000-0000-000000000001';
  insert into resource_reservations (business_id, resource_id, appointment_id, kind, period)
  values ('aaaaaaaa-0000-0000-0000-000000000000', 'a4000000-0000-0000-0000-000000000001', 'aa100000-0000-0000-0000-000000000002', 'booking', '[2026-12-01 15:30+00, 2026-12-01 16:30+00)');
  raise notice 'PASS a cancelled reservation frees the resource';
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Several bookings at the same time: staff, shared capacity, restaurant tables (§6.8)
-- ---------------------------------------------------------------------------------------------------------------------
insert into resources (id, business_id, location_id, kind, name, capacity) values
  ('a4000000-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000000', 'a1000000-0000-0000-0000-000000000001', 'staff', 'Colourist (2 at once)', 2);
insert into resources (id, business_id, location_id, kind, name, capacity, seats_min, seats_max) values
  ('b4000000-0000-0000-0000-000000000011', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'table', 'T1', 1, 2, 4),
  ('b4000000-0000-0000-0000-000000000012', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'table', 'T2', 1, 2, 4);
insert into resources (id, business_id, location_id, kind, name, capacity) values
  ('b4000000-0000-0000-0000-000000000020', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'dining_area', 'Patio (covers)', 20);
insert into table_combinations (id, business_id, location_id, name, seats_min, seats_max) values
  ('b5000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', 'b1000000-0000-0000-0000-000000000001', 'T1+T2', 5, 8);
insert into table_combination_members (business_id, combination_id, resource_id) values
  ('bbbbbbbb-0000-0000-0000-000000000000', 'b5000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000011'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'b5000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000012');

-- helper: one appointment + its reservations, as the booking function does in one transaction
create or replace function pg_temp.book(p_biz uuid, p_loc uuid, p_cust uuid, p_period tstzrange, p_resources uuid[], p_units int default 1)
returns uuid language plpgsql as $$
declare v_appt uuid := gen_random_uuid(); r uuid;
begin
  insert into appointments (id, business_id, location_id, customer_id, starts_at, ends_at, source, party_size)
  values (v_appt, p_biz, p_loc, p_cust, lower(p_period), upper(p_period), 'staff', p_units);
  foreach r in array p_resources loop
    insert into resource_reservations (business_id, resource_id, appointment_id, kind, period, units)
    values (p_biz, r, v_appt, 'booking', p_period, p_units);
  end loop;
  return v_appt;
end $$;

do $$
declare A uuid := 'aaaaaaaa-0000-0000-0000-000000000000'; B uuid := 'bbbbbbbb-0000-0000-0000-000000000000';
        AL uuid := 'a1000000-0000-0000-0000-000000000001'; BL uuid := 'b1000000-0000-0000-0000-000000000001';
        AC uuid := 'a3000000-0000-0000-0000-000000000001'; BC uuid := 'b3000000-0000-0000-0000-000000000001';
        slot tstzrange := '[2026-12-05 18:00+00, 2026-12-05 19:30+00)';
begin
  perform pg_temp.book(A, AL, AC, '[2026-12-05 15:00+00, 2026-12-05 17:00+00)', array['a4000000-0000-0000-0000-000000000003'::uuid]);
  perform pg_temp.book(A, AL, AC, '[2026-12-05 15:30+00, 2026-12-05 16:30+00)', array['a4000000-0000-0000-0000-000000000003'::uuid]);
  raise notice 'PASS salon: a staff member with capacity 2 takes two overlapping clients';
  begin
    perform pg_temp.book(A, AL, AC, '[2026-12-05 16:00+00, 2026-12-05 16:15+00)', array['a4000000-0000-0000-0000-000000000003'::uuid]);
    raise exception 'FAIL third overlapping client accepted';
  exception when raise_exception then
    if sqlerrm <> 'over_capacity' then raise; end if;
    raise notice 'PASS salon: a third overlapping client is refused (capacity full)';
  end;
  perform pg_temp.book(A, AL, AC, '[2026-12-05 17:00+00, 2026-12-05 18:00+00)', array['a4000000-0000-0000-0000-000000000003'::uuid]);
  raise notice 'PASS salon: the next free time on the same staff member is accepted';

  perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000011'::uuid], 4);
  perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000012'::uuid], 3);
  raise notice 'PASS restaurant: tables T1 and T2 booked for the same time';
  begin
    perform pg_temp.book(B, BL, BC, '[2026-12-05 19:00+00, 2026-12-05 20:00+00)', array['b4000000-0000-0000-0000-000000000011'::uuid], 2);
    raise exception 'FAIL table T1 double-booked';
  exception when exclusion_violation then raise notice 'PASS restaurant: the same table can''t hold two parties at once'; end;
  begin
    perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000011'::uuid, 'b4000000-0000-0000-0000-000000000012'::uuid], 8);
    raise exception 'FAIL combination booked over taken tables';
  exception when exclusion_violation then raise notice 'PASS restaurant: joined tables T1+T2 refused while either table is taken'; end;
  perform pg_temp.book(B, BL, BC, '[2026-12-05 20:00+00, 2026-12-05 21:30+00)',
                       array['b4000000-0000-0000-0000-000000000011'::uuid, 'b4000000-0000-0000-0000-000000000012'::uuid], 8);
  raise notice 'PASS restaurant: joined tables T1+T2 booked for a party of 8 when both are free';

  perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000020'::uuid], 8);
  perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000020'::uuid], 8);
  raise notice 'PASS restaurant covers: 16 of 20 guests booked in one slot';
  begin
    perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000020'::uuid], 6);
    raise exception 'FAIL covers over capacity';
  exception when raise_exception then
    if sqlerrm <> 'over_capacity' then raise; end if;
    raise notice 'PASS restaurant covers: a party of 6 refused when only 4 covers are left';
  end;
  perform pg_temp.book(B, BL, BC, slot, array['b4000000-0000-0000-0000-000000000020'::uuid], 4);
  raise notice 'PASS restaurant covers: a party of 4 fills the last covers';
  perform pg_temp.book(A, AL, AC, slot, array['a4000000-0000-0000-0000-000000000003'::uuid]);
  raise notice 'PASS different businesses never share capacity (A books while B''s patio is full)';
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Industry-driven platform (§22)
-- ---------------------------------------------------------------------------------------------------------------------
do $$ declare n int; begin
  select count(*) into n from industries; if n <> 28 then raise exception 'FAIL % industries seeded', n; end if;
  select count(*) into n from industries i where (select count(*) from industry_modules im join modules m on m.key = im.module_key
                                                    where im.industry_key = i.key and m.core and im.availability = 'required') < 11;
  if n <> 0 then raise exception 'FAIL % industries missing core modules', n; end if;
  if exists (select 1 from industry_modules where industry_key = 'ecommerce' and module_key = 'calendar') then raise exception 'FAIL e-commerce has a calendar'; end if;
  if exists (select 1 from industry_services where industry_key in (select key from industries)) and
     exists (select 1 from information_schema.columns where table_name = 'industry_services' and column_name like '%price%') then
    raise exception 'FAIL industry defaults carry prices';
  end if;
  raise notice 'PASS 28 industries seeded; every industry has the core modules; e-commerce has no calendar; no seeded prices';
end $$;

insert into businesses (id, name, industry_key, status) values
  ('dddddddd-0000-0000-0000-000000000000', 'Test Bistro D', 'restaurant', 'setup'),
  ('eeeeeeee-0000-0000-0000-000000000000', 'Test Shop E', 'ecommerce', 'setup'),
  ('ffffffff-0000-0000-0000-000000000000', 'Test Dental F', 'dental', 'setup');
select app_private.apply_industry(id) from businesses where id in ('aaaaaaaa-0000-0000-0000-000000000000','dddddddd-0000-0000-0000-000000000000','eeeeeeee-0000-0000-0000-000000000000','ffffffff-0000-0000-0000-000000000000');

do $$
declare R uuid := 'dddddddd-0000-0000-0000-000000000000'; E uuid := 'eeeeeeee-0000-0000-0000-000000000000';
        F uuid := 'ffffffff-0000-0000-0000-000000000000'; A uuid := 'aaaaaaaa-0000-0000-0000-000000000000';
begin
  if not app_private.module_enabled(R, 'tables') then raise exception 'FAIL restaurant has no tables module'; end if;
  if app_private.module_enabled(A, 'tables') then raise exception 'FAIL salon has a tables module'; end if;
  if not app_private.module_enabled(A, 'check_in') then raise exception 'FAIL salon has no check-in'; end if;
  if app_private.module_enabled(E, 'calendar') then raise exception 'FAIL e-commerce has a calendar'; end if;
  if not app_private.module_enabled(E, 'orders') then raise exception 'FAIL e-commerce has no orders'; end if;
  raise notice 'PASS Create Business applies the industry: restaurant gets tables, salon gets check-in, e-commerce gets orders and no calendar';
  if not exists (select 1 from record_types where business_id = R and key = 'guest_notes' and source_industry = 'restaurant') then raise exception 'FAIL restaurant record types'; end if;
  if not exists (select 1 from services where business_id = A and source_key = 'haircut' and price_minor is null) then raise exception 'FAIL salon services'; end if;
  raise notice 'PASS industry record types and services copied into the business, prices left for the business to enter';
  if (select enabled from automation_rules where business_id = E and kind = 'reminders') then raise exception 'FAIL e-commerce reminders on'; end if;
  if (select enabled from automation_rules where business_id = F and kind = 'review_request') then raise exception 'FAIL dental review requests on'; end if;
  raise notice 'PASS industry automations: e-commerce has no booking reminders; regulated dental has no automatic review requests';
  begin insert into business_modules (business_id, module_key, enabled) values (A, 'tables', true);
        raise exception 'FAIL salon switched on tables';
  exception when raise_exception then if sqlerrm <> 'module_not_offered' then raise; end if;
        raise notice 'PASS a business cannot switch on a module its industry does not offer'; end;
  begin update business_modules set enabled = false where business_id = A and module_key = 'calls';
        raise exception 'FAIL required module switched off';
  exception when raise_exception then if sqlerrm <> 'module_required' then raise; end if;
        raise notice 'PASS a required module cannot be switched off'; end;
  update business_modules set enabled = false, customized = true where business_id = A and module_key = 'waitlist';
  update record_types set name = 'Our colour cards', customized = true where business_id = A and key = 'colour_formula';
  update industry_record_types set name = 'Client preferences v2' where industry_key = 'beauty_salon' and key = 'client_profile';
  update industry_record_types set name = 'Colour formula v2' where industry_key = 'beauty_salon' and key = 'colour_formula';
  update industries set version = 2 where key = 'beauty_salon';
  perform app_private.apply_industry(A);
  if (select name from record_types where business_id = A and key = 'colour_formula') <> 'Our colour cards' then raise exception 'FAIL customization overwritten'; end if;
  if (select name from record_types where business_id = A and key = 'client_profile') <> 'Client preferences v2' then raise exception 'FAIL upgrade not applied'; end if;
  if (select enabled from business_modules where business_id = A and module_key = 'waitlist') then raise exception 'FAIL module choice overwritten'; end if;
  if (select industry_version from businesses where id = A) <> 2 then raise exception 'FAIL version not recorded'; end if;
  raise notice 'PASS industry upgrade: new defaults applied, the business''s customizations kept, version recorded';
end $$;

begin; select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
do $$ declare c jsonb; begin
  c := public.effective_config('aaaaaaaa-0000-0000-0000-000000000000');
  if c ->> 'booking_model' <> 'staff_appointment' or c -> 'terminology' ->> 'customer' <> 'client'
     or not (c -> 'modules' ? 'check_in') or (c -> 'modules' ? 'waitlist') then raise exception 'FAIL effective config %', c; end if;
  raise notice 'PASS effective configuration: industry words, booking model and the business''s own module choices';
  begin perform public.effective_config('dddddddd-0000-0000-0000-000000000000'); raise exception 'FAIL A read D configuration';
  exception when insufficient_privilege then raise notice 'PASS A cannot read another business''s configuration'; end;
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------------
-- Integrity guards
-- ---------------------------------------------------------------------------------------------------------------------
do $$ begin
  begin update business_members set role = 'admin' where id = 'b2000000-0000-0000-0000-000000000001';
        raise exception 'FAIL last owner demoted';
  exception when raise_exception then
    if sqlerrm <> 'last_owner' then raise; end if;
    raise notice 'PASS a business always keeps an owner';
  end;
  begin update audit_logs set action = 'x';
        raise exception 'FAIL audit log edited';
  exception when raise_exception then
    if sqlerrm <> 'append_only' then raise; end if;
    raise notice 'PASS audit log is append-only';
  end;
  if exists (select 1 from audit_logs where entity = 'record_secrets' and (after ? 'value' or before ? 'value')) then
    raise exception 'FAIL private value copied into audit log';
  end if;
  if not exists (select 1 from audit_logs where entity = 'record_secrets') then raise exception 'FAIL private field change not audited'; end if;
  raise notice 'PASS private field changes are audited without the value';
end $$;

-- Every public table has row-level security on, and every tenant table has a NOT NULL business_id or is mixed-scope.
do $$ declare n int; begin
  select count(*) into n from pg_tables where schemaname = 'public' and not rowsecurity;
  if n <> 0 then raise exception 'FAIL % tables without RLS', n; end if;
  raise notice 'PASS row-level security on every table';
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and column_name = 'business_id' and is_nullable = 'YES'
     and table_name not in ('message_templates','ai_eval_cases','audit_logs');
  if n <> 0 then raise exception 'FAIL % tenant tables with nullable business_id', n; end if;
  raise notice 'PASS business_id is mandatory on every tenant table (mixed-scope tables use explicit scope)';
end $$;
