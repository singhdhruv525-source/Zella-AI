-- View-only members: can read, can't change business data through functions; staff still can (zella_viewer_read_only.sql).
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
  ('d0000000-0000-0000-0000-00000000000a', 'v@t.test', now()), ('d0000000-0000-0000-0000-00000000000b', 's@t.test', now());
insert into public.profiles (id) values ('d0000000-0000-0000-0000-00000000000a'), ('d0000000-0000-0000-0000-00000000000b') on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values ('d0000000-0000-0000-0000-0000000000b1', 'Viewer Test Co', 'UTC', true, 'active');
insert into public.business_members (business_id, user_id, role, status) values
  ('d0000000-0000-0000-0000-0000000000b1', 'd0000000-0000-0000-0000-00000000000a', 'viewer', 'active'),
  ('d0000000-0000-0000-0000-0000000000b1', 'd0000000-0000-0000-0000-00000000000b', 'staff', 'active');
insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, fields)
  values ('d0000000-0000-0000-0000-0000000000b1', 'jobs', 'Job', 'Jobs', '[{"key":"new","label":"New"},{"key":"done","label":"Done"}]', '{done}', '[]');
insert into public.crm_records (id, business_id, type_key, title, status) values ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b1', 'jobs', 'A job', 'new');
insert into public.customers (id, business_id, first_name) values ('d0000000-0000-0000-0000-0000000000c2', 'd0000000-0000-0000-0000-0000000000b1', 'Pat');

set local role authenticated;
-- the viewer
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ declare n int := 0;
begin
  begin perform public.zella_set_record_status('d0000000-0000-0000-0000-0000000000c1', 'done'); exception when others then n := n + 1; end;
  begin perform public.zella_add_record_note('d0000000-0000-0000-0000-0000000000c1', 'hi'); exception when others then n := n + 1; end;
  begin perform public.zella_save_record('d0000000-0000-0000-0000-0000000000b1', 'jobs', null, 'Viewer job', 'new', null, null, null, '{}'); exception when others then n := n + 1; end;
  begin perform public.zella_set_lead_stage('d0000000-0000-0000-0000-0000000000c2', 'contacted', null, null); exception when others then n := n + 1; end;
  assert n = 4, format('viewer was refused %s of 4 changes', n);
  assert (select count(*) from public.crm_records where business_id = 'd0000000-0000-0000-0000-0000000000b1') = 1, 'viewer can still read records';
end $$;
-- staff can still do their work
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  perform public.zella_set_record_status('d0000000-0000-0000-0000-0000000000c1', 'done');
  perform public.zella_add_record_note('d0000000-0000-0000-0000-0000000000c1', 'done by staff');
  assert (select status from public.crm_records where id = 'd0000000-0000-0000-0000-0000000000c1') = 'done', 'staff changed the status';
end $$;
select 'PASS view-only members are refused record, note and lead changes; staff still can';
rollback;
