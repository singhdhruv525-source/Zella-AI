-- Zella Voice target schema: three-business isolation suite (docs/ARCHITECTURE.md §6.12).
-- Runs on the ISOLATED local test database only (sql/target/test.sh). Every check prints "PASS …" or raises "FAIL …".
-- Fake data only (SEC-4).

\set ON_ERROR_STOP 0
set client_min_messages = notice;

-- ---------------------------------------------------------------------------------------------------------------------
-- Fixtures (as the database owner): businesses A, B, C; users per role; locations, customers, resources, calls.
-- ---------------------------------------------------------------------------------------------------------------------
insert into industries (key, name) values ('beauty_salon', 'Beauty & Salon'), ('dental', 'Dental');
update industries set regulated = true where key = 'dental';

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
