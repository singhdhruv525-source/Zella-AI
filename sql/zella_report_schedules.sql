-- Zella - the daily report follows each business's own schedule (5 Nov 2026). Safe to run twice. Not applied.
-- Requirement 6 (docs/REQUIREMENTS_STATUS_2026-11-05.md); defect R6-1. Class A (owner notifications only; no customer
-- messages).
--
-- R6-1  zella_post_daily_summaries sent every business's report at 08:00 business time to its owners, whatever was set
--       up: no other hour, recipients or period, no record of when it ran or will run, and a missed hour was simply
--       skipped. Now each business has a schedule (business_report_schedules):
--         * hour (0-23) in the business's own time zone, daylight saving included: the run is due at that local hour on
--           each local date. The dispatcher runs hourly, so reports go out within that hour; minutes are not offered;
--         * recipients by role (owner / admin / manager; never staff or view-only), each receiving it in the CRM;
--         * period: yesterday (the business's local calendar day) or the last 24 hours;
--         * enabled or not.
--       Every run is recorded once per local date (business_report_runs: sent / nothing to report / failed / missed), so
--       a second dispatcher run, a retry or overlapping jobs never send twice. A run the dispatcher missed is caught up
--       later the same local day (up to 6 hours late), and after that recorded as missed rather than sent at a wrong
--       hour. Last run and next run are shown to the owner.
--       Contents follow the business: its own terminology (appointments, reservations, jobs, sessions...), its enabled
--       record types' open and due work (zella_today_operations), and bookings only where it takes bookings.
-- No time is assumed: the report time is chosen when the business is created (setup wizard, Automations step) and can be
-- changed later in the CRM (Settings > Reporting). A business with no chosen time gets no daily report. The old job's
-- fixed 08:00 goes; production had no active business on 5 Nov, so no one stops receiving a report [config].

create table if not exists public.business_report_schedules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null default 'daily_summary' check (kind in ('daily_summary')),
  enabled boolean not null default true,
  local_hour integer not null check (local_hour between 0 and 23),   -- chosen at setup; never defaulted
  recipient_roles text[] not null default '{owner}' check (recipient_roles <@ array['owner', 'admin', 'manager'] and cardinality(recipient_roles) > 0),
  period text not null default 'yesterday' check (period in ('yesterday', 'last_24_hours')),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  unique (business_id, kind)
);
create table if not exists public.business_report_runs (
  schedule_id uuid not null references public.business_report_schedules(id) on delete cascade,
  local_date date not null,
  status text not null check (status in ('sent', 'nothing_to_report', 'failed', 'missed')),
  recipients integer not null default 0,
  error text,
  ran_at timestamptz not null default now(),
  primary key (schedule_id, local_date)
);
alter table public.business_report_schedules enable row level security;
alter table public.business_report_runs enable row level security;
revoke all on public.business_report_schedules, public.business_report_runs from anon, authenticated;
grant select, insert, update, delete on public.business_report_schedules, public.business_report_runs to service_role;

-- (an earlier draft of this file gave every business a default schedule and a trigger for new ones: removed, so no time
-- is ever assumed)
drop trigger if exists zella_report_schedule_default on public.businesses;
drop function if exists public.zella_report_schedule_default_trg();

-- when it is next due (business time), given what has run
create or replace function public.zella_report_next_run(p_schedule_id uuid, p_now timestamptz default now()) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare s record; v_tz text; v_today date; v_due timestamptz;
begin
  select x.*, coalesce(nullif(b.timezone, ''), 'America/New_York') tz into s
    from business_report_schedules x join businesses b on b.id = x.business_id where x.id = p_schedule_id;
  if not found or not s.enabled then return null; end if;
  v_tz := s.tz; v_today := (p_now at time zone v_tz)::date;
  v_due := (v_today + make_time(s.local_hour, 0, 0)) at time zone v_tz;
  if exists (select 1 from business_report_runs r where r.schedule_id = s.id and r.local_date = v_today) or p_now > v_due + interval '6 hours' then
    v_due := ((v_today + 1) + make_time(s.local_hour, 0, 0)) at time zone v_tz;
  end if;
  return v_due;
end $$;

