-- Zella - outbound calls to leads and customers (dry-run). Safe to run more than once.
-- Needs zella_followups.sql and zella_run_all.sql (callbacks) first.
-- Two things Zella may call about:
--   1. callbacks it is allowed to make by itself (a missed call, a new lead)  -> zella_claim_callbacks
--   2. follow-up tasks set to "call" (no-show, after a visit, a quote)         -> zella_claim_followup_calls
-- The n8n "Zella - Outbound Calls" workflow asks for what is due and, only when calls_live is true, asks Vapi
-- to place the call. In dry-run (the default) nothing is dialled: the item is put back for later.
-- The result of a call (answered, no answer, voicemail...) arrives afterwards from Vapi's end-of-call report.

-- 1. Switches. calls_live stays false until Vapi and a phone number are connected.
insert into public.platform_settings (key, value) values ('calls_live', 'false'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('vapi_assistant_id', '""'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('vapi_phone_number_id', '""'::jsonb) on conflict (key) do nothing;

create or replace function public.zella_call_config()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'live', coalesce(public.zella_setting('calls_live', 'false'::jsonb) = 'true'::jsonb, false)
            and nullif(trim(public.zella_setting('vapi_assistant_id', '""'::jsonb) #>> '{}'), '') is not null
            and nullif(trim(public.zella_setting('vapi_phone_number_id', '""'::jsonb) #>> '{}'), '') is not null,
    'assistant_id', nullif(trim(public.zella_setting('vapi_assistant_id', '""'::jsonb) #>> '{}'), ''),
    'phone_number_id', nullif(trim(public.zella_setting('vapi_phone_number_id', '""'::jsonb) #>> '{}'), ''));
$$;

-- 2. Callbacks Zella may place itself. Same rules as before (calling hours, do-not-contact, attempt limits),
--    with the call settings added so the workflow knows whether it may really dial.
create or replace function public.zella_claim_callback_calls(p_limit integer default 10)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x || jsonb_build_object('source', 'callback', 'id', x ->> 'callback_id') || public.zella_call_config()), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_callbacks(p_limit)) x;
$$;

-- 3. Follow-up tasks set to "call". Only call tasks are taken (texts and emails have their own workflows).
--    A person who can't be called (opted out, no number, do-not-call) moves to a text, or an email, instead.
create or replace function public.zella_claim_followup_calls(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb := '[]'::jsonb; v_cfg jsonb := public.zella_call_config();
  v_task record; v_biz record; v_cust record; v_appt record; v_next timestamptz; v_purpose text;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'call' and t.due_at <= now() and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email into v_cust from public.customers c where c.id = v_task.customer_id;
    v_purpose := case when v_task.kind = 'lead_reactivation' then 'marketing' else 'transactional' end;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or not public.zella_can_contact(v_task.business_id, v_task.customer_id, 'call', v_purpose) or nullif(trim(coalesce(v_cust.phone, '')), '') is null then
      -- cannot be called: a text, then an email, if the person can receive one
      if v_cust.id is not null and nullif(trim(coalesce(v_cust.phone, '')), '') is not null and public.zella_can_contact(v_task.business_id, v_task.customer_id, 'sms', v_purpose) then
        update public.followup_tasks set channel = 'sms', updated_at = now() where id = v_task.id;
      elsif v_cust.id is not null and public.zella_valid_email(v_cust.email) and public.zella_can_contact(v_task.business_id, v_task.customer_id, 'email', v_purpose) then
        update public.followup_tasks set channel = 'email', updated_at = now() where id = v_task.id;
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;
    -- Outside calling hours: try again when they open.
    v_next := public.zella_next_call_time(now(), v_biz.timezone);
    if v_next > now() + interval '1 minute' then
      update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
      continue;
    end if;

    select a.id, a.title, a.start_time into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'source', 'task', 'id', v_task.id, 'task_id', v_task.id, 'kind', v_task.kind, 'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone),
      'appointment', case when v_appt.id is null then null else jsonb_build_object('id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time) end) || v_cfg);
  end loop;
  return v_res;
end $$;

-- 4. Put a claimed call back without using up an attempt (dry-run, or a missing setting). It comes up again later.
create or replace function public.zella_release_call(p_source text, p_id uuid, p_reason text default 'dry_run', p_defer_minutes integer default 720)
returns text language plpgsql security definer set search_path = public as $$
declare v_due timestamptz := now() + make_interval(mins => greatest(5, coalesce(p_defer_minutes, 720)));
begin
  if p_source = 'task' then
    update public.followup_tasks set status = 'pending', attempts = greatest(0, attempts - 1), due_at = v_due, outcome_notes = left(coalesce(p_reason, 'released'), 300), updated_at = now()
     where id = p_id and status = 'in_progress';
  elsif p_source = 'callback' then
    update public.callbacks set status = 'scheduled', attempts = greatest(0, attempts - 1), due_at = v_due, locked_at = null, updated_at = now()
     where id = p_id and status = 'in_progress';
  else
    raise exception 'BAD_SOURCE';
  end if;
  if not found then return 'not_in_progress'; end if;
  return 'released';
end $$;

-- 5. Vapi accepted the call. The follow-up task remembers the provider's call id; the result comes later.
create or replace function public.zella_mark_call_placed(p_source text, p_id uuid, p_provider_call_id text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_source = 'task' then
    update public.followup_tasks set provider_call_id = left(p_provider_call_id, 200), updated_at = now() where id = p_id and status = 'in_progress';
  elsif p_source <> 'callback' then
    raise exception 'BAD_SOURCE';
  end if;
  return 'placed';
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_call_config()', 'zella_claim_callback_calls(integer)', 'zella_claim_followup_calls(integer,text[])',
                           'zella_release_call(text,uuid,text,integer)', 'zella_mark_call_placed(text,uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
