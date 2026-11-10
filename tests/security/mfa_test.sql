-- Regression tests for sql/zella_mfa_enforcement.sql, on a restored baseline (tests/security/run.sh). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.act(p_user uuid, p_aal text default 'aal1') returns void language plpgsql as $$
begin
  if p_user is null then perform set_config('request.jwt.claims', '{"role":"service_role"}', false); reset role;
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, false);
    set role authenticated;
  end if;
end $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('d0000000-0000-0000-0000-000000000001', 'nomfa@biz.test', now()),
  ('d0000000-0000-0000-0000-000000000002', 'withmfa@biz.test', now()),
  ('d0000000-0000-0000-0000-000000000003', 'admin@zella.test', now());
insert into auth.mfa_factors (user_id, status) values ('d0000000-0000-0000-0000-000000000002', 'verified'), ('d0000000-0000-0000-0000-000000000003', 'verified'),
  ('d0000000-0000-0000-0000-000000000001', 'unverified');   -- a half-finished set-up doesn't count
insert into public.businesses (id, name) values ('b2000000-0000-0000-0000-000000000001', 'MFA Co');
insert into public.business_members (business_id, user_id, role, status) values
  ('b2000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 'owner', 'active'),
  ('b2000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002', 'admin', 'active');
insert into public.customers (business_id, first_name) values ('b2000000-0000-0000-0000-000000000001', 'Ana'), ('b2000000-0000-0000-0000-000000000001', 'Ben');
insert into public.platform_admins (user_id, role, is_active) values ('d0000000-0000-0000-0000-000000000003', 'zella_owner', true);

reset role;
do $$ declare n int; begin
  perform pg_temp.act('d0000000-0000-0000-0000-000000000002', 'aal1');
  select count(*) into n from public.customers;
  assert n = 0, 'enrolled user without the code read ' || n || ' customers';
  begin
    insert into public.customers (business_id, first_name) values ('b2000000-0000-0000-0000-000000000001', 'Eve');
    assert false, 'enrolled user without the code inserted a customer';
  exception when insufficient_privilege then null; end;
  perform pg_temp.act('d0000000-0000-0000-0000-000000000002', 'aal2');
  select count(*) into n from public.customers;
  assert n = 2, 'with the code: ' || n;
  raise notice 'PASS tables: enrolled user needs aal2 (reads 0 and cannot write at aal1, reads all at aal2)';
end $$;

reset role;
do $$ declare n int; begin
  perform pg_temp.act('d0000000-0000-0000-0000-000000000001', 'aal1');
  select count(*) into n from public.customers;
  assert n = 2, 'user without a verified factor (only an unfinished one) was blocked: ' || n;
  raise notice 'PASS users without two-step sign-in are not affected (unverified factor ignored)';
end $$;

reset role;
do $$ begin
  perform pg_temp.act('d0000000-0000-0000-0000-000000000003', 'aal1');
  begin perform public.zella_pre_request(); assert false, 'aal1 admin passed the request check';
  exception when insufficient_privilege then null; end;
  -- without the request check, a security-definer admin function would answer: this is what layer 1 closes
  assert public.is_platform_admin(), 'fixture: admin check';
  perform pg_temp.act('d0000000-0000-0000-0000-000000000003', 'aal2');
  perform public.zella_pre_request();
  perform pg_temp.act('d0000000-0000-0000-0000-000000000001', 'aal1');
  perform public.zella_pre_request();
  perform pg_temp.act(null);
  perform public.zella_pre_request();
  perform set_config('request.jwt.claims', '{"role":"anon"}', false); set role anon;
  perform public.zella_pre_request();
  raise notice 'PASS request check: aal1 admin refused; aal2 admin, users without a factor, service role and visitors pass';
end $$;

reset role;
do $$ declare n_tables int; n_pol int; v text; begin
  select count(*) into n_tables from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity;
  select count(*) into n_pol from pg_policies where schemaname = 'public' and policyname = 'zella_mfa_required' and permissive = 'RESTRICTIVE';
  assert n_tables = n_pol, format('restrictive policy on %s of %s tables', n_pol, n_tables);
  assert exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'zella_mfa_required');
  select array_to_string(setconfig, ',') into v from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where r.rolname = 'authenticator';
  assert v like '%pgrst.db_pre_request=public.zella_pre_request%', 'pre-request not set: ' || coalesce(v, 'none');
  raise notice 'PASS every table with row security (%) and storage.objects carry the restrictive policy; pre-request is set', n_tables;
end $$;
