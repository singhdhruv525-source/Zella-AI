-- Zella - customer text replies. Safe to run more than once.
-- Needs zella_followup_texts.sql, zella_callback_sms.sql and zella_followup_emails.sql first.
-- The router already sends every incoming text to zella_handle_inbound_sms_keyword. This file makes that
-- function do more, so the router workflow does NOT need to be re-imported:
--   * every incoming text is saved (matched to the customer when the number is known)
--   * STOP / START / HELP work as before, and HELP now gets a reply
--   * C, CONFIRM, YES, Y  -> the customer's next appointment becomes confirmed, and they get a thank-you text
--   * R, RESCHEDULE       -> staff get an alert and a callback task, and the customer gets an acknowledgement
--   * anything else       -> staff see a "new text" notice in the app
-- Replies to customers are queued as follow-up text tasks and sent by the "Zella - Follow-up Texts" workflow.

-- 1. Reply templates. A business can override them.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, v.key, 'sms', 'transactional', 'en-US', null, v.body, 1, 'active'
  from (values
    ('reply_confirmed', 'Thanks {{first_name}}, your appointment with {{business}} is confirmed. See you then.'),
    ('reply_reschedule', 'Thanks {{first_name}}, we have let {{business}} know you need a new time. They will contact you shortly.'),
    ('reply_help', '{{business}}: for help please contact us directly. Reply STOP to opt out.')
  ) as v(key, body)
 where not exists (
   select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = 'sms' and t.locale = 'en-US' and t.status = 'active');

-- 2. The incoming-text handler.
create or replace function public.zella_handle_inbound_sms_keyword(p_business_id uuid, p_from text, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k text := upper(regexp_replace(trim(coalesce(p_body, '')), '[^A-Za-z]', '', 'g'));
  v_cust uuid; v_name text; v_appt record; v_cb uuid; v_when text; v_tz text;
begin
  select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_from, null) m where m.certainty = 'exact' limit 1;
  select coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), p_from) into v_name from public.customers c where c.id = v_cust;
  v_name := coalesce(v_name, p_from);
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;

  -- Keep a copy so staff can see what the customer wrote (a repeat of the same text within 2 minutes is not stored twice).
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

  if v_cust is not null and k in ('C','CONFIRM','CONFIRMED','YES','Y','R','RESCHEDULE') then
    select a.id, a.title, a.start_time, a.status into v_appt from public.appointments a
     where a.customer_id = v_cust and a.business_id = p_business_id and a.status in ('scheduled', 'confirmed')
       and coalesce(a.booking_state, 'confirmed') = 'confirmed' and a.start_time > now()
     order by a.start_time limit 1;

    if v_appt.id is not null and k in ('C','CONFIRM','CONFIRMED','YES','Y') then
      if v_appt.status = 'scheduled' then update public.appointments set status = 'confirmed', updated_at = now() where id = v_appt.id; end if;
      update public.appointment_reminders set status = 'cancelled', error = 'customer_confirmed'
       where appointment_id = v_appt.id and kind = 'confirmation_request' and status = 'pending';
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      values (p_business_id, v_cust, v_appt.id, 'reply_confirmed', 'sms', now(), 2) on conflict do nothing;
      return jsonb_build_object('action', 'confirmed', 'keyword', k, 'appointment_id', v_appt.id);

    elsif v_appt.id is not null then
      v_when := to_char(v_appt.start_time at time zone v_tz, 'Dy Mon FMDD "at" FMHH12:MI AM');
      update public.appointments set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('reschedule_requested_at', now(), 'reschedule_requested_by', 'customer_text'),
             reschedule_requested_by = 'customer', updated_at = now() where id = v_appt.id;
      v_cb := public.zella_create_callback(p_business_id, p_from, 'appointment_request', 'normal',
                v_name || ' asked by text to reschedule their ' || coalesce(v_appt.title, 'appointment') || ' on ' || v_when || '.',
                null, v_cust, null, v_appt.id, 'system', 'reschedule_request');
      update public.callbacks set auto_call = false, status = 'reschedule_requested', updated_at = now() where id = v_cb;
      perform public.zella_notify_owners(p_business_id, 'reschedule_requested', 'Reschedule request',
        v_name || ' asked by text to reschedule their ' || coalesce(v_appt.title, 'appointment') || ' on ' || v_when || '. Please contact them to find a new time.', 'warning', 'callbacks');
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      values (p_business_id, v_cust, v_appt.id, 'reply_reschedule', 'sms', now(), 2) on conflict do nothing;
      return jsonb_build_object('action', 'reschedule_requested', 'keyword', k, 'appointment_id', v_appt.id, 'callback_id', v_cb);
    end if;
  end if;

  -- Anything else: let staff know there is a new text to read.
  perform public.zella_notify_owners(p_business_id, 'customer_reply', 'New text from ' || v_name, left(coalesce(p_body, ''), 300), 'info', 'inbox');
  return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null);
end $$;

-- 3. The text claim: replies to a customer's own message go out straight away (no calling-hours delay) and
--    are never moved to email. Everything else behaves as before.
create or replace function public.zella_claim_followup_texts(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_task record; v_biz record; v_cust record; v_appt record; v_next timestamptz; v_reply boolean;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'sms' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    v_reply := v_task.kind like 'reply\_%';
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email, coalesce(c.do_not_contact, false) as do_not_contact,
           coalesce(c.do_not_email, false) as do_not_email, coalesce(c.do_not_sms, false) as do_not_sms
      into v_cust from public.customers c where c.id = v_task.customer_id;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or v_cust.do_not_contact then
      update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if nullif(trim(coalesce(v_cust.phone, '')), '') is null or v_cust.do_not_sms then
      if not v_reply and public.zella_valid_email(v_cust.email) and not v_cust.do_not_email then
        update public.followup_tasks set channel = 'email', updated_at = now() where id = v_task.id;
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;
    if not v_reply then
      v_next := public.zella_next_call_time(now(), v_biz.timezone);
      if v_next > now() + interval '1 minute' then
        update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
        continue;
      end if;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id, 'kind', v_task.kind, 'channel', v_task.channel, 'entity_ref', v_task.entity_ref,
      'callback_reason', (select cb.reason from public.callbacks cb where cb.id = v_task.entity_ref and cb.business_id = v_task.business_id),
      'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time, 'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end));
  end loop;
  return v_result;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_handle_inbound_sms_keyword(uuid,text,text)', 'zella_claim_followup_texts(integer,text[])'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
