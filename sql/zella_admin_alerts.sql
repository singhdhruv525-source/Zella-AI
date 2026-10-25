-- Zella AI: email platform alerts to Zella admins (n8n workflow "Zella - Admin Alerts").
-- Needs: platform_alerts, platform_admins, zella_setting. Safe to run more than once.
-- Alerts come from the whole platform: offers (ending soon, limit reached, unusual claims, failed to go live,
-- completed), failed scheduled jobs, provider problems and more. They are always visible in the database;
-- this only adds an email digest. Nothing is claimed until email sending is switched on (email_live) and a
-- sender address is set, so no alert is used up while email is off.

create or replace function public.zella_claim_admin_alert_email(p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_to jsonb; v_alerts jsonb;
begin
  select coalesce(jsonb_agg(distinct lower(trim(u.email))), '[]'::jsonb) into v_to
  from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null;
  if not v_live or v_from is null or jsonb_array_length(v_to) = 0 then
    return jsonb_build_object('alerts', '[]'::jsonb, 'to', v_to, 'live', v_live, 'from', v_from,
                              'why', case when not v_live then 'email_off' when v_from is null then 'no_sender' else 'no_admins' end);
  end if;
  with c as (
    update public.platform_alerts a set notified_at = now()
    where a.id in (select s.id from public.platform_alerts s
                   where s.notified_at is null and s.status = 'open'
                   order by case s.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, s.first_seen_at
                   limit greatest(1, least(coalesce(p_limit, 25), 50)) for update skip locked)
    returning a.id, a.kind, a.severity, a.title, a.detail, a.occurrences, a.first_seen_at, a.last_seen_at, a.business_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'severity', c.severity, 'title', c.title, 'detail', c.detail,
           'occurrences', c.occurrences, 'first_seen_at', c.first_seen_at, 'last_seen_at', c.last_seen_at, 'business', b.name)
           order by case c.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, c.first_seen_at), '[]'::jsonb)
    into v_alerts from c left join public.businesses b on b.id = c.business_id;
  return jsonb_build_object('alerts', v_alerts, 'to', v_to, 'live', true, 'from', v_from, 'from_name', 'Zella');
end $$;

-- n8n reports back. A failed send puts the alerts back for the next run, up to 3 tries, then gives up
-- (the alerts stay open and visible in the dashboard; only the email is abandoned).
create or replace function public.zella_finish_admin_alert_email(p_ids uuid[], p_ok boolean, p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_released integer := 0; v_dropped integer := 0;
begin
  if p_ok then
    update public.platform_alerts set meta = meta || jsonb_build_object('emailed_at', now()) where id = any (coalesce(p_ids, array[]::uuid[]));
    return jsonb_build_object('ok', true);
  end if;
  with u as (
    update public.platform_alerts
       set meta = meta || jsonb_build_object('email_attempts', coalesce((meta ->> 'email_attempts')::int, 0) + 1, 'email_error', left(p_error, 200)),
           notified_at = case when coalesce((meta ->> 'email_attempts')::int, 0) + 1 < 3 then null else notified_at end
     where id = any (coalesce(p_ids, array[]::uuid[]))
    returning notified_at)
  select count(*) filter (where notified_at is null), count(*) filter (where notified_at is not null) into v_released, v_dropped from u;
  return jsonb_build_object('ok', false, 'retry', v_released, 'gave_up', v_dropped);
end $$;

revoke all on function public.zella_claim_admin_alert_email(integer) from public, anon, authenticated;
revoke all on function public.zella_finish_admin_alert_email(uuid[], boolean, text) from public, anon, authenticated;
grant execute on function public.zella_claim_admin_alert_email(integer) to service_role;
grant execute on function public.zella_finish_admin_alert_email(uuid[], boolean, text) to service_role;
