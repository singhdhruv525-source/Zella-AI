-- Zella - follow-up emails and automatic switching between text and email. Safe to run more than once.
-- Needs zella_followup_texts.sql, zella_callback_sms.sql and zella_email_sender.sql first.
-- Adds: email follow-ups (no-show, thank-you, quote, lead and missed-call acknowledgements, callback
-- acknowledgement), and a rule so every client still gets a message: if a text cannot go (no phone number
-- or text switched off) but an email can, the reminder or follow-up moves to email, and the other way round.
-- Nothing here sends an email. The n8n "Zella - Follow-up Emails" workflow does, only when email_live is true.

-- 1. A small helper used by every claim below.
create or replace function public.zella_valid_email(p_email text)
returns boolean language sql immutable as $$
  select coalesce(lower(trim(p_email)) ~ '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' and length(trim(p_email)) <= 254, false);
$$;

-- 2. Follow-up tasks may now be emails, and an email can be reported as sent.
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.followup_tasks'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%channel%';
  if c is not null then execute format('alter table public.followup_tasks drop constraint %I', c); end if;
  alter table public.followup_tasks add constraint followup_tasks_channel_check check (channel in ('call', 'sms', 'email'));
end $$;

create or replace function public.zella_complete_followup_task(p_task_id uuid, p_outcome text, p_notes text default null, p_provider_call_id text default null, p_call_id uuid default null, p_retry_in_minutes integer default 120)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_task record; v_tz text; v_status text;
begin
  select * into v_task from public.followup_tasks where id = p_task_id for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if p_outcome not in ('rescheduled', 'wants_callback', 'declined', 'no_answer', 'voicemail', 'sms_sent', 'email_sent', 'failed') then
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

  if p_outcome = 'wants_callback' and coalesce(p_call_id, v_task.call_id) is not null then
    update public.calls
       set needs_human = true,
           escalation_reason = coalesce(nullif(p_notes, ''), 'Asked for a call back after a missed appointment'),
           escalated_at = now(), escalation_resolved_at = null, updated_at = now()
     where id = coalesce(p_call_id, v_task.call_id);
  end if;
  return v_status;
end $$;

-- 3. Email versions of the follow-up messages. A business can override any of them.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, v.key, 'email', 'transactional', 'en-US', v.subject, v.body, 1, 'active'
  from (values
    ('no_show_follow_up', 'We missed you at {{business}}',
     E'Hi {{first_name}},\n\nWe missed you at {{business}} today. We would be happy to find you a new time - please contact {{business}} to rebook.'),
    ('post_appointment_follow_up', 'Thank you for visiting {{business}}',
     E'Hi {{first_name}},\n\nThank you for visiting {{business}}. We hope everything went well. If you have any feedback, please let {{business}} know.'),
    ('quote_follow_up', 'Following up on your quote from {{business}}',
     E'Hi {{first_name}},\n\nThis is {{business}} following up on your quote. If you have questions or want to go ahead, please contact {{business}}.'),
    ('lead_acknowledgement', 'Thanks for getting in touch with {{business}}',
     E'Hi {{first_name}},\n\nThank you for getting in touch with {{business}}. We have your details and will be in contact shortly.'),
    ('missed_call_follow_up', 'We missed your call - {{business}}',
     E'Hi {{first_name}},\n\nThis is {{business}}. We missed your call. Please contact {{business}} and we will get back to you as soon as we can.'),
    ('callback_acknowledgement', 'We will call you back - {{business}}',
     E'Hi {{first_name}},\n\nThank you for contacting {{business}}. A team member will call you back soon.')
  ) as v(key, subject, body)
 where not exists (
   select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = 'email' and t.locale = 'en-US' and t.status = 'active');

-- 4. Claim due follow-up EMAILS. Same checks as the text claim, except there is no calling-hours delay.
--    If the customer has no usable email but a text could go, the task moves to text instead.
create or replace function public.zella_claim_followup_emails(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_result jsonb := '[]'::jsonb; v_task record; v_biz record; v_cust record; v_appt record;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'email' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
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
    if v_cust.do_not_email or not public.zella_valid_email(v_cust.email) then
      if public.zella_digits(v_cust.phone) is not null and not v_cust.do_not_sms then
        update public.followup_tasks set channel = 'sms', updated_at = now() where id = v_task.id;   -- the text claim takes it from here
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
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

-- 5. The text claim: same as before, but a customer who cannot be texted and can be emailed moves to email.
create or replace function public.zella_claim_followup_texts(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_task record; v_biz record; v_cust record; v_appt record; v_next timestamptz;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'sms' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
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
      if public.zella_valid_email(v_cust.email) and not v_cust.do_not_email then
        update public.followup_tasks set channel = 'email', updated_at = now() where id = v_task.id;   -- the email claim takes it from here
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;
    v_next := public.zella_next_call_time(now(), v_biz.timezone);
    if v_next > now() + interval '1 minute' then
      update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
      continue;
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

-- 6. The reminder claim: same as before, but a reminder whose channel cannot reach the customer moves to
--    the other channel when that one can (text <-> email), so every client still gets the message.
drop function if exists public.zella_claim_reminders(integer, text);
create or replace function public.zella_claim_reminders(p_limit integer default 25, p_channel text default 'sms')
returns jsonb language plpgsql security definer set search_path = public as $$
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
    if b.suspended_at is not null or b.cancelled_at is not null or c.id is null or coalesce(c.do_not_contact, false) or (public.zella_digits(c.phone) is null and nullif(trim(coalesce(c.email, '')), '') is null) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    v_phone_ok := public.zella_digits(c.phone) is not null and not coalesce(c.do_not_sms, false);
    v_email_ok := public.zella_valid_email(c.email) and not coalesce(c.do_not_email, false);
    if v_channel = 'sms' and not v_phone_ok and v_email_ok then
      update public.appointment_reminders set channel = 'email' where id = r.id; continue;      -- the email sender takes it from here
    elsif v_channel = 'email' and not v_email_ok and v_phone_ok then
      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;        -- the text sender takes it from here
    end if;
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'zella_claim_followup_emails(integer,text[])',
    'zella_claim_followup_texts(integer,text[])',
    'zella_claim_reminders(integer,text)',
    'zella_complete_followup_task(uuid,text,text,text,uuid,integer)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
