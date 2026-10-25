-- Zella - appointment flow for staff (checklist 31, 42, 44, 46). Safe to run more than once.
-- Needs zella_run_all.sql (appointments, notifications) and zella_attendance.sql.
--   31  a customer already gets a confirmation text/email when an appointment is booked (zella_replace_reminders); nothing new needed
--   42  staff are told about new appointments, and the person an appointment is assigned to is told when it is moved or cancelled
--   44  a customer can text HERE / ARRIVED (see zella_reply_actions.sql); staff are told when someone has arrived
--   46  an appointment that ended with no attendance recorded becomes a task for staff; nothing is assumed from the clock
create or replace function public.zella_appointment_new_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text; v_tz text; v_when text; v_req boolean;
begin
  if new.status not in ('scheduled', 'confirmed') or new.start_time <= now() - interval '1 hour' then return new; end if;
  select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), new.title, 'A customer') into v_who from public.customers c where c.id = new.customer_id;
  v_who := coalesce(v_who, new.title, 'A customer');
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = new.business_id;
  v_when := to_char(new.start_time at time zone v_tz, 'Dy Mon FMDD "at" FMHH12:MI AM');
  v_req := coalesce(new.booking_state, 'confirmed') = 'requested';
  perform public.zella_notify(new.business_id, case when v_req then 'appointment_request' else 'appointment_new' end,
    case when v_req then 'Appointment request to confirm' else 'New appointment' end, v_who || ' - ' || v_when || '.', 'info', 'calendar', new.id, new.assigned_to);
  return new;
exception when others then
  return new;   -- a notice problem must never block saving an appointment
end $$;
drop trigger if exists zella_appointment_new on public.appointments;
create trigger zella_appointment_new after insert on public.appointments for each row execute function public.zella_appointment_new_trg();

create or replace function public.zella_appointment_staff_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text; v_tz text; v_when text; v_big boolean;
begin
  if new.assigned_to is null then return new; end if;
  -- owners and admins already get the general notices
  v_big := exists (select 1 from public.business_members m where m.business_id = new.business_id and m.user_id = new.assigned_to and m.status = 'active' and m.role in ('owner', 'admin'));
  select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), new.title, 'A customer') into v_who from public.customers c where c.id = new.customer_id;
  v_who := coalesce(v_who, new.title, 'A customer');
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = new.business_id;
  v_when := to_char(new.start_time at time zone v_tz, 'Dy Mon FMDD "at" FMHH12:MI AM');
  if new.arrived_at is not null and old.arrived_at is null and new.status in ('scheduled', 'confirmed') then
    perform public.zella_notify(new.business_id, 'customer_arrived', v_who || ' has arrived', 'Appointment ' || v_when || '.', 'info', 'calendar', new.id, new.assigned_to);
  end if;
  if not v_big then
    if new.status = 'cancelled' and old.status <> 'cancelled' then
      perform public.zella_notify(new.business_id, 'appointment_cancelled_mine', 'Your appointment was cancelled', v_who || ' - ' || v_when || '.', 'info', 'calendar', new.id, new.assigned_to);
    elsif new.start_time is distinct from old.start_time and new.status in ('scheduled', 'confirmed') then
      perform public.zella_notify(new.business_id, 'appointment_moved_mine', 'Your appointment was moved', v_who || ' is now ' || v_when || '.', 'info', 'calendar', new.id, new.assigned_to);
    end if;
  end if;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_appointment_staff on public.appointments;
create trigger zella_appointment_staff after update of status, start_time, arrived_at on public.appointments for each row execute function public.zella_appointment_staff_trg();

-- 46: hourly. An appointment that ended more than 2 hours ago with nothing recorded gets one task; it is never marked completed automatically.
create or replace function public.zella_flag_unrecorded_appointments() returns integer
language plpgsql security definer set search_path = public as $$
declare a record; n integer := 0; v_who text;
begin
  for a in select ap.id, ap.business_id, ap.customer_id, ap.assigned_to, ap.title, ap.end_time from public.appointments ap
            where ap.status in ('scheduled', 'confirmed') and ap.end_time < now() - interval '2 hours' and ap.end_time > now() - interval '7 days'
              and ap.arrived_at is null and ap.checked_in_at is null and ap.in_service_at is null
              and not exists (select 1 from public.crm_tasks t where t.kind = 'record_attendance' and t.entity_id = ap.id)
            order by ap.end_time limit 100 loop
    select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), a.title, 'a customer') into v_who from public.customers c where c.id = a.customer_id;
    v_who := coalesce(v_who, a.title, 'a customer');
    perform public.zella_create_task(a.business_id, a.customer_id, 'record_attendance', 'Did ' || v_who || ' come in? Mark completed or no-show', 'The appointment ended and nothing was recorded.', 'normal', now() + interval '1 day', a.assigned_to, 'automation', a.id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_flag_unrecorded_appointments() from public, anon, authenticated;
grant execute on function public.zella_flag_unrecorded_appointments() to service_role;
