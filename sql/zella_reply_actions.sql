-- Zella - customer text replies that do something (checklist 71). Safe to run more than once.
-- Needs zella_reschedule.sql and zella_inbound_replies.sql first. Replaces zella_handle_inbound_sms_keyword with a version that also:
--   * CONFIRM / YES / Y / OK on a known customer with an appointment in the next 7 days -> the appointment is marked confirmed and a thank-you text is queued
--   * RESCHEDULE / CHANGE / MOVE (or "need a new time") -> a callback is created for staff and the customer gets "we have let the business know"
--   * HERE / ARRIVED within an hour of an appointment -> the customer is marked arrived and staff are told
--   * words like urgent / emergency / asap raise the staff notice to a warning
-- STOP, START and HELP are unchanged. The router workflow does not change.
create or replace function public.zella_handle_inbound_sms_keyword(p_business_id uuid, p_from text, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k text := upper(regexp_replace(trim(coalesce(p_body, '')), '[^A-Za-z]', '', 'g'));
  v_text text := lower(coalesce(p_body, ''));
  v_cust uuid; v_name text; v_appt record; v_action text;
begin
  select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_from, null) m where m.certainty = 'exact' limit 1;
  select coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), p_from) into v_name from public.customers c where c.id = v_cust;
  v_name := coalesce(v_name, p_from);

  if not exists (select 1 from public.sms_messages where business_id = p_business_id and direction = 'inbound' and from_number = p_from
                   and message_body = left(p_body, 1600) and created_at > now() - interval '2 minutes') then
    insert into public.sms_messages (business_id, customer_id, direction, status, from_number, message_body, metadata)
    values (p_business_id, v_cust, 'inbound', 'received', p_from, left(p_body, 1600), jsonb_build_object('keyword', nullif(k, ''), 'source', 'router'));
  end if;

  if k in ('STOP','STOPALL','UNSUBSCRIBE','CANCEL','END','QUIT') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'marketing', k);
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_out', 'keyword', k);
  elsif k in ('START','UNSTOP','YES') and exists (
      select 1 from public.contact_consents where business_id = p_business_id and phone_digits = public.zella_digits(p_from) and channel = 'sms' and status = 'opted_out') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_in', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_in', 'keyword', k);
  elsif k = 'HELP' then
    if v_cust is not null then
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts) values (p_business_id, v_cust, 'reply_help', 'sms', now(), 2);
    end if;
    return jsonb_build_object('action', 'help', 'reply_queued', v_cust is not null);
  end if;

  if v_cust is not null and k in ('HERE','ARRIVED','IMHERE','CHECKIN','CHECKEDIN') then
    select a.id into v_appt from public.appointments a
     where a.business_id = p_business_id and a.customer_id = v_cust and a.status in ('scheduled', 'confirmed')
       and a.start_time between now() - interval '30 minutes' and now() + interval '60 minutes' order by a.start_time limit 1;
    if v_appt.id is not null then
      perform public.zella_set_attendance(v_appt.id, 'arrived');
      return jsonb_build_object('action', 'arrived', 'appointment_id', v_appt.id);
    end if;
  end if;

  if v_cust is not null then
    select a.id, a.start_time, a.status into v_appt from public.appointments a
     where a.business_id = p_business_id and a.customer_id = v_cust and a.start_time > now() and a.start_time < now() + interval '7 days' and a.status in ('scheduled', 'confirmed')
     order by a.start_time limit 1;
    -- confirm
    if k in ('CONFIRM','CONFIRMED','YES','Y','YEP','YEAH','OK','OKAY','SURE') and v_appt.id is not null then
      update public.appointments set status = 'confirmed', updated_at = now() where id = v_appt.id and status = 'scheduled';
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      select p_business_id, v_cust, v_appt.id, 'reply_confirmed', 'sms', now(), 2
       where not exists (select 1 from public.followup_tasks where appointment_id = v_appt.id and kind = 'reply_confirmed' and created_at > now() - interval '1 day');
      return jsonb_build_object('action', 'confirmed', 'appointment_id', v_appt.id);
    end if;
    -- change
    if (k in ('RESCHEDULE','CHANGE','MOVE') or v_text ~ '(need|want|have) to (reschedule|change|move)|new time|different time|can.t make it|cannot make it') and v_appt.id is not null then
      perform public.zella_create_callback(p_business_id, p_from, 'appointment_request', 'high', left('Customer replied to ask for a new time: ' || p_body, 400), null, v_cust, null, v_appt.id, 'customer_reply', null);
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      select p_business_id, v_cust, v_appt.id, 'reply_reschedule', 'sms', now(), 2
       where not exists (select 1 from public.followup_tasks where appointment_id = v_appt.id and kind = 'reply_reschedule' and created_at > now() - interval '1 day');
      perform public.zella_notify_owners(p_business_id, 'customer_reply', v_name || ' needs a new time', left(coalesce(p_body, ''), 300), 'warning', 'inbox');
      return jsonb_build_object('action', 'reschedule_requested', 'appointment_id', v_appt.id);
    end if;
  end if;

  v_action := case when v_text ~ 'urgent|emergency|asap|right away|immediately' then 'warning' else 'info' end;
  perform public.zella_notify_owners(p_business_id, 'customer_reply', 'New text from ' || v_name, left(coalesce(p_body, ''), 300), v_action, 'inbox');
  return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null, 'urgent', v_action = 'warning');
end $$;
revoke execute on function public.zella_handle_inbound_sms_keyword(uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_handle_inbound_sms_keyword(uuid, text, text) to service_role;
