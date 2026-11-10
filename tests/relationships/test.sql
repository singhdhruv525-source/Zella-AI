-- Release 1 (sql/zella_relationships.sql) on an ISOLATED copy of the production schema (tests/relationships/run.sh).
-- Synthetic people only (ids c7…); everything is rolled back.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('c7000000-0000-0000-0000-00000000000a', 'own@r1.test', now()), ('c7000000-0000-0000-0000-00000000000b', 'mgr@r1.test', now()),
 ('c7000000-0000-0000-0000-00000000000c', 'staff@r1.test', now()), ('c7000000-0000-0000-0000-00000000000d', 'view@r1.test', now()),
 ('c7000000-0000-0000-0000-00000000000e', 'other@r1.test', now()), ('c7000000-0000-0000-0000-00000000000f', 'salonstaff@r1.test', now());
insert into public.profiles (id) select id from auth.users where email like '%@r1.test' on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('c7000000-0000-0000-0000-0000000000a1', 'R1 Little Stars', 'UTC', true, 'active', (select id from public.industries where slug = 'childcare' limit 1)),
 ('c7000000-0000-0000-0000-0000000000b1', 'R1 Other', 'UTC', true, 'active', (select id from public.industries where slug = 'childcare' limit 1)),
 ('c7000000-0000-0000-0000-0000000000c1', 'R1 Salon', 'UTC', true, 'active', (select id from public.industries where slug = 'beauty-salon' limit 1));
insert into public.business_members (business_id, user_id, role, status)
select b::uuid, u::uuid, r, 'active' from (values
 ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-00000000000a', 'owner'), ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-00000000000b', 'manager'),
 ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-00000000000c', 'staff'), ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-00000000000d', 'viewer'),
 ('c7000000-0000-0000-0000-0000000000b1', 'c7000000-0000-0000-0000-00000000000e', 'owner'), ('c7000000-0000-0000-0000-0000000000c1', 'c7000000-0000-0000-0000-00000000000f', 'staff')) v(b, u, r);
insert into public.customers (id, business_id, first_name, last_name, phone) values
 ('c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000000a1', 'Pat', 'Parent', '+15125550301'),
 ('c7000000-0000-0000-0000-0000000001a2', 'c7000000-0000-0000-0000-0000000000a1', 'Quinn', 'Grandma', '+15125550302'),
 ('c7000000-0000-0000-0000-0000000001a3', 'c7000000-0000-0000-0000-0000000000a1', 'Sam', 'Stranger', '+15125550303'),
 ('c7000000-0000-0000-0000-0000000001b1', 'c7000000-0000-0000-0000-0000000000b1', 'Xena', 'Elsewhere', '+15125550304'),
 ('c7000000-0000-0000-0000-0000000001b2', 'c7000000-0000-0000-0000-0000000000b1', 'Yuri', 'Elsewhere', '+15125550307'),
 ('c7000000-0000-0000-0000-0000000001a4', 'c7000000-0000-0000-0000-0000000000a1', 'Quinn', 'Grandma (duplicate)', '+15125550312'),
 ('c7000000-0000-0000-0000-0000000001a5', 'c7000000-0000-0000-0000-0000000000a1', 'Pat', 'Parent (duplicate)', '+15125550311'),
 ('c7000000-0000-0000-0000-0000000001c1', 'c7000000-0000-0000-0000-0000000000c1', 'Cara', 'Client', '+15125550305'),
 ('c7000000-0000-0000-0000-0000000001c2', 'c7000000-0000-0000-0000-0000000000c1', 'Dan', 'Partner', '+15125550306');
insert into public.crm_record_types (business_id, key, singular, plural, statuses) values
 ('c7000000-0000-0000-0000-0000000000a1', 'r1children', 'Child', 'Children', '[{"key":"active","label":"Active"}]') on conflict do nothing;
insert into public.crm_records (id, business_id, type_key, title, status, customer_id) values
 ('c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000000a1', 'r1children', 'Mia', 'active', 'c7000000-0000-0000-0000-0000000001a1');
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
create temp table ids (k text primary key, v uuid) on commit drop;
grant all on ids to authenticated, anon;

