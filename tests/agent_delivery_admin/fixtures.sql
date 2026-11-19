-- Test data only (never production). f1: 1,500 deliveries in the last 7 days (more than one 1,000 row page) plus 300
-- older ones, two published versions; f2: no deliveries at all; f3: only an unknown number delivery.
insert into auth.users (id, email, email_confirmed_at) values
  ('a0000000-0000-0000-0000-0000000000c1', 'admin@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c2', 'readonly@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c4', 'owner@glow.test', now())
on conflict do nothing;
insert into public.platform_admins (user_id, role) values
  ('a0000000-0000-0000-0000-0000000000c1', 'zella_owner'), ('a0000000-0000-0000-0000-0000000000c2', 'read_only_admin')
on conflict do nothing;
insert into auth.mfa_factors (id, user_id, factor_type, status)
  select gen_random_uuid(), id, 'totp', 'verified' from auth.users where email like '%@zella.test'
  and not exists (select 1 from auth.mfa_factors f where f.user_id = auth.users.id);
insert into public.businesses (id, name, industry_id, onboarding_status)
select ('f1000000-0000-0000-0000-00000000000' || n)::uuid, 'Test Deliveries ' || n, (select id from public.industries where slug = 'dental'), 'active'
  from generate_series(1, 3) n;
insert into public.business_members (business_id, user_id, role, status)
  values ('f1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-0000000000c4', 'owner', 'active') on conflict do nothing;
delete from public.ai_agents where business_id::text like 'f1000000%';
insert into public.ai_agents (id, business_id, name, agent_type, status, is_default)
select ('f9000000-0000-0000-0000-00000000000' || n)::uuid, ('f1000000-0000-0000-0000-00000000000' || n)::uuid, 'Receptionist', 'receptionist', 'active', true
  from generate_series(1, 3) n;
insert into public.agent_config_versions (id, business_id, agent_id, version, config, status, sync_status, sync_error, published_at) values
  ('f8000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f9000000-0000-0000-0000-000000000001', 1, '{}', 'superseded', 'live', null, now() - interval '20 days'),
  ('f8000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001', 'f9000000-0000-0000-0000-000000000001', 2, '{}', 'published', 'failed', 'Test sync error', now() - interval '2 days');
-- problems are plain text lines, as zella_assistant_for_call stores them
-- last 7 days: 1,000 served (version 1), 400 not_ready, 60 unknown_number, 40 forwarded_usage; the newest is a not_ready
insert into public.assistant_deliveries (business_id, version_id, provider_call_id, outcome, problems, created_at)
select 'f1000000-0000-0000-0000-000000000001',
       case when n <= 1000 then 'f8000000-0000-0000-0000-000000000001'::uuid end,
       'test-call-' || lpad(n::text, 6, '0'),
       case when n <= 1000 then 'served' when n <= 1400 then 'not_ready' when n <= 1460 then 'unknown_number' else 'forwarded_usage' end,
       case when n > 1000 and n <= 1400 then jsonb_build_array('Test problem: opening hours missing', 'Test call ' || n) else '[]'::jsonb end,
       now() - interval '6 days' + (case when n between 1001 and 1400 then n + 500 else n end) * interval '1 minute'
  from generate_series(1, 1500) n;
insert into public.assistant_deliveries (business_id, outcome, created_at)
select 'f1000000-0000-0000-0000-000000000001', 'not_ready', now() - interval '20 days' from generate_series(1, 300);
insert into public.assistant_deliveries (business_id, outcome, created_at) values ('f1000000-0000-0000-0000-000000000003', 'unknown_number', now() - interval '1 hour');
