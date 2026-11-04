# Generates sql/zella_presets_v2.sql from presets_v2_definition.py. Run: python3 sql/generators/presets_v2_sql.py
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from presets_v2_definition import PRESETS as P
J = json.dumps(P, ensure_ascii=False, indent=None, separators=(",", ":"))
assert "$presets$" not in J
sql = r'''-- Industry records, version 2 (2026-11-04 industry work, batch 4). Generated from one definition for all 28 industries;
-- see docs/INDUSTRY_WORK_2026-11-04.md for the matrix.
--
-- What changes:
--   * New presets: insurance (policies, claims / first notice of loss, quotes, service requests) and cleaning
--     (properties with checklist and private access codes, visits, plans), split from financial services and home services.
--   * New record types and fields for every industry (treatment plans, refill requests, prior authorizations, classes with
--     capacity, colour cards, application records, VIN and plate, units and vendors, deadlines, children ...), record links
--     (a job's property, a repair order's vehicle, a booking's class), private fields for access codes, member IDs,
--     passport numbers and children's medical and pick-up details, and the capability each type belongs to.
--   * Nine title labels that repeated a field label are renamed (presets, and businesses still using the old label).
--
-- How existing businesses get it (zella_apply_crm_preset, also run lazily when the CRM opens):
--   * Never removes or renames anything a business has, never re-adds a field it has had before (fields_seen), never
--     changes a field's type, never turns a business's types on.
--   * New fields are added to types that came from an industry preset; types a business created itself are untouched.
--   * New types are added switched OFF for businesses already using that preset (the owner switches them on in Customize
--     records); a business new to the preset (new business, or a changed industry) gets them on.
--   * A field the preset now marks private becomes private (never the other way), and its values move out of record data.
--   * Prints a report: presets changed, types added, types upgraded, values moved.
-- Needs zella_capabilities.sql and zella_record_links_secrets.sql first. Safe to run twice. Needs the owner's approval.

create or replace function public.zella_preset_v2_merge(p_patch jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare k text; spec jsonb; t jsonb; cfg jsonb; types jsonb; idx int; cur jsonb; f jsonb; n int := 0;
begin
  for k, spec in select * from jsonb_each(p_patch) loop
    if coalesce((spec ->> 'new')::boolean, false) then
      insert into public.industry_crm_presets (key, match, config)
      values (k, array(select jsonb_array_elements_text(spec -> 'match')), jsonb_build_object('types', '[]'::jsonb))
      on conflict (key) do update set match = excluded.match;
    elsif spec ? 'match' then
      update public.industry_crm_presets set match = array(select jsonb_array_elements_text(spec -> 'match')) where key = k;
    end if;
    select config into cfg from public.industry_crm_presets where key = k;
    if cfg is null then raise notice 'preset % not found, skipped', k; continue; end if;
    types := coalesce(cfg -> 'types', '[]');
    for t in select * from jsonb_array_elements(spec -> 'types') loop
      select (o - 1)::int into idx from jsonb_array_elements(types) with ordinality e(x, o) where x ->> 'key' = t ->> 'key';
      if t ? 'add_fields' then
        if idx is null then raise exception 'preset %: type % to extend is missing', k, t ->> 'key'; end if;
        cur := types -> idx;
        for f in select * from jsonb_array_elements(t -> 'add_fields') loop
          if not exists (select 1 from jsonb_array_elements(cur -> 'fields') x where x ->> 'key' = f ->> 'key') then
            cur := jsonb_set(cur, '{fields}', (cur -> 'fields') || jsonb_build_array(f));
          end if;
        end loop;
        if t ? 'sensitive' then
          cur := jsonb_set(cur, '{fields}', (select jsonb_agg(case when (t -> 'sensitive') ? (x ->> 'key') then x || '{"sensitive": true}' else x end order by o)
                                             from jsonb_array_elements(cur -> 'fields') with ordinality e(x, o)));
        end if;
        if t ? 'relabel' then
          cur := jsonb_set(cur, '{fields}', (select jsonb_agg(case when (t -> 'relabel') ? (x ->> 'key') then x || jsonb_build_object('label', t -> 'relabel' ->> (x ->> 'key')) else x end order by o)
                                             from jsonb_array_elements(cur -> 'fields') with ordinality e(x, o)));
        end if;
        cur := cur || (t - 'key' - 'add_fields' - 'sensitive' - 'relabel');
        types := jsonb_set(types, array[idx::text], cur);
      elsif idx is null then
        types := types || jsonb_build_array(t);
      else
        types := jsonb_set(types, array[idx::text], (types -> idx) || (t - 'fields') ||
          jsonb_build_object('fields', (types -> idx -> 'fields') || coalesce((select jsonb_agg(f2) from jsonb_array_elements(t -> 'fields') f2
            where not exists (select 1 from jsonb_array_elements(types -> idx -> 'fields') x where x ->> 'key' = f2 ->> 'key')), '[]')));
      end if;
    end loop;
    if types is distinct from cfg -> 'types' then
      update public.industry_crm_presets set config = jsonb_set(config, '{types}', types) where key = k;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_preset_v2_merge(jsonb) from public, anon, authenticated;

-- Copies the industry's records into a business, and upgrades what it already has (rules at the top of this file).
create or replace function public.zella_apply_crm_preset(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v_name text; v_key text; v_cfg jsonb; t jsonb; ty record; i integer := 0; n integer := 0; v_existing boolean;
        v_add jsonb; v_fields jsonb; v_moved boolean := false;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  if not found then raise exception 'NOT_ALLOWED'; end if;
  select p.key, p.config into v_key, v_cfg from public.industry_crm_presets p where v_name = any (p.match) order by p.key limit 1;
  if v_key is null then select p.key, p.config into v_key, v_cfg from public.industry_crm_presets p where p.key = 'other'; end if;
  if v_key is null then return 0; end if;
  v_existing := exists (select 1 from public.crm_record_types where business_id = p_business_id and preset_key = v_key);
  for t in select * from jsonb_array_elements(v_cfg -> 'types') loop
    i := i + 1;
    select * into ty from public.crm_record_types where business_id = p_business_id and key = t ->> 'key' for update;
    if not found then
      insert into public.crm_record_types (business_id, key, singular, plural, icon, title_label, link_person, statuses, closed_statuses, fields, columns, notice,
                                           position, preset_key, capability, capacity, fields_seen, enabled)
      values (p_business_id, t ->> 'key', t ->> 'singular', t ->> 'plural', coalesce(t ->> 'icon', 'folder'), coalesce(t ->> 'title_label', 'Name'),
              coalesce((t ->> 'link_person')::boolean, true), t -> 'statuses',
              coalesce((select array_agg(x) from jsonb_array_elements_text(t -> 'closed_statuses') x), '{}'),
              t -> 'fields', coalesce((select array_agg(x) from jsonb_array_elements_text(t -> 'columns') x), '{}'),
              nullif(t ->> 'notice', ''), i, v_key, t ->> 'capability', t -> 'capacity',
              array(select f ->> 'key' from jsonb_array_elements(t -> 'fields') f), not v_existing)
      on conflict (business_id, key) do nothing;
      n := n + 1;
      continue;
    end if;
    -- privacy only goes up: a field the preset marks private becomes private here too (same key, same type)
    select jsonb_agg(case when not coalesce((x ->> 'sensitive')::boolean, false) and exists (select 1 from jsonb_array_elements(t -> 'fields') pf
                      where pf ->> 'key' = x ->> 'key' and pf ->> 'type' = x ->> 'type' and coalesce((pf ->> 'sensitive')::boolean, false))
                     then x || '{"sensitive": true}' else x end order by o)
      into v_fields from jsonb_array_elements(ty.fields) with ordinality e(x, o);
    v_fields := coalesce(v_fields, '[]');
    v_add := '[]';
    if ty.preset_key is not null then
      -- new fields, unless the business has (or once had) a field with that key
      select coalesce(jsonb_agg(f), '[]') into v_add from jsonb_array_elements(t -> 'fields') f
       where not exists (select 1 from jsonb_array_elements(ty.fields) x where x ->> 'key' = f ->> 'key') and not ((f ->> 'key') = any (ty.fields_seen));
      -- a link field is only added when its target type exists in this business (or is this type)
      select coalesce(jsonb_agg(f), '[]') into v_add from jsonb_array_elements(v_add) f
       where f ->> 'type' <> 'record' or f ->> 'target' = ty.key
          or exists (select 1 from public.crm_record_types x where x.business_id = p_business_id and x.key = f ->> 'target')
          or exists (select 1 from jsonb_array_elements(v_cfg -> 'types') pt where pt ->> 'key' = f ->> 'target');
    end if;
    if v_fields is distinct from ty.fields or v_add <> '[]'::jsonb
       or (ty.preset_key is not null and ((ty.capability is null and t ? 'capability') or (ty.capacity is null and t ? 'capacity'))) then
      update public.crm_record_types set
        fields = v_fields || v_add,
        fields_seen = array(select distinct x from unnest(ty.fields_seen || array(select f ->> 'key' from jsonb_array_elements(v_fields || v_add) f)) x),
        capability = case when ty.preset_key is not null then coalesce(ty.capability, t ->> 'capability') else ty.capability end,
        capacity = case when ty.preset_key is not null then coalesce(ty.capacity, t -> 'capacity') else ty.capacity end,
        updated_at = now()
       where id = ty.id;
      if v_fields is distinct from ty.fields then v_moved := true; end if;
      n := n + 1;
    end if;
  end loop;
  update public.crm_record_types tt set enabled = false, updated_at = now()
   where tt.business_id = p_business_id and tt.preset_key is distinct from v_key and tt.enabled
     and not exists (select 1 from jsonb_array_elements(v_cfg -> 'types') nt where nt ->> 'key' = tt.key)
     and not exists (select 1 from public.crm_records r where r.business_id = tt.business_id and r.type_key = tt.key);
  if v_moved then perform public.zella_move_sensitive_values(p_business_id); end if;
  return n;
end $$;

-- Today and the menu leave out record types whose kind of work is switched off.
create or replace function public.zella_today_operations(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_start timestamptz; v_end timestamptz;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.businesses where id = p_business_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_start := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_end := v_start + interval '1 day';
  return coalesce((
    select jsonb_agg(jsonb_build_object('key', t.key, 'plural', t.plural, 'icon', t.icon, 'open', coalesce(c.open, 0),
             'overdue', coalesce(c.overdue, 0), 'due_today', coalesce(c.due_today, 0), 'unassigned', coalesce(c.unassigned, 0)) order by t.position, t.key)
      from public.crm_record_types t
      left join lateral (
        select count(*) as open,
               count(*) filter (where r.due_at < now()) as overdue,
               count(*) filter (where r.due_at >= v_start and r.due_at < v_end) as due_today,
               count(*) filter (where r.assigned_to is null) as unassigned
          from public.crm_records r
         where r.business_id = p_business_id and r.type_key = t.key and r.archived_at is null and r.closed_at is null
           and not (r.status = any (coalesce(t.closed_statuses, '{}'::text[])))
      ) c on true
     where t.business_id = p_business_id and t.enabled and (t.capability is null or public.zella_capability_on(p_business_id, t.capability))), '[]'::jsonb);
end $$;
revoke execute on function public.zella_today_operations(uuid) from public, anon;
grant execute on function public.zella_today_operations(uuid) to authenticated, service_role;

-- Backfill: every field a business already has counts as seen, so it's never re-added after being removed later.
update public.crm_record_types set fields_seen = array(select f ->> 'key' from jsonb_array_elements(fields) f) where fields_seen = '{}' and jsonb_array_length(fields) > 0;

do $presets_do$
declare v_presets int; v_title int; v_types int := 0; v_biz int := 0; v_before int; v_after int; b record; v_secrets_before int; v_secrets_after int;
begin
  -- title labels that repeated a field label: rename where the business still has the old one
  update public.crm_record_types ty set title_label = v.new_label, updated_at = now()
    from (values ('financial_services', 'requests', 'Request', 'Summary'), ('legal', 'document_requests', 'Document', 'Request'),
                 ('plumbing', 'plans', 'Plan', 'Agreement name'), ('home_services', 'plans', 'Plan', 'Agreement name'),
                 ('landscaping', 'plans', 'Plan', 'Agreement name'), ('pest_control', 'plans', 'Plan', 'Agreement name'),
                 ('real_estate', 'viewings', 'Viewing', 'Summary'), ('spa_wellness', 'packages', 'Package', 'Client package'),
                 ('restaurant', 'requests', 'Request', 'Summary')) v(preset, type_key, old_label, new_label)
   where ty.preset_key = v.preset and ty.key = v.type_key and ty.title_label = v.old_label;
  get diagnostics v_title = row_count;
  v_presets := public.zella_preset_v2_merge($presets$__JSON__$presets$::jsonb);
  select count(*) into v_secrets_before from public.crm_record_secrets;
  for b in select id from public.businesses where onboarding_status in ('testing', 'ready', 'active', 'paused') loop
    select count(*) into v_before from public.crm_record_types where business_id = b.id;
    v_types := v_types + public.zella_apply_crm_preset(b.id);
    v_biz := v_biz + 1;
  end loop;
  select count(*) into v_secrets_after from public.crm_record_secrets;
  raise notice 'presets v2: % presets changed, % title labels renamed, % businesses checked, % types added or upgraded, % private values moved',
    v_presets, v_title, v_biz, v_types, v_secrets_after - v_secrets_before;
end $presets_do$;
'''.replace("__JSON__", J)
open(os.path.join(HERE, "..", "zella_presets_v2.sql"), "w").write(sql)
print("written", len(sql))
