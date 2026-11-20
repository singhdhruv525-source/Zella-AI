-- Test data only (never production). Two test admins and 1,203 test businesses in Dental, so a module count has to read
-- past the 1,000 row page size. Used by tests/industry_modules/run.sh and the local browser check.
insert into auth.users (id, email, email_confirmed_at) values
  ('a0000000-0000-0000-0000-0000000000c1', 'admin@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c2', 'readonly@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c3', 'support@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c4', 'owner@glow.test', now())
on conflict do nothing;
insert into public.platform_admins (user_id, role) values
  ('a0000000-0000-0000-0000-0000000000c1', 'zella_owner'),
  ('a0000000-0000-0000-0000-0000000000c2', 'read_only_admin'),
  ('a0000000-0000-0000-0000-0000000000c3', 'support_admin')
on conflict do nothing;
insert into auth.mfa_factors (id, user_id, factor_type, status)
  select gen_random_uuid(), id, 'totp', 'verified' from auth.users where email like '%@zella.test'
  and not exists (select 1 from auth.mfa_factors f where f.user_id = auth.users.id);

-- 1,203 Dental businesses; a second industry's business that still has a Dental module row (a module of another
-- industry never counts, zella_module_on); the Glow test business owned by owner@glow.test.
insert into public.businesses (id, name, industry_id, onboarding_status)
  select ('d1000000-0000-0000-0000-' || lpad(to_hex(n), 12, '0'))::uuid, 'Test Dental ' || n,
         (select id from public.industries where slug = 'dental'), 'active'
    from generate_series(1, 1203) n;
insert into public.businesses (id, name, industry_id, onboarding_status) values
  ('d2000000-0000-0000-0000-000000000001', 'Test Moved Plumbing', (select id from public.industries where slug = 'plumbing'), 'active'),
  ('d3000000-0000-0000-0000-000000000001', 'Test Glow Salon', (select id from public.industries where slug = 'beauty-salon'), 'active');
insert into public.business_members (business_id, user_id, role, status)
  values ('d3000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-0000000000c4', 'owner', 'active') on conflict do nothing;

-- Module switches: Calendar on for 1,101 Dental businesses (and off for the rest), AI follow up on for 2, Automations
-- on for none, plus a Calendar row for the Plumbing business (another industry: never counted).
delete from public.business_modules where business_id::text like 'd%';
insert into public.business_modules (business_id, module_id, enabled)
  select b.id, m.id, (right(b.id::text, 12)::text <= lpad(to_hex(1101), 12, '0'))
    from public.businesses b, public.industry_modules m join public.industries i on i.id = m.industry_id
   where b.id::text like 'd1%' and i.slug = 'dental' and m.slug = 'calendar';
insert into public.business_modules (business_id, module_id, enabled)
  select b.id, m.id, true from public.businesses b, public.industry_modules m join public.industries i on i.id = m.industry_id
   where b.id in ('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002') and i.slug = 'dental' and m.slug = 'ai-follow-up';
insert into public.business_modules (business_id, module_id, enabled)
  select 'd2000000-0000-0000-0000-000000000001', m.id, true from public.industry_modules m join public.industries i on i.id = m.industry_id
   where i.slug = 'dental' and m.slug = 'calendar';
