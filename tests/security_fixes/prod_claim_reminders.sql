-- production's zella_claim_reminders (24 Nov 2026, md5 50d4d7b4...: zprod3's version plus sql/zella_review_sql_fixes.sql's
-- cannot_contact check). Function code only, no data.
CREATE OR REPLACE FUNCTION public.zella_claim_reminders(p_limit integer DEFAULT 25, p_channel text DEFAULT 'sms'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res jsonb := '[]'::jsonb; r record; a record; c record; b record; v_staff text;
        v_channel text := case when p_channel = 'email' then 'email' else 'sms' end;
        v_phone_ok boolean; v_email_ok boolean;
begin
  for r in select * from public.appointment_reminders where status = 'pending' and due_at <= now() and channel = v_channel order by due_at
           limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked loop
    select * into a from public.appointments where id = r.appointment_id;
    select * into c from public.customers where id = r.customer_id;
    select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = r.business_id;
    if a.id is null or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or (r.kind in ('reminder', 'confirmation_request') and a.start_time <= now()) then
      update public.appointment_reminders set status = 'skipped', error = 'appointment_no_longer_active' where id = r.id; continue;
    end if;
    /* zella_channel_review: held while the owner chooses how it is sent */
    if public.zella_channel_on_hold(r.business_id, case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'channel_needs_review' where id = r.id; continue;
    end if;
    /* zella_message_settings_fix: the automation that queued it must still be on */
    if not exists (select 1 from public.automations x where x.business_id = r.business_id and x.status = 'active'
                     and x.trigger_type = case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'automation_off' where id = r.id; continue;
    end if;
    if b.suspended_at is not null or b.cancelled_at is not null or c.id is null or coalesce(c.do_not_contact, false) or (public.zella_digits(c.phone) is null and nullif(trim(coalesce(c.email, '')), '') is null) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    v_phone_ok := public.zella_digits(c.phone) is not null and not coalesce(c.do_not_sms, false);
    v_email_ok := public.zella_valid_email(c.email) and not coalesce(c.do_not_email, false);
    if v_channel = 'sms' and not v_phone_ok and v_email_ok then
      update public.appointment_reminders set channel = 'email' where id = r.id; continue;
    elsif v_channel = 'email' and not v_email_ok and v_phone_ok then
      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;
    end if;
    if (v_channel = 'sms' and not v_phone_ok) or (v_channel = 'email' and not v_email_ok) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'reschedule_line', public.zella_reschedule_line(a.id),
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $function$;
