-- Release 3 (sql/zella_record_workflows.sql) on an ISOLATED copy of the production schema (tests/workflows/run.sh).
-- Synthetic people only (ids c6…); everything is rolled back. A UTC auto-repair business and another business.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('c6000000-0000-0000-0000-00000000000a', 'own@r3.test', now()), ('c6000000-0000-0000-0000-00000000000b', 'mgr@r3.test', now()),
 ('c6000000-0000-0000-0000-00000000000c', 'staff@r3.test', now()), ('c6000000-0000-0000-0000-00000000000d', 'view@r3.test', now()),
 ('c6000000-0000-0000-0000-00000000000e', 'other@r3.test', now());
insert into public.profiles (id) select id from auth.users where email like '%@r3.test' on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('c6000000-0000-0000-0000-0000000000a1', 'R3 Garage', 'UTC', true, 'active', (select id from public.industries where slug = 'automotive')),
 ('c6000000-0000-0000-0000-0000000000b1', 'R3 Other', 'UTC', true, 'active', (select id from public.industries where slug = 'automotive'));
insert into public.business_members (business_id, user_id, role, status)
select b::uuid, u::uuid, r, 'active' from (values
 ('c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-00000000000a', 'owner'), ('c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-00000000000b', 'manager'),
 ('c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-00000000000c', 'staff'), ('c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-00000000000d', 'viewer'),
 ('c6000000-0000-0000-0000-0000000000b1', 'c6000000-0000-0000-0000-00000000000e', 'owner')) v(b, u, r);
insert into public.staff_members (id, business_id, name, is_active) values
 ('c6000000-0000-0000-0000-0000000005a1', 'c6000000-0000-0000-0000-0000000000a1', 'Mech Ana', true),
 ('c6000000-0000-0000-0000-0000000005b1', 'c6000000-0000-0000-0000-0000000000b1', 'Elsewhere Eve', true);
insert into public.customers (id, business_id, first_name, last_name, phone) values
 ('c6000000-0000-0000-0000-0000000001a1', 'c6000000-0000-0000-0000-0000000000a1', 'Pat', 'Owner', '+15125550901'),
 ('c6000000-0000-0000-0000-0000000001a2', 'c6000000-0000-0000-0000-0000000000a1', 'Sam', 'Spouse', '+15125550902'),
 ('c6000000-0000-0000-0000-0000000001a3', 'c6000000-0000-0000-0000-0000000000a1', 'Ned', 'Neighbour', '+15125550903'),
 ('c6000000-0000-0000-0000-0000000001b1', 'c6000000-0000-0000-0000-0000000000b1', 'Xena', 'Elsewhere', '+15125550904');
-- record types, as the industry preset creates them: the trigger fills each type's default workflow
insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, preset_key) values
 ('c6000000-0000-0000-0000-0000000000a1', 'repair_orders', 'Repair order', 'Repair orders',
  '[{"key":"checked_in","label":"Checked in"},{"key":"diagnosing","label":"Diagnosing"},{"key":"estimate_sent","label":"Estimate sent"},{"key":"approved","label":"Approved"},{"key":"in_repair","label":"In repair"},{"key":"collected","label":"Collected"},{"key":"cancelled","label":"Cancelled"}]',
  '{collected,cancelled}', 'automotive'),
 ('c6000000-0000-0000-0000-0000000000a1', 'packages', 'Package', 'Packages',
  '[{"key":"active","label":"Active"},{"key":"used_up","label":"Used up"},{"key":"expired","label":"Expired"}]', '{used_up,expired}', 'spa_wellness'),
 ('c6000000-0000-0000-0000-0000000000a1', 'vehicles', 'Vehicle', 'Vehicles', '[{"key":"active","label":"Active"},{"key":"inactive","label":"Inactive"}]', '{inactive}', 'automotive'),
 ('c6000000-0000-0000-0000-0000000000b1', 'repair_orders', 'Repair order', 'Repair orders', '[{"key":"checked_in","label":"Checked in"},{"key":"approved","label":"Approved"}]', '{}', 'automotive');