-- ===================================================== relationships: verification before authority
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');   -- staff
do $$ declare v uuid; begin
  v := public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', null, null, 'c7000000-0000-0000-0000-0000000004a1',
       'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup', 'discuss', 'pickup'], null, 'Grandma, picks up on Fridays');
  insert into ids values ('grandma', v);
  assert (select permissions from public.customer_relationships where id = v) = array['discuss', 'pickup'], 'permissions deduplicated and sorted';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'),
    'an unverified guardian may not pick up';
  -- staff can't verify in a sensitive industry (childcare)
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L)', v, 'id_checked', 'c7000000-0000-0000-0000-0000000001a2', 'guardian', '{discuss,pickup}'), 'NOT_ALLOWED');
end $$;
select 'PASS a new link grants nothing until verified; staff cannot verify in a sensitive industry';

select pg_temp.as_user('c7000000-0000-0000-0000-00000000000b');   -- manager
do $$ declare v uuid := (select v from ids where k = 'grandma'); begin
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L)', v, 'telepathy', 'c7000000-0000-0000-0000-0000000001a2', 'guardian', '{discuss,pickup}'), 'BAD_METHOD');
  perform public.zella_relationship_verify(v, 'id_checked', 'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['discuss', 'pickup'], null, (select updated_at from public.customer_relationships where id = v));
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'), 'verified guardian may pick up';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'approve'), 'but not approve';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a3', 'pickup'), 'a stranger may not';
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a1', 'approve'), 'the record''s primary contact may';
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a1', null, 'c7000000-0000-0000-0000-0000000001a1', 'discuss'), 'a person for themselves';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'fly'), 'unknown permission';
end $$;
select 'PASS a manager verifies (method checked); then exactly the granted permissions apply; the primary contact and the person themselves are authorized';

select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');   -- staff edits
do $$ declare v uuid := (select v from ids where k = 'grandma'); begin
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup'], null, null, (select updated_at from public.customer_relationships where id = v));
  assert (select verified_at is not null from public.customer_relationships where id = v), 'narrowing keeps the verification';
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup', 'approve'], null, null, (select updated_at from public.customer_relationships where id = v));
  assert (select verified_at is null from public.customer_relationships where id = v), 'widening clears the verification';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'), 'and so grants nothing';
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, null, %L, %L, %L, %L, %L, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'guardian', '{pickup}', null), '23505');   -- one active link per kind
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, null, %L, %L, %L, %L, %L, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a3', 'guardian', '{pickup}', (current_date - 1)::text), 'BAD_DATE');
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a1', 'household', '{discuss}'), 'SAME_PERSON');
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a2', 'best_friend', '{discuss}'), 'customer_relationships_kind');
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a2', 'household', '{everything}'), 'customer_relationships_permissions');
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001b1', 'household', '{discuss}'), 'NOT_VALID');   -- a person from another business
end $$;
-- a stale Verify: the manager saw "pickup", staff widened it to "pickup + approve" before the manager confirmed
reset role;
do $$ begin update public.customer_relationships set permissions = array['pickup'], verified_at = null where id = (select v from ids where k = 'grandma'); end $$;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');   -- staff widens it
do $$ begin perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', (select v from ids where k = 'grandma'), null,
  'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup', 'approve'], null, null, (select updated_at from public.customer_relationships where id = (select v from ids where k = 'grandma'))); end $$;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000b');   -- manager confirms what they were shown
do $$ declare v uuid := (select v from ids where k = 'grandma'); begin
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L)', v, 'id_checked',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', '{pickup}'), 'CHANGED');
  assert (select verified_at is null from public.customer_relationships where id = v), 'a stale verify changes nothing';
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L)', v, 'id_checked',
          'c7000000-0000-0000-0000-0000000001a3', 'guardian', '{approve,pickup}'), 'CHANGED');   -- a different person shown
  -- what is really there, in any order, verifies
  perform public.zella_relationship_verify(v, 'id_checked', 'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup', 'approve'], null, (select updated_at from public.customer_relationships where id = v));
  assert (select verified_at is not null from public.customer_relationships where id = v), 'verified as it really is';
