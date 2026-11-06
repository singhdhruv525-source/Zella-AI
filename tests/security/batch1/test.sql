-- Batch 1 security regression (6 Nov 2026), on an ISOLATED copy of the production schema (tests/security/batch1/run.sh).
-- Synthetic people and businesses only (ids b1…); everything is rolled back. Covers:
--   1. lead creation through zella_staff_add_lead: roles, tenant isolation, duplicates, invalid data, repeats
--   2. cross-tenant reads and writes, direct (tables / views) and through functions
--   3. call content privacy through calls_view
--   4. the SECURITY DEFINER functions the anonymous role may execute: exactly the six reviewed, and what they return
--   5. record files: unverified uploads are seen only by their uploader; other businesses see nothing
--   6. zella_appointment_holds_time after sql/zella_batch1_security.sql
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('b1000000-0000-0000-0000-00000000000a', 'own-a@b1.test', now()), ('b1000000-0000-0000-0000-00000000000b', 'staff-a@b1.test', now()),
 ('b1000000-0000-0000-0000-00000000000c', 'view-a@b1.test', now()), ('b1000000-0000-0000-0000-00000000000d', 'own-b@b1.test', now()),
 ('b1000000-0000-0000-0000-00000000000e', 'staff2-a@b1.test', now()), ('b1000000-0000-0000-0000-00000000000f', 'gone-a@b1.test', now());
insert into public.profiles (id) select id from auth.users where email like '%@b1.test' on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('b1000000-0000-0000-0000-0000000000a1', 'B1 Alpha', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing' limit 1)),
 ('b1000000-0000-0000-0000-0000000000b1', 'B1 Beta', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing' limit 1)),
 ('b1000000-0000-0000-0000-0000000000c1', 'B1 Paused', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing' limit 1));
update public.businesses set suspended_at = now() where id = 'b1000000-0000-0000-0000-0000000000c1';
insert into public.business_members (business_id, user_id, role, status)
select b::uuid, u::uuid, r, s from (values
 ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-00000000000b', 'staff', 'active'),
 ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-00000000000c', 'viewer', 'active'),
 ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-00000000000e', 'staff', 'active'),
 ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-00000000000f', 'staff', 'suspended'),
 ('b1000000-0000-0000-0000-0000000000b1', 'b1000000-0000-0000-0000-00000000000d', 'owner', 'active'),
 ('b1000000-0000-0000-0000-0000000000c1', 'b1000000-0000-0000-0000-00000000000a', 'owner', 'active')) v(b, u, r, s);
insert into public.customers (id, business_id, first_name, phone) values
 ('b1000000-0000-0000-0000-0000000001a1', 'b1000000-0000-0000-0000-0000000000a1', 'Ana', '+15125550101'),
 ('b1000000-0000-0000-0000-0000000001b1', 'b1000000-0000-0000-0000-0000000000b1', 'Ben', '+15125550201');
insert into public.appointments (id, business_id, customer_id, title, start_time, end_time, status) values
 ('b1000000-0000-0000-0000-0000000002b1', 'b1000000-0000-0000-0000-0000000000b1', 'b1000000-0000-0000-0000-0000000001b1', 'Beta visit', now() + interval '2 days', now() + interval '2 days 1 hour', 'scheduled');
insert into public.calls (id, business_id, direction, status, from_number, transcript, recording_url, summary) values
 ('b1000000-0000-0000-0000-0000000003a1', 'b1000000-0000-0000-0000-0000000000a1', 'inbound', 'completed', '+15125550101', 'Alpha transcript', 'https://rec.invalid/a', 'Alpha summary'),
 ('b1000000-0000-0000-0000-0000000003b1', 'b1000000-0000-0000-0000-0000000000b1', 'inbound', 'completed', '+15125550201', 'Beta transcript', 'https://rec.invalid/b', 'Beta summary');
insert into public.crm_record_types (business_id, key, singular, plural, statuses) values
 ('b1000000-0000-0000-0000-0000000000a1', 'b1jobs', 'Job', 'Jobs', '[{"key":"open","label":"Open"}]'),
 ('b1000000-0000-0000-0000-0000000000b1', 'b1jobs', 'Job', 'Jobs', '[{"key":"open","label":"Open"}]')
 on conflict do nothing;
insert into public.crm_records (id, business_id, type_key, title, status) values
 ('b1000000-0000-0000-0000-0000000004a1', 'b1000000-0000-0000-0000-0000000000a1', 'b1jobs', 'Alpha job', 'open'),
 ('b1000000-0000-0000-0000-0000000004b1', 'b1000000-0000-0000-0000-0000000000b1', 'b1jobs', 'Beta job', 'open');
-- the calls module on for both (calls_view only shows businesses with it on)
insert into public.business_modules (business_id, module_id, enabled)
select b.id, im.id, true from public.businesses b join public.industry_modules im on im.industry_id = b.industry_id and im.slug = 'calls'
 where b.id in ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-0000000000b1') on conflict do nothing;
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, true) $$;
create or replace function pg_temp.put(p text, mime text, sz int) returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner, metadata) values ('record-files', p, auth.uid(), jsonb_build_object('mimetype', mime, 'size', sz)) $$;
create temp table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated, anon;

-- ===================================================================== 1. leads
set local role authenticated;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000a');
do $$ declare r jsonb; begin
  r := public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Olive', 'Owner', '+15125550111', null, 'manual', 'from owner');
  assert r ->> 'result' = 'created', 'owner creates: ' || r::text;
  assert (select lead_stage = 'new' and contact_deadline_at is not null from public.customers where id = (r ->> 'customer_id')::uuid), 'owner lead has stage and deadline';
end $$;
select 'PASS lead: an owner creates a lead through the pipeline (stage and contact deadline set)';

select pg_temp.as_user('b1000000-0000-0000-0000-00000000000b');
do $$ declare r jsonb; n int; begin
  r := public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Sam', 'Staff', '+15125550122', 'sam@b1.test');
  assert r ->> 'result' = 'created', 'staff creates: ' || r::text;
  insert into ids values ('sam', r ->> 'customer_id');
  -- the same submission again (a double click, a retry after a slow answer) matches; it doesn't make a second person
  r := public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Sam', 'Staff', '+15125550122', 'sam@b1.test');
  assert r ->> 'result' = 'matched' and r ->> 'customer_id' = (select v from ids where k = 'sam'), 'repeat matched: ' || r::text;
  select count(*) into n from public.customers where business_id = 'b1000000-0000-0000-0000-0000000000a1' and phone = '+15125550122';
  assert n = 1, 'one person after a repeated submission, got ' || n;
end $$;
select 'PASS lead: staff create a lead; repeating the same submission matches the same person (no duplicate)';

do $$ begin
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'No', 'Contact', null, null); raise exception 'no contact accepted';
  exception when others then if sqlerrm not like '%NO_CONTACT%' then raise; end if; end;
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Bad', 'Mail', null, 'not-an-email'); raise exception 'bad email accepted';
  exception when others then if sqlerrm not like '%BAD_EMAIL%' then raise; end if; end;
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', null, ' ', '+15125550133'); raise exception 'no name accepted';
  exception when others then if sqlerrm not like '%NAME_REQUIRED%' then raise; end if; end;