insert into public.crm_records (id, business_id, type_key, title, status, customer_id) values
 ('c6000000-0000-0000-0000-0000000002a1', 'c6000000-0000-0000-0000-0000000000a1', 'repair_orders', 'Brake job', 'diagnosing', 'c6000000-0000-0000-0000-0000000001a1'),
 ('c6000000-0000-0000-0000-0000000002a2', 'c6000000-0000-0000-0000-0000000000a1', 'packages', '5 facials', 'active', 'c6000000-0000-0000-0000-0000000001a1'),
 ('c6000000-0000-0000-0000-0000000002a3', 'c6000000-0000-0000-0000-0000000000a1', 'vehicles', 'Blue hatchback', 'active', 'c6000000-0000-0000-0000-0000000001a1'),
 ('c6000000-0000-0000-0000-0000000002b1', 'c6000000-0000-0000-0000-0000000000b1', 'repair_orders', 'Other job', 'checked_in', 'c6000000-0000-0000-0000-0000000001b1');
insert into public.customer_charges (id, business_id, kind, description, amount_minor, currency, status, customer_id, record_id) values
 ('c6000000-0000-0000-0000-0000000003a1', 'c6000000-0000-0000-0000-0000000000a1', 'estimate', 'Brakes', 42000, 'USD', 'proposed', 'c6000000-0000-0000-0000-0000000001a1', 'c6000000-0000-0000-0000-0000000002a1'),
 ('c6000000-0000-0000-0000-0000000003b1', 'c6000000-0000-0000-0000-0000000000b1', 'estimate', 'Theirs', 1000, 'USD', 'proposed', 'c6000000-0000-0000-0000-0000000001b1', 'c6000000-0000-0000-0000-0000000002b1');
-- Sam may approve for Pat (verified); Ned is a contact who may only discuss
insert into public.customer_relationships (id, business_id, customer_id, related_customer_id, kind, permissions, verified_at, verification_method) values
 ('c6000000-0000-0000-0000-0000000004a1', 'c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-0000000001a1', 'c6000000-0000-0000-0000-0000000001a2', 'household', '{discuss,approve}', now(), 'known_to_team'),
 ('c6000000-0000-0000-0000-0000000004a2', 'c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-0000000001a1', 'c6000000-0000-0000-0000-0000000001a3', 'authorized_contact', '{discuss}', now(), 'known_to_team');
insert into public.appointments (id, business_id, customer_id, title, start_time, end_time, timezone, status) values
 ('c6000000-0000-0000-0000-0000000006a1', 'c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-0000000001a1', 'Facial', now() + interval '2 days', now() + interval '2 days 1 hour', 'UTC', 'scheduled'),
 ('c6000000-0000-0000-0000-0000000006a2', 'c6000000-0000-0000-0000-0000000000a1', 'c6000000-0000-0000-0000-0000000001a1', 'Facial 2', now() + interval '3 days', now() + interval '3 days 1 hour', 'UTC', 'scheduled');

create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, true) $$;
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
create temp table ids (k text primary key, val uuid) on commit drop;
grant all on ids to authenticated, anon;
grant execute on function pg_temp.expect(text, text) to authenticated, anon;

-- ===================================================== industry defaults
do $$ begin
  assert (select workflow -> 'approvals' = '["estimate", "additional_work"]' and workflow ->> 'approved_status' = 'approved' and workflow #>> '{inspection,title}' = 'Vehicle inspection'
            from public.crm_record_types where business_id = 'c6000000-0000-0000-0000-0000000000a1' and key = 'repair_orders'), 'repair orders get the automotive defaults';
  assert (select workflow #>> '{credits,unit}' = 'sessions' and workflow #>> '{credits,used_up_status}' = 'used_up'
            from public.crm_record_types where business_id = 'c6000000-0000-0000-0000-0000000000a1' and key = 'packages'), 'spa packages count sessions';
  assert (select workflow = '{}' from public.crm_record_types where business_id = 'c6000000-0000-0000-0000-0000000000a1' and key = 'vehicles'), 'vehicles: milestones and exceptions only';
  assert (select count(*) >= 60 from public.record_workflow_presets), 'presets for the industries';
  assert (select count(distinct preset_key) = 28 from public.record_workflow_presets), 'every one of the 28 industry presets has workflow defaults: ' || (select count(distinct preset_key) from public.record_workflow_presets);