end $$;
reset role;
do $$ begin update public.customer_relationships set permissions = array['pickup'] where id = (select v from ids where k = 'grandma'); end $$;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');
select 'PASS a verification only applies to exactly what the verifier was shown: a link changed meanwhile (wider permissions, another person) is refused and stays unverified';

select 'PASS edits: narrowing keeps verification, widening clears it; duplicates, past end dates, the same person, unknown kinds and permissions, and people from another business are refused';

-- stale forms: an edit or a verification made from an out-of-date screen changes nothing
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000b');   -- manager
do $$ declare v uuid; t timestamptz; begin
  v := public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000001a1', null,
       'c7000000-0000-0000-0000-0000000001a3', 'representative', array['discuss', 'book'], current_date + 20, null);
  t := (select updated_at from public.customer_relationships where id = v);   -- what both screens loaded
  -- someone else narrows it to "discuss" (with what they loaded) ...
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, 'c7000000-0000-0000-0000-0000000001a1', null,
       'c7000000-0000-0000-0000-0000000001a3', 'representative', array['discuss'], current_date + 20, null, t);
  -- ... so a save from the older screen, which still shows "book", is refused and doesn't bring "book" back
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, %L, %L, null, %L, %L, %L, %L, null, %L)', 'c7000000-0000-0000-0000-0000000000a1', v,
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'representative', '{discuss,book}', current_date + 20, t), 'CHANGED');
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, %L, %L, null, %L, %L, %L, %L, null)', 'c7000000-0000-0000-0000-0000000000a1', v,
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'representative', '{discuss,book}', current_date + 20), 'CHANGED');
  assert (select permissions = '{discuss}' from public.customer_relationships where id = v), 'stale saves changed nothing';
  -- the end date is part of what the verifier saw: extended while the Verify form was open -> nothing verified
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, 'c7000000-0000-0000-0000-0000000001a1', null,
       'c7000000-0000-0000-0000-0000000001a3', 'representative', array['discuss'], current_date + 300, null,
       (select updated_at from public.customer_relationships where id = v));
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L, %L)', v, 'id_checked',
          'c7000000-0000-0000-0000-0000000001a3', 'representative', '{discuss}', current_date + 20), 'CHANGED');
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L)', v, 'id_checked',
          'c7000000-0000-0000-0000-0000000001a3', 'representative', '{discuss}'), 'CHANGED');
  assert (select verified_at is null from public.customer_relationships where id = v), 'a verification of a different end date changed nothing';
  perform public.zella_relationship_verify(v, 'id_checked', 'c7000000-0000-0000-0000-0000000001a3', 'representative', array['discuss'], current_date + 300, (select updated_at from public.customer_relationships where id = v));
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a1', null, 'c7000000-0000-0000-0000-0000000001a3', 'discuss'), 'verifying what is current works';
  perform public.zella_relationship_revoke(v, 'test done');
end $$;
reset role;
select 'PASS stale screens: an edit from an out-of-date form (or without its version) and a verification of a different end date are refused (CHANGED) and change nothing';

-- expiry and revocation
reset role;
do $$ begin update public.customer_relationships set verified_at = now(), valid_until = current_date - 1 where id = (select v from ids where k = 'grandma'); end $$;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');
do $$ declare v uuid := (select v from ids where k = 'grandma'); p jsonb; begin
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'), 'expired link grants nothing';
  p := public.zella_people_panel('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1');
  assert p #>> '{relationships,0,state}' = 'expired', 'panel shows expired: ' || p::text;
  assert p #>> '{primary_contact,first_name}' = 'Pat', 'panel names the primary contact';
  -- staff (childcare) extends the expired link: the old verification doesn't come back, so it grants nothing
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', (select kind from public.customer_relationships where id = v),
          (select permissions from public.customer_relationships where id = v), current_date + 30, null, (select updated_at from public.customer_relationships where id = v));
  assert (select verified_at is null and verification_method is null from public.customer_relationships where id = v), 'extending an expired link clears its verification';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'), 'extended but unverified link grants nothing';
  assert (select state from jsonb_to_recordset(public.zella_people_panel('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1') -> 'relationships') x(id uuid, state text) where id = v) = 'unverified', 'panel shows the extended link as not verified';
  perform public.zella_relationship_revoke(v, 'No longer collects');
  perform public.zella_relationship_revoke(v, 'twice is fine');
  assert (select revoked_at is not null and revoke_reason = 'No longer collects' from public.customer_relationships where id = v), 'revoked with its reason';
  -- after revoking, the same kind can be added again (history kept)
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', null, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup'], null, null);
  assert (select count(*) from public.customer_relationships where record_id = 'c7000000-0000-0000-0000-0000000004a1') = 2, 'history kept';
  p := public.zella_people_panel('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a2', null);
  assert jsonb_array_length(p -> 'authorized_for') = 1 and p #>> '{authorized_for,0,subject,name}' = 'Mia', 'a person''s panel lists what they are linked to: ' || p::text;
