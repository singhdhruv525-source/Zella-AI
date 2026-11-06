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
 ('c7000000-0000-0000-0000-0000000001c1', 'c7000000-0000-0000-0000-0000000000c1', 'Cara', 'Client', '+15125550305'),
 ('c7000000-0000-0000-0000-0000000001c2', 'c7000000-0000-0000-0000-0000000000c1', 'Dan', 'Partner', '+15125550306');
insert into public.crm_record_types (business_id, key, singular, plural, statuses) values
 ('c7000000-0000-0000-0000-0000000000a1', 'r1children', 'Child', 'Children', '[{"key":"active","label":"Active"}]') on conflict do nothing;
insert into public.crm_records (id, business_id, type_key, title, status, customer_id) values
 ('c7000000-0000-0000-0000-0000000004a1', 'c7000000-0000-0000-0000-0000000000a1', 'r1children', 'Mia', 'active', 'c7000000-0000-0000-0000-0000000001a1');
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, true) $$;
create or replace function pg_temp.expect(p_sql text, p_code text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'expected % but it worked: %', p_code, p_sql;
exception when others then if position(p_code in sqlerrm) = 0 and sqlstate <> p_code then raise; end if; end $$;
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
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L)', v, 'id_checked'), 'NOT_ALLOWED');
end $$;
select 'PASS a new link grants nothing until verified; staff cannot verify in a sensitive industry';

select pg_temp.as_user('c7000000-0000-0000-0000-00000000000b');   -- manager
do $$ declare v uuid := (select v from ids where k = 'grandma'); begin
  perform pg_temp.expect(format('select public.zella_relationship_verify(%L, %L)', v, 'telepathy'), 'BAD_METHOD');
  perform public.zella_relationship_verify(v, 'id_checked');
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
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup'], null, null);
  assert (select verified_at is not null from public.customer_relationships where id = v), 'narrowing keeps the verification';
  perform public.zella_relationship_save('c7000000-0000-0000-0000-0000000000a1', v, null, 'c7000000-0000-0000-0000-0000000004a1',
          'c7000000-0000-0000-0000-0000000001a2', 'guardian', array['pickup', 'approve'], null, null);
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
select 'PASS edits: narrowing keeps verification, widening clears it; duplicates, past end dates, the same person, unknown kinds and permissions, and people from another business are refused';

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
select 'PASS viewers read but cannot change anything (functions or direct insert); another business sees and changes nothing; a paused business takes no changes; anon gets nothing';

-- ===================================================== non-sensitive industry: staff verify; the server answers
set local role authenticated;
select pg_temp.as_user('c7000000-0000-0000-0000-00000000000f');   -- salon staff
do $$ declare v uuid; begin
  v := public.zella_relationship_save('c7000000-0000-0000-0000-0000000000c1', null, 'c7000000-0000-0000-0000-0000000001c1', null,
       'c7000000-0000-0000-0000-0000000001c2', 'household', array['book'], null, null);
  perform public.zella_relationship_verify(v, 'known_to_team');
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

-- ===================================================== audit
do $$ declare n int; begin
  select count(*) into n from public.audit_logs where entity_type in ('customer_relationship', 'customer_consent')
    and business_id in ('c7000000-0000-0000-0000-0000000000a1', 'c7000000-0000-0000-0000-0000000000c1');
  assert n >= 12, 'audit rows: ' || n;
  assert not exists (select 1 from public.audit_logs where entity_type = 'customer_relationship' and (coalesce(new_data::text, '') || coalesce(old_data::text, '')) like '%Fridays%'),
    'note text is not copied into the audit log';
  assert exists (select 1 from public.audit_logs where action = 'relationship_verified' and new_data ->> 'method' = 'id_checked'), 'verification audited with its method';
end $$;
select 'PASS every change is audited (who, what kind, which permissions, how verified), without the note text';
rollback;