end $$;
-- a type a business has set up its own way is never overwritten by the defaults
insert into public.crm_record_types (business_id, key, singular, plural, statuses, preset_key, workflow) values
 ('c6000000-0000-0000-0000-0000000000a1', 'loaners', 'Loaner', 'Loaners', '[{"key":"available","label":"Available"}]', 'automotive', '{"custom": true}');
update public.crm_record_types t set workflow = p.config from public.record_workflow_presets p
 where t.workflow = '{}'::jsonb and p.preset_key = t.preset_key and p.type_key = t.key and p.config <> '{}'::jsonb;   -- the migration's backfill, run again
do $$ begin
  assert (select workflow = '{"custom": true}' from public.crm_record_types where business_id = 'c6000000-0000-0000-0000-0000000000a1' and key = 'loaners'), 'a business''s own choice is kept';
end $$;
select 'PASS industry defaults: every one of the 28 presets has workflow defaults; new record types get theirs; a business''s own setting is never overwritten';

-- ===================================================== approvals: estimate approved by the customer
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');   -- staff
do $$ declare a uuid; res jsonb; begin
  a := public.zella_approval_request('c6000000-0000-0000-0000-0000000002a1', 'estimate', 'Front brakes and discs', null, null, current_date + 7, 'c6000000-0000-0000-0000-0000000003a1');
  insert into ids values ('estimate', a);
  assert (select amount_minor = 42000 and currency = 'USD' from public.record_approvals where id = a), 'the amount comes from the estimate';
  assert (select status = 'estimate_sent' from public.crm_records where id = 'c6000000-0000-0000-0000-0000000002a1'), 'the repair order moves to "estimate sent"';
  -- nobody unrelated may approve: a stranger, a contact who may only discuss, someone from another business, nobody at all
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''phone'', %L)', a, 'c6000000-0000-0000-0000-0000000001a3'), 'NOT_AUTHORIZED_APPROVER');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''phone'', %L)', a, 'c6000000-0000-0000-0000-0000000001b1'), 'NOT_VALID');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''phone'', null)', a), 'NO_APPROVER');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', null, %L)', a, 'c6000000-0000-0000-0000-0000000001a1'), 'NOT_VALID');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''internal'', %L)', a, 'c6000000-0000-0000-0000-0000000001a1'), 'NOT_VALID');
  -- the customer approves by phone
  res := public.zella_approval_decide(a, 'approved', 'phone', 'c6000000-0000-0000-0000-0000000001a1', 'Agreed on the call');
  assert res ->> 'status' = 'approved' and (res ->> 'record_moved')::boolean, 'approved: ' || res::text;
  assert (select status = 'approved' and method = 'phone' and approver_customer_id = 'c6000000-0000-0000-0000-0000000001a1' and approver_relationship_id is null and decided_by is not null
            from public.record_approvals where id = a), 'who, how and when are recorded';
  assert (select status = 'accepted' from public.customer_charges where id = 'c6000000-0000-0000-0000-0000000003a1'), 'the estimate is accepted';
  assert (select status = 'approved' from public.crm_records where id = 'c6000000-0000-0000-0000-0000000002a1'), 'the repair order moves to "approved"';
  -- deciding again (a second screen) changes nothing
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''declined'', ''phone'', %L)', a, 'c6000000-0000-0000-0000-0000000001a1'), 'CHANGED');
  perform pg_temp.expect(format('select public.zella_approval_withdraw(%L)', a), 'CHANGED');
