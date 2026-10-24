-- Zella - list and switch industry rules per business. Safe to run more than once. Run AFTER zella_industry_engine.sql / zella_industry_presets.sql.
-- Shows every rule a business can have: the ones made for its industry (switched on by default) and a few general ones anyone can add.
-- Platform admins (setup wizard, admin page) and owners/admins of the business can use these.
insert into public.industry_automation_presets (industry_key, name, checklist_no, description, trigger_type, trigger_config) values
('general', 'Visit feedback request', null, 'Ask customers how their visit went the day after.', 'appointment_followup', '{"after_days":1,"rule":{"message":"Thanks for visiting. How did it go? Reply here with any feedback.","delay_minutes":1}}'::jsonb),
('general', 'Six-month check-in', null, 'Check in with customers who have not visited for six months.', 'service_due', '{"days":180,"service":"visit"}'::jsonb),
('general', 'Spring and autumn check-in', null, 'Reach out to past customers once in spring and once in autumn.', 'seasonal_reminder', '{"months":[3,9],"service":"visit"}'::jsonb)
on conflict (industry_key, name) do update set description = excluded.description, trigger_type = excluded.trigger_type, trigger_config = excluded.trigger_config;

create or replace function public.zella_industry_key_for(p_business_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_name text; v_key text;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  return coalesce(v_key, 'other');
end $$;
revoke all on function public.zella_industry_key_for(uuid) from public, anon, authenticated;
grant execute on function public.zella_industry_key_for(uuid) to service_role;

create or replace function public.zella_industry_rule_list(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_key text;
begin
  if not (public.is_platform_admin() or public.zella_is_member(p_business_id)) then raise exception 'NOT_ALLOWED'; end if;
  v_key := public.zella_industry_key_for(p_business_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'name', p.name, 'description', p.description, 'checklist_no', p.checklist_no, 'trigger_type', p.trigger_type,
             'preferred', v_key <> 'other' and p.industry_key <> 'general', 'status', a.status, 'notify_via', coalesce(a.trigger_config ->> 'notify_via', 'both'),
             'enabled', coalesce(a.status = 'active', false))
           order by (p.industry_key = 'general'), p.checklist_no nulls last, p.name)
      from (select distinct on (name) * from public.industry_automation_presets
             where industry_key in (v_key, 'general') or v_key = 'other' order by name, (industry_key = 'general')) p
      left join public.automations a on a.business_id = p_business_id and a.name = p.name
     ), '[]'::jsonb);
end $$;
revoke execute on function public.zella_industry_rule_list(uuid) from public, anon;
grant execute on function public.zella_industry_rule_list(uuid) to authenticated, service_role;

-- p_rules: [{"name": "...", "enabled": true, "notify_via": "both"}]
create or replace function public.zella_set_industry_rules(p_business_id uuid, p_rules jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare v_key text; r jsonb; p public.industry_automation_presets; a public.automations; n integer := 0; v_notify text; v_on boolean;
begin
  if not (public.is_platform_admin() or public.zella_has_role(p_business_id, array['owner', 'admin'])) then raise exception 'NOT_ALLOWED'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then raise exception 'BAD_RULES'; end if;
  v_key := public.zella_industry_key_for(p_business_id);
  for r in select * from jsonb_array_elements(p_rules) loop
    select * into p from public.industry_automation_presets where name = r ->> 'name' and (industry_key in (v_key, 'general') or v_key = 'other') order by (industry_key = 'general') limit 1;
    if not found then continue; end if;
    v_notify := case when r ->> 'notify_via' in ('sms', 'email', 'both') then r ->> 'notify_via' else null end;
    v_on := coalesce((r ->> 'enabled')::boolean, true);
    select * into a from public.automations where business_id = p_business_id and name = p.name for update;
    if not found then
      insert into public.automations (business_id, name, description, trigger_type, status, trigger_config, actions, conditions, created_by)
      values (p_business_id, p.name, p.description, p.trigger_type, case when v_on then 'active' else 'disabled' end,
              p.trigger_config || coalesce(jsonb_build_object('notify_via', v_notify), '{}'::jsonb), '[]'::jsonb, '{}'::jsonb, auth.uid());
    else
      update public.automations set
             status = case when v_on then 'active' else 'disabled' end,
             trigger_config = a.trigger_config || coalesce(jsonb_build_object('notify_via', v_notify), '{}'::jsonb), updated_at = now()
       where id = a.id;
    end if;
    n := n + 1;
  end loop;
  insert into public.audit_logs (business_id, user_id, action, entity_type, new_data) values (p_business_id, auth.uid(), 'industry_rules.changed', 'automations', jsonb_build_object('count', n));
  return n;
end $$;
revoke execute on function public.zella_set_industry_rules(uuid, jsonb) from public, anon;
grant execute on function public.zella_set_industry_rules(uuid, jsonb) to authenticated, service_role;

-- Before a business exists (setup wizard): the rules an industry would get.
create or replace function public.zella_industry_rules_for(p_industry_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_name text; v_key text;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select regexp_replace(lower(coalesce(name, '')), '[^a-z]', '', 'g') into v_name from public.industries where id = p_industry_id;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  v_key := coalesce(v_key, 'other');
  return coalesce((select jsonb_agg(jsonb_build_object('name', p.name, 'description', p.description, 'checklist_no', p.checklist_no,
           'trigger_type', p.trigger_type, 'preferred', v_key <> 'other' and p.industry_key <> 'general', 'enabled', v_key <> 'other' and p.industry_key <> 'general', 'notify_via', 'both')
           order by (p.industry_key = 'general'), p.checklist_no nulls last, p.name)
      from (select distinct on (name) * from public.industry_automation_presets
             where industry_key in (v_key, 'general') or v_key = 'other' order by name, (industry_key = 'general')) p), '[]'::jsonb);
end $$;
revoke execute on function public.zella_industry_rules_for(uuid) from public, anon;
grant execute on function public.zella_industry_rules_for(uuid) to authenticated, service_role;