-- the report itself (owner-level business data; recipients are owners, admins or managers of this business only)
create or replace function public.zella_report_build(p_business_id uuid, p_period text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b record; v_tz text; v_from timestamptz; v_to timestamptz; v_day_start timestamptz; t jsonb; v_calls int; v_missed int; v_booked int;
        v_leads int; v_today int; v_overdue int; v_ops text; v_lines text[] := '{}'; v_appt text; v_appts text; v_sched boolean;
begin
  select x.id, x.name, coalesce(nullif(x.timezone, ''), 'America/New_York') tz, coalesce(ic.terminology, '{}'::jsonb) term
    into b from businesses x left join industry_configurations ic on ic.industry_id = x.industry_id where x.id = p_business_id;
  v_tz := b.tz; t := b.term;
  v_day_start := date_trunc('day', p_now at time zone v_tz) at time zone v_tz;
  if p_period = 'last_24_hours' then v_from := p_now - interval '24 hours'; v_to := p_now;
  else v_from := v_day_start - interval '1 day'; v_to := v_day_start; end if;   -- yesterday, local calendar day (23 or 25 h across DST)
  -- the local day boundaries are recomputed so a DST change gives the real local day
  if p_period <> 'last_24_hours' then v_from := ((p_now at time zone v_tz)::date - 1)::timestamp at time zone v_tz; v_to := ((p_now at time zone v_tz)::date)::timestamp at time zone v_tz; end if;
  v_appt := lower(coalesce(t ->> 'appointment', 'appointment')); v_appts := lower(coalesce(t ->> 'appointments', v_appt || 's'));
  v_sched := public.zella_capability_on(p_business_id, 'scheduling');
  select count(*), count(*) filter (where c.status in ('missed', 'failed'))
    into v_calls, v_missed from calls c where c.business_id = p_business_id and c.created_at >= v_from and c.created_at < v_to;
  select count(*) into v_booked from appointments a where a.business_id = p_business_id and a.created_at >= v_from and a.created_at < v_to and coalesce(a.booking_state, 'confirmed') <> 'requested';
  select count(*) into v_leads from customers x where x.business_id = p_business_id and x.created_at >= v_from and x.created_at < v_to;
  select count(*) into v_today from appointments a where a.business_id = p_business_id and a.start_time >= v_day_start and a.start_time < v_day_start + interval '1 day'
     and a.status in ('scheduled', 'confirmed') and coalesce(a.booking_state, 'confirmed') = 'confirmed';
  select count(*) into v_overdue from callbacks cb where cb.business_id = p_business_id and cb.status not in ('completed', 'cancelled', 'needs_review') and cb.due_at < p_now;
  select string_agg(format('%s %s open (%s due today, %s overdue)', (o ->> 'open'), lower(o ->> 'plural'), (o ->> 'due_today'), (o ->> 'overdue')), '; ')
    into v_ops from jsonb_array_elements(public.zella_today_operations(p_business_id)) o where (o ->> 'open')::int > 0;
  v_lines := array[format('%s: %s call(s), %s missed, %s new %s.', case when p_period = 'last_24_hours' then 'Last 24 hours' else 'Yesterday' end,
                          v_calls, v_missed, v_leads, lower(coalesce(t ->> 'customers', 'customers')))];
  if v_sched then v_lines := v_lines || format('%s %s booked; %s today.', v_booked, v_appts, v_today); end if;
  if v_ops is not null then v_lines := v_lines || (v_ops || '.'); end if;
  if v_overdue > 0 then v_lines := v_lines || format('%s callback(s) overdue.', v_overdue); end if;
  return jsonb_build_object('title', 'Your day with Zella - ' || b.name, 'body', array_to_string(v_lines, ' '),
    'has_content', v_calls + v_leads + v_booked + v_today + v_overdue > 0 or v_ops is not null, 'severity', case when v_overdue > 0 or v_missed > 0 then 'warning' else 'info' end,
    'period', jsonb_build_object('from', v_from, 'to', v_to));
end $$;

-- one pass at a given moment (tests pass a moment; the dispatcher's hourly job below passes now())
create or replace function public.zella_run_daily_reports(p_now timestamptz) returns integer
language plpgsql security definer set search_path = public as $$
declare s record; v_now timestamptz := p_now; v_local timestamp; v_date date; v_due timestamptz; r jsonb; u record; n_users int; n integer := 0;
begin
  for s in select x.*, coalesce(nullif(b.timezone, ''), 'America/New_York') tz from business_report_schedules x join businesses b on b.id = x.business_id
            where x.kind = 'daily_summary' and x.enabled and b.onboarding_status = 'active' and b.suspended_at is null and b.cancelled_at is null loop
    begin
      v_local := v_now at time zone s.tz; v_date := v_local::date;
      v_due := (v_date + make_time(s.local_hour, 0, 0)) at time zone s.tz;
      if v_now < v_due then continue; end if;                                               -- not yet today
      if exists (select 1 from business_report_runs where schedule_id = s.id and local_date = v_date) then continue; end if;   -- already ran today
      if v_now > v_due + interval '6 hours' then                                            -- too late to be useful: record, don't send
        insert into business_report_runs (schedule_id, local_date, status, error) values (s.id, v_date, 'missed', 'The scheduler did not run within 6 hours of the report time.')
        on conflict do nothing;
        continue;
      end if;
      -- claim the day first, so a parallel run can't send it too
      insert into business_report_runs (schedule_id, local_date, status) values (s.id, v_date, 'sent') on conflict do nothing;
      if not found then continue; end if;
      r := public.zella_report_build(s.business_id, s.period, v_now);
      if not (r ->> 'has_content')::boolean then
        update business_report_runs set status = 'nothing_to_report' where schedule_id = s.id and local_date = v_date; continue;
      end if;
      n_users := 0;
      for u in select distinct m.user_id from business_members m where m.business_id = s.business_id and m.status = 'active' and m.role = any (s.recipient_roles) loop
        perform public.zella_notify(s.business_id, 'daily_summary', r ->> 'title', r ->> 'body', r ->> 'severity', 'reports', null, u.user_id);
        n_users := n_users + 1;
      end loop;
      update business_report_runs set recipients = n_users where schedule_id = s.id and local_date = v_date;
      n := n + 1;
    exception when others then
      insert into business_report_runs (schedule_id, local_date, status, error) values (s.id, v_date, 'failed', left(sqlerrm, 300))
      on conflict (schedule_id, local_date) do update set status = 'failed', error = excluded.error;
    end;
  end loop;
  return n;
end $$;

-- the dispatcher's hourly job (same name, so the existing schedule keeps calling it)
create or replace function public.zella_post_daily_summaries() returns integer
language sql security definer set search_path = public as $$ select public.zella_run_daily_reports(now()) $$;

-- owners, admins and managers see the schedule with its last and next run; owners and admins change it
create or replace function public.zella_report_schedules(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kind', s.kind, 'enabled', s.enabled, 'local_hour', s.local_hour, 'recipient_roles', s.recipient_roles,
            'period', s.period, 'timezone', coalesce(nullif(b.timezone, ''), 'America/New_York'), 'next_run_at', public.zella_report_next_run(s.id),
            'last_run', (select jsonb_build_object('date', r.local_date, 'status', r.status, 'recipients', r.recipients, 'error', r.error, 'at', r.ran_at)
                           from business_report_runs r where r.schedule_id = s.id order by r.local_date desc limit 1)))
     from business_report_schedules s join businesses b on b.id = s.business_id where s.business_id = p_business_id), '[]'::jsonb);
