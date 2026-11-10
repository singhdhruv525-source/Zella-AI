-- Zella - monitoring (checklist 90, 268, 269, 309). Safe to run more than once.
-- Needs zella_run_all.sql (notifications, platform alerts, events), zella_connection_health.sql and zella_meta.sql.
--   90  customers waiting too long for a reply are flagged to owners; a report shows how fast the team replies
--   268 a platform admin can send a failed event back to be processed again (businesses already retry their own failed work: zella_retry_failed)
--   269 a business sees the state of its connections; the platform admin sees the state of providers, alerts and failures
--   309 the platform admin can tell every active business about an incident, and tell them when it is over
insert into public.platform_settings (key, value) values ('response_time_minutes', '60'::jsonb) on conflict (key) do nothing;

-- 90: every 15 minutes
create or replace function public.zella_check_response_times() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0; v_min integer := greatest(10, coalesce((public.zella_setting('response_time_minutes', '60'::jsonb) #>> '{}')::int, 60));
begin
  for r in
    select business_id, count(*) as waiting, array_agg(id) as ids from public.sms_messages m
     where m.direction = 'inbound' and m.status = 'received' and m.created_at between now() - interval '24 hours' and now() - make_interval(mins => v_min)
       and coalesce(m.metadata ->> 'slow_notified', '') = ''
       and upper(regexp_replace(coalesce(m.message_body, ''), '[^A-Za-z]', '', 'g')) not in ('STOP','STOPALL','UNSUBSCRIBE','CANCEL','END','QUIT','START','UNSTOP','HELP','YES','Y','OK','OKAY','CONFIRM','CONFIRMED','HERE','ARRIVED','THANKS','THANKYOU','')
       and (public.zella_business_open(m.business_id) ->> 'open')::boolean
       and not exists (select 1 from public.sms_messages o where o.business_id = m.business_id and o.direction = 'outbound' and o.created_at > m.created_at
                         and (o.customer_id = m.customer_id and m.customer_id is not null or o.to_number = m.from_number))
     group by business_id loop
    perform public.zella_notify_owners(r.business_id, 'slow_reply', r.waiting || (case when r.waiting = 1 then ' text is' else ' texts are' end) || ' waiting for a reply',
      'Customers have been waiting more than ' || v_min || ' minutes. Open the inbox to reply.', 'warning', 'inbox');
    update public.sms_messages set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('slow_notified', now()) where id = any (r.ids);
    n := n + 1;
  end loop;
  for r in
    select business_id, count(*) as waiting, array_agg(id) as ids from public.email_messages m
     where m.direction = 'inbound' and m.created_at between now() - interval '24 hours' and now() - make_interval(mins => v_min * 4)
       and coalesce(m.metadata ->> 'slow_notified', '') = ''
       and (public.zella_business_open(m.business_id) ->> 'open')::boolean
       and not exists (select 1 from public.email_messages o where o.business_id = m.business_id and o.direction = 'outbound' and o.created_at > m.created_at
                         and (o.customer_id = m.customer_id and m.customer_id is not null))
     group by business_id loop
    perform public.zella_notify_owners(r.business_id, 'slow_reply', r.waiting || (case when r.waiting = 1 then ' email is' else ' emails are' end) || ' waiting for a reply',
      'Open the inbox to reply.', 'warning', 'inbox');
    update public.email_messages set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('slow_notified', now()) where id = any (r.ids);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_check_response_times() from public, anon, authenticated;
grant execute on function public.zella_check_response_times() to service_role;

create or replace function public.zella_response_time_report(p_business_id uuid, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365))); v_res jsonb;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  with first_reply as (
    select m.id, m.created_at,
           (select min(o.created_at) from public.sms_messages o where o.business_id = m.business_id and o.direction = 'outbound' and o.created_at > m.created_at
               and (o.customer_id = m.customer_id and m.customer_id is not null or o.to_number = m.from_number)) as replied_at
      from public.sms_messages m
     where m.business_id = p_business_id and m.direction = 'inbound' and m.status = 'received' and m.created_at > now() - d)
  select jsonb_build_object(
    'texts_received', count(*),
    'replied', count(replied_at),
    'waiting', count(*) filter (where replied_at is null and created_at < now() - interval '15 minutes'),
    'median_minutes', round((percentile_cont(0.5) within group (order by extract(epoch from (replied_at - created_at)) / 60) filter (where replied_at is not null))::numeric, 1),
    'average_minutes', round((avg(extract(epoch from (replied_at - created_at)) / 60) filter (where replied_at is not null))::numeric, 1),
    'replied_within_hour', count(*) filter (where replied_at is not null and replied_at < created_at + interval '1 hour'))
    into v_res from first_reply;
  return v_res;
end $$;
revoke execute on function public.zella_response_time_report(uuid, integer) from public, anon;
grant execute on function public.zella_response_time_report(uuid, integer) to authenticated, service_role;

-- 269: one business
create or replace function public.zella_integration_summary(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_items jsonb := '[]'::jsonb; v_n integer; v_bad integer := 0; v_status text; v_err text;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select count(*) into v_n from public.business_phone_numbers where business_id = p_business_id and status = 'active';
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'phone', 'label', 'Phone number', 'ok', v_n > 0, 'detail', case when v_n > 0 then v_n || ' active' else 'No phone number connected' end));
  select status, last_error into v_status, v_err from public.calendar_connections where business_id = p_business_id order by connected_at desc nulls last limit 1;
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'calendar', 'label', 'Calendar', 'ok', v_status = 'active', 'detail', case when v_status is null then 'Not connected' when v_status = 'active' then 'Connected' else 'Needs attention: ' || coalesce(left(v_err, 100), v_status) end));
  select count(*), count(*) filter (where status <> 'connected') into v_n, v_bad from public.meta_connections where business_id = p_business_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'social', 'label', 'Facebook, Instagram, WhatsApp', 'ok', v_n > 0 and v_bad = 0, 'detail', case when v_n = 0 then 'Not connected' when v_bad = 0 then 'Connected' else v_bad || ' need to be reconnected' end));
  select count(*) into v_n from public.sms_messages where business_id = p_business_id and direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours';
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'texts', 'label', 'Texts sent in the last day', 'ok', v_n = 0, 'detail', case when v_n = 0 then 'No failures' else v_n || ' failed' end));
  select count(*) into v_n from public.email_messages where business_id = p_business_id and direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours';
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'emails', 'label', 'Emails sent in the last day', 'ok', v_n = 0, 'detail', case when v_n = 0 then 'No failures' else v_n || ' failed' end));
  return jsonb_build_object('items', v_items, 'all_ok', not exists (select 1 from jsonb_array_elements(v_items) i where (i ->> 'ok')::boolean = false));
