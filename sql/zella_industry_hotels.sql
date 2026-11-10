-- Zella - Hotels industry (2026-10-26). Safe to re-run. Adds rows only; changes and deletes nothing that exists.
--
-- Hospitality already serves hotels (Guests, Reservations; records: Stays, Guest requests, Group and event enquiries).
-- This adds a separate "Hotels" industry for businesses that should be listed as hotels, built from Hospitality so
-- the two stay consistent:
--   1. industries: "Hotels" (slug hotels), only if no industry named Hotel or Hotels exists yet.
--   2. industry_configurations: Hospitality's words and features, with hotel wording on top.
--   3. industry_modules: the same shared modules Hospitality has (same slugs, so the sidebar and Settings work as-is).
--   4. industry_crm_presets: the hospitality preset also matches the name "Hotels", so a hotel business starts with
--      Stays, Guest requests and Group and event enquiries instead of the general set.
-- Rollback: delete the Hotels rows from industry_modules, industry_configurations and industries (only if no business
--   uses it: select count(*) from businesses b join industries i on i.id = b.industry_id where i.slug = 'hotels'), and
--   remove 'hotels' from industry_crm_presets.match where key = 'hospitality'.

do $$
declare v_src uuid; v_id uuid;
begin
  select id into v_src from public.industries where slug = 'hospitality';
  if v_src is null then raise notice 'No Hospitality industry to copy from; nothing added.'; return; end if;

  select id into v_id from public.industries where lower(name) in ('hotel', 'hotels') or slug in ('hotel', 'hotels') limit 1;
  if v_id is null then
    insert into public.industries (id, name, slug, description, is_active)
    values (gen_random_uuid(), 'Hotels', 'hotels', 'Hotels, inns and resorts: reservations, stays and guest requests.', true)
    returning id into v_id;
  end if;

  if not exists (select 1 from public.industry_configurations where industry_id = v_id) then
    insert into public.industry_configurations (id, industry_id, terminology, statuses, features)
    select gen_random_uuid(), v_id,
           coalesce(c.terminology, '{}'::jsonb) || jsonb_build_object(
             'staff', 'Hotel Staff', 'staff_plural', 'Hotel Staff', 'visit', 'Stay', 'visits', 'Stays',
             'service', 'Room', 'services', 'Rooms and Services',
             'voice', coalesce(c.terminology -> 'voice', '{}'::jsonb) || jsonb_build_object(
               'greeting', 'Thank you for calling. I''m Zella, your virtual hotel receptionist. How can I help with your stay today?',
               'staff_role', 'Front Desk', 'booking_action', 'Reservation')),
           c.statuses,
           coalesce(c.features, '{}'::jsonb) || jsonb_build_object('operations_label', 'Hotel operations')
      from public.industry_configurations c where c.industry_id = v_src;
  end if;

  insert into public.industry_modules (id, industry_id, name, slug, description, is_active)
  select gen_random_uuid(), v_id, m.name, m.slug, m.description, m.is_active
    from public.industry_modules m
   where m.industry_id = v_src
     and not exists (select 1 from public.industry_modules x where x.industry_id = v_id and x.slug = m.slug);
end $$;

update public.industry_crm_presets
   set match = array_append(match, 'hotels'), updated_at = now()
 where key = 'hospitality' and not ('hotels' = any (match));

-- Check: select i.name, i.slug, (select count(*) from industry_modules m where m.industry_id = i.id) modules,
--        c.features ->> 'operations_label' from industries i left join industry_configurations c on c.industry_id = i.id
--        where i.slug in ('hospitality', 'hotels');
