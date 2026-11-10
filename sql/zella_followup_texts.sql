-- Zella - follow-up texts (no-show, post-visit, quote, reactivation). Safe to run more than once.
-- Adds: message templates for the three kinds that had none, a claim that takes only text tasks
-- (so call tasks are never picked up by the text sender), and a way to skip a task for a known reason.
-- Nothing here sends a text. Sending is done by the n8n "Zella - Follow-up Texts" workflow.

-- 1. Platform templates (every business and industry can override them).
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, v.key, 'sms', v.purpose, 'en-US', null, v.body, 1, 'active'
  from (values
    ('post_appointment_follow_up', 'transactional', 'Hi {{first_name}}, thanks for visiting {{business}}. We hope everything went well. Reply here with any feedback. Reply STOP to opt out.'),
    ('quote_follow_up',            'transactional', 'Hi {{first_name}}, this is {{business}} following up on your quote. Reply here if you have questions or want to go ahead. Reply STOP to opt out.'),
    ('lead_reactivation',          'marketing',     'Hi {{first_name}}, it has been a while since we heard from you. Reply here if {{business}} can help. Reply STOP to opt out.')
  ) as v(key, purpose, body)
 where not exists (
   select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = 'sms' and t.locale = 'en-US');

-- 2. Claim only text tasks. Same rules as zella_claim_followup_tasks: business active, person can be
--    contacted, inside the 9 am to 7 pm window, rows locked so two workers never take the same task.
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
     order by t.due_at
     limit greatest(1, least(coalesce(p_limit, 10), 50))
     for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
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
    v_next := public.zella_next_call_time(now(), v_biz.timezone);
    if v_next > now() + interval '1 minute' then
      update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
      continue;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id, 'kind', v_task.kind, 'channel', v_task.channel,
      'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time, 'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end));
  end loop;
  return v_result;
end $$;

-- 3. Skip a claimed task for a known reason (no consent, dry run...). Not retried.
create or replace function public.zella_skip_followup_task(p_task_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
begin
  update public.followup_tasks
     set status = 'skipped', outcome = left(coalesce(p_reason, 'skipped'), 100), completed_at = now(), updated_at = now()
   where id = p_task_id and status = 'in_progress';
  if not found then return 'not_in_progress'; end if;
  return 'skipped';
end $$;

-- Only the service role (n8n) may call these.
do $$
declare f text;
begin
  foreach f in array array['zella_claim_followup_texts(integer,text[])', 'zella_skip_followup_task(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
