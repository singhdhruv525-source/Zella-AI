-- Arrival windows for businesses that come to the customer (plumbing, electrical, HVAC, home services, cleaning,
-- landscaping, pest control, property management). Safe to run twice.
-- Rollback: sql/rollback/zella_arrival_windows_rollback.sql (tests/setup/make_rollback.py windows).
--
-- BM1  Every business booked an exact minute ("Tuesday at 10:30 AM"). A plumber can't promise that; callers of those
--      businesses should hear "between 8 and 10 AM". The receptionist could only offer exact times, so it either
--      promised an arrival time the team can't keep, or the owner switched booking off.
--      Now a business can book arrival windows: appointment_rules.arrival_window_minutes (60 to 480). When it is set:
--        - check_availability offers windows ("Tuesday, November 10 between 8:00 AM and 10:00 AM"), at most five, in
--          order from opening time and never overlapping. A window is offered only if a technician (or the business,
--          without staff) is free for the whole window, after the gap between jobs, holidays and blocked times;
--        - book_appointment holds that whole window for one technician (the job can be anywhere inside it), so two
--          jobs are never promised to the same person at the same time, and tells the caller the team arrives
--          within the window;
--        - every other rule still holds (notice, how far ahead, booking switched off, the table guard).
--      Not set (or 0): exact times, as before. Nothing is assumed: the window is chosen in setup or the CRM.

-- the times to offer: exact slots, or non-overlapping windows taken in order
create or replace function public.zella_booking_choices(p_business_id uuid, p_from timestamptz, p_to timestamptz, p_duration integer, p_window integer, p_limit integer default 5)
returns table (slot_start timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare r record; v_next timestamptz := '-infinity'; n integer := 0;
begin
  if p_window is null then
    return query select s.slot_start from public.zella_available_slots(p_business_id, p_from, p_to, p_duration, null, 30, p_limit, null) s;
    return;
  end if;
  -- whole-hour and half-hour starts that fit a whole window; then the earliest, the next from its end, and so on
  for r in select distinct s.slot_start from public.zella_available_slots(p_business_id, p_from, p_to, p_window, null, 30, 50, null) s order by s.slot_start loop
    if r.slot_start >= v_next then
      slot_start := r.slot_start; return next;
      v_next := r.slot_start + make_interval(mins => p_window);
      n := n + 1;
      exit when n >= least(coalesce(p_limit, 5), 10);
    end if;
  end loop;
end $$;

-- how a time is said: an exact time, or a window
create or replace function public.zella_slot_say(p_start timestamptz, p_tz text, p_window integer) returns text
language sql immutable set search_path = public as $$
  select case when p_window is null then to_char(p_start at time zone p_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')
              else to_char(p_start at time zone p_tz, 'FMDay, FMMonth FMDD "between" FMHH12:MI AM') || ' and '
                   || to_char((p_start + make_interval(mins => p_window)) at time zone p_tz, 'FMHH12:MI AM') end
$$;

-- the business's window, or null for exact times
create or replace function public.zella_arrival_window(p_business_id uuid) returns integer
language sql stable security definer set search_path = public as $$
  select case when (r ->> 'arrival_window_minutes') ~ '^\d{2,3}$' and (r ->> 'arrival_window_minutes')::int between 60 and 480
              then (r ->> 'arrival_window_minutes')::int end
    from (select public.zella_booking_rules(p_business_id) r) x
$$;

revoke execute on function public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer), public.zella_arrival_window(uuid) from public, anon;
grant execute on function public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer), public.zella_arrival_window(uuid) to authenticated, service_role;

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_ai_booking(text, uuid, text, jsonb)'::regprocedure);
  if position('zella_arrival_windows' in def) = 0 then
    def := replace(def, $a$v_book_rules jsonb; v_notice integer; v_ahead integer;$a$, $a$v_book_rules jsonb; v_notice integer; v_ahead integer; v_window integer;$a$);
    def := replace(def, $a$  if p_action in ('availability', 'book') then$a$, $a$  v_window := public.zella_arrival_window(v_biz);   /* zella_arrival_windows: a window is booked whole */
  if v_window is not null then v_dur := v_window; end if;

  if p_action in ('availability', 'book') then$a$);
    def := replace(def, $a$to_char(s.slot_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')$a$, $a$public.zella_slot_say(s.slot_start, v_tz, v_window)$a$);
    def := replace(def, $a$from public.zella_available_slots(v_biz, v_from, v_to, v_dur, null, 30, 5, null) s;$a$, $a$from public.zella_booking_choices(v_biz, v_from, v_to, v_dur, v_window) s;$a$);
    def := replace(def, $a$from public.zella_available_slots(v_biz, greatest(now(), v_start - interval '1 day'), v_start + interval '3 days', v_dur, null, 30, 5, null) s;$a$,
                        $a$from public.zella_booking_choices(v_biz, greatest(now(), v_start - interval '1 day'), v_start + interval '3 days', v_dur, v_window) s;$a$);
    def := replace(def, $a$  v_when := to_char(v_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');$a$, $a$  v_when := public.zella_slot_say(v_start, v_tz, v_window);$a$);
    def := replace(def, $a$'Booked for ' || v_when || '. Tell the caller they are all set'$a$,
                        $a$'Booked for ' || v_when || '.' || case when v_window is not null then ' The team arrives within that window.' else '' end || ' Tell the caller they are all set'$a$);
    if position('zella_arrival_windows' in def) = 0 or position('zella_booking_choices(v_biz, v_from' in def) = 0 or position('zella_slot_say(v_start' in def) = 0
       or position('arrives within that window' in def) = 0 then
      raise exception 'zella_ai_booking has changed; review this patch';
    end if;
    execute def;
  end if;
end $$;

-- rescheduling, cancelling and "find my appointments" say a window business's times as windows too
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_ai_manage_booking(text, uuid, text, jsonb)'::regprocedure);
  if position('zella_arrival_windows' in def) = 0 then
    def := replace(def, $a$to_char(x.start_time at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')$a$, $a$public.zella_slot_say(x.start_time, v_tz, public.zella_arrival_window(v_biz))$a$);
    def := replace(def, $a$to_char(v_appt.start_time at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')$a$, $a$public.zella_slot_say(v_appt.start_time, v_tz, public.zella_arrival_window(v_biz))$a$);
    def := replace(def, $a$  v_when := to_char(v_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');$a$, $a$  v_when := public.zella_slot_say(v_start, v_tz, public.zella_arrival_window(v_biz));   /* zella_arrival_windows */$a$);
    def := replace(def, $a$to_char(s.slot_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')$a$, $a$public.zella_slot_say(s.slot_start, v_tz, public.zella_arrival_window(v_biz))$a$);
    if position('zella_arrival_windows' in def) = 0 or position('FMDD "at"' in def) > 0 then raise exception 'zella_ai_manage_booking has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
