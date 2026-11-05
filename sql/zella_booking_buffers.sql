-- Zella - the gap between appointments, and no double booking on any path (5 Nov 2026). Safe to run twice. Not applied.
-- Defect B1 (was D3b in docs/SETUP_FIELD_TRACE_2026-11-05.md); report: docs/BOOKING_RULES_2026-11-05.md. Class V.
--
-- B1  Setup saves "Buffer between appointments" (ai_agent_configs.appointment_rules.buffer_minutes, 0-120), but nothing
--     read it: a 10:00-10:30 booking left 10:30 open even with a 15-minute buffer. zella_available_slots - which offers
--     times to callers, checks every AI booking, hold, reschedule, confirmation of a request, staff-unavailable offer and
--     the customer's own reschedule link - now keeps the buffer on both sides of every booking that holds a time.
-- B2  Only the server booking functions took the per-business booking lock and checked times. The CRM's New booking and
--     Reschedule forms write the table directly, and create_appointment checked nothing, so a team member and the AI
--     receptionist booking the same time at the same moment could both succeed. A last-line guard on the table now takes
--     the same lock and refuses an overlapping booking (buffer included) on every path with SLOT_TAKEN. A team member
--     can still book over another appointment on purpose ("Book anyway" in the CRM); that write carries
--     metadata.allow_overlap, which only signed-in staff can use, is consumed, and is recorded in conflict_note.
--
-- Who conflicts with whom (the same rule zella_available_slots already used):
--   * a business with active staff: bookings of the same staff member; an unassigned booking claims no one;
--   * a business without staff: every booking holds the business's single calendar;
--   * holding a time: scheduled or confirmed bookings that are not "requested" and not an expired hold.
-- Changing only the status, notes or customer of an existing booking is never refused (old overlaps stay as they are),
-- and a booking that has already ended (history, imports) is never refused.

create or replace function public.zella_booking_buffer(p_business_id uuid) returns integer
language sql stable security definer set search_path = '' as $$
  select case when (public.zella_booking_rules(p_business_id) ->> 'buffer_minutes') ~ '^\d{1,3}$'
              then least(120, (public.zella_booking_rules(p_business_id) ->> 'buffer_minutes')::integer) else 0 end;
$$;
revoke execute on function public.zella_booking_buffer(uuid) from public, anon, authenticated;
grant execute on function public.zella_booking_buffer(uuid) to service_role;

-- B1: availability keeps the buffer
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer, uuid)'::regprocedure);
  if position('zella_booking_buffers' in def) = 0 then
    def := replace(def, $a$  v_has_hours boolean;$a$, $a$  v_has_hours boolean;
  v_buffer interval := make_interval(mins => public.zella_booking_buffer(p_business_id)); /* zella_booking_buffers */$a$);
    def := replace(def, $a$          and a.start_time < r.t + v_duration and a.end_time > r.t$a$,
                        $a$          and a.start_time < r.t + v_duration + v_buffer and a.end_time + v_buffer > r.t$a$);
    if position('zella_booking_buffers' in def) = 0 or position('a.end_time + v_buffer > r.t' in def) = 0 then
      raise exception 'zella_available_slots has changed; review this patch';
    end if;
    execute def;
  end if;
end $$;

-- B2: the last-line guard
create or replace function public.zella_appointment_holds_time(p_status text, p_state text, p_hold_expires timestamptz) returns boolean
language sql immutable as $$
  select p_status in ('scheduled', 'confirmed') and coalesce(p_state, 'confirmed') <> 'requested'
     and not (coalesce(p_state, '') = 'tentative' and coalesce(p_hold_expires, 'infinity'::timestamptz) < now());
$$;

create or replace function public.zella_appointment_conflict_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_buf interval; v_has_staff boolean; v_override boolean; v_clash uuid;
begin
  if not public.zella_appointment_holds_time(new.status, new.booking_state, new.hold_expires_at) then return new; end if;
  if new.end_time <= now() then return new; end if;   -- recording a visit that is already over (history, imports) never clashes
  if tg_op = 'UPDATE' and new.start_time = old.start_time and new.end_time = old.end_time and new.staff_id is not distinct from old.staff_id
     and public.zella_appointment_holds_time(old.status, old.booking_state, old.hold_expires_at) then
    return new;   -- nothing about its time changed
  end if;
  v_override := coalesce((new.metadata ->> 'allow_overlap')::boolean, false);
  if v_override then
    new.metadata := new.metadata - 'allow_overlap';
    if auth.uid() is not null and public.zella_can_edit(new.business_id) then
      new.conflict_note := left(coalesce(new.conflict_note || ' ', '') || 'Booked over another appointment by the team (' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' UTC).', 500);
      return new;
    end if;   -- anyone else: the flag is ignored
  end if;
  perform public.zella_booking_lock(new.business_id);   -- the same lock the booking functions hold: concurrent writes queue here
  v_buf := make_interval(mins => public.zella_booking_buffer(new.business_id));
  v_has_staff := exists (select 1 from public.staff_members s where s.business_id = new.business_id and s.is_active);
  if v_has_staff and new.staff_id is null then return new; end if;   -- an unassigned booking claims no one
  select a.id into v_clash from public.appointments a
   where a.business_id = new.business_id and a.id <> new.id
     and public.zella_appointment_holds_time(a.status, a.booking_state, a.hold_expires_at)
     and (not v_has_staff or a.staff_id = new.staff_id)
     and a.start_time < new.end_time + v_buf and a.end_time + v_buf > new.start_time
   limit 1;
  if v_clash is not null then
    raise exception 'SLOT_TAKEN' using detail = 'overlaps another booking' || case when v_buf > interval '0' then ' or its ' || extract(epoch from v_buf)::int / 60 || '-minute gap' else '' end,
      hint = 'Pick another time, or book anyway on purpose.';
  end if;
  return new;
end $$;
revoke execute on function public.zella_appointment_conflict_guard() from public, anon, authenticated;
drop trigger if exists zella_appointment_conflict_guard on public.appointments;
create trigger zella_appointment_conflict_guard before insert or update of start_time, end_time, staff_id, status, booking_state on public.appointments
  for each row execute function public.zella_appointment_conflict_guard();

-- hygiene from the 5 Nov production advisor run
alter function public.zella_capability_catalog() set search_path = '';
alter function public.zella_asset_type_keys() set search_path = '';
revoke execute on function public.zella_capability_appointment_trg() from public, anon, authenticated;
