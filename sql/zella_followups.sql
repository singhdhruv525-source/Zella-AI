-- =========================================================
-- Zella: follow-up calls and texts (no-shows, missed calls, new leads...)
-- and "find me a free time" for the AI receptionist.
--
-- Run AFTER zella_crm_details.sql. Safe to run again.
--
-- How it works
--   1. When an appointment becomes "no_show", and the business has the
--      "No-show follow-up" automation switched on, a task is queued.
--   2. n8n asks for due tasks (zella_claim_followup_tasks), has the Vapi
--      assistant place the call or sends the text, then reports the result
--      (zella_complete_followup_task).
--   3. The assistant finds new times with zella_available_slots, which
--      respects working hours, breaks, time off and existing bookings.
--   Calls only go out inside the business's calling window, never to
--   people marked "do not contact", and never for paused or ended plans.
-- =========================================================

alter table public.customers
  add column if not exists do_not_contact boolean not null default false;

create table if not exists public.followup_tasks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  appointment_id uuid references public.appointments(id) on delete cascade,
  call_id uuid,
  -- same names as the automations: no_show_follow_up, missed_call_follow_up, new_lead_callback...
  kind text not null,
  channel text not null default 'call' check (channel in ('call', 'sms')),
  due_at timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'in_progress', 'done', 'failed', 'cancelled', 'skipped')),
  attempts integer not null default 0,
  max_attempts integer not null default 2,
  -- rescheduled, wants_callback, declined, no_answer, voicemail, sms_sent, failed,
  -- do_not_contact, business_inactive
  outcome text,
  outcome_notes text,
  provider_call_id text,
  claimed_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists followup_tasks_due_idx
  on public.followup_tasks (due_at) where status = 'pending';
create index if not exists followup_tasks_business_idx
  on public.followup_tasks (business_id, created_at desc);
create index if not exists followup_tasks_customer_idx
  on public.followup_tasks (customer_id, created_at desc);

-- One live no-show task per appointment.
create unique index if not exists followup_tasks_one_per_appointment_idx
  on public.followup_tasks (appointment_id, kind)
  where appointment_id is not null and status in ('pending', 'in_progress');

alter table public.followup_tasks enable row level security;

drop policy if exists followup_tasks_member_select on public.followup_tasks;
create policy followup_tasks_member_select on public.followup_tasks
  for select to authenticated
  using (exists (select 1 from public.business_members m
                 where m.business_id = followup_tasks.business_id
                   and m.user_id = auth.uid() and m.status = 'active'));

-- Members can read tasks. They are created and updated only by the
-- functions below, never straight from the browser.
revoke insert, update, delete on public.followup_tasks from authenticated, anon;
grant select on public.followup_tasks to authenticated;

-- ---------------------------------------------------------
-- The next moment a call may be placed: inside the window, in the
-- business's own time zone.
-- ---------------------------------------------------------
create or replace function public.zella_next_call_time(
  p_at timestamptz,
  p_timezone text,
  p_start time default '09:00',
  p_end time default '19:00'
) returns timestamptz
language plpgsql
immutable
set search_path = public
as $$
declare
  v_tz text := coalesce(nullif(p_timezone, ''), 'America/New_York');
  v_local timestamp := p_at at time zone v_tz;
  v_time time := v_local::time;
begin
  if v_time >= p_start and v_time < p_end then
    return p_at;
  end if;
  if v_time < p_start then
    return (v_local::date + p_start) at time zone v_tz;
  end if;
  return ((v_local::date + 1) + p_start) at time zone v_tz;
end;
$$;

-- ---------------------------------------------------------
-- Queue the no-show call, or cancel it if the appointment is put right.
-- ---------------------------------------------------------
create or replace function public.zella_queue_no_show_followup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auto record;
  v_tz text;
  v_minutes integer;
  v_channel text;
  v_cust record;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- No longer a no-show (rescheduled, marked done...): drop any waiting call.
  if old.status = 'no_show' and new.status <> 'no_show' then
    update public.followup_tasks
       set status = 'cancelled', outcome = coalesce(outcome, 'appointment_changed'),
           completed_at = now(), updated_at = now()
     where appointment_id = new.id and kind = 'no_show_follow_up' and status = 'pending';
    return new;
  end if;

  if new.status <> 'no_show' or new.customer_id is null then
    return new;
  end if;

  -- Only for businesses with this automation live ("active").
  select a.* into v_auto
    from public.automations a
   where a.business_id = new.business_id
     and a.trigger_type = 'no_show_follow_up'
     and a.status = 'active'
   limit 1;
  if not found then
    return new;
  end if;

  select c.phone, c.do_not_contact into v_cust from public.customers c where c.id = new.customer_id;
  if not found or coalesce(v_cust.do_not_contact, false) or nullif(trim(coalesce(v_cust.phone, '')), '') is null then
    return new;
  end if;

  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = new.business_id;
  v_minutes := coalesce((v_auto.trigger_config ->> 'minutes_after')::integer, 15);
  v_channel := case when v_auto.trigger_config ->> 'channel' = 'sms' then 'sms' else 'call' end;

  insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
  values (
    new.business_id, new.customer_id, new.id, 'no_show_follow_up', v_channel,
    public.zella_next_call_time(
      now() + make_interval(mins => v_minutes), v_tz,
      coalesce((v_auto.trigger_config ->> 'window_start')::time, '09:00'),
      coalesce((v_auto.trigger_config ->> 'window_end')::time, '19:00')
    ),
    coalesce((v_auto.trigger_config ->> 'max_attempts')::integer, 2)
  )
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists zella_no_show_followup on public.appointments;
create trigger zella_no_show_followup
  after update of status on public.appointments
  for each row execute function public.zella_queue_no_show_followup();