end $$;

create or replace function public.zella_set_report_schedule(p_business_id uuid, p_kind text, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old jsonb;
begin
  if auth.uid() is not null and not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_kind <> 'daily_summary' or jsonb_typeof(p_patch) <> 'object' then raise exception 'BAD_INPUT'; end if;
  if p_patch ? 'local_hour' and not (jsonb_typeof(p_patch -> 'local_hour') = 'number' and (p_patch ->> 'local_hour') ~ '^\d{1,2}$' and (p_patch ->> 'local_hour')::int between 0 and 23) then raise exception 'BAD_HOUR'; end if;
  if p_patch ? 'period' and p_patch ->> 'period' not in ('yesterday', 'last_24_hours') then raise exception 'BAD_PERIOD'; end if;
  if p_patch ? 'recipient_roles' and (jsonb_typeof(p_patch -> 'recipient_roles') <> 'array' or jsonb_array_length(p_patch -> 'recipient_roles') = 0
       or exists (select 1 from jsonb_array_elements_text(p_patch -> 'recipient_roles') x where x not in ('owner', 'admin', 'manager'))) then raise exception 'BAD_RECIPIENTS'; end if;
  if p_patch ? 'enabled' and jsonb_typeof(p_patch -> 'enabled') <> 'boolean' then raise exception 'BAD_INPUT'; end if;
  select to_jsonb(s) - 'id' - 'business_id' into v_old from business_report_schedules s where s.business_id = p_business_id and s.kind = p_kind;
  if not exists (select 1 from business_report_schedules where business_id = p_business_id and kind = p_kind) then
    if not p_patch ? 'local_hour' then raise exception 'HOUR_REQUIRED' using hint = 'Choose when the report is sent.'; end if;
    insert into business_report_schedules (business_id, kind, local_hour) values (p_business_id, p_kind, (p_patch ->> 'local_hour')::int);
  end if;
  update business_report_schedules set
      enabled = coalesce((p_patch ->> 'enabled')::boolean, enabled),
      local_hour = coalesce((p_patch ->> 'local_hour')::int, local_hour),
      period = coalesce(p_patch ->> 'period', period),
      recipient_roles = case when p_patch ? 'recipient_roles' then array(select distinct jsonb_array_elements_text(p_patch -> 'recipient_roles')) else recipient_roles end,
      updated_by = auth.uid(), updated_at = now()
   where business_id = p_business_id and kind = p_kind;
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'report_schedule_changed', 'business', p_business_id, v_old, p_patch);
  return public.zella_report_schedules(p_business_id);
end $$;

revoke execute on function public.zella_report_next_run(uuid, timestamptz), public.zella_report_build(uuid, text, timestamptz), public.zella_post_daily_summaries(),
  public.zella_run_daily_reports(timestamptz) from public, anon, authenticated;
grant execute on function public.zella_report_next_run(uuid, timestamptz), public.zella_report_build(uuid, text, timestamptz), public.zella_post_daily_summaries(),
  public.zella_run_daily_reports(timestamptz) to service_role;
revoke execute on function public.zella_report_schedules(uuid), public.zella_set_report_schedule(uuid, text, jsonb) from public, anon;
grant execute on function public.zella_report_schedules(uuid), public.zella_set_report_schedule(uuid, text, jsonb) to authenticated, service_role;
