-- Zella Voice: admin pages work for every role they are shown to, and admin changes are audited
-- (docs/ADMIN_AUDIT_2026-11-16.md: OPS-03, OPS-04, OPS-14, CFG-23, CFG-24, BIZ-08, ACC-04, ACC-05, ACC-09).
--
-- 1. 22 functions the admin pages call checked is_platform_admin(), which lets in only the Zella Voice owner and super
--    admin, while the pages are offered to restricted roles by the permission matrix. Each now checks the permission
--    its page uses, through zella_admin_can (owner: everything; super admin: everything but admins and roles;
--    restricted roles: what is ticked for them). Nothing else in the functions changes. Each function is archived
--    first (zella_function_archive) and must match production exactly (md5 read on 16 Nov 2026), otherwise the file
--    stops with VERSION_MISMATCH. Kept on purpose: approving and rejecting offers stays Zella Voice owner only (checked
--    inside zella_offer_transition), and zella_retry_event stays owner and super admin until it gets the replay
--    safety check (OPS-05), so a retry can't repeat a message for more people.
-- 2. platform_incidents can be read by any admin with businesses.view (the Platform operations page), not only the
--    owner and super admin.
-- 3. Audit: opening, resolving and publishing an incident, and acknowledging or resolving an alert, now write an
--    audit row naming the admin (triggers, only for changes made by a signed in person; server and scheduled job
--    changes are left to their own audit). Admin actions on offer claims (apply, cancel, reverse) are now audited too:
--    zella_offer_log skipped every "claim" kind, including the ones an admin made.
-- Rollback: sql/rollback/zella_admin_permissions_rollback.sql
begin;

do $$ begin
  if to_regprocedure('public.zella_admin_can(text)') is null or to_regclass('public.zella_function_archive') is null
     or to_regclass('public.platform_incidents') is null or to_regclass('public.platform_alerts') is null
     or to_regclass('public.audit_logs') is null or to_regprocedure('public.zella_admin_role()') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
end $$;

-- 1. permission checks
do $$
declare f record; d text; n int;
begin
  for f in select * from (values
      ('public.zella_admin_acknowledge_alert(uuid)', 'support.manage', '33e81535b95cfd34168160c846539831'),
      ('public.zella_automation_readiness()', 'businesses.view', '16794979c03050d9c9029924b669ef98'),
      ('public.zella_business_readiness(uuid)', 'businesses.view', '718aad99777bf9de32551427eee928e1'),
      ('public.zella_capabilities(uuid)', 'businesses.view', 'f4513bd42248bbf4327677a700278749'),
      ('public.zella_set_capability(uuid,text,boolean)', 'businesses.manage', 'af5e77583f887bdca3ebbd6144f0535a'),
      ('public.zella_set_business_size(uuid,text)', 'businesses.manage', '1e33bc8674a4defefe792b2cedfed1a6'),
      ('public.zella_platform_health_summary()', 'businesses.view', '76f756489f20462ecbe97ecad24d20e1'),
      ('public.zella_open_incident(text,text)', 'support.manage', '9910861088d5b54a47793118cdd94281'),
      ('public.zella_resolve_incident(uuid,text)', 'support.manage', 'ad734daa08faee02b59e270c9934dc87'),
      ('public.zella_set_incident_public(uuid,boolean,text,text)', 'support.manage', '21f34c945ab91636185971b5bc8fe94e'),
      ('public.zella_offers_list()', 'billing.view', '775aac6c859d951f6af84c016c994daa'),
      ('public.zella_offer_detail(uuid)', 'billing.view', 'bc1aa65ea5d8e3749d17b3a8e9d75553'),
      ('public.zella_offer_audience(uuid)', 'billing.view', 'ab0246de0f4e63c2171e87929902b3d6'),
      ('public.zella_offer_monitor(text,integer)', 'billing.view', 'ddf491f792429a80109fc5eedba03a7c'),
      ('public.zella_offer_report(timestamp with time zone,timestamp with time zone)', 'billing.view', '59556fd1d1e608d364c873baf9c67c0f'),
      ('public.zella_offer_rules_list()', 'billing.view', 'f7924db31885624441b45358a9051fac'),
      ('public.zella_offer_save(uuid,jsonb)', 'billing.manage', 'b379b84a293ea22c4018b0f8dc97a707'),
      ('public.zella_offer_transition(uuid,text,text)', 'billing.manage', 'e7a0173d588339b645a789700c7173f7'),
      ('public.zella_offer_apply_admin(uuid,uuid,text,text)', 'billing.manage', '3e186bf23cebc40c99954bdde50c3e23'),
      ('public.zella_offer_cancel_claim(uuid)', 'billing.manage', '4a9bb42bcd029f4ca765b681429e60b1'),
      ('public.zella_offer_set_redemption(uuid,text,text)', 'billing.manage', '646b4a0b166baff3602f2e59c4b5da91'),
      ('public.zella_offer_retry()', 'billing.manage', 'b8db5f0fe2d3e5b3aec977779b810dfd')) x(sig, perm, md5) loop
    if to_regprocedure(f.sig) is null then raise exception 'VERSION_MISMATCH: % is missing', f.sig; end if;
    d := pg_get_functiondef(f.sig::regprocedure);
    if position('public.is_platform_admin()' in d) = 0 and position(format('public.zella_admin_can(%L)', f.perm) in d) > 0 then
      continue;   -- already applied
    end if;
    if md5(d) <> f.md5 then raise exception 'VERSION_MISMATCH: % is not the version this file was written for', f.sig; end if;
    n := (length(d) - length(replace(d, 'public.is_platform_admin()', ''))) / length('public.is_platform_admin()');
    if n <> 1 then raise exception 'VERSION_MISMATCH: % checks is_platform_admin % times, expected once', f.sig, n; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_admin_permissions', f.sig, d, md5(d)) on conflict (migration, signature) do nothing;
    execute replace(d, 'public.is_platform_admin()', format('public.zella_admin_can(%L)', f.perm));
  end loop;
