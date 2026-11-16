-- Zella Voice: editable alert rules (docs/ADMIN_AUDIT_2026-11-16.md SET-ALERT-RULES, part 1). Every check raises its
-- alert through zella_platform_alert, which read no rules.
--   1. platform_alert_rules, one row per alert kind: enabled, severity (or as raised), destination (bell, or bell and
--      email), who gets the email (admins holding a permission, or every admin), repeat interval and quiet window
--      (the email side is part 2, sql/zella_alert_rules_email.sql). Server only (row security on, no policies).
--   2. zella_platform_alert: the SAME signature, parameter names and defaults, so every caller (46 database functions,
--      the n8n event router with named arguments) is unchanged. With no rule for a kind it behaves exactly as before.
--      With a rule: switched off raises nothing (returns null); a severity replaces the raised one; a repeat interval
--      doesn't open a new alert within that many minutes of the last one being resolved. Urgent alerts are never
--      switched off, lowered or held back: an alert raised as urgent, or of a protected kind (service_incident,
--      scheduler_failed, provider_down, integration_disconnected, tenant_leak), ignores enabled, severity and repeat.
--      Archived first; must match production's version (16 Nov 2026). sql/zella_run_all.sql:1519 re-creates the old
--      body: never re-run it after this file (the rules would silently stop being read); if it ever is, apply this file
--      again (the guard accepts production's body, and the rules table is kept).
--   3. zella_admin_alert_rules(): businesses.view, every rule and the protected kinds. zella_admin_alert_rule_save(kind,
--      rule, reason): platform.configure, a reason, audited (alert_rule.saved, alert_rule.removed); refuses to switch
--      off or lower a protected kind (URGENT_PROTECTED). A null rule removes it (back to as raised).
-- Rollback: sql/rollback/zella_alert_rules_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null or to_regclass('public.platform_alerts') is null
     or to_regprocedure('public.zella_admin_require(text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'd2dda6716c1f0285a8290ef442f5a90f' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_alert_rules', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> 'a4d850dbfe1be1b404f97623e8a63c8e' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  if to_regclass('public.platform_alert_rules') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'platform_alert_rules' and column_name = 'repeat_minutes') then
    raise exception 'VERSION_MISMATCH: a different platform_alert_rules table already exists';
  end if;
end $$;

create table if not exists public.platform_alert_rules (
  kind text primary key check (kind ~ '^[a-z][a-z0-9_]{1,60}$'),
  enabled boolean not null default true,
  severity text check (severity in ('info', 'warning', 'urgent')),
  destination text not null default 'bell_and_email' check (destination in ('bell', 'bell_and_email')),
  email_permission text check (email_permission ~ '^[a-z]+\.[a-z]+$'),
  repeat_minutes integer check (repeat_minutes between 5 and 10080),
  quiet_start time,
  quiet_end time,
  quiet_tz text not null default 'America/New_York',
  updated_by uuid,
  updated_at timestamptz not null default now(),
  check ((quiet_start is null) = (quiet_end is null))
);
alter table public.platform_alert_rules enable row level security;
revoke all on table public.platform_alert_rules from public, anon, authenticated;
grant all on table public.platform_alert_rules to service_role;

-- the kinds that are always urgent: never switched off, lowered, held back or delayed (the owner decision's safety default)
create or replace function public.zella_alert_protected_kinds() returns text[]
language sql immutable set search_path = '' as $$
  select array['service_incident', 'scheduler_failed', 'provider_down', 'integration_disconnected', 'tenant_leak']::text[];
$$;
revoke all on function public.zella_alert_protected_kinds() from public, anon;
grant execute on function public.zella_alert_protected_kinds() to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.zella_platform_alert(p_kind text, p_title text, p_detail text DEFAULT NULL::text, p_severity text DEFAULT 'warning'::text, p_business_id uuid DEFAULT NULL::uuid, p_dedupe_key text DEFAULT ''::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_sev text := case when p_severity in ('info','urgent') then p_severity else 'warning' end; rule public.platform_alert_rules;
begin
  -- the rule for this kind (sql/zella_alert_rules.sql); none means exactly the old behaviour. An urgent alert, or a
  -- protected kind, is never switched off, lowered or held back by a rule.
  select * into rule from public.platform_alert_rules where kind = p_kind;
  if rule.kind is not null and v_sev <> 'urgent' and not (p_kind = any (public.zella_alert_protected_kinds())) then
    if not rule.enabled then return null; end if;
    v_sev := coalesce(rule.severity, v_sev);
    if rule.repeat_minutes is not null and v_sev <> 'urgent'
       and not exists (select 1 from public.platform_alerts a where a.kind = p_kind and a.business_id is not distinct from p_business_id
                          and a.dedupe_key = coalesce(p_dedupe_key, '') and a.status <> 'resolved') then
      select a.id into v_id from public.platform_alerts a where a.kind = p_kind and a.business_id is not distinct from p_business_id
         and a.dedupe_key = coalesce(p_dedupe_key, '') and a.status = 'resolved' and a.resolved_at > now() - make_interval(mins => rule.repeat_minutes)
       order by a.resolved_at desc limit 1;
      if v_id is not null then return v_id; end if;   -- resolved too recently to raise again
    end if;
  end if;
  insert into public.platform_alerts (kind, title, detail, severity, business_id, dedupe_key, meta)
  values (p_kind, p_title, left(p_detail, 1000), v_sev, p_business_id, coalesce(p_dedupe_key, ''), coalesce(p_meta, '{}'::jsonb))
  on conflict (kind, coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), dedupe_key) where status <> 'resolved'
  do update set occurrences = platform_alerts.occurrences + 1, last_seen_at = now(), detail = coalesce(excluded.detail, platform_alerts.detail), meta = platform_alerts.meta || excluded.meta
  returning id into v_id;
  return v_id;
end $function$;

create or replace function public.zella_admin_alert_rules()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_admin_require('businesses.view');
  return jsonb_build_object('protected', to_jsonb(public.zella_alert_protected_kinds()),
    'rules', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'enabled', r.enabled, 'severity', r.severity, 'destination', r.destination,
               'email_permission', r.email_permission, 'repeat_minutes', r.repeat_minutes, 'quiet_start', r.quiet_start, 'quiet_end', r.quiet_end,
               'quiet_tz', r.quiet_tz, 'updated_at', r.updated_at, 'updated_by', (select u.email from auth.users u where u.id = r.updated_by)) order by r.kind)
               from public.platform_alert_rules r), '[]'::jsonb),
    -- how often each kind was raised lately, so the editor can show which kinds are live
    'seen', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from public.platform_alerts where first_seen_at > now() - interval '30 days' group by kind) x), '{}'::jsonb));