end $$;
select 'PASS lead: missing contact, a malformed email and a missing name are refused';

-- staff of Alpha can't add to Beta; the viewer can't add; a suspended member can't add; a paused business takes none
do $$ begin
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000b1', 'Cross', 'Tenant', '+15125550144'); raise exception 'cross-tenant lead accepted';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000c');
do $$ begin
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Vee', 'Viewer', '+15125550155'); raise exception 'viewer lead accepted';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  -- nor directly into the table
  begin insert into public.customers (business_id, first_name, phone) values ('b1000000-0000-0000-0000-0000000000a1', 'Vee', '+15125550155'); raise exception 'viewer direct insert accepted';
  exception when insufficient_privilege then null; when others then if sqlerrm not like '%row-level security%' then raise; end if; end;
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000f');
do $$ begin
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Ex', 'Member', '+15125550166'); raise exception 'suspended member lead accepted';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000a');
do $$ begin
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000c1', 'Paused', 'Biz', '+15125550177'); raise exception 'paused business lead accepted';
  exception when others then if sqlerrm not like '%BUSINESS_NOT_AVAILABLE%' then raise; end if; end;
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ begin
  begin perform public.zella_staff_add_lead('b1000000-0000-0000-0000-0000000000a1', 'Anon', 'Y', '+15125550188'); raise exception 'anon lead accepted';
  exception when insufficient_privilege then null; end;
  begin perform public.zella_capture_lead('b1000000-0000-0000-0000-0000000000a1', 'Anon', 'Y', '+15125550188'); raise exception 'anon reached the pipeline directly';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS lead: another business''s member, a viewer (RPC and direct insert), a suspended member, a paused business and the anonymous role are all refused';

