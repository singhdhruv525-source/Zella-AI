-- Zella - configuration-driven CRM navigation (2026-10-26). Safe to re-run. Adds no tables and changes no rows.
--
-- What already exists and is reused (no second configuration system):
--   industries / industry_configurations   the business's industry, its words (terminology) and feature flags
--   industry_modules                       which shared modules an industry supports (industry availability)
--   business_modules                       which of those a business has switched on (business enablement)
--   crm_record_types                       the business's industry-specific operations (Tables, Recalls, Jobs, ...),
--                                          copied from industry_crm_presets the first time the CRM opens
--   business_members.role                  what this person may do (user permissions)
--
-- This file adds:
--   1. zella_module_on(business, slug)        true when the module is supported by the business's industry and switched
--                                             on for the business. Used by the policies below and by the navigation.
--   2. zella_workspace_navigation(business)   everything the CRM sidebar needs for one business, for a member of that
--                                             business only: industry, words, modules (available and enabled), record
--                                             types, the person's role, business location, logo and live phone number.
--   3. Server-side enforcement, so hiding a menu item is never the only protection:
--      - calls and call_insights can be read only while the business's "calls" module is on;
--      - automations can be read or changed only while the "automations" module is on;
--      - crm_records of a switched-off record type can't be read (writes already refuse them).
--      Restrictive policies: they add a condition to the existing member policies and never widen access.
--      The server key (AI receptionist, n8n) bypasses row security and is unaffected.
--
-- Needs: zella_is_member (zella_ops_extras.sql), zella_has_role, the tables above.
-- Rollback: drop policy zella_module_calls_read on public.calls; drop policy zella_module_calls_read on
--   public.call_insights; drop policy zella_module_automations_{read,insert,update,delete} on public.automations;
--   drop policy zella_record_type_enabled_read on public.crm_records; drop function zella_workspace_navigation(uuid),
--   zella_module_on(uuid, text).
-- Check after applying: select public.zella_workspace_navigation('<business id>') as a member of that business.

-- 1. Is a module on for this business? ------------------------------------------------------------------------

create or replace function public.zella_module_on(p_business_id uuid, p_slug text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.business_modules bm
      join public.industry_modules im on im.id = bm.module_id
      join public.businesses b on b.id = bm.business_id
     where bm.business_id = p_business_id
       and bm.enabled
       and im.slug = p_slug
       and im.is_active
       and im.industry_id = b.industry_id   -- a module of another industry never counts
  );
$$;
revoke all on function public.zella_module_on(uuid, text) from public, anon;
grant execute on function public.zella_module_on(uuid, text) to authenticated, service_role;

-- 2. Navigation configuration for one business ------------------------------------------------------------------

create or replace function public.zella_workspace_navigation(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b public.businesses; v_role text;
begin
  select m.role into v_role from public.business_members m
   where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active';
  if auth.uid() is null or v_role is null then raise exception 'NOT_ALLOWED'; end if;
  select * into b from public.businesses where id = p_business_id;

  return jsonb_build_object(
    'business_id', b.id,
    'role', v_role,
    'industry', (select jsonb_build_object('id', i.id, 'slug', i.slug, 'name', i.name) from public.industries i where i.id = b.industry_id),
    -- Configured means the industry exists and has its configuration row; the CRM shows a configuration notice otherwise.
    'configured', exists (select 1 from public.industries i join public.industry_configurations ic on ic.industry_id = i.id where i.id = b.industry_id),
    'operations_label', (select coalesce(nullif(ic.features ->> 'operations_label', ''), i.name || ' operations')
                           from public.industries i left join public.industry_configurations ic on ic.industry_id = i.id where i.id = b.industry_id),
    'terminology', coalesce((select ic.terminology from public.industry_configurations ic where ic.industry_id = b.industry_id), '{}'::jsonb)
                   || coalesce(b.terminology_overrides, '{}'::jsonb),
    'modules', coalesce((
        select jsonb_agg(jsonb_build_object('slug', im.slug, 'name', im.name, 'available', im.is_active,
                 'enabled', coalesce(bm.enabled, false) and im.is_active) order by im.slug)
          from public.industry_modules im
          left join public.business_modules bm on bm.module_id = im.id and bm.business_id = b.id
         where im.industry_id = b.industry_id), '[]'::jsonb),
    'record_types', coalesce((
        select jsonb_agg(jsonb_build_object('key', t.key, 'singular', t.singular, 'plural', t.plural, 'icon', t.icon,
                 'enabled', t.enabled, 'position', t.position, 'preset', t.preset_key) order by t.position, t.plural)
          from public.crm_record_types t where t.business_id = b.id), '[]'::jsonb),
    'location', nullif(concat_ws(', ', nullif(b.city, ''), nullif(b.state, ''), nullif(b.country, '')), ''),
    'logo_url', b.logo_url,
    'phone', (select p.e164 from public.business_phone_numbers p where p.business_id = b.id and p.status = 'active' order by p.created_at limit 1)
  );
end $$;
revoke all on function public.zella_workspace_navigation(uuid) from public, anon;
grant execute on function public.zella_workspace_navigation(uuid) to authenticated;

-- 3. Server-side module enforcement -----------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.calls') is not null then
    drop policy if exists zella_module_calls_read on public.calls;
    create policy zella_module_calls_read on public.calls as restrictive for select to authenticated
      using (public.zella_module_on(business_id, 'calls'));
  end if;
  if to_regclass('public.call_insights') is not null then
    drop policy if exists zella_module_calls_read on public.call_insights;
    create policy zella_module_calls_read on public.call_insights as restrictive for select to authenticated
      using (public.zella_module_on(business_id, 'calls'));
  end if;
  if to_regclass('public.automations') is not null then
    drop policy if exists zella_module_automations_read on public.automations;
    create policy zella_module_automations_read on public.automations as restrictive for select to authenticated
      using (public.zella_module_on(business_id, 'automations'));
    drop policy if exists zella_module_automations_insert on public.automations;
    create policy zella_module_automations_insert on public.automations as restrictive for insert to authenticated
      with check (public.zella_module_on(business_id, 'automations'));
    drop policy if exists zella_module_automations_update on public.automations;
    create policy zella_module_automations_update on public.automations as restrictive for update to authenticated
      using (public.zella_module_on(business_id, 'automations')) with check (public.zella_module_on(business_id, 'automations'));
    drop policy if exists zella_module_automations_delete on public.automations;
    create policy zella_module_automations_delete on public.automations as restrictive for delete to authenticated
      using (public.zella_module_on(business_id, 'automations'));
  end if;
  if to_regclass('public.crm_records') is not null then
    drop policy if exists zella_record_type_enabled_read on public.crm_records;
    create policy zella_record_type_enabled_read on public.crm_records as restrictive for select to authenticated
      using (exists (select 1 from public.crm_record_types t
                      where t.business_id = crm_records.business_id and t.key = crm_records.type_key and t.enabled));
  end if;
end $$;
