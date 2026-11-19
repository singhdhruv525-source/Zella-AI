-- Test data only (never production). The isolated template has only two CRM presets, so every key the receptionist's
-- industry CASE knows is given a test preset matching its industry's name (configuration, not customer data), and one
-- test business per industry. Industries without a CASE branch (other, ecommerce...) keep the empty lines.
insert into public.industry_crm_presets (key, match, config) values
  ('dental', '{dental}', '{}'), ('healthcare', '{healthcare}', '{}'), ('plumbing', '{plumbing}', '{}'), ('electrical', '{electrical}', '{}'),
  ('hvac', '{hvac}', '{}'), ('home_services', '{homeservices}', '{}'), ('automotive', '{automotive}', '{}'), ('landscaping', '{landscapinglawncare}', '{}'),
  ('legal', '{legal}', '{}'), ('financial_services', '{financialservices}', '{}'), ('real_estate', '{realestate}', '{}'),
  ('restaurant', '{restaurant}', '{}'), ('hospitality', '{hospitality}', '{}'), ('fitness', '{fitness}', '{}'),
  ('property_management', '{propertymanagement}', '{}'), ('travel', '{travel}', '{}'), ('education', '{education}', '{}'),
  ('photography_events', '{photographyevents}', '{}'), ('pet_care', '{petcareveterinary}', '{}'), ('spa_wellness', '{spawellness}', '{}'),
  ('childcare', '{childcare}', '{}'), ('pest_control', '{pestcontrol}', '{}'), ('beauty_salon', '{beautysalon}', '{}'), ('ecommerce', '{ecommerce}', '{}')
on conflict (key) do nothing;
insert into public.businesses (id, name, industry_id, onboarding_status)
select ('9d000000-0000-0000-0000-0000000000' || lpad(row_number() over (order by i.slug)::text, 2, '0'))::uuid, 'Test Industry ' || i.name, i.id, 'active'
  from public.industries i;
insert into public.businesses (id, name, onboarding_status) values ('9d000000-0000-0000-0000-000000000099', 'Test No Industry', 'active');