end $$;
select 'PASS an expired link grants nothing; revoking keeps the history (and is safe to repeat); the person''s own panel lists what they are linked to';
reset role;
do $$ begin update public.customer_relationships set verified_at = now(), verification_method = 'known_to_team', valid_until = current_date + 30
  where record_id = 'c7000000-0000-0000-0000-0000000004a1' and revoked_at is null; end $$;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');
do $$ declare v uuid := (select id from public.customer_relationships where record_id = 'c7000000-0000-0000-0000-0000000004a1' and revoked_at is null); begin
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup'], current_date + 10, null, (select updated_at from public.customer_relationships where id = v));
  assert (select verified_at is not null from public.customer_relationships where id = v), 'an earlier end date keeps the verification';
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'), 'still in force after shortening';
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup'], null, null, (select updated_at from public.customer_relationships where id = v));
  assert (select verified_at is null from public.customer_relationships where id = v), 'removing the end date clears the verification';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a2', 'pickup'), 'open-ended again but unverified: nothing';
end $$;
select 'PASS end dates: extending a link (an expired one included) or removing its end date needs a fresh verification; an earlier end date keeps it';

-- ===================================================== consents
do $$ declare c uuid; p jsonb; begin
  perform pg_temp.expect(format('select public.zella_consent_record(%L, null, %L, %L, %L, %L)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000004a1', 'photo_media', 'granted', 'c7000000-0000-0000-0000-0000000001a2'), 'NOT_AUTHORIZED_GIVER');   -- unverified, no approve
  perform pg_temp.expect(format('select public.zella_consent_record(%L, null, %L, %L, %L, %L)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000004a1', 'photo_media', 'granted', 'c7000000-0000-0000-0000-0000000001a3'), 'NOT_AUTHORIZED_GIVER');   -- a stranger
  c := public.zella_consent_record('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'photo_media', 'granted',
       'c7000000-0000-0000-0000-0000000001a1', 'Class photos only', (current_date + 365), 'Signed form, 6 Nov');
  perform public.zella_consent_record('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'medication', 'refused',
       'c7000000-0000-0000-0000-0000000001a1', 'Paracetamol', null, null);
  perform pg_temp.expect(format('select public.zella_consent_record(%L, null, %L, %L, %L, %L, null, %L)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000004a1', 'treatment', 'granted', 'c7000000-0000-0000-0000-0000000001a1', (current_date - 1)::text), 'BAD_DATE');
  perform pg_temp.expect(format('select public.zella_consent_record(%L, null, %L, %L, %L, %L)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000004a1', 'treatment', 'maybe', 'c7000000-0000-0000-0000-0000000001a1'), 'customer_consents_status');
  p := public.zella_people_panel('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1');
  assert (select array_agg(x ->> 'state' order by x ->> 'kind') from jsonb_array_elements(p -> 'consents') x) = array['refused', 'active'], 'states: ' || (p -> 'consents')::text;
  perform public.zella_consent_revoke(c, 'Parent withdrew');
  p := public.zella_people_panel('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1');
  assert exists (select 1 from jsonb_array_elements(p -> 'consents') x where x ->> 'kind' = 'photo_media' and x ->> 'state' = 'revoked'), 'revoked consent';