-- ===================================================================== 2. cross-tenant
set local role authenticated;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000a');
do $$ declare n int; begin
  select count(*) into n from public.customers where business_id = 'b1000000-0000-0000-0000-0000000000b1'; assert n = 0, 'customers of B visible: ' || n;
  select count(*) into n from public.appointments where business_id = 'b1000000-0000-0000-0000-0000000000b1'; assert n = 0, 'appointments of B visible';
  select count(*) into n from public.crm_records where business_id = 'b1000000-0000-0000-0000-0000000000b1'; assert n = 0, 'records of B visible';
  select count(*) into n from public.calls_view where business_id = 'b1000000-0000-0000-0000-0000000000b1'; assert n = 0, 'calls of B visible';
  select count(*) into n from public.businesses where id = 'b1000000-0000-0000-0000-0000000000b1'; assert n = 0, 'business B visible';
  select count(*) into n from public.customers where business_id = 'b1000000-0000-0000-0000-0000000000a1'; assert n >= 1, 'own customers visible';
  -- writes into B: refused or no rows touched
  -- (either refused outright, or row security leaves nothing to change; checked as the database owner below)
  begin update public.customers set first_name = 'hacked' where id = 'b1000000-0000-0000-0000-0000000001b1'; exception when insufficient_privilege then null; end;
  begin update public.appointments set title = 'hacked' where id = 'b1000000-0000-0000-0000-0000000002b1'; exception when insufficient_privilege then null; end;
  begin update public.crm_records set title = 'hacked' where id = 'b1000000-0000-0000-0000-0000000004b1'; exception when insufficient_privilege then null; end;
  begin update public.businesses set name = 'hacked' where id = 'b1000000-0000-0000-0000-0000000000b1'; exception when insufficient_privilege then null; end;
  begin delete from public.customers where id = 'b1000000-0000-0000-0000-0000000001b1'; exception when insufficient_privilege then null; end;
  begin delete from public.calls where id = 'b1000000-0000-0000-0000-0000000003b1'; exception when insufficient_privilege then null; end;
  begin insert into public.customers (business_id, first_name, phone) values ('b1000000-0000-0000-0000-0000000000b1', 'Planted', '+15125550199'); raise exception 'insert into B accepted';
  exception when others then if sqlerrm not like '%row-level security%' then raise; end if; end;
  begin insert into public.appointments (business_id, title, start_time, end_time) values ('b1000000-0000-0000-0000-0000000000b1', 'Planted', now() + interval '3 days', now() + interval '3 days 1 hour'); raise exception 'appointment into B accepted';
  exception when others then if sqlerrm not like '%row-level security%' and sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
-- through functions: B's settings, profile and navigation
do $$ begin
  begin perform public.zella_business_settings('b1000000-0000-0000-0000-0000000000b1'); raise exception 'settings of B readable';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' and sqlerrm not like '%not a member%' and sqlerrm not like '%NOT_A_MEMBER%' then raise; end if; end;
  begin perform public.zella_save_business_profile('b1000000-0000-0000-0000-0000000000b1', '{"name":"hacked"}'); raise exception 'profile of B writable';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' and sqlerrm not like '%NOT_A_MEMBER%' then raise; end if; end;
  begin perform public.zella_begin_record_file('b1000000-0000-0000-0000-0000000004b1', 'x.jpg', 'image/jpeg', 100); raise exception 'file on B record accepted';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
reset role;
do $$ begin
  assert (select first_name from public.customers where id = 'b1000000-0000-0000-0000-0000000001b1') = 'Ben', 'B customer changed';
  assert (select title from public.appointments where id = 'b1000000-0000-0000-0000-0000000002b1') = 'Beta visit', 'B appointment changed';
  assert (select title from public.crm_records where id = 'b1000000-0000-0000-0000-0000000004b1') = 'Beta job', 'B record changed';
  assert (select name from public.businesses where id = 'b1000000-0000-0000-0000-0000000000b1') = 'B1 Beta', 'B business changed';
  assert exists (select 1 from public.calls where id = 'b1000000-0000-0000-0000-0000000003b1'), 'B call deleted';
end $$;
select 'PASS isolation: Alpha''s owner reads none of Beta''s customers, appointments, records, calls or business, and can''t write them directly or through settings, profile or file functions';

-- platform tables: a business owner reads none of them
set local role authenticated;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000a');
do $$ begin
  begin perform 1 from public.platform_admins limit 1; raise exception 'platform_admins readable'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.platform_settings limit 1; raise exception 'platform_settings readable'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.platform_role_permissions limit 1; raise exception 'role permissions readable'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.integration_secrets limit 1; raise exception 'integration secrets readable'; exception when insufficient_privilege then null; end;
  assert public.zella_admin_role() is null, 'a business owner has no platform role';
  assert (select count(*) from public.audit_logs where business_id = 'b1000000-0000-0000-0000-0000000000b1') = 0, 'B audit visible';