end $$;
-- an estimate voided after the approval was asked for can't then be approved
reset role;
insert into public.customer_charges (id, business_id, kind, description, amount_minor, currency, status, customer_id, record_id) values
 ('c6000000-0000-0000-0000-0000000003a2', 'c6000000-0000-0000-0000-0000000000a1', 'estimate', 'Exhaust', 30000, 'USD', 'proposed', 'c6000000-0000-0000-0000-0000000001a1', 'c6000000-0000-0000-0000-0000000002a1');
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ begin insert into ids values ('exhaust', public.zella_approval_request('c6000000-0000-0000-0000-0000000002a1', 'estimate', 'Exhaust', null, null, null, 'c6000000-0000-0000-0000-0000000003a2')); end $$;
reset role;
update public.customer_charges set status = 'void' where id = 'c6000000-0000-0000-0000-0000000003a2';
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ begin
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''phone'', %L)', (select val from ids where k = 'exhaust'), 'c6000000-0000-0000-0000-0000000001a1'), 'CHANGED');
  assert (select status = 'requested' from public.record_approvals where id = (select val from ids where k = 'exhaust')), 'nothing was decided';
  perform public.zella_approval_withdraw((select val from ids where k = 'exhaust'));
end $$;
-- additional work, approved by the spouse who may approve; the record stays where it is
reset role;
update public.crm_records set status = 'in_repair' where id = 'c6000000-0000-0000-0000-0000000002a1';
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ declare a uuid; begin
  a := public.zella_approval_request('c6000000-0000-0000-0000-0000000002a1', 'additional_work', 'Rear pads too', 9000, 'usd');
  assert (select currency = 'USD' from public.record_approvals where id = a), 'currency upper-cased';
  perform public.zella_approval_decide(a, 'approved', 'text', 'c6000000-0000-0000-0000-0000000001a2');
  assert (select approver_relationship_id = 'c6000000-0000-0000-0000-0000000004a1' from public.record_approvals where id = a), 'approved through the "approve" relationship';
  assert (select status = 'in_repair' from public.crm_records where id = 'c6000000-0000-0000-0000-0000000002a1'), 'extra work doesn''t move the job back';
end $$;
-- once that relationship is revoked, the spouse can no longer approve
reset role;
update public.customer_relationships set revoked_at = now() where id = 'c6000000-0000-0000-0000-0000000004a1';
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ declare a uuid; begin
  a := public.zella_approval_request('c6000000-0000-0000-0000-0000000002a1', 'additional_work', 'Wipers');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''text'', %L)', a, 'c6000000-0000-0000-0000-0000000001a2'), 'NOT_AUTHORIZED_APPROVER');
  perform public.zella_approval_withdraw(a, 'customer will think about it');
  -- expired requests can't be decided; dates in the past and other businesses' estimates are refused
  a := public.zella_approval_request('c6000000-0000-0000-0000-0000000002a1', 'additional_work', 'Tyres', null, null, current_date);
  insert into ids values ('tyres', a);
end $$;
reset role;
update public.record_approvals set expires_on = current_date - 1 where id = (select val from ids where k = 'tyres');
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ declare a uuid := (select val from ids where k = 'tyres'); begin
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''phone'', %L)', a, 'c6000000-0000-0000-0000-0000000001a1'), 'EXPIRED');
  perform pg_temp.expect('select public.zella_approval_request(''c6000000-0000-0000-0000-0000000002a1'', ''additional_work'', ''Old'', null, null, current_date - 1)', 'BAD_DATE');
  perform pg_temp.expect('select public.zella_approval_request(''c6000000-0000-0000-0000-0000000002a1'', ''estimate'', ''Theirs'', null, null, null, ''c6000000-0000-0000-0000-0000000003b1'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_approval_request(''c6000000-0000-0000-0000-0000000002a1'', ''estimate'', ''x'')', 'record_approvals_title_len');
  -- a refund is a manager's decision
  perform pg_temp.expect('select public.zella_approval_request(''c6000000-0000-0000-0000-0000000002a1'', ''refund'', ''Refund the diagnostic'', 5000, ''USD'')', 'NOT_ALLOWED');
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000b');   -- manager
do $$ declare a uuid; begin
  a := public.zella_approval_request('c6000000-0000-0000-0000-0000000002a1', 'refund', 'Refund the diagnostic', 5000, 'USD');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''approved'', ''phone'', %L)', a, 'c6000000-0000-0000-0000-0000000001a1'), 'NOT_VALID');
  perform public.zella_approval_decide(a, 'approved', 'internal');
  assert (select status = 'approved' and approver_customer_id is null and method = 'internal' from public.record_approvals where id = a), 'refund decided internally';
  assert (select count(*) from public.zella_approval_approvers('c6000000-0000-0000-0000-0000000002a1')) = 1, 'after the revoke only Pat may approve';
