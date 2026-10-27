-- Test fixture (staging only): two businesses, customers, a staffless calendar (Mon-Fri 9-17 default hours).
delete from public.appointments; delete from public.ai_tool_calls; delete from public.calls; delete from public.customers;
delete from public.businesses; delete from public.staff_members; delete from public.business_phone_numbers; delete from public.ai_agents; delete from public.ai_agent_configs;
insert into public.businesses (id, name, timezone, onboarding_status) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'Bright Smile Dental', 'America/New_York', 'active'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'Other Business', 'America/Chicago', 'active');
insert into public.customers (id, business_id, first_name, last_name, phone) values
  ('cccccccc-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Ana', 'Lopez', '+15551230001'),
  ('cccccccc-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'Ben', 'Ray', '+15551230002'),
  ('cccccccc-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000002', 'Cy', 'Other', '+15551230003');