-- ---------------------------------------------------------
-- For n8n (service role): take the next due tasks.
-- ---------------------------------------------------------
create or replace function public.zella_claim_followup_tasks(
  p_limit integer default 10,
  p_kinds text[] default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_task record;
  v_biz record;
  v_cust record;
  v_appt record;
  v_next timestamptz;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at
     limit greatest(1, least(coalesce(p_limit, 10), 50))
     for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone,
           b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email, coalesce(c.do_not_contact, false) as do_not_contact
      into v_cust from public.customers c where c.id = v_task.customer_id;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or v_cust.do_not_contact or nullif(trim(coalesce(v_cust.phone, '')), '') is null then
      update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;

    -- Outside the calling window: try again when it opens.
    v_next := public.zella_next_call_time(now(), v_biz.timezone);
    if v_next > now() + interval '1 minute' then
      update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
      continue;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt
      from public.appointments a where a.id = v_task.appointment_id;

    update public.followup_tasks
       set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now()
     where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id,
      'kind', v_task.kind,
      'channel', v_task.channel,
      'attempt', v_task.attempts + 1,
      'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object(
        'id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name,
        'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time,
        'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end
    ));
  end loop;
  return v_result;
end;
$$;

-- ---------------------------------------------------------
-- For n8n (service role): report what happened.
-- ---------------------------------------------------------
create or replace function public.zella_complete_followup_task(
  p_task_id uuid,
  p_outcome text,
  p_notes text default null,
  p_provider_call_id text default null,
  p_call_id uuid default null,
  p_retry_in_minutes integer default 120
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task record;
  v_tz text;
  v_status text;
begin
  select * into v_task from public.followup_tasks where id = p_task_id for update;
  if not found then
    raise exception 'TASK_NOT_FOUND';
  end if;
  if p_outcome not in ('rescheduled', 'wants_callback', 'declined', 'no_answer', 'voicemail', 'sms_sent', 'failed') then
    raise exception 'BAD_OUTCOME';
  end if;

  if p_outcome in ('no_answer', 'voicemail', 'failed') and v_task.attempts < v_task.max_attempts then
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = v_task.business_id;
    update public.followup_tasks
       set status = 'pending', outcome = p_outcome, outcome_notes = p_notes,
           provider_call_id = coalesce(p_provider_call_id, provider_call_id),
           call_id = coalesce(p_call_id, call_id),
           due_at = public.zella_next_call_time(now() + make_interval(mins => greatest(5, coalesce(p_retry_in_minutes, 120))), v_tz),
           updated_at = now()
     where id = p_task_id;
    return 'retry_scheduled';
  end if;

  v_status := case when p_outcome = 'failed' then 'failed' else 'done' end;
  update public.followup_tasks
     set status = v_status, outcome = p_outcome, outcome_notes = p_notes,
         provider_call_id = coalesce(p_provider_call_id, provider_call_id),
         call_id = coalesce(p_call_id, call_id),
         completed_at = now(), updated_at = now()
   where id = p_task_id;

  -- They asked for a person to call them back: put it in "Needs attention".
  if p_outcome = 'wants_callback' and coalesce(p_call_id, v_task.call_id) is not null then
    update public.calls
       set needs_human = true,
           escalation_reason = coalesce(nullif(p_notes, ''), 'Asked for a call back after a missed appointment'),
           escalated_at = now(), escalation_resolved_at = null, updated_at = now()
     where id = coalesce(p_call_id, v_task.call_id);
  end if;
  return v_status;
end;
$$;

-- ---------------------------------------------------------
-- Members can cancel a call that hasn't gone out yet.
-- ---------------------------------------------------------
create or replace function public.zella_cancel_followup_task(p_task_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
begin
  select business_id into v_business from public.followup_tasks where id = p_task_id;
  if v_business is null or not exists (
    select 1 from public.business_members m
     where m.business_id = v_business and m.user_id = auth.uid() and m.status = 'active'
  ) then
    raise exception 'NOT_ALLOWED';
  end if;
  update public.followup_tasks
     set status = 'cancelled', outcome = 'cancelled_by_team', completed_at = now(), updated_at = now()
   where id = p_task_id and status = 'pending';
  return found;
end;
$$;

-- ---------------------------------------------------------
-- Free times for a booking: working hours, breaks, time off and existing
-- bookings all respected. Used by the AI receptionist when it reschedules.
-- ---------------------------------------------------------
drop function if exists public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer);
create or replace function public.zella_available_slots(
  p_business_id uuid,
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '7 days',
  p_duration_minutes integer default 30,
  p_staff_id uuid default null,
  p_step_minutes integer default 30,
  p_limit integer default 12,
  p_ignore_appointment uuid default null
) returns table (slot_start timestamptz, slot_end timestamptz, staff_id uuid, staff_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tz text;
  v_duration interval := make_interval(mins => greatest(5, coalesce(p_duration_minutes, 30)));
  v_step interval := make_interval(mins => greatest(5, coalesce(p_step_minutes, 30)));
  v_has_staff boolean;
begin
  -- Members can look for their own business; the service role can look for any.
  if auth.uid() is not null and not exists (
    select 1 from public.business_members m
     where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active'
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  if v_tz is null then
    raise exception 'BUSINESS_NOT_FOUND';
  end if;
  select exists (select 1 from public.staff_members s where s.business_id = p_business_id and s.is_active) into v_has_staff;

  return query
  with people as (
    select s.id as sid, s.name as sname, s.working_hours as hours
      from public.staff_members s
     where s.business_id = p_business_id and s.is_active and (p_staff_id is null or s.id = p_staff_id)
    union all
    select null::uuid, null::text, '{}'::jsonb
     where not v_has_staff
  ),
  candidates as (
    select p.sid, p.sname, p.hours, g.t as t
      from people p,
           generate_series(
             date_trunc('hour', greatest(p_from, now())) + (ceil(extract(minute from greatest(p_from, now())) / extract(minute from v_step)) * v_step),
             p_to, v_step) as g(t)
  ),
  checked as (
    select c.*,
           (c.t at time zone v_tz) as lstart,
           ((c.t + v_duration) at time zone v_tz) as lend,
           to_char(c.t at time zone v_tz, 'dy') as dow
      from candidates c
  ),
  resolved as (
    select k.*,
           coalesce(k.hours -> lower(k.dow), '{}'::jsonb) as d
      from checked k
  )
  select r.t, r.t + v_duration, r.sid, r.sname
    from resolved r
   where r.lstart::date = r.lend::date
     -- inside that day's working hours (default Mon-Fri 9-5 when none are set)
     and (
       case
         when r.hours = '{}'::jsonb then
           r.dow not in ('sat', 'sun') and r.lstart::time >= time '09:00' and r.lend::time <= time '17:00'
         else
           coalesce((r.d ->> 'on')::boolean, false)
           and r.lstart::time >= coalesce(nullif(r.d ->> 'start', '')::time, time '09:00')
           and r.lend::time <= coalesce(nullif(r.d ->> 'end', '')::time, time '17:00')
           and not (
             nullif(r.d ->> 'break_start', '') is not null and nullif(r.d ->> 'break_end', '') is not null
             and r.lstart::time < (r.d ->> 'break_end')::time and r.lend::time > (r.d ->> 'break_start')::time
           )
       end
     )
     -- not in blocked time (business-wide or this person)
     and not exists (
       select 1 from public.blocked_times bt
        where bt.business_id = p_business_id
          and (bt.staff_id is null or bt.staff_id = r.sid)
          and bt.start_time < r.t + v_duration and bt.end_time > r.t
     )
     -- not on top of another booking for the same person
     and not exists (
       select 1 from public.appointments a
        where a.business_id = p_business_id
          and a.status not in ('cancelled', 'no_show', 'completed')
          and (p_ignore_appointment is null or a.id <> p_ignore_appointment)
          -- a request without a confirmed time, or an expired hold, does not block a slot
          and coalesce(to_jsonb(a) ->> 'booking_state', 'confirmed') <> 'requested'
          and not (coalesce(to_jsonb(a) ->> 'booking_state', '') = 'tentative' and coalesce((to_jsonb(a) ->> 'hold_expires_at')::timestamptz, now() + interval '1 minute') < now())
          and (r.sid is null or a.staff_id = r.sid)
          and a.start_time < r.t + v_duration and a.end_time > r.t
     )
   order by r.t, r.sname nulls last
   limit greatest(1, least(coalesce(p_limit, 12), 50));
end;
$$;

revoke all on function public.zella_next_call_time(timestamptz, text, time, time) from public, anon;
revoke all on function public.zella_claim_followup_tasks(integer, text[]) from public, anon, authenticated;
revoke all on function public.zella_complete_followup_task(uuid, text, text, text, uuid, integer) from public, anon, authenticated;
revoke all on function public.zella_cancel_followup_task(uuid) from public, anon;
revoke all on function public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer, uuid) from public, anon;

grant execute on function public.zella_next_call_time(timestamptz, text, time, time) to authenticated, service_role;
grant execute on function public.zella_claim_followup_tasks(integer, text[]) to service_role;
grant execute on function public.zella_complete_followup_task(uuid, text, text, text, uuid, integer) to service_role;
grant execute on function public.zella_cancel_followup_task(uuid) to authenticated, service_role;
grant execute on function public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer, uuid) to authenticated, service_role;