end $$;
-- viewers and other businesses: no amounts to read, nothing to change
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000d');   -- viewer
do $$ begin
  assert (select count(*) from public.record_approvals) = 0, 'viewers don''t see approvals (amounts)';
  perform pg_temp.expect('select public.zella_approval_request(''c6000000-0000-0000-0000-0000000002a1'', ''additional_work'', ''Viewer try'')', 'NOT_ALLOWED');
  perform pg_temp.expect('select public.zella_approval_approvers(''c6000000-0000-0000-0000-0000000002a1'')', 'NOT_ALLOWED');
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000e');   -- another business's owner
do $$ begin
  assert (select count(*) from public.record_approvals) = 0, 'another business sees no approvals';
  perform pg_temp.expect('select public.zella_approval_request(''c6000000-0000-0000-0000-0000000002a1'', ''additional_work'', ''Not mine'')', 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_approval_decide(%L, ''declined'', ''phone'', %L)', (select val from ids where k = 'estimate'), 'c6000000-0000-0000-0000-0000000001b1'), 'NOT_ALLOWED');
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.crm_record_events where record_id = 'c6000000-0000-0000-0000-0000000002a1' and kind = 'approval') >= 6, 'approvals are in the record''s history';
  assert (select count(*) from public.audit_logs where business_id = 'c6000000-0000-0000-0000-0000000000a1' and action = 'workflow_approval') >= 6, 'and audited';
end $$;
select 'PASS approvals: the amount comes from the estimate; only the customer or someone they authorized to approve can approve (strangers, discuss-only contacts, revoked and other businesses'' people refused); who, how and when are recorded; the estimate is accepted and the record moves on; extra work doesn''t move it back; stale and expired decisions refused, and so is approving an estimate that was voided meanwhile; refunds are a manager''s internal decision; viewers and other businesses see and change nothing';

