-- Zella - Google Calendar sync. Safe to run more than once.
-- Needs zella_run_all.sql (appointments, blocked_times, platform alerts).
-- Zella's own calendar (this database) stays the source of truth for free times and bookings, so the phone assistant
-- is fast and can never double-book. Google Calendar is kept in step both ways:
--   OUT: every confirmed booking, move or cancel is copied to the business's Google Calendar (a queue; n8n delivers it)
--   IN : the busy times in the business's own Google Calendar become blocked times here, so those slots are not offered
-- Nothing happens until calendar_sync_live is true AND a business has connected its calendar. Dry-run by default.

insert into public.platform_settings (key, value) values ('calendar_sync_live', 'false'::jsonb) on conflict (key) do nothing;

create table if not exists public.calendar_connections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider text not null default 'google' check (provider in ('google')),
  status text not null default 'active' check (status in ('active', 'paused', 'error', 'disconnected')),
  calendar_id text not null default 'primary',
  account_email text,
  vault_secret_name text,
  connected_at timestamptz not null default now(),
  last_pushed_at timestamptz,
  last_pulled_at timestamptz,
  busy_refresh_due_at timestamptz,
  last_error text,
  unique (business_id, provider)
);
alter table public.calendar_connections enable row level security;
revoke all on public.calendar_connections from anon, authenticated;
grant select (id, business_id, provider, status, calendar_id, account_email, connected_at, last_pushed_at, last_pulled_at, last_error) on public.calendar_connections to authenticated;
do $$ begin
  create policy calendar_connections_member_read on public.calendar_connections for select to authenticated
    using (exists (select 1 from public.business_members m where m.business_id = calendar_connections.business_id and m.user_id = auth.uid() and m.status = 'active'));
exception when duplicate_object then null; end $$;

alter table public.blocked_times add column if not exists source text, add column if not exists external_id text, add column if not exists connection_id uuid;
create unique index if not exists blocked_times_external_idx on public.blocked_times (connection_id, external_id) where external_id is not null;

create table if not exists public.calendar_sync_queue (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  action text not null check (action in ('upsert', 'delete')),
  status text not null default 'pending' check (status in ('pending', 'in_progress', 'done', 'failed', 'skipped')),
  attempts integer not null default 0,
  due_at timestamptz not null default now(),
  claimed_at timestamptz,
  event_id text,
  error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create unique index if not exists calendar_sync_queue_one_pending_idx on public.calendar_sync_queue (appointment_id) where status = 'pending';
create index if not exists calendar_sync_queue_due_idx on public.calendar_sync_queue (status, due_at);
alter table public.calendar_sync_queue enable row level security;
revoke all on public.calendar_sync_queue from anon, authenticated;

-- A booking changed: queue the copy for businesses that connected a calendar. Confirmed bookings only.
create or replace function public.zella_queue_calendar_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_action text; v_state text := coalesce(to_jsonb(new) ->> 'booking_state', 'confirmed');
begin
  if not exists (select 1 from public.calendar_connections c where c.business_id = new.business_id and c.status = 'active') then return new; end if;
  if new.status in ('cancelled', 'no_show') or v_state = 'requested' then
    if new.external_event_id is null then return new; end if;
    v_action := 'delete';
  elsif v_state = 'tentative' or new.status not in ('scheduled', 'confirmed', 'completed') then
    return new;
  else
    v_action := 'upsert';
  end if;
  insert into public.calendar_sync_queue (business_id, appointment_id, action) values (new.business_id, new.id, v_action)
  on conflict (appointment_id) where status = 'pending' do update set action = excluded.action, due_at = now();
  return new;
end $$;
drop trigger if exists zella_calendar_sync_trg on public.appointments;
create trigger zella_calendar_sync_trg after insert or update of start_time, end_time, status, title, staff_id, booking_state, customer_id on public.appointments
  for each row execute function public.zella_queue_calendar_sync();

-- Used by the "Connect Google Calendar" step (a server function, later). The refresh token is stored in Vault; only its name is kept here.
create or replace function public.zella_calendar_connect(p_business_id uuid, p_account_email text, p_refresh_token text, p_calendar_id text default 'primary')
returns uuid language plpgsql security definer set search_path = public, vault as $$
declare v_name text := 'zella_gcal_' || p_business_id::text; v_id uuid;
begin
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then raise exception 'NO_TOKEN'; end if;
  if exists (select 1 from vault.secrets where name = v_name) then
    perform vault.update_secret((select id from vault.secrets where name = v_name), p_refresh_token);
  else
    perform vault.create_secret(p_refresh_token, v_name);
  end if;
  insert into public.calendar_connections (business_id, provider, status, calendar_id, account_email, vault_secret_name, busy_refresh_due_at, last_error)
  values (p_business_id, 'google', 'active', coalesce(nullif(trim(p_calendar_id), ''), 'primary'), left(p_account_email, 200), v_name, now(), null)
  on conflict (business_id, provider) do update set status = 'active', calendar_id = excluded.calendar_id, account_email = excluded.account_email,
    vault_secret_name = excluded.vault_secret_name, busy_refresh_due_at = now(), last_error = null
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.zella_calendar_live() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.zella_setting('calendar_sync_live', 'false'::jsonb) = 'true'::jsonb, false);
$$;

