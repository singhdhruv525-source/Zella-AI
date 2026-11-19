-- Zella Voice: admin alert email follows the alert rules (docs/ADMIN_AUDIT_2026-11-16.md SET-ALERT-RULES, part 2).
-- zella_claim_admin_alert_email emailed every waiting alert to every active admin, with no per kind destination or
-- quiet window. Needs sql/zella_alert_rules.sql (the rules table). Now:
--   * a kind whose rule says bell only is not emailed: it is marked handled (meta.email_skipped = bell_only) and stays
--     in the bell. Never for an urgent alert: urgent alerts are always emailed;
--   * a rule's quiet window (local time in its time zone, may cross midnight) holds warning and info alerts until it
--     ends. Never urgent ones or protected kinds: a quiet window never delays them;
--   * a rule's email permission sends that kind only to active admins holding the permission (the Zella Voice owner
--     holds every one); when nobody holds it, every admin gets it, so an alert is never lost;
--   * one call claims one group of recipients (the group of the most urgent waiting alert), so the n8n Admin Alerts
--     workflow keeps sending one digest to "to" and is unchanged; the next run takes the next group.
-- Nothing else changes: the same live switch, sender and per admin opt out checks, the same retry of a claim that
-- never finished (at most 3 tries in all), limits, order and answer (plus "group").
-- Archived first; must match production's version (16 Nov 2026). Email only goes out once email_live is on.
-- Rollback: sql/rollback/zella_alert_rules_email_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_claim_admin_alert_email(integer)'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null or to_regclass('public.platform_alert_rules') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_alert_rules.sql first)';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'cd96d330aa78de5fbb9e4091e1ab77c1' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_alert_rules_email', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> 'b73e43f58bbaf3cc2a939b8e142d1fea' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
end $$;

-- whether a rule's quiet window covers now (start and end in its own time zone; a window may cross midnight)
create or replace function public.zella_alert_quiet_now(p_start time, p_end time, p_tz text)
returns boolean language plpgsql stable set search_path = '' as $$
declare t time;
begin
  if p_start is null or p_end is null or p_start = p_end then return false; end if;
  t := (now() at time zone coalesce(p_tz, 'America/New_York'))::time;
  return case when p_start < p_end then t >= p_start and t < p_end else t >= p_start or t < p_end end;
