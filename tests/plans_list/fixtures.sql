-- Test data only (never production). 30 test businesses (two pages of 25): p01 to p20 have plans, p01 with three
-- versions (Base, then Pro, then Pro yearly), p02 with two; p21 to p30 have none. Subscriptions as the plan step
-- writes them (no plan_id, which is why the old page said "Unknown plan").
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
select ('b1000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'Test Plans ' || lpad(n::text, 2, '0'),
       (select id from public.industries where slug = 'dental'), 'active'
  from generate_series(1, 30) n;
insert into public.business_members (business_id, user_id, role, status)
  values ('b1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-0000000000c4', 'owner', 'active') on conflict do nothing;
insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, setup_fee_cents, minutes, texts, emails,
  team_seats, phone_numbers, locations, languages, trial_enabled, idempotency_key, values_hash, effective_from)
select ('b1000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, v,
       case when v = 1 then 'base' else 'pro' end, case when v = 3 then 'yearly' else 'monthly' end,
       9900 + v * 10000, 0, 300 * v, 200, 200, 2 + v, 1, 1, array['en'], v = 1, 'test-' || n || '-' || v, md5(n || '-' || v),
       now() - (4 - v) * interval '10 days'
  from generate_series(1, 20) n, generate_series(1, 3) v
 where v = 1 or (n = 1) or (n = 2 and v = 2);
insert into public.subscriptions (business_id, status, billing_interval)
select ('b1000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, case when n = 1 then 'active' else 'trial' end, 'monthly'
  from generate_series(1, 20) n;