end $$;
revoke all on function public.zella_admin_alert_rules() from public, anon;
grant execute on function public.zella_admin_alert_rules() to authenticated, service_role;

create or replace function public.zella_admin_alert_rule_save(p_kind text, p_rule jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); v_old public.platform_alert_rules; v_new public.platform_alert_rules;
  v_protected boolean; r jsonb := p_rule;
begin
  perform public.zella_admin_require('platform.configure');
  if p_kind is null or p_kind !~ '^[a-z][a-z0-9_]{1,60}$' then raise exception 'INVALID_KIND'; end if;
  v_protected := p_kind = any (public.zella_alert_protected_kinds());
  select * into v_old from public.platform_alert_rules where kind = p_kind;
  if r is null or jsonb_typeof(r) = 'null' then
    delete from public.platform_alert_rules where kind = p_kind;
    if v_old.kind is not null then
      perform public.zella_admin_audit('alert_rule.removed', 'alert_rule', null, null, to_jsonb(v_old) - 'updated_by', jsonb_build_object('kind', p_kind, 'reason', v_reason));
    end if;
    return jsonb_build_object('kind', p_kind, 'removed', v_old.kind is not null);
  end if;
  if jsonb_typeof(r) <> 'object' then raise exception 'INVALID_RULE'; end if;
  if r ? 'enabled' and jsonb_typeof(r -> 'enabled') <> 'boolean' then raise exception 'INVALID_RULE'; end if;
  if coalesce(r ->> 'severity', 'warning') not in ('info', 'warning', 'urgent') then raise exception 'INVALID_SEVERITY'; end if;
  if coalesce(r ->> 'destination', 'bell_and_email') not in ('bell', 'bell_and_email') then raise exception 'INVALID_DESTINATION'; end if;
  if r ->> 'email_permission' is not null and r ->> 'email_permission' !~ '^[a-z]+\.[a-z]+$' then raise exception 'INVALID_PERMISSION'; end if;
  if r ->> 'repeat_minutes' is not null and (r ->> 'repeat_minutes' !~ '^[0-9]{1,5}$' or (r ->> 'repeat_minutes')::int not between 5 and 10080) then raise exception 'INVALID_REPEAT'; end if;
  if (r ->> 'quiet_start' is null) <> (r ->> 'quiet_end' is null)
     or (r ->> 'quiet_start' is not null and (r ->> 'quiet_start' !~ '^[0-2][0-9]:[0-5][0-9]$' or r ->> 'quiet_end' !~ '^[0-2][0-9]:[0-5][0-9]$')) then
    raise exception 'INVALID_QUIET_HOURS';
  end if;
  if r ->> 'quiet_tz' is not null and not exists (select 1 from pg_timezone_names where name = r ->> 'quiet_tz') then raise exception 'INVALID_TIMEZONE'; end if;
  -- urgent kinds can be rerouted, never switched off or lowered
  if v_protected and (coalesce((r ->> 'enabled')::boolean, true) = false or coalesce(r ->> 'severity', 'urgent') <> 'urgent') then raise exception 'URGENT_PROTECTED'; end if;
  insert into public.platform_alert_rules (kind, enabled, severity, destination, email_permission, repeat_minutes, quiet_start, quiet_end, quiet_tz, updated_by, updated_at)
  values (p_kind, coalesce((r ->> 'enabled')::boolean, true), r ->> 'severity', coalesce(r ->> 'destination', 'bell_and_email'), r ->> 'email_permission',
          (r ->> 'repeat_minutes')::int, (r ->> 'quiet_start')::time, (r ->> 'quiet_end')::time, coalesce(r ->> 'quiet_tz', 'America/New_York'), auth.uid(), now())
  on conflict (kind) do update set enabled = excluded.enabled, severity = excluded.severity, destination = excluded.destination,
    email_permission = excluded.email_permission, repeat_minutes = excluded.repeat_minutes, quiet_start = excluded.quiet_start,
    quiet_end = excluded.quiet_end, quiet_tz = excluded.quiet_tz, updated_by = excluded.updated_by, updated_at = excluded.updated_at
  returning * into v_new;
  perform public.zella_admin_audit('alert_rule.saved', 'alert_rule', null, null,
    case when v_old.kind is null then null else to_jsonb(v_old) - 'updated_by' - 'updated_at' end,
    (to_jsonb(v_new) - 'updated_by' - 'updated_at') || jsonb_build_object('reason', v_reason));
  return to_jsonb(v_new) - 'updated_by';
end $$;
revoke all on function public.zella_admin_alert_rule_save(text, jsonb, text) from public, anon;
grant execute on function public.zella_admin_alert_rule_save(text, jsonb, text) to authenticated, service_role;

commit;
