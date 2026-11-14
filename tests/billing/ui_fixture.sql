-- Synthetic people and businesses for the billing pages in a browser (tests/billing/ui-journey.cjs). Isolated test
-- database only; test values, not Zella Voice prices. Every test password is the local backend's test password.
\set ON_ERROR_STOP 1
insert into auth.users (id, email, email_confirmed_at) values
  ('b2300000-0000-4000-8000-000000000009', 'admin@zella.test', now()), ('b2300000-0000-4000-8000-000000000008', 'support@zella.test', now()),
  ('b2300000-0000-4000-8000-000000000001', 'owner@glow.test', now()), ('b2300000-0000-4000-8000-000000000002', 'staff@glow.test', now()),
  ('b2300000-0000-4000-8000-000000000007', 'ops@zella.test', now())
on conflict do nothing;
insert into auth.identities (user_id, provider, email, identity_data) values
  ('b2300000-0000-4000-8000-000000000009', 'email', 'admin@zella.test', '{"email": "admin@zella.test", "email_verified": true}'),
  ('b2300000-0000-4000-8000-000000000008', 'email', 'support@zella.test', '{"email": "support@zella.test", "email_verified": true}'),
  ('b2300000-0000-4000-8000-000000000007', 'email', 'ops@zella.test', '{"email": "ops@zella.test", "email_verified": true}');
insert into platform_admins (user_id, role, is_active) values ('b2300000-0000-4000-8000-000000000009', 'zella_owner', true),
  ('b2300000-0000-4000-8000-000000000008', 'support_admin', true);
insert into platform_admins (user_id, role, is_active) values ('b2300000-0000-4000-8000-000000000007', 'platform_operations', true);
-- platform operations: may set up businesses, has no billing permission (test permission matrix)
delete from platform_role_permissions where role in ('support_admin', 'platform_operations');
insert into platform_role_permissions (role, permission) values ('platform_operations', 'businesses.manage'), ('platform_operations', 'businesses.view');
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'b2000000-0000-4000-8000-00000000000a', 'Glow Dental', i.id, 'America/New_York', true, 'active' from industries i where i.slug = 'dental';
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'b2000000-0000-4000-8000-00000000000b', 'Draft Clinic', i.id, 'America/New_York', false, 'started' from industries i where i.slug = 'dental';
insert into business_members (business_id, user_id, role, status) values
  ('b2000000-0000-4000-8000-00000000000a', 'b2300000-0000-4000-8000-000000000001', 'owner', 'active'),
  ('b2000000-0000-4000-8000-00000000000a', 'b2300000-0000-4000-8000-000000000002', 'staff', 'active');
insert into platform_settings (key, value) values ('billing_rules', '{"unit_costs": {"sms_part": 1, "email": 0.1, "phone_number_month": 115, "texting_registration_month": 400}}')
  on conflict (key) do update set value = excluded.value;
insert into voice_pricing (provider, unit_cost, effective_from) values ('vapi', 0.10, now() - interval '1 day') on conflict do nothing;
-- Glow Dental: a saved plan (as the billing admin), a current month, some usage and one granted pack
select set_config('request.jwt.claims', json_build_object('sub', 'b2300000-0000-4000-8000-000000000009', 'role', 'authenticated')::text, false);
select public.zella_admin_plan_save('b2000000-0000-4000-8000-00000000000a',
  '{"tier": "pro", "billing_interval": "monthly", "price_cents": 29900, "setup_fee_cents": 59900, "minutes": 500, "texts": 1000, "emails": 10000,
    "team_seats": 3, "phone_numbers": 1, "locations": 1, "languages": ["en", "es"], "trial_enabled": false}', '{}', 'ui-fixture-plan-a1');
select set_config('request.jwt.claims', '', false);
insert into subscriptions (business_id, plan_id, status, billing_interval, current_period_start, current_period_end)
values ('b2000000-0000-4000-8000-00000000000a', null, 'active', 'monthly', date_trunc('day', now()) - interval '10 days', date_trunc('day', now()) - interval '10 days' + interval '1 month');
select public.zella_usage_consume('b2000000-0000-4000-8000-00000000000a', 'minutes', 420, 'ui-fixture-minutes', 'admin', null);
select public.zella_usage_consume('b2000000-0000-4000-8000-00000000000a', 'texts', 300, 'ui-fixture-texts', 'admin', null, 'routine');
select set_config('request.jwt.claims', json_build_object('sub', 'b2300000-0000-4000-8000-000000000009', 'role', 'authenticated')::text, false);
select public.zella_admin_pack_grant('b2000000-0000-4000-8000-00000000000a', 'minutes_100', 'Test grant for the browser check', 'ui-fixture-pack-1');
select set_config('request.jwt.claims', '', false);