end $$;
reset role;
select 'PASS isolation: platform admin, settings, role-permission and integration-secret tables are closed to business users; no platform role';

-- ===================================================================== 3. call content
set local role authenticated;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000a');
do $$ declare t text; r text; begin
  select transcript, recording_url into t, r from public.calls_view where id = 'b1000000-0000-0000-0000-0000000003a1';
  if t is null and not exists (select 1 from public.calls_view where id = 'b1000000-0000-0000-0000-0000000003a1') then
    raise exception 'owner sees no call (calls module off?)';
  end if;
  assert t = 'Alpha transcript' and r = 'https://rec.invalid/a', 'owner sees content';
  begin perform transcript from public.calls limit 1; raise exception 'calls.transcript readable directly'; exception when insufficient_privilege then null; end;
  begin perform recording_url from public.calls limit 1; raise exception 'calls.recording_url readable directly'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000b');
do $$ declare t text; r text; s text; begin
  select transcript, recording_url, summary into t, r, s from public.calls_view where id = 'b1000000-0000-0000-0000-0000000003a1';
  assert s = 'Alpha summary', 'staff see the call';
  assert t is null and r is null, 'staff see no transcript or recording by default';
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ begin
  begin perform 1 from public.calls_view limit 1; raise exception 'anon reads calls_view'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.customers limit 1; raise exception 'anon reads customers'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS calls: owners see transcript and recording, staff see the call without them, nobody reads them from calls directly, anon reads nothing';

-- ===================================================================== 4. anonymous SECURITY DEFINER functions
do $$ declare got text; begin
  select string_agg(p.proname, ',' order by p.proname) into got from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef and has_function_privilege('anon', p.oid, 'execute');
  assert got = 'zella_mfa_satisfied,zella_platform_public_info,zella_pre_request,zella_public_status,zella_unsubscribe_email,zella_unsubscribe_lookup',
    'anon-executable SECURITY DEFINER functions changed: ' || coalesce(got, '(none)');
end $$;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ declare j jsonb; k text; begin
  assert public.zella_mfa_satisfied(), 'anon passes the MFA gate (row security still applies)';
  perform public.zella_pre_request();
  assert public.zella_unsubscribe_lookup('nope') = '{"ok": false}'::jsonb, 'bad token';
  assert public.zella_unsubscribe_lookup(repeat('0', 32)) = '{"ok": false}'::jsonb, 'unknown token';
  assert public.zella_unsubscribe_email(repeat('0', 32)) = '{"ok": false}'::jsonb, 'unknown token, nothing recorded';
  j := public.zella_platform_public_info();
  for k in select jsonb_object_keys(j) loop
    assert k in ('display_name', 'support_email', 'support_phone', 'website', 'logo_url', 'login_headline', 'maintenance'), 'public info leaks ' || k;
  end loop;
  j := public.zella_public_status();
  assert (select array_agg(x order by x) from jsonb_object_keys(j) x) = array['components', 'generated_at', 'incidents', 'overall'], 'status keys: ' || j::text;
  assert j::text not like '%B1 Alpha%' and j::text not like '%b1000000%', 'status names no business';
end $$;
reset role;
select 'PASS public endpoints: exactly the six reviewed functions run for anon; unsubscribe needs a real token; public info and status return only platform-level fields';

-- ===================================================================== 5. record files
set local role authenticated;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000b');
do $$ declare f jsonb; begin
  f := public.zella_begin_record_file('b1000000-0000-0000-0000-0000000004a1', 'waiting.jpg', 'image/jpeg', 2000);
  insert into ids values ('wait_id', f ->> 'id'), ('wait_path', f ->> 'path');
  perform pg_temp.put(f ->> 'path', 'image/jpeg', 2000);
  f := public.zella_finish_record_file((f ->> 'id')::uuid);       -- arrived; the content check never answered
  assert f ->> 'status' = 'checking', 'checking: ' || f::text;
  f := public.zella_finish_record_file((select v from ids where k = 'wait_id')::uuid);   -- "Check again" is safe to repeat
  assert f ->> 'status' = 'checking', 'repeat finish: ' || f::text;
  assert (select count(*) from public.crm_record_files where id = (select v from ids where k = 'wait_id')::uuid) = 1, 'uploader sees the waiting file';
  assert public.zella_record_file_storage_ok((select v from ids where k = 'wait_path'), 'select'), 'uploader may read their own upload';
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000e');   -- a teammate
do $$ begin
  assert (select count(*) from public.crm_record_files where id = (select v from ids where k = 'wait_id')::uuid) = 0, 'teammate sees an unchecked file';
  assert not public.zella_record_file_storage_ok((select v from ids where k = 'wait_path'), 'select'), 'teammate gets a link to an unchecked file';
  begin perform public.zella_finish_record_file((select v from ids where k = 'wait_id')::uuid); raise exception 'teammate finished someone else''s upload';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000d');   -- another business