end $$;
revoke execute on function public.zella_integration_summary(uuid) from public, anon;
grant execute on function public.zella_integration_summary(uuid) to authenticated, service_role;

-- 269: the platform
create or replace function public.zella_platform_health_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'providers', coalesce((select jsonb_agg(jsonb_build_object('provider', provider, 'ok', ok, 'detail', detail, 'checked_at', checked_at, 'failures_in_a_row', consecutive_failures)) from public.provider_health), '[]'::jsonb),
    'open_alerts', coalesce((select jsonb_object_agg(severity, c) from (select severity, count(*) c from public.platform_alerts where status = 'open' group by severity) x), '{}'::jsonb),
    'failed_events_24h', (select count(*) from public.automation_events where status = 'failed' and received_at > now() - interval '24 hours'),
    'businesses_active', (select count(*) from public.businesses where suspended_at is null and cancelled_at is null),
    'businesses_with_failed_messages_24h', (select count(distinct business_id) from public.sms_messages where direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours'));
end $$;
revoke execute on function public.zella_platform_health_summary() from public, anon;
grant execute on function public.zella_platform_health_summary() to authenticated, service_role;

-- 268: platform admin sends a failed event back
create or replace function public.zella_retry_event(p_event_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  update public.automation_events set status = 'received', attempts = 0, next_attempt_at = now(), claimed_at = null, error_category = null, error_message = null
   where id = p_event_id and status = 'failed';
  if not found then raise exception 'NOT_RETRYABLE'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  select business_id, auth.uid(), 'event_retried', 'automation_event', id, '{}'::jsonb from public.automation_events where id = p_event_id;
  return 'queued';
end $$;
revoke execute on function public.zella_retry_event(uuid) from public, anon;
grant execute on function public.zella_retry_event(uuid) to authenticated, service_role;

-- 309: incidents
create table if not exists public.platform_incidents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  detail text,
  status text not null default 'open' check (status in ('open', 'resolved')),
  notified_businesses integer not null default 0,
  created_by uuid,
  resolution_note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz);
alter table public.platform_incidents enable row level security;
drop policy if exists platform_incidents_admin on public.platform_incidents;
create policy platform_incidents_admin on public.platform_incidents for select to authenticated using (public.is_platform_admin());
revoke all on public.platform_incidents from anon;
grant select on public.platform_incidents to authenticated;

create or replace function public.zella_open_incident(p_title text, p_detail text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; b record; n integer := 0;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if length(trim(coalesce(p_title, ''))) < 3 then raise exception 'TITLE_REQUIRED'; end if;
  insert into public.platform_incidents (title, detail, created_by) values (left(trim(p_title), 200), left(p_detail, 1000), auth.uid()) returning id into v_id;
  for b in select id from public.businesses where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    perform public.zella_notify_owners(b.id, 'incident_open', left(trim(p_title), 120), coalesce(left(p_detail, 300), 'We are working on it and will tell you when it is fixed.'), 'warning', 'home');
    n := n + 1;
  end loop;
  update public.platform_incidents set notified_businesses = n where id = v_id;
  return v_id;
end $$;
revoke execute on function public.zella_open_incident(text, text) from public, anon;
grant execute on function public.zella_open_incident(text, text) to authenticated, service_role;

create or replace function public.zella_resolve_incident(p_incident_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare i public.platform_incidents; b record;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into i from public.platform_incidents where id = p_incident_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if i.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  update public.platform_incidents set status = 'resolved', resolved_at = now(), resolution_note = left(p_note, 500) where id = i.id;
  for b in select id from public.businesses where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    perform public.zella_notify_owners(b.id, 'incident_resolved', 'Fixed: ' || left(i.title, 110), coalesce(left(p_note, 300), 'Everything is working again.'), 'info', 'home');
  end loop;
end $$;
revoke execute on function public.zella_resolve_incident(uuid, text) from public, anon;
grant execute on function public.zella_resolve_incident(uuid, text) to authenticated, service_role;
