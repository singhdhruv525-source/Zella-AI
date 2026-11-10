-- Callback fallback texts. Safe to run more than once.
-- When a callback runs out of tries, the database queues a text task (kind 'callback_sms') for the person.
-- This makes the text-only claim also report which callback it came from and why (missed call or new lead),
-- so the Follow-up Texts workflow can pick the right message. Run after zella_followup_texts.sql.

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
