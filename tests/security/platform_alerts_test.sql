-- platform_alerts: platform admins can read them (the bell), other signed-in users can't, platform_admins stays private.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
  ('f0000000-0000-0000-0000-000000000001', 'boss@zella.test', now()), ('f0000000-0000-0000-0000-000000000002', 'someone@shop.test', now());
insert into public.platform_admins (user_id, role) values ('f0000000-0000-0000-0000-000000000001', 'zella_owner');
insert into public.platform_alerts (kind, title) values ('test', 'Something to look at');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert (select count(*) from public.platform_alerts where kind = 'test') = 1, 'admin reads alerts'; end $$;
do $$ begin perform 1 from public.platform_admins; raise exception 'platform_admins should stay private';
exception when insufficient_privilege then null; end $$;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000002","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert (select count(*) from public.platform_alerts) = 0, 'non-admin sees none'; end $$;
select 'PASS platform alerts readable by platform admins only; platform_admins not exposed';
rollback;
