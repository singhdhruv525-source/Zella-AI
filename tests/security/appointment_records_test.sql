-- Appointments linked to records (zella_appointment_records.sql).
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('e9000000-0000-0000-0000-00000000000a', 'own@ar.test', now()), ('e9000000-0000-0000-0000-00000000000b', 'stf@ar.test', now()),
 ('e9000000-0000-0000-0000-00000000000c', 'view@ar.test', now()), ('e9000000-0000-0000-0000-00000000000d', 'out@ar.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values
 ('e9000000-0000-0000-0000-0000000000a1', 'Vet A', 'UTC', true, 'active'), ('e9000000-0000-0000-0000-0000000000b1', 'Vet B', 'UTC', true, 'active');
insert into public.business_members (business_id, user_id, role, status) values
 ('e9000000-0000-0000-0000-0000000000a1', 'e9000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('e9000000-0000-0000-0000-0000000000a1', 'e9000000-0000-0000-0000-00000000000b', 'staff', 'active'),
 ('e9000000-0000-0000-0000-0000000000a1', 'e9000000-0000-0000-0000-00000000000c', 'viewer', 'active'),
 ('e9000000-0000-0000-0000-0000000000b1', 'e9000000-0000-0000-0000-00000000000d', 'owner', 'active');
insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, appointment_link) values
 ('e9000000-0000-0000-0000-0000000000a1', 'pets', 'Pet', 'Pets', '[{"key":"active","label":"Active"}]', '{}', true),
 ('e9000000-0000-0000-0000-0000000000a1', 'notes', 'Note', 'Notes', '[{"key":"open","label":"Open"}]', '{}', false),
 ('e9000000-0000-0000-0000-0000000000b1', 'pets', 'Pet', 'Pets', '[{"key":"active","label":"Active"}]', '{}', true);
insert into public.customers (id, business_id, first_name, phone) values
 ('e9000000-0000-0000-0000-0000000000c1', 'e9000000-0000-0000-0000-0000000000a1', 'One pet', '+15555550301'),
 ('e9000000-0000-0000-0000-0000000000c2', 'e9000000-0000-0000-0000-0000000000a1', 'Two pets', '+15555550302'),
 ('e9000000-0000-0000-0000-0000000000c9', 'e9000000-0000-0000-0000-0000000000b1', 'Other vet', '+15555550309');
insert into public.crm_records (id, business_id, type_key, title, status, customer_id, archived_at) values
 ('e9000000-0000-0000-0000-0000000000f1', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Bella', 'active', 'e9000000-0000-0000-0000-0000000000c1', null),
 ('e9000000-0000-0000-0000-0000000000f2', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Max', 'active', 'e9000000-0000-0000-0000-0000000000c2', null),
 ('e9000000-0000-0000-0000-0000000000f3', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Luna', 'active', 'e9000000-0000-0000-0000-0000000000c2', null),
 ('e9000000-0000-0000-0000-0000000000f4', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Old', 'active', 'e9000000-0000-0000-0000-0000000000c2', now()),
 ('e9000000-0000-0000-0000-0000000000f5', 'e9000000-0000-0000-0000-0000000000a1', 'notes', 'A note', 'open', 'e9000000-0000-0000-0000-0000000000c2', null),
 ('e9000000-0000-0000-0000-0000000000f9', 'e9000000-0000-0000-0000-0000000000b1', 'pets', 'Elsewhere', 'active', 'e9000000-0000-0000-0000-0000000000c9', null);

create or replace function pg_temp.book(c uuid, r uuid) returns uuid language sql as $$
  insert into public.appointments (business_id, customer_id, record_id, title, start_time, end_time)
  values ('e9000000-0000-0000-0000-0000000000a1', c, r, 'Checkup', now() + interval '1 day', now() + interval '1 day 30 minutes') returning id $$;
do $$ declare a uuid; begin
  -- one pet: linked automatically (an AI booking with only the customer gets the pet too)
  a := pg_temp.book('e9000000-0000-0000-0000-0000000000c1', null);
  assert (select record_id from public.appointments where id = a) = 'e9000000-0000-0000-0000-0000000000f1', 'single pet linked automatically';
  assert exists (select 1 from public.crm_record_events where record_id = 'e9000000-0000-0000-0000-0000000000f1' and kind = 'appointment'), 'history line on the pet';
  -- two pets (and an archived one): nothing guessed
  a := pg_temp.book('e9000000-0000-0000-0000-0000000000c2', null);
  assert (select record_id from public.appointments where id = a) is null, 'two pets: nothing guessed';
  -- record given without a customer: the record's customer is filled in
  a := pg_temp.book(null, 'e9000000-0000-0000-0000-0000000000f3');
  assert (select customer_id from public.appointments where id = a) = 'e9000000-0000-0000-0000-0000000000c2', 'customer filled from the pet';
  -- refusals
  begin perform pg_temp.book('e9000000-0000-0000-0000-0000000000c1', 'e9000000-0000-0000-0000-0000000000f2'); raise exception 'another customer''s pet linked';
  exception when others then if sqlerrm <> 'RECORD_OTHER_CUSTOMER' then raise; end if; end;
  begin perform pg_temp.book(null, 'e9000000-0000-0000-0000-0000000000f9'); raise exception 'another business''s pet linked';
  exception when others then if sqlerrm <> 'BAD_RECORD' then raise; end if; end;
  begin perform pg_temp.book(null, 'e9000000-0000-0000-0000-0000000000f4'); raise exception 'archived pet linked';
  exception when others then if sqlerrm <> 'BAD_RECORD' then raise; end if; end;
  begin perform pg_temp.book(null, 'e9000000-0000-0000-0000-0000000000f5'); raise exception 'a type that isn''t bookable linked';
  exception when others then if sqlerrm <> 'BAD_RECORD' then raise; end if; end;
end $$;

-- roles: staff link, viewer and other businesses can't
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ declare a uuid := (select id from public.appointments where customer_id = 'e9000000-0000-0000-0000-0000000000c2' and record_id is null limit 1); begin
  perform public.zella_set_appointment_record(a, 'e9000000-0000-0000-0000-0000000000f2');
  assert (select record_id from public.appointments where id = a) = 'e9000000-0000-0000-0000-0000000000f2', 'staff linked Max';
end $$;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_appointment_record((select id from public.appointments limit 1), null); raise exception 'viewer changed a link';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_appointment_record((select id from public.appointments where business_id = 'e9000000-0000-0000-0000-0000000000a1' limit 1), null);
    raise exception 'other business changed a link';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
reset role;
-- archiving the pet keeps the history link; new links to it are refused
update public.crm_records set archived_at = now() where id = 'e9000000-0000-0000-0000-0000000000f1';
do $$ begin
  assert (select count(*) from public.appointments where record_id = 'e9000000-0000-0000-0000-0000000000f1') = 1, 'history link kept after archiving';
  update public.appointments set title = 'Moved' where record_id = 'e9000000-0000-0000-0000-0000000000f1';
end $$;
select 'PASS appointments linked to records: single pet automatic, nothing guessed with two, customer filled, other customer / business / archived / non-bookable refused, history line, staff yes, viewer and outsiders no';
rollback;
