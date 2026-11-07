-- sql/zella_slots_resource_blocks.sql on an ISOLATED copy of the production schema (tests/slotblocks/run.sh).
-- Synthetic data only (ids c7…); everything is rolled back. A UTC business with two people working 09:00-17:00.
\set ON_ERROR_STOP on
begin;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('c7000000-0000-0000-0000-0000000000a1', 'SB Bays', 'UTC', true, 'active', (select id from public.industries where slug = 'automotive'));
insert into public.staff_members (id, business_id, name, is_active) values
 ('c7000000-0000-0000-0000-0000000005a1', 'c7000000-0000-0000-0000-0000000000a1', 'Mech Ana', true),
 ('c7000000-0000-0000-0000-0000000005a2', 'c7000000-0000-0000-0000-0000000000a1', 'Mech Ben', true);
update public.staff_members set working_hours = jsonb_build_object(lower(to_char(current_date + 20, 'dy')), jsonb_build_object('on', true, 'start', '09:00', 'end', '17:00'))
 where business_id = 'c7000000-0000-0000-0000-0000000000a1';
insert into public.resources (id, business_id, name, kind) values
 ('c7000000-0000-0000-0000-0000000009a1', 'c7000000-0000-0000-0000-0000000000a1', 'Bay 1', 'bay');
create or replace function pg_temp.at(d int, hm text) returns timestamptz language sql as $$ select (current_date + d + hm::time) at time zone 'UTC' $$;
-- how many 30-minute slots are offered from 10:00 to 10:30 on day 20, for one person or anyone
create or replace function pg_temp.slots(p_staff uuid default null) returns int language sql as $$
  select count(*)::int from public.zella_available_slots('c7000000-0000-0000-0000-0000000000a1', pg_temp.at(20, '10:00'), pg_temp.at(20, '10:30'), 30, p_staff) $$;

do $$
declare ana uuid := 'c7000000-0000-0000-0000-0000000005a1'; ben uuid := 'c7000000-0000-0000-0000-0000000005a2'; b uuid := 'c7000000-0000-0000-0000-0000000000a1'; blk uuid;
begin
  assert pg_temp.slots() > 0 and pg_temp.slots(ana) > 0 and pg_temp.slots(ben) > 0, format('both people are free at 10:00 (any %s, ana %s, ben %s)', pg_temp.slots(), pg_temp.slots(ana), pg_temp.slots(ben));

  -- a block on Bay 1 alone: people are still offered times
  insert into public.blocked_times (business_id, title, start_time, end_time, resource_id)
    values (b, 'Bay 1 lift service', pg_temp.at(20, '00:00'), pg_temp.at(21, '00:00'), 'c7000000-0000-0000-0000-0000000009a1') returning id into blk;
  assert pg_temp.slots(ana) > 0 and pg_temp.slots(ben) > 0 and pg_temp.slots() > 0, 'a resource-only block does not close the business';
  -- ... and the bay itself is still refused when a booking uses it
  begin
    insert into public.appointments (business_id, title, start_time, end_time, timezone, status, resource_ids)
      values (b, 'Oil change', pg_temp.at(20, '10:00'), pg_temp.at(20, '10:30'), 'UTC', 'scheduled', array['c7000000-0000-0000-0000-0000000009a1'::uuid]);
    raise exception 'EXPECTED_SLOT_TAKEN';
  exception when others then
    if position('SLOT_TAKEN' in sqlerrm) = 0 or sqlerrm = 'EXPECTED_SLOT_TAKEN' then raise; end if;
  end;

  -- a block on one person closes only that person
  insert into public.blocked_times (business_id, title, start_time, end_time, staff_id)
    values (b, 'Ana off', pg_temp.at(20, '00:00'), pg_temp.at(21, '00:00'), ana);
  assert pg_temp.slots(ana) = 0 and pg_temp.slots(ben) > 0, 'a person''s block closes only that person';

  -- a block with neither a person nor a resource still closes the whole business (holidays, training days)
  insert into public.blocked_times (business_id, title, start_time, end_time)
    values (b, 'Closed for training', pg_temp.at(20, '09:00'), pg_temp.at(20, '12:00'));
  assert pg_temp.slots() = 0 and pg_temp.slots(ben) = 0, 'a business-wide block closes everyone';
end $$;
select 'PASS a block on a resource no longer closes the business in slot search (the resource is still refused when booked); a person''s block closes only them; a business-wide block closes everyone';
rollback;