-- OUT: take queued copies. Returns nothing unless sync is live.
create or replace function public.zella_claim_calendar_sync(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public, vault as $$
declare v_res jsonb := '[]'::jsonb; q record; a record; c record; b record; cu record; v_token text; v_tz text;
begin
  if not public.zella_calendar_live() then return v_res; end if;
  for q in select * from public.calendar_sync_queue where status = 'pending' and due_at <= now()
            order by due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked loop
    select * into c from public.calendar_connections where business_id = q.business_id and status = 'active';
    select * into a from public.appointments where id = q.appointment_id;
    if c.id is null or a.id is null then
      update public.calendar_sync_queue set status = 'skipped', error = 'no_active_connection_or_appointment', completed_at = now() where id = q.id; continue;
    end if;
    select decrypted_secret into v_token from vault.decrypted_secrets where name = c.vault_secret_name limit 1;
    if v_token is null then
      update public.calendar_sync_queue set status = 'failed', error = 'no_token', completed_at = now() where id = q.id;
      update public.calendar_connections set status = 'error', last_error = 'The calendar needs to be connected again.' where id = c.id;
      continue;
    end if;
    select coalesce(timezone, 'America/New_York') as tz, name into b from public.businesses where id = q.business_id;
    select nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '') as nm, phone into cu from public.customers where id = a.customer_id;
    update public.calendar_sync_queue set status = 'in_progress', attempts = attempts + 1, claimed_at = now() where id = q.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'queue_id', q.id, 'action', q.action, 'appointment_id', a.id, 'event_id', a.external_event_id, 'attempt', q.attempts + 1,
      'calendar_id', c.calendar_id, 'refresh_token', v_token,
      'event', jsonb_build_object(
        'summary', left(coalesce(nullif(trim(a.title), ''), 'Appointment') || coalesce(' - ' || cu.nm, ''), 200),
        'description', left('Booked with Zella.' || coalesce(E'\nCustomer: ' || cu.nm, '') || coalesce(E'\nPhone: ' || cu.phone, '') || coalesce(E'\nNotes: ' || a.description, ''), 1000),
        'start', a.start_time, 'end', a.end_time, 'timezone', b.tz)));
  end loop;
  return v_res;
end $$;

create or replace function public.zella_finish_calendar_sync(p_queue_id uuid, p_ok boolean, p_event_id text default null, p_error text default null)
returns text language plpgsql security definer set search_path = public as $$
declare q record;
begin
  select * into q from public.calendar_sync_queue where id = p_queue_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if q.status <> 'in_progress' then return 'ignored'; end if;
  if p_ok then
    update public.calendar_sync_queue set status = 'done', event_id = left(p_event_id, 200), error = null, completed_at = now() where id = q.id;
    update public.appointments set external_event_id = case when q.action = 'delete' then null else coalesce(left(p_event_id, 200), external_event_id) end where id = q.appointment_id;
    update public.calendar_connections set last_pushed_at = now(), last_error = null where business_id = q.business_id and provider = 'google';
    return 'done';
  end if;
  if q.attempts < 5 then
    update public.calendar_sync_queue set status = 'pending', due_at = now() + make_interval(mins => 5 * q.attempts), error = left(p_error, 300) where id = q.id;
    return 'retry';
  end if;
  update public.calendar_sync_queue set status = 'failed', error = left(p_error, 300), completed_at = now() where id = q.id;
  update public.calendar_connections set last_error = left(p_error, 300) where business_id = q.business_id and provider = 'google';
  if not exists (select 1 from public.staff_notifications where business_id = q.business_id and kind = 'calendar_sync_owner' and created_at > now() - interval '12 hours') then
    perform public.zella_notify_owners(q.business_id, 'calendar_sync_owner', 'A booking is not on your calendar', 'Zella could not copy a booking to Google Calendar. The booking itself is saved. Check the calendar connection in Settings.', 'warning', 'settings');
  end if;
  perform public.zella_platform_alert('calendar_sync_failed', 'A booking could not be copied to Google Calendar', left(p_error, 300), 'warning', q.business_id, q.appointment_id::text);
  return 'failed';
end $$;

