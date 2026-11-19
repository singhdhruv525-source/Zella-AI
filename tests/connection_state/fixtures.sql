-- Test data only (never production). One business per case of the connected, answering and live definition.
--   e...01 live and answering: active, receptionist on, number linked to Vapi, served 1 day ago, calendar, website form
--   e...02 number without its Vapi id            e...03 receptionist paused        e...04 suspended
--   e...05 setup not finished                    e...06 live, last served 10 days ago (not answering)
--   e...07 only telnyx and vapi integrations rows, no number (the old rule called it connected)
--   e...08 three connections that need attention, a paused number, a Meta lead source
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

insert into public.businesses (id, name, industry_id, onboarding_status, suspended_at)
select ('e1000000-0000-0000-0000-00000000000' || n)::uuid, 'Test Connections ' || n, (select id from public.industries where slug = 'dental'),
       case when n = 5 then 'ai_setup' else 'active' end, case when n = 4 then now() end
  from generate_series(1, 8) n;
insert into public.business_members (business_id, user_id, role, status)
  values ('e1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-0000000000c4', 'owner', 'active') on conflict do nothing;
delete from public.ai_agents where business_id::text like 'e1000000%';
insert into public.ai_agents (business_id, name, agent_type, status, is_default)
select b.id, 'Receptionist', 'receptionist', case when b.id::text like '%3' then 'paused' else 'active' end, true
  from public.businesses b where b.id::text like 'e1000000%';
insert into public.business_phone_numbers (business_id, e164, vapi_phone_number_id, status) values
  ('e1000000-0000-0000-0000-000000000001', '+15550100001', 'test-vapi-1', 'active'),
  ('e1000000-0000-0000-0000-000000000002', '+15550100002', null, 'active'),
  ('e1000000-0000-0000-0000-000000000003', '+15550100003', 'test-vapi-3', 'active'),
  ('e1000000-0000-0000-0000-000000000004', '+15550100004', 'test-vapi-4', 'active'),
  ('e1000000-0000-0000-0000-000000000005', '+15550100005', 'test-vapi-5', 'active'),
  ('e1000000-0000-0000-0000-000000000006', '+15550100006', 'test-vapi-6', 'active'),
  ('e1000000-0000-0000-0000-000000000008', '+15550100008', 'test-vapi-8', 'paused');
insert into public.assistant_deliveries (business_id, outcome, created_at) values
  ('e1000000-0000-0000-0000-000000000001', 'served', now() - interval '1 day'),
  ('e1000000-0000-0000-0000-000000000001', 'not_ready', now() - interval '1 hour'),
  ('e1000000-0000-0000-0000-000000000006', 'served', now() - interval '10 days'),
  ('e1000000-0000-0000-0000-000000000002', 'not_ready', now() - interval '1 hour');
insert into public.calendar_connections (business_id, provider, status) values
  ('e1000000-0000-0000-0000-000000000001', 'google', 'active'),
  ('e1000000-0000-0000-0000-000000000008', 'google', 'error');
insert into public.website_forms (business_id, name, enabled) values ('e1000000-0000-0000-0000-000000000001', 'Website', true),
  ('e1000000-0000-0000-0000-000000000002', 'Old form', false);
insert into public.meta_connections (business_id, page_id, status) values
  ('e1000000-0000-0000-0000-000000000008', 'test-page-8', 'needs_reconnect'),
  ('e1000000-0000-0000-0000-000000000006', 'test-page-6', 'connected');
insert into public.integrations (business_id, provider, integration_type, status) values
  ('e1000000-0000-0000-0000-000000000007', 'telnyx', 'phone', 'active'),
  ('e1000000-0000-0000-0000-000000000007', 'vapi', 'voice', 'active'),
  ('e1000000-0000-0000-0000-000000000008', 'shopify', 'store', 'error');
-- What each business asked for in setup (the Integrations page lists businesses that finished that step).
update public.businesses set setup_data = '{"integrations": {"phone": {"mode": "new_number"}, "calendar": "google", "email": "gmail", "lead_sources": {"website": true, "meta": true}}}'::jsonb
 where id::text like 'e1000000%';