-- ===================================================== milestones and renewals
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ declare m uuid; n uuid; n2 uuid; begin
  m := public.zella_milestone_save('c6000000-0000-0000-0000-0000000002a3', null, 'Registration renewal', current_date + 3, 'renewal', 'c6000000-0000-0000-0000-0000000005a1');
  perform pg_temp.expect('select public.zella_milestone_save(''c6000000-0000-0000-0000-0000000002a3'', null, ''Service'', current_date, ''milestone'', ''c6000000-0000-0000-0000-0000000005b1'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_milestone_save(''c6000000-0000-0000-0000-0000000002a3'', null, ''Service'', null)', 'BAD_DATE');
  perform pg_temp.expect(format('select public.zella_milestone_done(%L, true, current_date)', m), 'BAD_DATE');   -- the next one must come after
  n := public.zella_milestone_done(m, true, (current_date + interval '1 year')::date);
  assert n <> m and (select next_of = m and kind = 'renewal' and done_at is null and staff_id = 'c6000000-0000-0000-0000-0000000005a1' from public.record_milestones where id = n), 'the renewal rolls forward a year';
  perform pg_temp.expect(format('select public.zella_milestone_done(%L, true, current_date + 400)', m), 'CHANGED');
  -- reopen and finish again: still only one next one
  perform public.zella_milestone_done(m, false);
  n2 := public.zella_milestone_done(m, true, (current_date + interval '1 year')::date);
  assert (select count(*) from public.record_milestones where next_of = m) = 1, 'rolled forward once';
  perform pg_temp.expect(format('select public.zella_milestone_save(%L, %L, ''Changed'', current_date + 9)', 'c6000000-0000-0000-0000-0000000002a3', m), 'CHANGED');   -- done ones are history
  perform public.zella_milestone_save('c6000000-0000-0000-0000-0000000002a3', n, 'Registration renewal (rego)', current_date + 380, 'renewal');
  assert (select due_on = current_date + 380 from public.record_milestones where id = n), 'an open one can be moved';
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000d');   -- viewer: reads milestones, changes none
do $$ begin
  assert (select count(*) from public.record_milestones where record_id = 'c6000000-0000-0000-0000-0000000002a3') = 2, 'viewers read milestones';
  perform pg_temp.expect('select public.zella_milestone_save(''c6000000-0000-0000-0000-0000000002a3'', null, ''Viewer'', current_date + 1)', 'NOT_ALLOWED');
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000e');
do $$ begin assert (select count(*) from public.record_milestones) = 0, 'another business reads none'; end $$;
select 'PASS milestones and renewals: added with a person from this business only; a done renewal rolls forward once to a later date; done ones are history; viewers read them; other businesses see none';

-- ===================================================== inspections and exceptions
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ declare res jsonb; res2 jsonb; e uuid; begin
  perform pg_temp.expect('select public.zella_inspection_save(''c6000000-0000-0000-0000-0000000002a1'', null, ''Vehicle inspection'', ''[{"label":"Brakes"}]'', true)', 'CHECKLIST_INCOMPLETE');
  perform pg_temp.expect('select public.zella_inspection_save(''c6000000-0000-0000-0000-0000000002a1'', null, ''Vehicle inspection'', ''[]'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_inspection_save(''c6000000-0000-0000-0000-0000000002a1'', null, ''Vehicle inspection'', ''[{"label":"Brakes","result":"maybe"}]'')', 'NOT_VALID');
  res := public.zella_inspection_save('c6000000-0000-0000-0000-0000000002a1', null, 'Vehicle inspection', '[{"label":"Brakes","result":"pass"},{"label":"Tyres"}]', false, 'c6000000-0000-0000-0000-0000000005a1');
  assert res ->> 'outcome' = 'in_progress', 'saved part-way';
  -- a stale screen can't overwrite it
  perform pg_temp.expect(format('select public.zella_inspection_save(%L, %L, ''Vehicle inspection'', ''[{"label":"Brakes","result":"pass"}]'', false, null, null, %L)',
    'c6000000-0000-0000-0000-0000000002a1', res ->> 'id', now() - interval '1 day'), 'CHANGED');
  res2 := public.zella_inspection_save('c6000000-0000-0000-0000-0000000002a1', (res ->> 'id')::uuid, 'Vehicle inspection',
    '[{"label":"Brakes","result":"pass"},{"label":"Tyres","result":"fail","note":"2mm tread"}]', true, 'c6000000-0000-0000-0000-0000000005a1', null, (res ->> 'updated_at')::timestamptz);
  assert res2 ->> 'outcome' = 'failed' and res2 ->> 'exception_id' is not null, 'a failed item fails the inspection and opens an exception: ' || res2::text;
  assert (select kind = 'inspection_failed' and detail like '%Tyres%' and inspection_id = (res ->> 'id')::uuid from public.record_exceptions where id = (res2 ->> 'exception_id')::uuid), 'the exception names what failed';
  perform pg_temp.expect(format('select public.zella_inspection_save(%L, %L, ''Vehicle inspection'', ''[{"label":"Brakes","result":"pass"}]'')', 'c6000000-0000-0000-0000-0000000002a1', res ->> 'id'), 'CHANGED');   -- finished = history
  -- a passing one opens nothing
  res := public.zella_inspection_save('c6000000-0000-0000-0000-0000000002a1', null, 'Road test', '[{"label":"Noise","result":"pass"},{"label":"Pull","result":"na"}]', true);
  assert res ->> 'outcome' = 'passed' and res ->> 'exception_id' is null, 'passed';
  -- exceptions by hand
  e := public.zella_exception_open('c6000000-0000-0000-0000-0000000002a1', 'waiting_parts', 'Discs on back order', current_date + 5);
  perform pg_temp.expect('select public.zella_exception_open(''c6000000-0000-0000-0000-0000000002a1'', ''waiting_parts'')', 'ALREADY_OPEN');
  perform pg_temp.expect('select public.zella_exception_open(''c6000000-0000-0000-0000-0000000002a1'', ''inspection_failed'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_exception_open(''c6000000-0000-0000-0000-0000000002a1'', ''bored'')', 'record_exceptions_kind');
  perform public.zella_exception_resolve(e, 'Discs arrived');
  perform pg_temp.expect(format('select public.zella_exception_resolve(%L)', e), 'CHANGED');
  e := public.zella_exception_open('c6000000-0000-0000-0000-0000000002a1', 'waiting_parts', 'Calipers now');   -- a new one once the old one is resolved
  assert e is not null, 'reopened after resolving';
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000e');
do $$ begin
  assert (select count(*) from public.record_inspections) = 0 and (select count(*) from public.record_exceptions) = 0, 'another business sees none';
  perform pg_temp.expect('select public.zella_exception_open(''c6000000-0000-0000-0000-0000000002a1'', ''delayed'')', 'NOT_ALLOWED');
end $$;
select 'PASS inspections and exceptions: every item answered before finishing; a stale screen changes nothing; a failed item fails it and opens an "inspection failed" exception naming what failed; finished inspections are history; one open exception of a kind at a time, resolved once; other businesses see and change nothing';

-- ===================================================== credits
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');   -- staff can't grant
do $$ begin
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''grant'', 5)', 'NOT_ALLOWED');
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a1'', ''grant'', 5)', 'NOT_ALLOWED');
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000b');   -- manager
do $$ declare res jsonb; begin
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a1'', ''grant'', 5)', 'NOT_VALID');   -- repair orders don't count credits
  res := public.zella_credit_add('c6000000-0000-0000-0000-0000000002a2', 'grant', 3, null, 'Bought 3');
  assert (res ->> 'balance')::int = 3, 'granted 3';
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ declare res jsonb; begin
  res := public.zella_credit_add('c6000000-0000-0000-0000-0000000002a2', 'use', 1, 'c6000000-0000-0000-0000-0000000006a1', null, 3);
  assert (res ->> 'balance')::int = 2, 'used one';
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 1, ''c6000000-0000-0000-0000-0000000006a1'')', 'ALREADY_USED');   -- one visit, once
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 3)', 'NO_CREDITS');
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 1, null, null, 3)', 'CHANGED');   -- the screen showed 3, there are 2
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 0)', 'record_credits_units');
  res := public.zella_credit_add('c6000000-0000-0000-0000-0000000002a2', 'use', 2, 'c6000000-0000-0000-0000-0000000006a2');
  assert (res ->> 'balance')::int = 0 and (res ->> 'record_moved')::boolean, 'last ones used: ' || res::text;
  assert (select status = 'used_up' from public.crm_records where id = 'c6000000-0000-0000-0000-0000000002a2'), 'the package is used up';
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 1)', 'NOT_OPEN');
  res := public.zella_credit_add('c6000000-0000-0000-0000-0000000002a2', 'refund', 1, null, 'Cancelled in time');
  assert (res ->> 'balance')::int = 1, 'a refund puts one back';
  -- giving back can't create credits: only what was used (3), less what was already given back (1)
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''refund'', 3)', 'MORE_THAN_USED');
  res := public.zella_credit_add('c6000000-0000-0000-0000-0000000002a2', 'refund', 2);
  assert (res ->> 'balance')::int = 3, 'gave back the rest that was used';
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''refund'', 1)', 'MORE_THAN_USED');
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000d');
do $$ begin
  assert (select coalesce(sum(case when kind in ('grant', 'refund') then units else -units end), 0) from public.record_credits where record_id = 'c6000000-0000-0000-0000-0000000002a2') = 3, 'viewers can read the balance';
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 1)', 'NOT_ALLOWED');
end $$;
select 'PASS credits: managers grant and expire, staff use and give back only what was used; never below zero; one visit uses a package once; a stale screen changes nothing; the last one marks the package used up and a used-up package can''t be used; viewers read, change nothing';

