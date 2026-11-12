-- Rollback zella_workflow_alert_email.sql: restore the preceding email claim definition.
begin;
do $guard$ declare v text; begin
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_claim_admin_alert_email(integer)');
  if v is null or v not in ('2ad910b9dcd8f270ff2f46061259033f', '1f8a35cff22ae78eeedaffd7897f3299') then
    raise exception 'VERSION_MISMATCH: zella_claim_admin_alert_email(integer)';
  end if;
end $guard$;
CREATE OR REPLACE FUNCTION public.zella_claim_admin_alert_email(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_to jsonb; v_alerts jsonb;
begin
  select coalesce(jsonb_agg(distinct lower(trim(u.email))), '[]'::jsonb) into v_to
  from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null and not exists (select 1 from public.admin_alert_prefs ap where ap.user_id = p.user_id and not ap.email_enabled);
  if not v_live or v_from is null or jsonb_array_length(v_to) = 0 then
    return jsonb_build_object('alerts', '[]'::jsonb, 'to', v_to, 'live', v_live, 'from', v_from,
                              'why', case when not v_live then 'email_off' when v_from is null then 'no_sender' else 'no_admins' end);
  end if;
  with c as (
    update public.platform_alerts a set notified_at = now(),
           meta = coalesce(a.meta, '{}'::jsonb) || jsonb_build_object('email_claimed_at', now())
                  || case when a.notified_at is null then '{}'::jsonb
                          else jsonb_build_object('email_attempts', coalesce((a.meta ->> 'email_attempts')::int, 0) + 1) end
    where a.id in (select s.id from public.platform_alerts s
                   where s.status = 'open'
                     and (s.notified_at is null
                          -- claimed by this version, never finished (no emailed_at), retried at most 3 times in all
                          or (s.meta ? 'email_claimed_at' and not s.meta ? 'emailed_at' and s.notified_at < now() - interval '15 minutes'
                              and coalesce((s.meta ->> 'email_attempts')::int, 0) < 2))
                   order by case s.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, s.first_seen_at
                   limit greatest(1, least(coalesce(p_limit, 25), 50)) for update skip locked)
    returning a.id, a.kind, a.severity, a.title, a.detail, a.occurrences, a.first_seen_at, a.last_seen_at, a.business_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'severity', c.severity, 'title', c.title, 'detail', c.detail,
           'occurrences', c.occurrences, 'first_seen_at', c.first_seen_at, 'last_seen_at', c.last_seen_at, 'business', b.name)
           order by case c.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, c.first_seen_at), '[]'::jsonb)
    into v_alerts from c left join public.businesses b on b.id = c.business_id;
  return jsonb_build_object('alerts', v_alerts, 'to', v_to, 'live', true, 'from', v_from, 'from_name', 'Zella Voice');
end $function$;
commit;