do $$ begin
  assert (select count(*) from public.crm_record_files where business_id = 'b1000000-0000-0000-0000-0000000000a1') = 0, 'other business sees files';
  assert not public.zella_record_file_storage_ok((select v from ids where k = 'wait_path'), 'select'), 'other business gets a link';
  begin perform public.zella_remove_record_file((select v from ids where k = 'wait_id')::uuid); raise exception 'other business removed a file';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000b');   -- the uploader discards it
do $$ declare r jsonb; begin
  r := public.zella_remove_record_file((select v from ids where k = 'wait_id')::uuid);
  assert r ->> 'status' = 'removed', 'discarded: ' || r::text;
  assert public.zella_record_file_storage_ok((select v from ids where k = 'wait_path'), 'delete'), 'uploader may delete the stored copy of a discarded upload';
end $$;
reset role;
-- an upload that never arrived: the reservation can be let go by its uploader (what the app does after a failed upload)
set local role authenticated;
select pg_temp.as_user('b1000000-0000-0000-0000-00000000000b');
do $$ declare f jsonb; begin
  f := public.zella_begin_record_file('b1000000-0000-0000-0000-0000000004a1', 'never.jpg', 'image/jpeg', 2000);
  begin perform public.zella_finish_record_file((f ->> 'id')::uuid); raise exception 'finished without an upload';
  exception when others then if sqlerrm not like '%UPLOAD_MISSING%' then raise; end if; end;
  assert public.zella_remove_record_file((f ->> 'id')::uuid) ->> 'status' = 'removed', 'reservation let go';
end $$;
reset role;
-- abandoned uploads are cleaned up by the server after a day
do $$ declare j jsonb; begin
  update public.crm_record_files set created_at = now() - interval '2 days' where record_id = 'b1000000-0000-0000-0000-0000000004a1' and status <> 'removed';
  insert into public.crm_record_files (business_id, record_id, path, file_name, mime_type, size_bytes, kind, uploaded_by, status, created_at)
  values ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-0000000004a1', 'b1000000-0000-0000-0000-0000000000a1/x/abandoned.jpg', 'a.jpg', 'image/jpeg', 10, 'photo',
          'b1000000-0000-0000-0000-00000000000b', 'checking', now() - interval '2 days');
  j := public.zella_record_file_cleanup(50);
  assert (select status from public.crm_record_files where path = 'b1000000-0000-0000-0000-0000000000a1/x/abandoned.jpg') = 'removed', 'abandoned check let go';
end $$;
select 'PASS files: an unchecked upload is seen and re-checkable only by its uploader; teammates and other businesses get neither the row nor a link; the uploader can discard it; abandoned uploads are let go after a day';

-- ===================================================================== 6. holds_time
do $$ declare p record; begin
  select provolatile, proconfig into p from pg_proc where oid = 'public.zella_appointment_holds_time(text, text, timestamptz)'::regprocedure;
  assert p.provolatile = 's', 'stable, got ' || p.provolatile;
  assert p.proconfig = array['search_path=""'], 'fixed search path, got ' || coalesce(p.proconfig::text, 'none');
  assert public.zella_appointment_holds_time('scheduled', null, null), 'scheduled holds';
  assert public.zella_appointment_holds_time('confirmed', 'tentative', now() + interval '1 hour'), 'live hold holds';
  assert not public.zella_appointment_holds_time('confirmed', 'tentative', now() - interval '1 minute'), 'expired hold frees';
  assert not public.zella_appointment_holds_time('scheduled', 'requested', null), 'request frees';
  assert not public.zella_appointment_holds_time('cancelled', null, null), 'cancelled frees';
end $$;
set search_path = pg_temp, public;   -- a hostile search path changes nothing
do $$ begin assert public.zella_appointment_holds_time('scheduled', null, null); end $$;
reset search_path;
select 'PASS holds_time: stable with a fixed search path; same answers for scheduled, holds, expired holds, requests and cancellations';
rollback;