end $$;
select 'PASS consent: only someone who may approve can give or refuse it (not an unverified relative or a stranger); refusals, expiry dates and withdrawals are recorded';

-- a verified relative with "approve" may give consent
reset role;
do $$ begin update public.customer_relationships set permissions = array['approve', 'pickup'], verified_at = now()
            where record_id = 'c7000000-0000-0000-0000-0000000004a1' and revoked_at is null; end $$;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000c');
do $$ begin
  perform public.zella_consent_record('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'emergency_care', 'granted',
          'c7000000-0000-0000-0000-0000000001a2');
end $$;
select 'PASS a verified relative allowed to approve can give consent';

-- ===================================================== roles, other businesses, paused business, anon
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000d');   -- viewer
do $$ declare p jsonb; begin
  p := public.zella_people_panel('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1');
  assert (p ->> 'can_edit')::boolean = false and (p ->> 'can_verify')::boolean = false and jsonb_array_length(p -> 'relationships') = 2, 'viewer reads, cannot edit';
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'household', '{discuss}'), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_relationship_revoke(%L)', (select id from public.customer_relationships where record_id = 'c7000000-0000-0000-0000-0000000004a1' and revoked_at is null)), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_consent_record(%L, %L, null, %L, %L, %L)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'terms', 'granted', 'c7000000-0000-0000-0000-0000000001a1'), 'NOT_ALLOWED');
  perform pg_temp.expect('insert into public.customer_relationships (business_id, customer_id, related_customer_id, kind) values (''c7000000-0000-0000-0000-0000000000a1'', ''c7000000-0000-0000-0000-0000000001a1'', ''c7000000-0000-0000-0000-0000000001a3'', ''household'')', '42501');
end $$;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000e');   -- owner of another business
do $$ begin
  perform pg_temp.expect(format('select public.zella_people_panel(%L, null, %L)', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000004a1'), 'NOT_ALLOWED');
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a1', 'approve'), 'no answers for another business';
  assert (select count(*) from public.customer_relationships) = 0 and (select count(*) from public.customer_consents) = 0, 'reads none of their rows';
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'household', '{discuss}'), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000b1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001b1', 'household', '{discuss}'), 'NOT_VALID');   -- someone else's person as subject
  perform pg_temp.expect(format('select public.zella_relationship_revoke(%L)', (select v from ids where k = 'grandma')), 'NOT_ALLOWED');
end $$;
-- the same owner against Alpha's ACTIVE rows (looked up as the database owner, then attacked as the other business)
reset role;
insert into ids select 'active_rel', id from public.customer_relationships where record_id = 'c7000000-0000-0000-0000-0000000004a1' and revoked_at is null;
insert into ids select 'active_consent', id from public.customer_consents where record_id = 'c7000000-0000-0000-0000-0000000004a1' and revoked_at is null and kind = 'emergency_care';
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000e');
do $$ begin
  assert (select v from ids where k = 'active_rel') is not null and (select v from ids where k = 'active_consent') is not null, 'foreign fixtures exist';
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L)', (select v from ids where k = 'active_rel'), 'id_checked',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', '{approve,pickup}'), 'NOT_ALLOWED');
  perform pg_temp.expect(format('select public.zella_consent_revoke(%L)', (select v from ids where k = 'active_consent')), 'NOT_ALLOWED');
  -- their own business and people, but Alpha's relationship id: not theirs to change
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, %L, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000b1',
          (select v from ids where k = 'active_rel'), 'c7000000-0000-0000-0000-0000000001b1', 'c7000000-0000-0000-0000-0000000001b2', 'household', '{discuss}'), 'NOT_FOUND');
end $$;
reset role;
do $$ begin
  assert (select revoked_at is null and verified_at is not null and related_customer_id = 'c7000000-0000-0000-0000-0000000001a2'
            from public.customer_relationships where id = (select v from ids where k = 'active_rel')), 'Alpha''s link untouched';
  assert (select revoked_at is null from public.customer_consents where id = (select v from ids where k = 'active_consent')), 'Alpha''s consent untouched';