exception when others then return false;   -- an unknown time zone never holds an alert back
end $$;
revoke all on function public.zella_alert_quiet_now(time, time, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.zella_claim_admin_alert_email(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_to jsonb; v_alerts jsonb; v_first record; v_group text; v_group_to jsonb;
begin
  select coalesce(jsonb_agg(distinct lower(trim(u.email))), '[]'::jsonb) into v_to
  from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null and not exists (select 1 from public.admin_alert_prefs ap where ap.user_id = p.user_id and not ap.email_enabled);
  if not v_live or v_from is null or jsonb_array_length(v_to) = 0 then
    return jsonb_build_object('alerts', '[]'::jsonb, 'to', v_to, 'live', v_live, 'from', v_from,
                              'why', case when not v_live then 'email_off' when v_from is null then 'no_sender' else 'no_admins' end);
  end if;
  -- the alert rules (sql/zella_alert_rules.sql): bell only kinds are handled without an email; urgent alerts always email
  update public.platform_alerts a set notified_at = now(), meta = coalesce(a.meta, '{}'::jsonb) || jsonb_build_object('email_skipped', 'bell_only')
    from public.platform_alert_rules r
   where r.kind = a.kind and r.destination = 'bell' and a.severity <> 'urgent' and not (a.kind = any (public.zella_alert_protected_kinds()))
     and a.notified_at is null and a.status = 'open';
  -- the most urgent alert that may go now (a quiet window holds warning and info, never urgent) picks the recipients
  select s.id, r.email_permission into v_first
    from public.platform_alerts s left join public.platform_alert_rules r on r.kind = s.kind
   where s.status = 'open'
     and (s.notified_at is null
          or (s.meta ? 'email_claimed_at' and not s.meta ? 'emailed_at' and s.notified_at < now() - interval '15 minutes'
              and coalesce((s.meta ->> 'email_attempts')::int, 0) < 2))
     and (s.severity = 'urgent' or s.kind = any (public.zella_alert_protected_kinds()) or r.kind is null
          or not public.zella_alert_quiet_now(r.quiet_start, r.quiet_end, r.quiet_tz))
     -- a bell only kind is never emailed, also not by the retry of a claim made before its rule changed (urgent and
     -- protected kinds always are)
     and (s.severity = 'urgent' or s.kind = any (public.zella_alert_protected_kinds()) or r.kind is null or r.destination is distinct from 'bell')
   order by case s.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, s.first_seen_at limit 1;
  if v_first.id is null then
    return jsonb_build_object('alerts', '[]'::jsonb, 'to', v_to, 'live', true, 'from', v_from, 'from_name', 'Zella Voice', 'group', null);
  end if;
  v_group := v_first.email_permission;
  if v_group is not null then
    select coalesce(jsonb_agg(distinct lower(trim(u.email))), '[]'::jsonb) into v_group_to
      from public.platform_admins p join auth.users u on u.id = p.user_id
     where p.is_active and u.email is not null and not exists (select 1 from public.admin_alert_prefs ap where ap.user_id = p.user_id and not ap.email_enabled)
       and (p.role = 'zella_owner' or (p.role = 'super_admin' and v_group not in ('admins.manage', 'roles.manage'))
            or exists (select 1 from public.platform_role_permissions rp where rp.role = p.role and rp.permission = v_group));
    -- nobody holds the permission: every admin gets it, so an alert is never lost
    if jsonb_array_length(v_group_to) > 0 then v_to := v_group_to; end if;
  end if;
  with c as (
    update public.platform_alerts a set notified_at = now(),
           meta = coalesce(a.meta, '{}'::jsonb) || jsonb_build_object('email_claimed_at', now())
                  || case when a.notified_at is null then '{}'::jsonb
                          else jsonb_build_object('email_attempts', coalesce((a.meta ->> 'email_attempts')::int, 0) + 1) end
    where a.id in (select s.id from public.platform_alerts s left join public.platform_alert_rules r on r.kind = s.kind
                   where s.status = 'open'
                     and r.email_permission is not distinct from v_group
                     and (s.severity = 'urgent' or s.kind = any (public.zella_alert_protected_kinds()) or r.kind is null
          or not public.zella_alert_quiet_now(r.quiet_start, r.quiet_end, r.quiet_tz))
     -- a bell only kind is never emailed, also not by the retry of a claim made before its rule changed (urgent and
     -- protected kinds always are)
     and (s.severity = 'urgent' or s.kind = any (public.zella_alert_protected_kinds()) or r.kind is null or r.destination is distinct from 'bell')
                     and (s.notified_at is null
                          -- claimed by this version, never finished (no emailed_at), retried at most 3 times in all
                          or (s.meta ? 'email_claimed_at' and not s.meta ? 'emailed_at' and s.notified_at < now() - interval '15 minutes'
                              and coalesce((s.meta ->> 'email_attempts')::int, 0) < 2))
                   order by case s.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, s.first_seen_at
                   limit greatest(1, least(coalesce(p_limit, 25), 50)) for update of s skip locked)
    returning a.id, a.kind, a.severity, a.title, a.detail, a.occurrences, a.first_seen_at, a.last_seen_at, a.business_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'severity', c.severity, 'title', c.title, 'detail', c.detail,
           'occurrences', c.occurrences, 'first_seen_at', c.first_seen_at, 'last_seen_at', c.last_seen_at, 'business', b.name)
           order by case c.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, c.first_seen_at), '[]'::jsonb)
    into v_alerts from c left join public.businesses b on b.id = c.business_id;
  return jsonb_build_object('alerts', v_alerts, 'to', v_to, 'live', true, 'from', v_from, 'from_name', 'Zella Voice', 'group', v_group);
end $function$;

commit;
