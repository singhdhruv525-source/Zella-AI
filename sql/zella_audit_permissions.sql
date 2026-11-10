-- Zella - privileged-action audit and permission checks (checklist 314, 326). Safe to run more than once.
--   326 every change to who can do what (team members, roles), to the AI agent, to automations, to platform settings and to
--       suspension/cancellation is written to audit_logs. Secret-like values are never copied: only which fields changed.
--   314 a daily check lists any function a signed-out visitor could call (other than the few meant for the public)
--       and any table whose rules let everyone in. Findings become a platform alert.
create or replace function public.zella_audit_privileged() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_id uuid; v_old jsonb := '{}'::jsonb; v_new jsonb := '{}'::jsonb; v_changed text[] := '{}'; k text; o jsonb; n jsonb;
begin
  o := case when TG_OP = 'INSERT' then '{}'::jsonb else to_jsonb(OLD) end;
  n := case when TG_OP = 'DELETE' then '{}'::jsonb else to_jsonb(NEW) end;
  v_biz := nullif(coalesce(n ->> 'business_id', o ->> 'business_id', case when TG_TABLE_NAME = 'businesses' then coalesce(n ->> 'id', o ->> 'id') end), '')::uuid;
  v_id := nullif(coalesce(n ->> 'id', o ->> 'id'), '')::uuid;
  if TG_TABLE_NAME in ('business_members', 'platform_admins') then
    v_old := jsonb_build_object('role', o ->> 'role', 'status', o ->> 'status', 'user_id', o ->> 'user_id');
    v_new := jsonb_build_object('role', n ->> 'role', 'status', n ->> 'status', 'user_id', n ->> 'user_id');
    if TG_OP = 'UPDATE' and v_old = v_new then return NEW; end if;
  elsif TG_TABLE_NAME = 'businesses' then
    foreach k in array array['suspended_at', 'cancelled_at', 'cancel_at', 'is_active', 'onboarding_status'] loop
      if o -> k is distinct from n -> k then v_changed := array_append(v_changed, k); v_old := v_old || jsonb_build_object(k, o -> k); v_new := v_new || jsonb_build_object(k, n -> k); end if;
    end loop;
    if cardinality(v_changed) = 0 then return NEW; end if;
  else
    -- agent, automations, settings: record which fields changed, not their values
    select coalesce(array_agg(key order by key), '{}') into v_changed from jsonb_each(n) e(key, value)
     where key not in ('updated_at', 'last_run_at', 'last_assigned_at') and o -> key is distinct from n -> key;
    if TG_OP = 'UPDATE' and cardinality(v_changed) = 0 then return NEW; end if;
    v_new := jsonb_build_object('changed_fields', to_jsonb(v_changed), 'name', coalesce(n ->> 'name', n ->> 'key', o ->> 'name', o ->> 'key'));
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (v_biz, auth.uid(), 'privileged_' || lower(TG_OP), TG_TABLE_NAME, v_id, nullif(v_old, '{}'::jsonb), v_new);
  return coalesce(NEW, OLD);
end $$;
revoke all on function public.zella_audit_privileged() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['business_members', 'ai_agents', 'automations', 'platform_settings', 'businesses'] loop
    execute format('drop trigger if exists zella_audit_privileged_trg on public.%I', t);
    execute format('create trigger zella_audit_privileged_trg after insert or update or delete on public.%I for each row execute function public.zella_audit_privileged()', t);
  end loop;
end $$;

-- 314
create or replace function public.zella_permission_check() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_fn text[]; v_pol text[]; v_allowed text[] := array['zella_unsubscribe_email', 'zella_unsubscribe_lookup', 'zella_digits', 'zella_valid_email'];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}') into v_fn from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and has_function_privilege('anon', p.oid, 'execute')
     and pg_get_function_result(p.oid) <> 'trigger' and p.proname <> all (v_allowed);
  select coalesce(array_agg(tablename || '.' || policyname order by tablename), '{}') into v_pol from pg_policies
   where schemaname = 'public' and (qual = 'true' or with_check = 'true') and (roles && array['anon'::name, 'public'::name] or cmd <> 'SELECT')
     and tablename not in ('plans', 'industries');
  return jsonb_build_object('anon_functions', to_jsonb(v_fn), 'open_policies', to_jsonb(v_pol), 'ok', cardinality(v_fn) = 0 and cardinality(v_pol) = 0);
end $$;
revoke all on function public.zella_permission_check() from public, anon, authenticated;
grant execute on function public.zella_permission_check() to service_role;

create or replace function public.zella_run_permission_check() returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb := public.zella_permission_check();
begin
  if (r ->> 'ok')::boolean then
    perform public.zella_resolve_platform_alerts('permission_gap', null, 'perm', 'Clean');
    return 0;
  end if;
  perform public.zella_platform_alert('permission_gap', 'Permission check found something open', left(r::text, 500), 'urgent', null, 'perm');
  return 1;
end $$;
revoke all on function public.zella_run_permission_check() from public, anon, authenticated;
grant execute on function public.zella_run_permission_check() to service_role;