end $$;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000e');
reset role;
update public.businesses set suspended_at = now() where id = 'c7000000-0000-0000-0000-0000000000a1';
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000a');   -- owner, business paused
do $$ begin
  perform pg_temp.expect(format('select public.zella_relationship_save(%L, null, %L, null, %L, %L, %L, null, null)', 'c7000000-0000-0000-0000-0000000000a1',
          'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'household', '{discuss}'), 'NOT_ALLOWED');
end $$;
reset role;
update public.businesses set suspended_at = null where id = 'c7000000-0000-0000-0000-0000000000a1';
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ begin
  perform pg_temp.expect('select public.zella_people_panel(''c7000000-0000-0000-0000-0000000000a1'', null, ''c7000000-0000-0000-0000-0000000004a1'')', '42501');
  perform pg_temp.expect('select public.zella_is_authorized(''c7000000-0000-0000-0000-0000000000a1'', null, ''c7000000-0000-0000-0000-0000000004a1'', ''c7000000-0000-0000-0000-0000000001a1'', ''pickup'')', '42501');
  perform pg_temp.expect('select 1 from public.customer_relationships', '42501');
end $$;
reset role;
select 'PASS viewers read but cannot change anything (functions or direct insert); another business sees and changes nothing (including verifying, withdrawing or saving over our active rows); a paused business takes no changes; anon gets nothing';

-- ===================================================== non-sensitive industry: staff verify; the server answers
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000f');   -- salon staff
do $$ declare v uuid; begin
  v := public.zella_relationship_save('c7000000-0000-0000-0000-0000000000c1', null, 'c7000000-0000-0000-0000-0000000001c1', null,
       'c7000000-0000-0000-0000-0000000001c2', 'household', array['book'], null, null);
  perform public.zella_relationship_verify(v, 'known_to_team', 'c7000000-0000-0000-0000-0000000001c2', 'household', array['book'], null, (select updated_at from public.customer_relationships where id = v));
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000c1', 'c7000000-0000-0000-0000-0000000001c1', null, 'c7000000-0000-0000-0000-0000000001c2', 'book'), 'partner may book';
end $$;
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$ begin
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000c1', 'c7000000-0000-0000-0000-0000000001c1', null, 'c7000000-0000-0000-0000-0000000001c2', 'book'), 'the server gets the same answer';
  assert not public.zella_is_authorized('c7000000-0000-0000-0000-0000000000c1', 'c7000000-0000-0000-0000-0000000001c1', null, 'c7000000-0000-0000-0000-0000000001c2', 'discuss'), 'and only for what was granted';
end $$;
reset role;
select 'PASS outside sensitive industries staff verify; the server (for the AI receptionist later) gets the same answer';

-- ===================================================== customer merge
reset role;
insert into public.customer_relationships (id, business_id, customer_id, record_id, related_customer_id, kind, permissions, verified_at, verification_method) values
 ('c7000000-0000-0000-0000-0000000005a1', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a5', null, 'c7000000-0000-0000-0000-0000000001a3', 'household', '{discuss}', now(), 'known_to_team'),
 ('c7000000-0000-0000-0000-0000000005a2', 'c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a4', 'authorized_contact', '{pickup}', now(), 'id_checked'),
 ('c7000000-0000-0000-0000-0000000005a3', 'c7000000-0000-0000-0000-0000000000a1', null, 'c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000001a4', 'guardian', '{pickup}', now(), 'id_checked'),
 ('c7000000-0000-0000-0000-0000000005a4', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a2', null, 'c7000000-0000-0000-0000-0000000001a4', 'household', '{discuss}', now(), 'known_to_team');
-- collisions about the dropped Pat (a5) with links about the kept Pat (a1), both to Sam (a3):
--   emergency contact: the moving link is verified, the existing one isn't -> the verified one survives
--   proxy: the existing link is verified and grants more -> the moving one is the duplicate
insert into public.customer_relationships (id, business_id, customer_id, related_customer_id, kind, permissions, verified_at, verification_method) values
 ('c7000000-0000-0000-0000-0000000005b1', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a5', 'c7000000-0000-0000-0000-0000000001a3', 'emergency_contact', '{discuss}', now(), 'id_checked'),
 ('c7000000-0000-0000-0000-0000000005b3', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a5', 'c7000000-0000-0000-0000-0000000001a3', 'proxy', '{discuss}', now(), 'id_checked'),
 ('c7000000-0000-0000-0000-0000000005b4', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'proxy', '{discuss,book}', now(), 'known_to_team');
insert into public.customer_relationships (id, business_id, customer_id, related_customer_id, kind, permissions) values
 ('c7000000-0000-0000-0000-0000000005b2', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a3', 'emergency_contact', '{discuss}');
insert into public.customer_consents (business_id, customer_id, kind, status, given_by_customer_id) values
 ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a5', 'terms', 'granted', 'c7000000-0000-0000-0000-0000000001a5');
-- an unverified link about the dropped Pat, with a Verify form opened on it before the merge (its version kept)
insert into public.customer_relationships (id, business_id, customer_id, related_customer_id, kind, permissions) values
 ('c7000000-0000-0000-0000-0000000005c1', 'c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a5', 'c7000000-0000-0000-0000-0000000001a3', 'tenant', '{discuss}');
create temp table seen (k text primary key, t timestamptz) on commit drop;
grant all on seen to authenticated;
insert into seen select 'tenant', updated_at from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005c1';
-- the helper itself refuses people from another business, or the same person twice, and changes nothing
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$ begin
  perform pg_temp.expect('select public.zella_people_merge(''c7000000-0000-0000-0000-0000000000a1'', ''c7000000-0000-0000-0000-0000000001b1'', ''c7000000-0000-0000-0000-0000000001a5'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_people_merge(''c7000000-0000-0000-0000-0000000000a1'', ''c7000000-0000-0000-0000-0000000001a1'', ''c7000000-0000-0000-0000-0000000001b1'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_people_merge(''c7000000-0000-0000-0000-0000000000a1'', ''c7000000-0000-0000-0000-0000000001a5'', ''c7000000-0000-0000-0000-0000000001a5'')', 'NOT_VALID');
  perform pg_temp.expect('select public.zella_people_merge(''c7000000-0000-0000-0000-0000000000a1'', null, ''c7000000-0000-0000-0000-0000000001a5'')', 'NOT_VALID');
  assert (select count(*) from public.customer_relationships where customer_id = 'c7000000-0000-0000-0000-0000000001a5' and revoked_at is null) >= 4, 'refused direct calls moved nothing';
end $$;
reset role;
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000b');   -- manager merges the duplicate grandma into Quinn
do $$ declare j jsonb; begin
  j := public.zella_merge_customers('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a2', 'c7000000-0000-0000-0000-0000000001a4');
  assert not (j -> 'tables_skipped') ? 'customer_relationships' and not (j -> 'tables_skipped') ? 'customer_consents', 'merge skipped a table: ' || j::text;
  j := public.zella_merge_customers('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a1', 'c7000000-0000-0000-0000-0000000001a5');
  assert not (j -> 'tables_skipped') ? 'customer_relationships' and not (j -> 'tables_skipped') ? 'customer_consents', 'merge skipped a table: ' || j::text;
  -- the Verify form opened before the merge shows the dropped Pat: confirming it now verifies nothing
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L, %L, %L, %L, null, %L)', 'c7000000-0000-0000-0000-0000000005c1', 'id_checked',
          'c7000000-0000-0000-0000-0000000001a3', 'tenant', '{discuss}', (select t from seen where k = 'tenant')), 'CHANGED');
  assert (select verified_at is null and customer_id = 'c7000000-0000-0000-0000-0000000001a1' from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005c1'),
    'a link moved by a merge is not verified from a form opened before it';
end $$;
reset role;
do $$ declare r record; begin
  -- authority held by the dropped person moves to the kept person, unverified
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005a2';
  assert r.related_customer_id = 'c7000000-0000-0000-0000-0000000001a2' and r.verified_at is null and r.revoked_at is null, 'authority moved, needs verifying again';
  -- a duplicate of an active link is revoked
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005a3';
  assert r.revoked_at is not null and r.revoke_reason like 'merged: duplicate%', 'duplicate revoked: ' || coalesce(r.revoke_reason, 'not revoked');
  -- a link that would make Quinn her own household member is revoked
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005a4';
  assert r.revoked_at is not null and r.revoke_reason like 'merged: would link%', 'self link revoked';
  -- a link about the dropped person moves to the kept person and keeps its verification
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005a1';
  assert r.customer_id = 'c7000000-0000-0000-0000-0000000001a1' and r.verified_at is not null and r.revoked_at is null, 'subject moved, still verified';
  assert exists (select 1 from public.customer_consents where customer_id = 'c7000000-0000-0000-0000-0000000001a1' and kind = 'terms'), 'consent moved with its subject';
  -- collisions keep the stronger link, and the related person keeps exactly the authority it carried
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005b1';
  assert r.customer_id = 'c7000000-0000-0000-0000-0000000001a1' and r.verified_at is not null and r.revoked_at is null, 'the verified moving link survives a collision with an unverified one';
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005b2';
  assert r.revoked_at is not null and r.revoke_reason = 'merged: replaced by a stronger link', 'the weaker existing link is revoked: ' || coalesce(r.revoke_reason, 'not revoked');
  select * into r from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005b3';
  assert r.revoked_at is not null and r.revoke_reason like 'merged: duplicate%', 'a moving link no stronger than the existing one is the duplicate';
  assert (select revoked_at is null and verified_at is not null from public.customer_relationships where id = 'c7000000-0000-0000-0000-0000000005b4'), 'the stronger existing link stays';
  assert (select count(*) from public.customer_relationships where customer_id = 'c7000000-0000-0000-0000-0000000001a1' and related_customer_id = 'c7000000-0000-0000-0000-0000000001a3' and revoked_at is null and kind in ('emergency_contact', 'proxy')) = 2, 'one active link per kind after the merge';
  assert public.zella_is_authorized('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000001a1', null, 'c7000000-0000-0000-0000-0000000001a3', 'book'), 'Sam keeps booking through the stronger proxy link';
  assert not exists (select 1 from public.customer_relationships where revoked_at is null and (customer_id in ('c7000000-0000-0000-0000-0000000001a4', 'c7000000-0000-0000-0000-0000000001a5')
                       or related_customer_id in ('c7000000-0000-0000-0000-0000000001a4', 'c7000000-0000-0000-0000-0000000001a5'))), 'nothing active is left on the archived duplicates';
end $$;
select 'PASS customer merge: links move to the kept person (authority they held must be verified again), duplicates and self-links are revoked, a collision keeps the stronger link, a Verify form opened before the merge verifies nothing, the helper refuses people from another business, consents follow their subject, and no table is skipped';

-- ===================================================== audit
do $$ declare missing text; begin
  select string_agg(e.action || ' (' || coalesce(n, 0) || ' of ' || e.min_count || ')', ', ') into missing
    from (values ('relationship_added', 3), ('relationship_updated', 3), ('relationship_verified', 3), ('relationship_revoked', 1),
                 ('relationship_merged', 4), ('consent_recorded', 3), ('consent_revoked', 1)) e(action, min_count)
    left join (select action, count(*) n from public.audit_logs where business_id in ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000000c1')
               group by action) a on a.action = e.action
   where coalesce(n, 0) < e.min_count;
  assert missing is null, 'actions not audited often enough: ' || missing;
  assert not exists (select 1 from public.audit_logs where entity_type = 'customer_relationship' and (coalesce(new_data::text, '') || coalesce(old_data::text, '')) like '%Fridays%'),
    'note text is not copied into the audit log';
  assert not exists (select 1 from public.audit_logs where entity_type = 'customer_consent'
    and ((coalesce(new_data::text, '') || coalesce(old_data::text, '')) like '%Class photos only%' or (coalesce(new_data::text, '') || coalesce(old_data::text, '')) like '%Signed form, 6 Nov%')),
    'consent scope and evidence are not copied into the audit log';
  assert exists (select 1 from public.audit_logs where action = 'relationship_verified' and new_data ->> 'method' = 'id_checked'), 'verification audited with its method';
end $$;
select 'PASS every kind of change is audited at least as often as it happened (who, kind, permissions, method), without note, scope or evidence text';
rollback;