-- ===================================================== workflow settings, the follow-through list, paused businesses, anon
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000c');
do $$ begin
  perform pg_temp.expect('select public.zella_record_workflow_save(''c6000000-0000-0000-0000-0000000000a1'', ''vehicles'', ''{"approvals":["contract"]}'')', 'NOT_ALLOWED');
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000b');
do $$ declare w jsonb; begin
  w := public.zella_record_workflow_save('c6000000-0000-0000-0000-0000000000a1', 'vehicles', '{"approvals":["contract","contract"],"inspection":{"title":"Pre-purchase check","items":["Body"," Engine "]},"junk":1}');
  assert w = '{"approvals":["contract"],"inspection":{"title":"Pre-purchase check","items":["Body","Engine"]},"custom":true}', 'cleaned and marked as the business''s own: ' || w::text;
  perform pg_temp.expect('select public.zella_record_workflow_save(''c6000000-0000-0000-0000-0000000000a1'', ''vehicles'', ''{"approved_status":"sold"}'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_record_workflow_save(''c6000000-0000-0000-0000-0000000000a1'', ''vehicles'', ''{"approvals":["bribe"]}'')', 'NOT_VALID');
  w := public.zella_record_workflow_save('c6000000-0000-0000-0000-0000000000a1', 'vehicles', '{}');
  assert w = '{"custom":true}', 'turning everything off is kept as a choice';
end $$;
do $$ declare d jsonb; begin
  d := public.zella_workflow_due('c6000000-0000-0000-0000-0000000000a1', 30);
  assert jsonb_array_length(d -> 'approvals') >= 1 and jsonb_array_length(d -> 'exceptions') >= 2 and (d ->> 'can_work')::boolean, 'manager sees what''s waiting: ' || d::text;
  assert exists (select 1 from jsonb_array_elements(d -> 'approvals') a where (a ->> 'expired')::boolean), 'expired approvals are flagged';
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000d');
do $$ declare d jsonb; begin
  d := public.zella_workflow_due('c6000000-0000-0000-0000-0000000000a1', 30);
  assert d -> 'approvals' = 'null'::jsonb and jsonb_array_length(d -> 'exceptions') >= 2 and not (d ->> 'can_work')::boolean, 'viewers: no amounts, read only';
end $$;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000e');
do $$ begin perform pg_temp.expect('select public.zella_workflow_due(''c6000000-0000-0000-0000-0000000000a1'')', 'NOT_ALLOWED'); end $$;
reset role;
update public.businesses set suspended_at = now() where id = 'c6000000-0000-0000-0000-0000000000a1';
set local role authenticated;
select pg_temp.as_user('c6000000-0000-0000-0000-00000000000a');   -- the owner of a paused business
do $$ begin
  perform pg_temp.expect('select public.zella_exception_open(''c6000000-0000-0000-0000-0000000002a3'', ''delayed'')', 'NOT_ALLOWED');
  perform pg_temp.expect('select public.zella_record_workflow_save(''c6000000-0000-0000-0000-0000000000a1'', ''vehicles'', ''{}'')', 'NOT_ALLOWED');
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ begin
  perform pg_temp.expect('select count(*) from public.record_approvals', '42501');
  perform pg_temp.expect('select count(*) from public.record_milestones', '42501');
  perform pg_temp.expect('select public.zella_workflow_due(''c6000000-0000-0000-0000-0000000000a1'')', '42501');
  perform pg_temp.expect('select public.zella_credit_add(''c6000000-0000-0000-0000-0000000002a2'', ''use'', 1)', '42501');
end $$;
reset role;
select 'PASS settings, follow-through and access: managers set a type''s workflow (cleaned, statuses checked, kept as the business''s own); the follow-through list shows waiting approvals (expired flagged), due milestones and open exceptions, with no amounts for viewers; paused businesses change nothing; anon gets nothing';
rollback;
