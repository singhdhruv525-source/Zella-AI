-- Appointments linked to records (zella_appointment_records.sql): never silently the wrong pet / vehicle / property.
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
 ('e9000000-0000-0000-0000-0000000000c3', 'e9000000-0000-0000-0000-0000000000a1', 'No pets', '+15555550303'),
 ('e9000000-0000-0000-0000-0000000000c4', 'e9000000-0000-0000-0000-0000000000a1', 'One pet (duplicate)', '+15555550304'),
 ('e9000000-0000-0000-0000-0000000000c9', 'e9000000-0000-0000-0000-0000000000b1', 'Other vet', '+15555550309');
insert into public.crm_records (id, business_id, type_key, title, status, customer_id, archived_at) values
 ('e9000000-0000-0000-0000-0000000000f1', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Bella', 'active', 'e9000000-0000-0000-0000-0000000000c1', null),
 ('e9000000-0000-0000-0000-0000000000f2', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Max', 'active', 'e9000000-0000-0000-0000-0000000000c2', null),
 ('e9000000-0000-0000-0000-0000000000f3', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Luna', 'active', 'e9000000-0000-0000-0000-0000000000c2', null),
 ('e9000000-0000-0000-0000-0000000000f4', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Old', 'active', 'e9000000-0000-0000-0000-0000000000c2', now()),
 ('e9000000-0000-0000-0000-0000000000f5', 'e9000000-0000-0000-0000-0000000000a1', 'notes', 'A note', 'open', 'e9000000-0000-0000-0000-0000000000c2', null),
 ('e9000000-0000-0000-0000-0000000000f6', 'e9000000-0000-0000-0000-0000000000a1', 'pets', 'Rex', 'active', 'e9000000-0000-0000-0000-0000000000c4', null),
 ('e9000000-0000-0000-0000-0000000000f9', 'e9000000-0000-0000-0000-0000000000b1', 'pets', 'Elsewhere', 'active', 'e9000000-0000-0000-0000-0000000000c9', null);
create temp table ids (k text primary key, id uuid) on commit drop;
grant all on ids to authenticated;
create or replace function pg_temp.book(c uuid, r uuid, d int default 1) returns uuid language sql as $$
  insert into public.appointments (business_id, customer_id, record_id, title, start_time, end_time)
  values ('e9000000-0000-0000-0000-0000000000a1', c, r, 'Checkup', now() + make_interval(days => d), now() + make_interval(days => d, mins => 30)) returning id $$;
do $$ declare a uuid; n jsonb; begin
  -- one pet on file: suggested, NOT linked (it may be a new pet)
  a := pg_temp.book('e9000000-0000-0000-0000-0000000000c1', null); insert into ids values ('one', a);
  assert (select record_id is null and record_suggested_id = 'e9000000-0000-0000-0000-0000000000f1' from public.appointments where id = a), 'single pet: suggested only';
  -- two pets (and an archived one): nothing suggested
  a := pg_temp.book('e9000000-0000-0000-0000-0000000000c2', null); insert into ids values ('two', a);
  assert (select record_id is null and record_suggested_id is null from public.appointments where id = a), 'two pets: nothing chosen or suggested';
  -- no pet on file: nothing asked
  a := pg_temp.book('e9000000-0000-0000-0000-0000000000c3', null); insert into ids values ('none', a);
  -- explicit choice when booking: linked; the customer is filled from the pet
  a := pg_temp.book(null, 'e9000000-0000-0000-0000-0000000000f3', 2); insert into ids values ('explicit', a);
  assert (select record_id = 'e9000000-0000-0000-0000-0000000000f3' and customer_id = 'e9000000-0000-0000-0000-0000000000c2' from public.appointments where id = a), 'explicit link, customer filled';
  -- the list of bookings that still need an answer: one-pet (with the suggestion) and two-pet (with both choices); not the no-pet one, not the explicit one
  n := public.zella_appointments_needing_record('e9000000-0000-0000-0000-0000000000a1');
  assert jsonb_array_length(n) = 2, 'two bookings need an answer: ' || n::text;
  assert (select (x -> 'suggested' ->> 'title') = 'Bella' and jsonb_array_length(x -> 'choices') = 1 from jsonb_array_elements(n) x where (x ->> 'appointment_id')::uuid = (select id from ids where k = 'one')), 'suggestion shown';
  assert (select x -> 'suggested' = 'null'::jsonb and jsonb_array_length(x -> 'choices') = 2 from jsonb_array_elements(n) x where (x ->> 'appointment_id')::uuid = (select id from ids where k = 'two')), 'both pets offered, archived one not';
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

-- staff confirm the suggestion / choose explicitly; viewer and another business can't
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  perform public.zella_confirm_appointment_record((select id from ids where k = 'one'));
  assert (select record_id = 'e9000000-0000-0000-0000-0000000000f1' and record_suggested_id is null from public.appointments where id = (select id from ids where k = 'one')), 'staff confirmed Bella';
  begin perform public.zella_confirm_appointment_record((select id from ids where k = 'two')); raise exception 'confirmed with nothing suggested';
  exception when others then if sqlerrm not like '%NO_SUGGESTION%' then raise; end if; end;
  perform public.zella_set_appointment_record((select id from ids where k = 'two'), 'e9000000-0000-0000-0000-0000000000f3');
  assert (select record_id from public.appointments where id = (select id from ids where k = 'two')) = 'e9000000-0000-0000-0000-0000000000f3', 'staff chose Luna';
end $$;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_appointment_record((select id from ids where k = 'two'), null); raise exception 'viewer changed a link';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_appointment_record((select id from ids where k = 'two'), null); raise exception 'other business changed a link';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  begin perform public.zella_appointments_needing_record('e9000000-0000-0000-0000-0000000000a1'); raise exception 'other business read the list';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
reset role;

-- reschedule and cancel keep the link
do $$ begin
  update public.appointments set start_time = start_time + interval '1 day', end_time = end_time + interval '1 day' where id = (select id from ids where k = 'two');
  update public.appointments set status = 'cancelled' where id = (select id from ids where k = 'explicit');
  assert (select record_id from public.appointments where id = (select id from ids where k = 'two')) = 'e9000000-0000-0000-0000-0000000000f3', 'rescheduled: link kept';
  assert (select record_id from public.appointments where id = (select id from ids where k = 'explicit')) = 'e9000000-0000-0000-0000-0000000000f3', 'cancelled: link kept for history';
  assert exists (select 1 from public.crm_record_events where record_id = 'e9000000-0000-0000-0000-0000000000f1' and kind = 'appointment'), 'history line on confirm';
end $$;

-- moving a booking to another customer while it points at the old customer's pet is refused (when the change is committed)
savepoint move;
do $$ begin
  update public.appointments set customer_id = 'e9000000-0000-0000-0000-0000000000c3' where id = (select id from ids where k = 'one');
  set constraints zella_appointment_record_match immediate;
  raise exception 'moved to another customer with the old pet';
exception when others then if sqlerrm <> 'RECORD_OTHER_CUSTOMER' then raise; end if;
end $$;
rollback to savepoint move;
-- moving it with the pet cleared is fine, and a stale suggestion is dropped
do $$ begin
  update public.appointments set record_id = null, customer_id = 'e9000000-0000-0000-0000-0000000000c3' where id = (select id from ids where k = 'one');
  set constraints zella_appointment_record_match immediate;
  set constraints zella_appointment_record_match deferred;
end $$;

-- merging duplicate customers moves bookings and pets together: nothing skipped, links intact
do $$ declare a uuid; m jsonb; begin
  a := pg_temp.book('e9000000-0000-0000-0000-0000000000c4', 'e9000000-0000-0000-0000-0000000000f6', 3);
  insert into ids values ('merge', a);
end $$;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e9000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ declare m jsonb; begin
  m := public.zella_merge_customers('e9000000-0000-0000-0000-0000000000a1', 'e9000000-0000-0000-0000-0000000000c1', 'e9000000-0000-0000-0000-0000000000c4');
  assert not (m::text like '%appointments%' or m::text like '%crm_records%'), 'merge skipped bookings or records: ' || m::text;
  set constraints zella_appointment_record_match immediate;
  assert (select customer_id = 'e9000000-0000-0000-0000-0000000000c1' and record_id = 'e9000000-0000-0000-0000-0000000000f6' from public.appointments where id = (select id from ids where k = 'merge')), 'merged: booking and pet together';
end $$;
reset role;
select 'PASS linked bookings: one pet suggested never linked, several never guessed, none never asked, explicit choice linked, list of bookings needing an answer, staff confirm/choose (viewer and others refused), reschedule and cancel keep the link, moving to another customer with the old pet refused, merge keeps bookings and pets together';
rollback;