-- IN: connections whose busy times need refreshing (a change notice from Google, or the hourly safety check).
create or replace function public.zella_claim_calendar_pulls(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public, vault as $$
declare v_res jsonb := '[]'::jsonb; c record; v_token text;
begin
  if not public.zella_calendar_live() then return v_res; end if;
  for c in select * from public.calendar_connections where status = 'active' and busy_refresh_due_at <= now()
            order by busy_refresh_due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked loop
    select decrypted_secret into v_token from vault.decrypted_secrets where name = c.vault_secret_name limit 1;
    if v_token is null then
      update public.calendar_connections set status = 'error', last_error = 'The calendar needs to be connected again.', busy_refresh_due_at = null where id = c.id; continue;
    end if;
    update public.calendar_connections set busy_refresh_due_at = now() + interval '15 minutes' where id = c.id;   -- a failed pull is tried again later
    v_res := v_res || jsonb_build_array(jsonb_build_object('connection_id', c.id, 'business_id', c.business_id, 'calendar_id', c.calendar_id,
      'refresh_token', v_token, 'from', now() - interval '1 day', 'to', now() + interval '60 days'));
  end loop;
  return v_res;
end $$;

-- p_events: [{id, start, end, all_day}] for busy events only. Replaces this connection's imported blocks from yesterday on.
-- Events Zella itself created are ignored (the booking already blocks that time).
create or replace function public.zella_replace_calendar_busy(p_connection_id uuid, p_events jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare c record; e jsonb; n integer := 0; v_s timestamptz; v_e timestamptz;
begin
  select * into c from public.calendar_connections where id = p_connection_id and status = 'active';
  if c.id is null then return 0; end if;
  if jsonb_typeof(p_events) <> 'array' then raise exception 'BAD_EVENTS'; end if;
  delete from public.blocked_times where connection_id = c.id and source = 'google' and end_time >= now() - interval '1 day';
  for e in select * from jsonb_array_elements(p_events) limit 500 loop
    begin v_s := (e ->> 'start')::timestamptz; v_e := (e ->> 'end')::timestamptz; exception when others then continue; end;
    if v_s is null or v_e is null or v_e <= v_s or (e ->> 'id') is null then continue; end if;
    if exists (select 1 from public.appointments a where a.business_id = c.business_id and a.external_event_id = e ->> 'id') then continue; end if;
    insert into public.blocked_times (business_id, title, reason, start_time, end_time, all_day, source, external_id, connection_id)
    values (c.business_id, 'Busy (Google Calendar)', 'Busy in the business calendar', v_s, v_e, coalesce((e ->> 'all_day')::boolean, false), 'google', left(e ->> 'id', 200), c.id)
    on conflict (connection_id, external_id) where external_id is not null do update set start_time = excluded.start_time, end_time = excluded.end_time, all_day = excluded.all_day;
    n := n + 1;
  end loop;
  update public.calendar_connections set last_pulled_at = now(), busy_refresh_due_at = null, last_error = null where id = c.id;
  return n;
end $$;

-- Safety net, hourly inside Supabase: ask for a refresh of every connected calendar (Google's change notices do the rest).
create or replace function public.zella_schedule_calendar_pulls() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.zella_calendar_live() then return 0; end if;
  update public.calendar_connections set busy_refresh_due_at = now() where status = 'active' and busy_refresh_due_at is null and coalesce(last_pulled_at, 'epoch') < now() - interval '55 minutes';
  get diagnostics n = row_count; return n;
end $$;

-- A change notice from Google arrived for this calendar: refresh its busy times now.
create or replace function public.zella_calendar_changed(p_connection_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.calendar_connections set busy_refresh_due_at = least(coalesce(busy_refresh_due_at, now()), now()) where id = p_connection_id and status = 'active';
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_queue_calendar_sync()', 'zella_calendar_connect(uuid,text,text,text)', 'zella_calendar_live()', 'zella_claim_calendar_sync(integer)',
      'zella_finish_calendar_sync(uuid,boolean,text,text)', 'zella_claim_calendar_pulls(integer)', 'zella_replace_calendar_busy(uuid,jsonb)',
      'zella_schedule_calendar_pulls()', 'zella_calendar_changed(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- A busy-time refresh that could not read the calendar: keep a short note; a fatal one (access removed) pauses the link.
create or replace function public.zella_calendar_mark_error(p_connection_id uuid, p_error text, p_fatal boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_biz uuid;
begin
  update public.calendar_connections
     set last_error = left(p_error, 300),
         status = case when p_fatal then 'error' else status end,
         busy_refresh_due_at = case when p_fatal then null else busy_refresh_due_at end
   where id = p_connection_id returning business_id into v_biz;
  if v_biz is null then return false; end if;
  if p_fatal then
    perform public.zella_platform_alert('calendar_disconnected', 'A business calendar needs to be connected again', left(p_error, 300), 'warning', v_biz, 'cal-' || p_connection_id::text);
  end if;
  return true;
end $$;
revoke execute on function public.zella_calendar_mark_error(uuid,text,boolean) from public, anon, authenticated;
grant execute on function public.zella_calendar_mark_error(uuid,text,boolean) to service_role;