end $$;

-- 1b. admin actions on offer claims are audited (a business's own claims stay in offer_events only)
do $$
declare s constant text := 'public.zella_offer_log(uuid,text,text,text,jsonb,uuid)'; d text;
        old_t constant text := $t$if auth.uid() is not null and p_kind not like 'claim%' then$t$;
        new_t constant text := $t$if auth.uid() is not null and (p_kind not like 'claim%' or public.zella_admin_role() is not null) then$t$;
begin
  if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
  d := pg_get_functiondef(s::regprocedure);
  if position(new_t in d) > 0 then return; end if;
  if md5(d) <> '6a32898de09bec7bf4405fe536af04ec' or position(old_t in d) = 0 then
    raise exception 'VERSION_MISMATCH: % is not the version this file was written for', s;
  end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_admin_permissions', s, d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, old_t, new_t);
end $$;

-- 2. any admin who can see Platform operations can read incidents
drop policy if exists platform_incidents_admin_view on public.platform_incidents;
create policy platform_incidents_admin_view on public.platform_incidents for select to authenticated
  using ((select public.zella_admin_can('businesses.view')));

-- 3. incident and alert changes made by an admin are audited
create or replace function public.zella_audit_admin_incident_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_action text;
begin
  if auth.uid() is null or public.zella_admin_role() is null then return new; end if;
  v_action := case
    when tg_op = 'INSERT' then 'platform.incident_opened'
    when new.status is distinct from old.status and new.status = 'resolved' then 'platform.incident_resolved'
    when new.is_public is distinct from old.is_public or new.public_message is distinct from old.public_message
      or new.component is distinct from old.component then 'platform.incident_public_changed'
    else null end;
  if v_action is null then return new; end if;
  insert into public.audit_logs (user_id, business_id, action, entity_type, entity_id, old_data, new_data)
  values (auth.uid(), null, v_action, 'platform_incident', new.id,
          case when tg_op = 'UPDATE' then jsonb_build_object('status', old.status, 'is_public', old.is_public, 'public_message', old.public_message, 'component', old.component) end,
          jsonb_strip_nulls(jsonb_build_object('title', new.title, 'status', new.status, 'is_public', new.is_public,
            'public_message', new.public_message, 'component', new.component, 'note', new.resolution_note)));
  return new;
end $$;

create or replace function public.zella_audit_admin_alert_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.zella_admin_role() is null or new.status is not distinct from old.status then return new; end if;
  insert into public.audit_logs (user_id, business_id, action, entity_type, entity_id, old_data, new_data)
  values (auth.uid(), new.business_id, 'platform.alert_' || new.status, 'platform_alert', new.id,
          jsonb_build_object('status', old.status),
          jsonb_strip_nulls(jsonb_build_object('status', new.status, 'kind', new.kind, 'title', new.title, 'note', new.resolution_note)));
  return new;
end $$;

revoke all on function public.zella_audit_admin_incident_trg(), public.zella_audit_admin_alert_trg() from public, anon, authenticated;

drop trigger if exists zella_audit_admin_incident on public.platform_incidents;
create trigger zella_audit_admin_incident after insert or update on public.platform_incidents
  for each row execute function public.zella_audit_admin_incident_trg();
drop trigger if exists zella_audit_admin_alert on public.platform_alerts;
create trigger zella_audit_admin_alert after update of status on public.platform_alerts
  for each row execute function public.zella_audit_admin_alert_trg();

commit;
