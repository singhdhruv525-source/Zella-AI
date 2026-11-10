-- The 28 industries production has (slugs and names read from production on 5 Nov 2026; configuration rows only, no
-- customer data). sql/zella_industries_seed.sql has 19 of them, one under an older slug; this brings an isolated copy
-- to production's list before the pending migrations run (they set per-industry defaults by slug).
update public.industries set slug = 'ecommerce' where slug = 'e-commerce';
insert into public.industries (name, slug, description, is_active)
select n, s, n, true from (values
  ('Pet Care & Veterinary', 'pet-care-veterinary'), ('Landscaping & Lawn Care', 'landscaping-lawn-care'), ('Pest Control', 'pest-control'),
  ('Spa & Wellness', 'spa-wellness'), ('Photography & Events', 'photography-events'), ('Property Management', 'property-management'),
  ('Childcare', 'childcare'), ('Cleaning Services', 'cleaning-services'), ('Insurance', 'insurance')) v(n, s)
where not exists (select 1 from public.industries i where i.slug = v.s);
insert into public.industry_configurations (industry_id, terminology)
select i.id, '{}'::jsonb from public.industries i where not exists (select 1 from public.industry_configurations c where c.industry_id = i.id);
