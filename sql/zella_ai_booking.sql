-- Zella - booking by the phone assistant. Safe to run more than once.
-- Needs zella_run_all.sql (booking, zella_available_slots, zella_capture_lead).
-- The assistant (Vapi) calls two tools during a call: "check_availability" and "book_appointment".
-- Everything is decided here, in the database, so the schedule always has the last word:
--   * a time is only booked if the calendar accepts it (working hours, breaks, time off, other bookings)
--   * if the time was just taken, the caller is offered other times
--   * if anything unexpected happens, a REQUEST is saved and staff finish it - never a half booking
--   * reminders and the confirmation message come from the normal booking rules (nothing extra here)
-- The business comes from the call when Zella knows it, otherwise from the business id the call carries.

create or replace function public.zella_ai_booking(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_args jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_call_biz uuid; v_call_phone text; v_biz uuid; v_tz text;
  v_dur integer; v_from timestamptz; v_to timestamptz; v_day date; v_days integer; v_slots jsonb;
  v_start timestamptz; v_title text; v_first text; v_last text; v_phone text; v_email text; v_notes text;
  v_lead jsonb; v_cust uuid; v_appt uuid; v_err text; v_when text;
begin
  if nullif(p_provider_call_id, '') is not null then
    select c.business_id, c.from_number into v_call_biz, v_call_phone from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call_biz, p_business_id);
  select b.id, coalesce(b.timezone, 'America/New_York') into v_biz, v_tz from public.businesses b
   where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true);
  if v_biz is null then raise exception 'UNKNOWN_BUSINESS'; end if;

  v_dur := least(480, greatest(5, coalesce(nullif(v_args ->> 'duration_minutes', '')::integer, 30)));

  if p_action in ('availability', 'book') then
    -- times offered: from the day asked for (business local time), or today
    begin v_day := nullif(v_args ->> 'date', '')::date; exception when others then v_day := null; end;
    v_day := greatest(coalesce(v_day, (now() at time zone v_tz)::date), (now() at time zone v_tz)::date);
    v_days := least(14, greatest(1, coalesce(nullif(v_args ->> 'days', '')::integer, 3)));
  end if;

  if p_action = 'availability' then
    v_from := v_day::timestamp at time zone v_tz;
    v_to := (v_day + v_days)::timestamp at time zone v_tz;
    select coalesce(jsonb_agg(jsonb_build_object('start', s.slot_start, 'say', to_char(s.slot_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM'))), '[]'::jsonb)
      into v_slots from public.zella_available_slots(v_biz, v_from, v_to, v_dur, null, 30, 5, null) s;
    return jsonb_build_object('ok', true, 'status', 'slots', 'slots', v_slots,
      'say', case when jsonb_array_length(v_slots) = 0 then 'There are no openings in that period. Offer to look at other days.' else 'Offer the caller these times and let them choose.' end);
  end if;

  if p_action <> 'book' then raise exception 'BAD_ACTION'; end if;

  begin v_start := nullif(v_args ->> 'start', '')::timestamptz; exception when others then v_start := null; end;
  if v_start is null or v_start <= now() or v_start > now() + interval '1 year' then
    return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'The time was not clear. Ask the caller to choose one of the offered times.');
  end if;
  v_first := nullif(trim(left(coalesce(v_args ->> 'first_name', ''), 80)), '');
  v_last := nullif(trim(left(coalesce(v_args ->> 'last_name', ''), 80)), '');
  v_phone := nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), '');
  v_email := nullif(trim(left(coalesce(v_args ->> 'email', ''), 200)), '');
  v_title := coalesce(nullif(trim(left(coalesce(v_args ->> 'title', ''), 120)), ''), 'Appointment');
  v_notes := nullif(trim(left(coalesce(v_args ->> 'notes', ''), 500)), '');
  v_phone := coalesce(v_phone, v_call_phone);
  if v_first is null then return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for their name.'); end if;
  if public.zella_digits(v_phone) is null and v_email is null then
    return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for a phone number so the business can reach them.');
  end if;
  v_when := to_char(v_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');

  begin
    v_lead := public.zella_capture_lead(v_biz, v_first, v_last, v_phone, v_email, 'phone_call', 'Booked by the phone assistant', null);
    v_cust := (v_lead ->> 'customer_id')::uuid;
  exception when others then
    v_err := sqlerrm;
    if v_err = 'BAD_EMAIL' then return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'The email address did not look right. Ask the caller to repeat it, or skip it.'); end if;
    v_cust := null;
  end;

  -- the same caller asking twice for the same time must not book twice
  if v_cust is not null then
    select a.id into v_appt from public.appointments a
     where a.business_id = v_biz and a.customer_id = v_cust and a.start_time = v_start and a.status in ('scheduled', 'confirmed') and coalesce(a.booking_state, 'confirmed') = 'confirmed' limit 1;
    if v_appt is not null then return jsonb_build_object('ok', true, 'status', 'booked', 'appointment_id', v_appt, 'say', 'Already booked for ' || v_when || '. Tell the caller they are all set.'); end if;
  end if;

  if v_cust is null or coalesce(v_lead ->> 'result', '') = 'needs_review' then
    -- we could not tell who this is for sure: save a request, staff will confirm it
    v_appt := public.zella_request_appointment(v_biz, v_cust, v_phone, v_title, v_start, v_notes);
    return jsonb_build_object('ok', true, 'status', 'requested', 'appointment_id', v_appt, 'say', 'The request for ' || v_when || ' was passed to the team, who will confirm it. Do not say it is booked.');
  end if;

  begin
    v_appt := public.zella_book_appointment(v_biz, v_cust, v_title, v_start, v_dur, null, null, v_notes);
    return jsonb_build_object('ok', true, 'status', 'booked', 'appointment_id', v_appt, 'say', 'Booked for ' || v_when || '. Tell the caller they are all set and will get a confirmation message.');
  exception when others then
    v_err := sqlerrm;
    if v_err = 'SLOT_TAKEN' or v_err = 'BAD_TIME' then
      select coalesce(jsonb_agg(jsonb_build_object('start', s.slot_start, 'say', to_char(s.slot_start at time zone v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM'))), '[]'::jsonb)
        into v_slots from public.zella_available_slots(v_biz, greatest(now(), v_start - interval '1 day'), v_start + interval '3 days', v_dur, null, 30, 5, null) s;
      return jsonb_build_object('ok', false, 'status', 'unavailable', 'slots', v_slots, 'say', 'That time is not available. Apologise briefly and offer these other times.');
    end if;
    v_appt := public.zella_request_appointment(v_biz, v_cust, v_phone, v_title, v_start, v_notes);
    return jsonb_build_object('ok', true, 'status', 'requested', 'appointment_id', v_appt, 'say', 'The request for ' || v_when || ' was passed to the team, who will confirm it. Do not say it is booked.');
  end;
end $$;
revoke execute on function public.zella_ai_booking(text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_ai_booking(text, uuid, text, jsonb) to service_role;
