-- Reminder rules for bookings made at any lead time (days ahead, or 30 to 45 minutes before the visit).
-- Changes only zella_replace_reminders:
--   1. A reminder or confirmation request is kept only if it is still at least 10 minutes away,
--      so it never arrives right after the booking confirmation.
--   2. Short notice safety net: if the booking confirmation is switched off and every reminder time
--      has already passed, one reminder is sent straight away, so every client gets a message.
-- Unchanged: the booking confirmation still goes out straight away; reminders still replace
-- themselves when an appointment moves, and cancel when it is cancelled. Safe to run more than once.

create or replace function public.zella_replace_reminders(p_appointment_id uuid, p_send_confirmation boolean default false, p_reason text default 'booked')
returns void language plpgsql security definer set search_path = public as $$
declare a record; v_rem record; v_conf record; v_hours numeric[]; h numeric; v_gap interval := interval '10 minutes'; v_scheduled integer := 0; v_text_going boolean := false;
begin
  update public.appointment_reminders set status = 'cancelled', error = 'replaced' where appointment_id = p_appointment_id and status in ('pending');
  select * into a from public.appointments where id = p_appointment_id;
  if not found or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or a.start_time <= now() then return; end if;

  select x.* into v_rem from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_reminder' and x.status = 'active' limit 1;
  if v_rem.id is not null then
    v_hours := case when v_rem.trigger_config ? 'hours_before' and jsonb_typeof(v_rem.trigger_config -> 'hours_before') = 'array'
                    then array(select jsonb_array_elements_text(v_rem.trigger_config -> 'hours_before')::numeric) else array[24]::numeric[] end;
    foreach h in array v_hours loop
      -- Keep a reminder only if it is still at least 10 minutes away, so it never lands right after
      -- the booking confirmation (or after it should already have gone).
      if a.start_time - make_interval(secs => h * 3600) > now() + v_gap then
        insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
        values (a.business_id, a.id, a.customer_id, 'reminder', h, p_reason, a.start_time - make_interval(secs => h * 3600), coalesce(v_rem.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
        v_scheduled := v_scheduled + 1;
      end if;
    end loop;
  end if;
  select x.* into v_conf from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_confirmation' and x.status = 'active' limit 1;
  if v_conf.id is not null then
    if p_send_confirmation then
      insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, reason, due_at, channel)
      values (a.business_id, a.id, a.customer_id, 'confirmation', p_reason, now(), coalesce(v_conf.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
      v_text_going := true;
    end if;
    -- later, ask them to confirm they are still coming
    h := coalesce((v_conf.trigger_config ->> 'hours_before')::numeric, 24);
    if a.start_time - make_interval(secs => h * 3600) > now() + v_gap then
      insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
      values (a.business_id, a.id, a.customer_id, 'confirmation_request', h, p_reason, a.start_time - make_interval(secs => h * 3600), coalesce(v_conf.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
    end if;
  end if;

  -- Short notice with nothing else going out: every client still gets one message. If the booking
  -- confirmation is off and every reminder time has already passed, send a reminder straight away.
  if v_rem.id is not null and p_send_confirmation and not v_text_going and v_scheduled = 0 then
    insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, reason, due_at, channel)
    values (a.business_id, a.id, a.customer_id, 'reminder', 'short_notice', now(), coalesce(v_rem.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
  end if;
end $$;
revoke all on function public.zella_replace_reminders(uuid, boolean, text) from public, anon, authenticated;
