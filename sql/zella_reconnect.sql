-- Zella - reconnection flow (checklist 258). Safe to run more than once. Run AFTER zella_calendar_sync.sql and zella_meta.sql.
--   * a calendar that loses access now tells the owners right away (before, only the platform admin was alerted)
--   * every day, owners are reminded about any connection still waiting to be reconnected (calendar, Facebook/Instagram/WhatsApp)
--   * zella_connections_to_reconnect(business) feeds the "Reconnect" buttons in the app
create or replace function public.zella_calendar_mark_error(p_connection_id uuid, p_error text, p_fatal boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_was text;
begin
  select status into v_was from public.calendar_connections where id = p_connection_id;
  update public.calendar_connections
     set last_error = left(p_error, 300),
         status = case when p_fatal then 'error' else status end,
         busy_refresh_due_at = case when p_fatal then null else busy_refresh_due_at end
   where id = p_connection_id returning business_id into v_biz;
  if v_biz is null then return false; end if;
  if p_fatal then
    perform public.zella_platform_alert('calendar_disconnected', 'A business calendar needs to be connected again', left(p_error, 300), 'warning', v_biz, 'cal-' || p_connection_id::text);
    if v_was is distinct from 'error' then
      perform public.zella_notify_owners(v_biz, 'calendar_disconnected', 'Reconnect your calendar',
        'Zella lost access to your calendar, so new bookings are not being added to it and busy times are not being read. Reconnect it in Settings.', 'urgent', 'settings');
    end if;
  end if;
  return true;
end $$;
revoke execute on function public.zella_calendar_mark_error(uuid,text,boolean) from public, anon, authenticated;
grant execute on function public.zella_calendar_mark_error(uuid,text,boolean) to service_role;

create or replace function public.zella_connections_to_reconnect(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'label') from (
      select jsonb_build_object('kind', 'calendar', 'label', 'Calendar', 'reason', coalesce(left(last_error, 120), 'Needs to be connected again')) x
        from public.calendar_connections where business_id = p_business_id and status = 'error'
      union all
      select jsonb_build_object('kind', 'meta', 'label', coalesce(page_name, 'Facebook/Instagram'), 'reason', coalesce(left(last_error, 120), 'Needs to be connected again'))
        from public.meta_connections where business_id = p_business_id and status in ('needs_reconnect', 'error')) y), '[]'::jsonb);
end $$;
revoke execute on function public.zella_connections_to_reconnect(uuid) from public, anon;
grant execute on function public.zella_connections_to_reconnect(uuid) to authenticated, service_role;

-- daily: one reminder per business, only for connections broken for more than a day
create or replace function public.zella_remind_reconnects() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in
    select business_id, string_agg(label, ' and ') as what from (
      select business_id, 'calendar' as label from public.calendar_connections
       where status = 'error' and coalesce(last_pushed_at, last_pulled_at, connected_at) < now() - interval '1 day'
      union
      select business_id, 'Facebook/Instagram' from public.meta_connections
       where status = 'needs_reconnect' and coalesce(last_checked_at, now()) < now() - interval '1 day') x
     group by business_id loop
    perform public.zella_notify_owners(r.business_id, 'reconnect_reminder', 'Still not connected: ' || r.what,
      'Reconnect in Settings so bookings, messages and leads keep flowing.', 'warning', 'settings');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_remind_reconnects() from public, anon, authenticated;
grant execute on function public.zella_remind_reconnects() to service_role;
