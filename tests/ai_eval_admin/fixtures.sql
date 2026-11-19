-- Test data only (never production). e01: 3 cases that all pass (business passes); e02: 3 cases, one fails; e03: 2
-- passing cases (too few to pass); e04: no cases. Knowledge written as a test business would, set ready.
insert into auth.users (id, email, email_confirmed_at) values
  ('a0000000-0000-0000-0000-0000000000c1', 'admin@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c2', 'readonly@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c3', 'support@zella.test', now()),
  ('a0000000-0000-0000-0000-0000000000c4', 'owner@glow.test', now())
on conflict do nothing;
insert into public.platform_admins (user_id, role) values
  ('a0000000-0000-0000-0000-0000000000c1', 'zella_owner'), ('a0000000-0000-0000-0000-0000000000c2', 'read_only_admin'),
  ('a0000000-0000-0000-0000-0000000000c3', 'support_admin')
on conflict do nothing;
insert into auth.mfa_factors (id, user_id, factor_type, status)
  select gen_random_uuid(), id, 'totp', 'verified' from auth.users where email like '%@zella.test'
  and not exists (select 1 from auth.mfa_factors f where f.user_id = auth.users.id);
insert into public.businesses (id, name, industry_id, onboarding_status)
select ('e0000000-0000-0000-0000-00000000000' || n)::uuid, 'Test Evals ' || n, (select id from public.industries where slug = 'dental'), 'active'
  from generate_series(1, 4) n;
insert into public.business_members (business_id, user_id, role, status)
  values ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-0000000000c4', 'owner', 'active') on conflict do nothing;
insert into public.knowledge_items (business_id, kind, title, answer, status)
select b, k, t, a, 'ready' from (values
  ('Opening hours', 'We are open Monday to Friday from 9 to 5.', 'faq'),
  ('Parking', 'Free parking is available behind the building.', 'faq'),
  ('Teeth whitening', 'Teeth whitening takes one hour.', 'service')) v(t, a, k),
  (values ('e0000000-0000-0000-0000-000000000001'::uuid), ('e0000000-0000-0000-0000-000000000002'::uuid), ('e0000000-0000-0000-0000-000000000003'::uuid)) bs(b);
insert into public.ai_eval_cases (business_id, question, expect_contains, expect_none) values
  ('e0000000-0000-0000-0000-000000000001', 'What are your opening hours?', '{Monday,9}', false),
  ('e0000000-0000-0000-0000-000000000001', 'Is there parking?', '{free parking}', false),
  ('e0000000-0000-0000-0000-000000000001', 'Do you sell submarines?', '{}', true),
  ('e0000000-0000-0000-0000-000000000002', 'What are your opening hours?', '{Monday}', false),
  ('e0000000-0000-0000-0000-000000000002', 'Is there parking?', '{valet}', false),
  ('e0000000-0000-0000-0000-000000000002', 'How long does whitening take?', '{one hour}', false),
  ('e0000000-0000-0000-0000-000000000003', 'What are your opening hours?', '{Friday}', false),
  ('e0000000-0000-0000-0000-000000000003', 'Is there parking?', '{parking}', false);
