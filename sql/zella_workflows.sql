-- ============================================================
-- Zella workflows: callbacks, leads, appointments, AI maintenance,
-- platform-owner automations. Paste ALL of this into the Supabase SQL Editor.
-- Run AFTER: zella_crm_details.sql, zella_followups.sql, zella_knowledge.sql
-- Safe to run again.
-- ============================================================

-- =========================================================
-- Zella workflows, part 1: shared helpers, staff notifications,
-- and the callback queue (missed calls, requested callbacks,
-- "needs a human", failed transfers, retries).
-- Run AFTER zella_crm_details.sql and zella_followups.sql. Safe to re-run.
-- =========================================================

create or replace function public.zella_is_member(p_business_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.business_members m
                  where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active');
$$;
create or replace function public.zella_digits(p text)
returns text language sql immutable as $$
  select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '');
$$;
revoke all on function public.zella_is_member(uuid) from public, anon;
grant execute on function public.zella_is_member(uuid) to authenticated, service_role;
grant execute on function public.zella_digits(text) to authenticated, service_role;

-- Match a caller / form to an existing record. 'uncertain' means a person
-- must review it: never create a duplicate and never merge silently.
create or replace function public.zella_match_customer(p_business_id uuid, p_phone text, p_email text)
returns table (customer_id uuid, certainty text)
language plpgsql stable security definer set search_path = public as $$
declare v_phone text := public.zella_digits(p_phone); v_email text := lower(nullif(trim(coalesce(p_email, '')), ''));
        v_by_phone uuid[]; v_by_email uuid[];
begin
  select coalesce(array_agg(c.id), '{}') into v_by_phone from public.customers c
   where c.business_id = p_business_id and v_phone is not null and public.zella_digits(c.phone) = v_phone;
  select coalesce(array_agg(c.id), '{}') into v_by_email from public.customers c
   where c.business_id = p_business_id and v_email is not null and lower(c.email) = v_email;
  if cardinality(v_by_phone) = 0 and cardinality(v_by_email) = 0 then
    return query select null::uuid, 'none'::text; return;
  end if;
  if cardinality(v_by_phone) = 1 and cardinality(v_by_email) = 0 then return query select v_by_phone[1], 'exact'; return; end if;
  if cardinality(v_by_email) = 1 and cardinality(v_by_phone) = 0 then return query select v_by_email[1], 'exact'; return; end if;
  if cardinality(v_by_phone) = 1 and cardinality(v_by_email) = 1 and v_by_phone[1] = v_by_email[1] then
    return query select v_by_phone[1], 'exact'; return;
  end if;
  return query select coalesce(v_by_phone[1], v_by_email[1]), 'uncertain';
end $$;
revoke all on function public.zella_match_customer(uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_match_customer(uuid, text, text) to service_role;

-- ---------------------------------------------------------
-- Staff notifications (n8n delivers them by email / SMS / push)
-- ---------------------------------------------------------
create table if not exists public.staff_notifications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid,                       -- null = everyone who manages the business
  kind text not null,
  severity text not null default 'info' check (severity in ('info', 'warning', 'urgent')),
  title text not null,
  body text,
  page_key text,                      -- which CRM page to open
  entity_id uuid,
  delivery_status text not null default 'pending' check (delivery_status in ('pending', 'sent', 'failed', 'skipped')),
  delivery_error text,
  delivered_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists staff_notifications_biz_idx on public.staff_notifications (business_id, created_at desc);
create index if not exists staff_notifications_pending_idx on public.staff_notifications (created_at) where delivery_status = 'pending';
alter table public.staff_notifications enable row level security;
drop policy if exists staff_notifications_select on public.staff_notifications;
create policy staff_notifications_select on public.staff_notifications for select to authenticated
  using (public.zella_is_member(business_id) and (user_id is null or user_id = auth.uid()));
revoke all on public.staff_notifications from anon;
revoke insert, update, delete on public.staff_notifications from authenticated;
grant select on public.staff_notifications to authenticated;

create or replace function public.zella_notify(p_business_id uuid, p_kind text, p_title text, p_body text default null,
  p_severity text default 'info', p_page_key text default null, p_entity_id uuid default null, p_user_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.staff_notifications (business_id, user_id, kind, severity, title, body, page_key, entity_id)
  values (p_business_id, p_user_id, p_kind, p_severity, p_title, p_body, p_page_key, p_entity_id) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.zella_notify(uuid, text, text, text, text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_notify(uuid, text, text, text, text, text, uuid, uuid) to service_role;

create or replace function public.zella_mark_notifications_read(p_ids uuid[]) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.staff_notifications set read_at = now()
   where id = any (p_ids) and read_at is null and public.zella_is_member(business_id) and (user_id is null or user_id = auth.uid());
  get diagnostics n = row_count; return n;
end $$;
revoke all on function public.zella_mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.zella_mark_notifications_read(uuid[]) to authenticated, service_role;

create or replace function public.zella_claim_notifications(p_limit integer default 50)
returns setof public.staff_notifications language plpgsql security definer set search_path = public as $$
begin
  return query
  update public.staff_notifications n set delivery_status = 'sent', delivered_at = now()
   where n.id in (select s.id from public.staff_notifications s where s.delivery_status = 'pending' order by s.created_at
                   limit greatest(1, least(coalesce(p_limit, 50), 200)) for update skip locked)
  returning n.*;
end $$;
create or replace function public.zella_fail_notification(p_id uuid, p_error text) returns void
language sql security definer set search_path = public as $$
  update public.staff_notifications set delivery_status = 'failed', delivery_error = left(p_error, 300) where id = p_id;
$$;
revoke all on function public.zella_claim_notifications(integer) from public, anon, authenticated;
revoke all on function public.zella_fail_notification(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_claim_notifications(integer) to service_role;
grant execute on function public.zella_fail_notification(uuid, text) to service_role;

alter table public.followup_tasks add column if not exists entity_ref uuid;

-- ---------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------
alter table public.calls add column if not exists transfer_status text;
do $$ begin
  alter table public.calls add constraint calls_transfer_status_chk
    check (transfer_status is null or transfer_status in ('not_needed', 'attempted', 'connected', 'failed', 'no_one_available'));
exception when duplicate_object then null; end $$;

create table if not exists public.callbacks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  call_id uuid,
  appointment_id uuid,
  reason text not null default 'other'
    check (reason in ('missed_call', 'new_lead', 'requested', 'needs_human', 'transfer_failed', 'appointment_request', 'booking_failed', 'after_hours', 'other')),
  priority text not null default 'normal' check (priority in ('normal', 'high', 'urgent')),
  status text not null default 'new' check (status in (
    'new', 'scheduled', 'due', 'in_progress', 'contacted', 'reschedule_requested', 'retry_scheduled',
    'waiting_on_customer', 'completed', 'cancelled', 'escalated', 'needs_review')),
  contact_number text,
  summary text,
  preferred_at timestamptz,
  due_at timestamptz,
  assigned_to uuid,
  assigned_team text,
  auto_call boolean not null default false,       -- the business authorised Zella to call back
  attempts integer not null default 0,
  max_attempts integer not null default 3,
  retry_delay_minutes integer not null default 120,
  outcome text,
  note text,
  locked_at timestamptz,
  created_by text not null default 'ai',          -- ai | system | staff
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists callbacks_biz_idx on public.callbacks (business_id, status, due_at);
create index if not exists callbacks_due_idx on public.callbacks (due_at) where status in ('scheduled', 'retry_scheduled', 'due');
create index if not exists callbacks_customer_idx on public.callbacks (customer_id);
-- older installs: allow the 'new_lead' reason
alter table public.callbacks drop constraint if exists callbacks_reason_check;
alter table public.callbacks add constraint callbacks_reason_check
  check (reason in ('missed_call', 'new_lead', 'requested', 'needs_human', 'transfer_failed', 'appointment_request', 'booking_failed', 'after_hours', 'other'));
-- one live callback per caller and reason
create unique index if not exists callbacks_one_live_idx on public.callbacks (business_id, (public.zella_digits(contact_number)), reason)
  where contact_number is not null and status not in ('completed', 'cancelled', 'needs_review');

create table if not exists public.callback_attempts (
  id uuid primary key default gen_random_uuid(),
  callback_id uuid not null references public.callbacks(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  attempt_no integer not null,
  attempted_at timestamptz not null default now(),
  outcome text not null check (outcome in ('connected', 'no_answer', 'busy', 'voicemail', 'invalid_number', 'failed_connection', 'declined')),
  provider_ref text,
  error text,
  notes text,
  next_attempt_at timestamptz,
  initiated_by text not null default 'system'
);
create index if not exists callback_attempts_cb_idx on public.callback_attempts (callback_id, attempt_no);

alter table public.callbacks enable row level security;
alter table public.callback_attempts enable row level security;
drop policy if exists callbacks_select on public.callbacks;
create policy callbacks_select on public.callbacks for select to authenticated using (public.zella_is_member(business_id));
drop policy if exists callback_attempts_select on public.callback_attempts;
create policy callback_attempts_select on public.callback_attempts for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.callbacks, public.callback_attempts from anon;
revoke insert, update, delete on public.callbacks, public.callback_attempts from authenticated;
grant select on public.callbacks, public.callback_attempts to authenticated;

-- Create a callback. Used by the AI (service role) and, through the wrapper below, by staff.
-- Never duplicates: asking again for the same caller and reason updates the live one.
create or replace function public.zella_create_callback(
  p_business_id uuid, p_contact_number text, p_reason text default 'other', p_priority text default 'normal',
  p_summary text default null, p_preferred_at timestamptz default null, p_customer_id uuid default null,
  p_call_id uuid default null, p_appointment_id uuid default null, p_created_by text default 'ai', p_automation text default 'missed_call_follow_up'
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_tz text; v_auto record; v_due timestamptz; v_cust uuid := p_customer_id; v_id uuid; v_note text;
  v_reason text := case when p_reason in ('missed_call','new_lead','requested','needs_human','transfer_failed','appointment_request','booking_failed','after_hours') then p_reason else 'other' end;
  v_priority text := case when p_priority in ('high','urgent') then p_priority else 'normal' end;
  v_max integer; v_delay integer; v_first integer;
begin
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  if v_tz is null then raise exception 'BUSINESS_NOT_FOUND'; end if;
  if nullif(trim(coalesce(p_contact_number, '')), '') is null and v_cust is null then raise exception 'NO_CONTACT'; end if;
  if v_cust is null then select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_contact_number, null) m where m.certainty = 'exact'; end if;
  if nullif(trim(coalesce(p_contact_number, '')), '') is null then select c.phone into p_contact_number from public.customers c where c.id = v_cust; end if;

  -- Zella calls back by itself only when the business switched that on.
  select a.* into v_auto from public.automations a
   where a.business_id = p_business_id and a.trigger_type = case when p_automation = 'new_lead_callback' then 'new_lead_callback' else 'missed_call_follow_up' end and a.status = 'active' limit 1;
  v_max := coalesce((v_auto.trigger_config ->> 'max_attempts')::integer, 3);
  -- missed-call: retry after retry_delay_minutes (default 2h); new lead: retry_after_hours (default 24h)
  v_delay := coalesce((v_auto.trigger_config ->> 'retry_delay_minutes')::integer, (v_auto.trigger_config ->> 'retry_after_hours')::integer * 60, 120);
  v_first := coalesce((v_auto.trigger_config ->> 'minutes_after')::integer, 5);

  -- Never silently book an inappropriate time: move it into the calling window.
  v_due := public.zella_next_call_time(coalesce(p_preferred_at, now() + make_interval(mins => v_first)), v_tz);
  if p_preferred_at is not null and v_due <> p_preferred_at then
    v_note := 'The requested time was outside calling hours, so it was moved to the next available time.';
  end if;

  insert into public.callbacks (business_id, customer_id, call_id, appointment_id, reason, priority, status, contact_number, summary,
      preferred_at, due_at, auto_call, max_attempts, retry_delay_minutes, note, created_by)
  values (p_business_id, v_cust, p_call_id, p_appointment_id, v_reason, v_priority, 'scheduled', p_contact_number, left(p_summary, 1000),
      p_preferred_at, v_due, (v_auto.id is not null and coalesce(v_auto.trigger_config ->> 'channel', 'call') = 'call' and v_reason not in ('needs_human', 'transfer_failed')),
      v_max, v_delay, v_note, case when p_created_by in ('ai','system','staff') then p_created_by else 'ai' end)
  on conflict (business_id, (public.zella_digits(contact_number)), reason) where contact_number is not null and status not in ('completed','cancelled','needs_review')
  do update set summary = coalesce(excluded.summary, callbacks.summary), priority = case when excluded.priority = 'urgent' or callbacks.priority = 'urgent' then 'urgent' when excluded.priority = 'high' or callbacks.priority = 'high' then 'high' else 'normal' end,
                call_id = coalesce(excluded.call_id, callbacks.call_id), updated_at = now()
  returning id into v_id;

  perform public.zella_notify(p_business_id, 'callback', 'Callback needed',
    coalesce(p_summary, 'A caller needs a call back.'), case when v_priority = 'normal' then 'info' else 'urgent' end, 'callbacks', v_id);
  return v_id;
end $$;

create or replace function public.zella_staff_create_callback(
  p_business_id uuid, p_contact_number text, p_summary text default null, p_preferred_at timestamptz default null,
  p_customer_id uuid default null, p_priority text default 'normal'
) returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return public.zella_create_callback(p_business_id, p_contact_number, 'requested', p_priority, p_summary, p_preferred_at, p_customer_id, null, null, 'staff');
end $$;

-- Staff actions on a callback (assign, start, mark contacted, reschedule, complete, cancel, escalate...).
create or replace function public.zella_update_callback(
  p_callback_id uuid, p_status text default null, p_note text default null, p_preferred_at timestamptz default null, p_assign_to uuid default null
) returns text language plpgsql security definer set search_path = public as $$
declare v_cb record; v_tz text; v_status text;
begin
  select * into v_cb from public.callbacks where id = p_callback_id for update;
  if not found or not public.zella_is_member(v_cb.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_status is not null and p_status not in ('scheduled','in_progress','contacted','reschedule_requested','waiting_on_customer','completed','cancelled','escalated','needs_review') then
    raise exception 'BAD_STATUS';
  end if;
  if v_cb.status in ('completed','cancelled') and p_status is not null then raise exception 'ALREADY_CLOSED'; end if;
  v_status := coalesce(p_status, v_cb.status);
  if p_preferred_at is not null then
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = v_cb.business_id;
    v_status := case when p_status is null or p_status = 'reschedule_requested' then 'scheduled' else v_status end;
    update public.callbacks set preferred_at = p_preferred_at, due_at = public.zella_next_call_time(p_preferred_at, v_tz) where id = p_callback_id;
  end if;
  update public.callbacks set status = v_status, note = coalesce(nullif(p_note, ''), note),
      assigned_to = coalesce(p_assign_to, assigned_to), locked_at = null,
      completed_at = case when v_status in ('completed','cancelled') then now() else completed_at end,
      outcome = case when v_status in ('completed','cancelled') then coalesce(nullif(p_note, ''), outcome, v_status) else outcome end,
      updated_at = now()
   where id = p_callback_id;
  return v_status;
end $$;

-- n8n: take callbacks that are due and that Zella is allowed to make by itself.
create or replace function public.zella_claim_callbacks(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res jsonb := '[]'::jsonb; v_cb record; v_biz record; v_cust record; v_next timestamptz;
begin
  for v_cb in
    select c.* from public.callbacks c
     where c.status in ('scheduled', 'retry_scheduled', 'due') and c.due_at <= now() and c.auto_call
       and (c.locked_at is null or c.locked_at < now() - interval '15 minutes')
     order by case c.priority when 'urgent' then 0 when 'high' then 1 else 2 end, c.due_at
     limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as tz, b.suspended_at, b.cancelled_at, coalesce(b.is_active, true) as is_active
      into v_biz from public.businesses b where b.id = v_cb.business_id;
    select c.first_name, c.last_name, coalesce(c.do_not_contact, false) as dnc into v_cust from public.customers c where c.id = v_cb.customer_id;
    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not v_biz.is_active then
      update public.callbacks set status = 'needs_review', outcome = 'business_inactive', updated_at = now() where id = v_cb.id; continue;
    end if;
    if coalesce(v_cust.dnc, false) then
      update public.callbacks set status = 'cancelled', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_cb.id; continue;
    end if;
    v_next := public.zella_next_call_time(now(), v_biz.tz);
    if v_next > now() + interval '1 minute' then
      update public.callbacks set due_at = v_next, updated_at = now() where id = v_cb.id; continue;
    end if;
    update public.callbacks set status = 'in_progress', attempts = attempts + 1, locked_at = now(), updated_at = now() where id = v_cb.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'callback_id', v_cb.id, 'attempt', v_cb.attempts + 1, 'max_attempts', v_cb.max_attempts, 'reason', v_cb.reason,
      'contact_number', v_cb.contact_number, 'summary', v_cb.summary,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.tz),
      'customer', jsonb_build_object('id', v_cb.customer_id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name)));
  end loop;
  return v_res;
end $$;

-- n8n or staff: record what happened on an attempt, then apply the retry policy.
create or replace function public.zella_record_callback_attempt(
  p_callback_id uuid, p_outcome text, p_provider_ref text default null, p_error text default null, p_notes text default null
) returns text language plpgsql security definer set search_path = public as $$
declare v_cb record; v_tz text; v_next timestamptz; v_status text; v_by text; v_uid uuid := auth.uid();
begin
  select * into v_cb from public.callbacks where id = p_callback_id for update;
  if not found then raise exception 'CALLBACK_NOT_FOUND'; end if;
  if v_uid is not null and not public.zella_is_member(v_cb.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_outcome not in ('connected','no_answer','busy','voicemail','invalid_number','failed_connection','declined') then raise exception 'BAD_OUTCOME'; end if;
  if v_cb.status in ('completed','cancelled') then raise exception 'ALREADY_CLOSED'; end if;
  v_by := case when v_uid is null then 'system' else v_uid::text end;
  -- staff calling by hand count as an attempt too
  if v_cb.status <> 'in_progress' then v_cb.attempts := v_cb.attempts + 1; end if;

  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = v_cb.business_id;
  if p_outcome in ('no_answer','busy','voicemail','failed_connection') and v_cb.attempts < v_cb.max_attempts then
    v_status := 'retry_scheduled';
    v_next := public.zella_next_call_time(now() + make_interval(mins => greatest(5, v_cb.retry_delay_minutes)), v_tz);
  elsif p_outcome in ('no_answer','busy','voicemail','failed_connection','invalid_number') then
    v_status := 'needs_review';       -- attempt limit reached (or bad number): stop automatic calling, hand to staff
  elsif p_outcome = 'connected' then v_status := 'contacted';
  else v_status := 'completed';       -- declined
  end if;

  insert into public.callback_attempts (callback_id, business_id, attempt_no, outcome, provider_ref, error, notes, next_attempt_at, initiated_by)
  values (p_callback_id, v_cb.business_id, v_cb.attempts, p_outcome, p_provider_ref, left(p_error, 300), p_notes, v_next, v_by);

  update public.callbacks set status = v_status, attempts = v_cb.attempts, due_at = coalesce(v_next, due_at), locked_at = null,
      outcome = case when v_status in ('contacted','completed','needs_review') then p_outcome else outcome end,
      completed_at = case when v_status = 'completed' then now() else completed_at end,
      auto_call = case when v_status = 'needs_review' then false else auto_call end,
      note = coalesce(nullif(p_notes, ''), note), updated_at = now()
   where id = p_callback_id;

  if v_status = 'needs_review' and p_outcome <> 'invalid_number' and v_cb.reason in ('missed_call', 'new_lead') then
    -- the business allowed a text as a last resort
    if exists (select 1 from public.automations a where a.business_id = v_cb.business_id and a.status = 'active'
                 and a.trigger_type = case when v_cb.reason = 'new_lead' then 'new_lead_callback' else 'missed_call_follow_up' end
                 and coalesce((a.trigger_config ->> 'fallback_sms')::boolean, false))
       and v_cb.customer_id is not null
       and exists (select 1 from public.customers c where c.id = v_cb.customer_id and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null) then
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, entity_ref)
      values (v_cb.business_id, v_cb.customer_id, 'callback_sms', 'sms', public.zella_next_call_time(now(), v_tz), 1, v_cb.id) on conflict do nothing;
    end if;
  end if;
  if v_status = 'needs_review' then
    perform public.zella_notify(v_cb.business_id, 'callback_review', 'A callback needs a person',
      case when p_outcome = 'invalid_number' then 'The phone number could not be reached.' else 'Zella tried ' || v_cb.attempts || ' times without reaching them.' end,
      'warning', 'callbacks', p_callback_id);
  end if;
  return v_status;
end $$;

-- The customer got in touch another way (called, texted, was booked): stop any waiting callbacks.
create or replace function public.zella_stop_callbacks_for(p_business_id uuid, p_customer_id uuid default null, p_phone text default null, p_reason text default 'customer_responded')
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.callbacks set status = 'completed', outcome = left(p_reason, 60), completed_at = now(), locked_at = null, auto_call = false, updated_at = now()
   where business_id = p_business_id and status in ('new','scheduled','due','retry_scheduled','waiting_on_customer')
     and ((p_customer_id is not null and customer_id = p_customer_id) or (p_phone is not null and public.zella_digits(contact_number) = public.zella_digits(p_phone)));
  get diagnostics n = row_count; return n;
end $$;

-- Missed call -> callback. Needs-a-human / failed transfer -> urgent callback.
create or replace function public.zella_calls_to_callbacks() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_row jsonb := to_jsonb(new); v_old jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
        v_phone text := coalesce(v_row ->> 'from_number', v_row ->> 'caller_number', v_row ->> 'phone');
        v_dir text := coalesce(v_row ->> 'direction', 'inbound');
begin
  if v_dir <> 'inbound' then return new; end if;
  if (v_row ->> 'status') = 'missed' and coalesce(v_old ->> 'status', '') <> 'missed' then
    perform public.zella_create_callback(new.business_id, v_phone, 'missed_call', 'normal', 'Missed call. Call them back.', null, new.customer_id, new.id, null, 'system');
  end if;
  if coalesce((v_row ->> 'transfer_status'), '') in ('failed', 'no_one_available') and coalesce(v_old ->> 'transfer_status', '') not in ('failed', 'no_one_available') then
    perform public.zella_create_callback(new.business_id, v_phone, 'transfer_failed', 'urgent',
      'The caller asked for a person but the transfer did not connect. ' || coalesce(v_row ->> 'summary', ''), null, new.customer_id, new.id, null, 'system');
  elsif coalesce((v_row ->> 'needs_human')::boolean, false) and not coalesce((v_old ->> 'needs_human')::boolean, false)
        and coalesce(v_row ->> 'transfer_status', '') <> 'connected' then
    perform public.zella_create_callback(new.business_id, v_phone, 'needs_human', 'high', coalesce(nullif(v_row ->> 'escalation_reason', ''), 'The caller needs a person.'), null, new.customer_id, new.id, null, 'system');
  end if;
  return new;
end $$;
drop trigger if exists zella_calls_callbacks_trg on public.calls;
create trigger zella_calls_callbacks_trg after insert or update on public.calls
  for each row execute function public.zella_calls_to_callbacks();

-- A customer who is marked do-not-contact must never be called again.
create or replace function public.zella_dnc_stops_callbacks() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.do_not_contact, false) and not coalesce(old.do_not_contact, false) then
    update public.callbacks set status = 'cancelled', outcome = 'do_not_contact', auto_call = false, completed_at = now(), updated_at = now()
     where customer_id = new.id and status not in ('completed', 'cancelled');
    update public.followup_tasks set status = 'cancelled', outcome = 'do_not_contact', completed_at = now(), updated_at = now()
     where customer_id = new.id and status = 'pending';
  end if;
  return new;
end $$;
drop trigger if exists zella_dnc_trg on public.customers;
create trigger zella_dnc_trg after update of do_not_contact on public.customers
  for each row execute function public.zella_dnc_stops_callbacks();

drop function if exists public.zella_create_callback(uuid, text, text, text, text, timestamptz, uuid, uuid, uuid, text);
revoke all on function public.zella_create_callback(uuid, text, text, text, text, timestamptz, uuid, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.zella_staff_create_callback(uuid, text, text, timestamptz, uuid, text) from public, anon;
revoke all on function public.zella_update_callback(uuid, text, text, timestamptz, uuid) from public, anon;
revoke all on function public.zella_claim_callbacks(integer) from public, anon, authenticated;
revoke all on function public.zella_record_callback_attempt(uuid, text, text, text, text) from public, anon;
revoke all on function public.zella_stop_callbacks_for(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.zella_calls_to_callbacks() from public, anon, authenticated;
revoke all on function public.zella_dnc_stops_callbacks() from public, anon, authenticated;
grant execute on function public.zella_create_callback(uuid, text, text, text, text, timestamptz, uuid, uuid, uuid, text, text) to service_role;
grant execute on function public.zella_staff_create_callback(uuid, text, text, timestamptz, uuid, text) to authenticated, service_role;
grant execute on function public.zella_update_callback(uuid, text, text, timestamptz, uuid) to authenticated, service_role;
grant execute on function public.zella_claim_callbacks(integer) to service_role;
grant execute on function public.zella_record_callback_attempt(uuid, text, text, text, text) to authenticated, service_role;
grant execute on function public.zella_stop_callbacks_for(uuid, uuid, text, text) to service_role;


-- =========================================================
-- Zella workflows, part 2: leads, tasks, quotes, duplicates.
-- Run AFTER part 1 (1_callbacks section). Safe to re-run.
-- =========================================================

alter table public.customers
  add column if not exists lead_stage text,
  add column if not exists assigned_to uuid,
  add column if not exists priority text,
  add column if not exists qualification jsonb not null default '{}'::jsonb,
  add column if not exists qualification_result text,
  add column if not exists contact_deadline_at timestamptz,
  add column if not exists next_follow_up_at timestamptz,
  add column if not exists lost_reason text,
  add column if not exists lost_at timestamptz,
  add column if not exists reactivate_after timestamptz,
  add column if not exists converted_at timestamptz;
do $$ begin
  alter table public.customers add constraint customers_lead_stage_chk
    check (lead_stage is null or lead_stage in ('new', 'contacted', 'qualified', 'unqualified', 'quote_sent', 'won', 'lost'));
  alter table public.customers add constraint customers_priority_chk check (priority is null or priority in ('normal', 'high', 'urgent'));
exception when duplicate_object then null; end $$;
create index if not exists customers_lead_stage_idx on public.customers (business_id, lead_stage);

-- Staff to-do items created by workflows (or by hand)
create table if not exists public.crm_tasks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  kind text not null default 'follow_up',
  title text not null,
  body text,
  priority text not null default 'normal' check (priority in ('normal', 'high', 'urgent')),
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  due_at timestamptz,
  assigned_to uuid,
  source text not null default 'automation' check (source in ('automation', 'ai', 'staff')),
  entity_id uuid,
  escalated_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists crm_tasks_biz_idx on public.crm_tasks (business_id, status, due_at);
create unique index if not exists crm_tasks_one_open_idx on public.crm_tasks (business_id, customer_id, kind)
  where status = 'open' and customer_id is not null and kind in ('overdue_contact', 'duplicate_review', 'onboarding', 'quote_review');

create table if not exists public.lead_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  -- all keys must match: {"source":"website","keyword":"emergency","answer_equals":{"urgent":"yes"}}
  match jsonb not null default '{}'::jsonb,
  assign_to uuid,
  set_priority text check (set_priority in ('normal', 'high', 'urgent')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.lead_questions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  key text not null,
  question text not null,
  required boolean not null default false,
  -- optional rule that counts as "qualified": {"equals":"yes"} or {"min":3}
  qualifies_when jsonb,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  unique (business_id, key)
);
create table if not exists public.quotes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  title text not null,
  status text not null default 'issued' check (status in ('issued', 'accepted', 'declined', 'expired')),
  issued_at timestamptz not null default now(),
  expires_at timestamptz,
  follow_ups_sent integer not null default 0,
  max_follow_ups integer not null default 3,
  follow_up_every_days integer not null default 3,
  next_follow_up_at timestamptz,
  closed_at timestamptz,
  created_by uuid
);
create index if not exists quotes_biz_idx on public.quotes (business_id, status, next_follow_up_at);
create table if not exists public.duplicate_reviews (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,   -- the existing record it might match
  incoming jsonb not null,
  status text not null default 'open' check (status in ('open', 'merged', 'kept_separate', 'dismissed')),
  resolved_by uuid, resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists duplicate_reviews_biz_idx on public.duplicate_reviews (business_id, status);

alter table public.crm_tasks enable row level security;
alter table public.lead_rules enable row level security;
alter table public.lead_questions enable row level security;
alter table public.quotes enable row level security;
alter table public.duplicate_reviews enable row level security;
do $$ declare t text; begin
  foreach t in array array['crm_tasks','quotes','duplicate_reviews'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.zella_is_member(business_id))', t || '_select', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
  foreach t in array array['lead_rules','lead_questions'] loop
    execute format('drop policy if exists %I on public.%I', t || '_all', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.zella_is_member(business_id)) with check (public.zella_is_member(business_id))', t || '_all', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- ---- helpers ------------------------------------------------------------
create or replace function public.zella_create_task(p_business_id uuid, p_customer_id uuid, p_kind text, p_title text, p_body text default null,
  p_priority text default 'normal', p_due_at timestamptz default null, p_assigned_to uuid default null, p_source text default 'automation', p_entity_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.crm_tasks (business_id, customer_id, kind, title, body, priority, due_at, assigned_to, source, entity_id)
  values (p_business_id, p_customer_id, coalesce(p_kind, 'follow_up'), p_title, p_body, case when p_priority in ('high','urgent') then p_priority else 'normal' end,
          p_due_at, p_assigned_to, case when p_source in ('automation','ai','staff') then p_source else 'automation' end, p_entity_id)
  on conflict (business_id, customer_id, kind) where status = 'open' and customer_id is not null and kind in ('overdue_contact','duplicate_review','onboarding','quote_review')
  do nothing returning id into v_id;
  return v_id;
end $$;
revoke all on function public.zella_create_task(uuid, uuid, text, text, text, text, timestamptz, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_create_task(uuid, uuid, text, text, text, text, timestamptz, uuid, text, uuid) to service_role;

create or replace function public.zella_staff_create_task(p_business_id uuid, p_customer_id uuid, p_title text, p_due_at timestamptz default null, p_assigned_to uuid default null, p_priority text default 'normal')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if nullif(trim(coalesce(p_title, '')), '') is null then raise exception 'EMPTY_TITLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.crm_tasks (business_id, customer_id, kind, title, priority, due_at, assigned_to, source)
  values (p_business_id, p_customer_id, 'follow_up', trim(p_title), case when p_priority in ('high','urgent') then p_priority else 'normal' end, p_due_at, p_assigned_to, 'staff') returning id into v_id;
  return v_id;
end $$;
create or replace function public.zella_complete_task(p_task_id uuid, p_cancel boolean default false) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_b uuid;
begin
  select business_id into v_b from public.crm_tasks where id = p_task_id;
  if v_b is null or not public.zella_is_member(v_b) then raise exception 'NOT_ALLOWED'; end if;
  update public.crm_tasks set status = case when p_cancel then 'cancelled' else 'done' end, completed_at = now() where id = p_task_id and status = 'open';
  return found;
end $$;
revoke all on function public.zella_staff_create_task(uuid, uuid, text, timestamptz, uuid, text) from public, anon;
revoke all on function public.zella_complete_task(uuid, boolean) from public, anon;
grant execute on function public.zella_staff_create_task(uuid, uuid, text, timestamptz, uuid, text) to authenticated, service_role;
grant execute on function public.zella_complete_task(uuid, boolean) to authenticated, service_role;

-- Routing + priority rules. First match in sort order wins; otherwise the
-- team member with the fewest open leads gets it.
create or replace function public.zella_apply_lead_rules(p_customer_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c record; r record; v_assign uuid; v_priority text := 'normal'; v_text text; v_ok boolean; k text; v_hit boolean := false;
begin
  select * into c from public.customers where id = p_customer_id;
  if not found then return; end if;
  v_text := lower(coalesce(c.notes, '') || ' ' || coalesce(c.qualification::text, ''));
  for r in select * from public.lead_rules where business_id = c.business_id and is_active order by sort_order, created_at loop
    v_ok := true;
    if r.match ? 'source' and coalesce(c.source, '') <> r.match ->> 'source' then v_ok := false; end if;
    if v_ok and r.match ? 'keyword' and position(lower(r.match ->> 'keyword') in v_text) = 0 then v_ok := false; end if;
    if v_ok and r.match ? 'answer_equals' then
      for k in select jsonb_object_keys(r.match -> 'answer_equals') loop
        if lower(coalesce(c.qualification ->> k, '')) <> lower(r.match -> 'answer_equals' ->> k) then v_ok := false; end if;
      end loop;
    end if;
    if v_ok then
      v_hit := true;
      v_assign := coalesce(v_assign, r.assign_to);
      if r.set_priority is not null and (r.set_priority = 'urgent' or (r.set_priority = 'high' and v_priority = 'normal')) then v_priority := r.set_priority; end if;
      if v_assign is not null and v_priority <> 'normal' then exit; end if;
    end if;
  end loop;
  if v_assign is null then
    select m.user_id into v_assign from public.business_members m
     where m.business_id = c.business_id and m.status = 'active'
     order by (select count(*) from public.customers x where x.business_id = c.business_id and x.assigned_to = m.user_id and x.lead_stage in ('new','contacted','qualified','quote_sent')), m.created_at
     limit 1;
  end if;
  update public.customers set assigned_to = coalesce(c.assigned_to, v_assign),
         priority = case when c.priority in ('high','urgent') and v_priority = 'normal' then c.priority else v_priority end
   where id = p_customer_id;
end $$;
revoke all on function public.zella_apply_lead_rules(uuid) from public, anon, authenticated;

-- Save the answers to the business's approved qualifying questions, then judge them.
create or replace function public.zella_save_qualification(p_customer_id uuid, p_answers jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare c record; q record; v_ans text; v_stage text := 'qualified'; v_any boolean := false; v_ok boolean;
begin
  select * into c from public.customers where id = p_customer_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is not null and not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  -- keep only keys that are approved questions
  update public.customers set qualification = coalesce(qualification, '{}'::jsonb) || coalesce((
    select jsonb_object_agg(e.key, e.value) from jsonb_each(coalesce(p_answers, '{}'::jsonb)) e
     where exists (select 1 from public.lead_questions lq where lq.business_id = c.business_id and lq.key = e.key and lq.is_active)), '{}'::jsonb)
   where id = p_customer_id returning * into c;
  for q in select * from public.lead_questions where business_id = c.business_id and is_active loop
    v_ans := c.qualification ->> q.key;
    if q.required and nullif(trim(coalesce(v_ans, '')), '') is null then v_stage := 'new'; end if;
    if q.qualifies_when is not null and nullif(trim(coalesce(v_ans, '')), '') is not null then
      v_any := true; v_ok := true;
      if q.qualifies_when ? 'equals' then v_ok := lower(coalesce(v_ans, '')) = lower(q.qualifies_when ->> 'equals'); end if;
      if v_ok and q.qualifies_when ? 'min' then v_ok := coalesce(nullif(regexp_replace(coalesce(v_ans, ''), '[^0-9.]', '', 'g'), '')::numeric, -1) >= (q.qualifies_when ->> 'min')::numeric; end if;
      if not v_ok and v_stage = 'qualified' then v_stage := 'unqualified'; end if;
    end if;
  end loop;
  -- The result is stored on the record. The pipeline stage only moves once a person has contacted the lead.
  update public.customers set qualification_result = case when v_stage = 'new' then 'incomplete' else v_stage end,
         lead_stage = case when lead_stage = 'contacted' and v_stage in ('qualified', 'unqualified') then v_stage else lead_stage end
   where id = p_customer_id;
  perform public.zella_apply_lead_rules(p_customer_id);
  return v_stage;
end $$;
revoke all on function public.zella_save_qualification(uuid, jsonb) from public, anon;
grant execute on function public.zella_save_qualification(uuid, jsonb) to authenticated, service_role;

-- ---- capture a lead (call, website form, SMS, AI) --------------------------
create or replace function public.zella_capture_lead(
  p_business_id uuid, p_first_name text default null, p_last_name text default null, p_phone text default null, p_email text default null,
  p_source text default 'website', p_notes text default null, p_answers jsonb default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_m record; v_id uuid; v_auto record; v_minutes integer; v_assigned uuid; v_pri text; v_name text; v_note_add text;
begin
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  -- validate: need some way to reach them, and sane lengths
  if public.zella_digits(p_phone) is null and nullif(trim(coalesce(p_email, '')), '') is null then raise exception 'NO_CONTACT'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  v_name := nullif(trim(coalesce(p_first_name, '') || ' ' || coalesce(p_last_name, '')), '');
  select * into v_m from public.zella_match_customer(p_business_id, p_phone, p_email);

  if v_m.certainty = 'uncertain' then
    insert into public.duplicate_reviews (business_id, customer_id, incoming)
    values (p_business_id, v_m.customer_id, jsonb_build_object('first_name', p_first_name, 'last_name', p_last_name, 'phone', p_phone, 'email', p_email, 'source', p_source, 'notes', p_notes, 'answers', p_answers));
    perform public.zella_create_task(p_business_id, v_m.customer_id, 'duplicate_review', 'Possible duplicate: check ' || coalesce(v_name, 'a new enquiry'), 'Zella found more than one possible match, so nothing was created or changed.', 'normal', now() + interval '1 day', null, 'ai');
    perform public.zella_notify(p_business_id, 'duplicate', 'Possible duplicate to review', coalesce(v_name, 'A new enquiry') || ' may already be in your list.', 'info', 'tasks', v_m.customer_id);
    return jsonb_build_object('result', 'needs_review', 'customer_id', v_m.customer_id);
  end if;

  if v_m.certainty = 'exact' then
    v_note_add := nullif(trim(coalesce(p_notes, '')), '');
    update public.customers set notes = case when v_note_add is null then notes else coalesce(notes || E'\n', '') || to_char(now(), 'YYYY-MM-DD') || ': ' || v_note_add end,
           updated_at = now() where id = v_m.customer_id;
    if p_answers is not null then perform public.zella_save_qualification(v_m.customer_id, p_answers); end if;
    return jsonb_build_object('result', 'matched', 'customer_id', v_m.customer_id);
  end if;

  select a.* into v_auto from public.automations a where a.business_id = p_business_id and a.trigger_type = 'new_lead_callback' and a.status = 'active' limit 1;
  v_minutes := coalesce((v_auto.trigger_config ->> 'contact_within_minutes')::integer, 60);
  insert into public.customers (business_id, first_name, last_name, phone, email, source, notes, lead_stage, contact_deadline_at)
  values (p_business_id, nullif(trim(p_first_name), ''), nullif(trim(p_last_name), ''), nullif(trim(p_phone), ''), lower(nullif(trim(p_email), '')), coalesce(nullif(p_source, ''), 'website'),
          left(p_notes, 2000), 'new', now() + make_interval(mins => v_minutes))
  returning id into v_id;
  if p_answers is not null then perform public.zella_save_qualification(v_id, p_answers); else perform public.zella_apply_lead_rules(v_id); end if;
  select assigned_to, priority into v_assigned, v_pri from public.customers where id = v_id;
  update public.customers set next_follow_up_at = contact_deadline_at where id = v_id;
  perform public.zella_create_task(p_business_id, v_id, 'follow_up', 'Contact ' || coalesce(v_name, 'the new lead'), coalesce(p_notes, ''), coalesce(v_pri, 'normal'), now() + make_interval(mins => v_minutes), v_assigned, 'ai');
  -- the business turned on automatic callbacks for new leads
  if v_auto.id is not null and public.zella_digits(p_phone) is not null then
    perform public.zella_create_callback(p_business_id, p_phone, 'new_lead', coalesce(v_pri, 'normal'), 'New lead: ' || coalesce(p_notes, 'call them back.'), null, v_id, null, null, 'system', 'new_lead_callback');
  end if;
  perform public.zella_notify(p_business_id, 'new_lead', case when v_pri in ('high','urgent') then 'New priority lead' else 'New lead' end,
    coalesce(v_name, 'A new enquiry') || ' came in from ' || coalesce(p_source, 'website') || '.', case when v_pri in ('high','urgent') then 'urgent' else 'info' end, 'leads', v_id, v_assigned);
  return jsonb_build_object('result', 'created', 'customer_id', v_id, 'assigned_to', v_assigned, 'priority', v_pri);
end $$;
revoke all on function public.zella_capture_lead(uuid, text, text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_capture_lead(uuid, text, text, text, text, text, text, jsonb) to service_role;

-- Staff: resolve a possible duplicate.
create or replace function public.zella_resolve_duplicate(p_review_id uuid, p_action text) returns uuid
language plpgsql security definer set search_path = public as $$
declare d record; v_id uuid := null; i jsonb;
begin
  select * into d from public.duplicate_reviews where id = p_review_id for update;
  if not found or not public.zella_is_member(d.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  i := d.incoming;
  if p_action = 'merge' and d.customer_id is not null then
    update public.customers set first_name = coalesce(first_name, nullif(i ->> 'first_name', '')), last_name = coalesce(last_name, nullif(i ->> 'last_name', '')),
           phone = coalesce(phone, nullif(i ->> 'phone', '')), email = coalesce(email, lower(nullif(i ->> 'email', ''))),
           notes = case when nullif(i ->> 'notes', '') is null then notes else coalesce(notes || E'\n', '') || (i ->> 'notes') end, updated_at = now()
     where id = d.customer_id;
    v_id := d.customer_id;
    update public.duplicate_reviews set status = 'merged', resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
  elsif p_action = 'keep_separate' then
    insert into public.customers (business_id, first_name, last_name, phone, email, source, notes, lead_stage)
    values (d.business_id, nullif(i ->> 'first_name', ''), nullif(i ->> 'last_name', ''), nullif(i ->> 'phone', ''), lower(nullif(i ->> 'email', '')), coalesce(nullif(i ->> 'source', ''), 'website'), nullif(i ->> 'notes', ''), 'new')
    returning id into v_id;
    perform public.zella_apply_lead_rules(v_id);
    update public.duplicate_reviews set status = 'kept_separate', resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
  elsif p_action = 'dismiss' then
    update public.duplicate_reviews set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
  else raise exception 'BAD_ACTION'; end if;
  update public.crm_tasks set status = 'done', completed_at = now() where business_id = d.business_id and kind = 'duplicate_review' and status = 'open' and customer_id is not distinct from d.customer_id;
  return v_id;
end $$;
revoke all on function public.zella_resolve_duplicate(uuid, text) from public, anon;
grant execute on function public.zella_resolve_duplicate(uuid, text) to authenticated, service_role;

-- Staff: change a lead's stage, assignment. Won/lost stop the sales reminders.
create or replace function public.zella_set_lead_stage(p_customer_id uuid, p_stage text, p_reason text default null, p_reengage_days integer default null)
returns text language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from public.customers where id = p_customer_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_stage not in ('new','contacted','qualified','unqualified','quote_sent','won','lost') then raise exception 'BAD_STAGE'; end if;
  if p_stage = 'lost' and nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'REASON_REQUIRED'; end if;

  update public.customers set lead_stage = p_stage, updated_at = now(),
         last_contacted_at = case when p_stage = 'contacted' then now() else last_contacted_at end,
         converted_at = case when p_stage = 'won' then now() else converted_at end,
         lost_reason = case when p_stage = 'lost' then trim(p_reason) else lost_reason end,
         lost_at = case when p_stage = 'lost' then now() else lost_at end,
         reactivate_after = case when p_stage = 'lost' and p_reengage_days > 0 and not coalesce(do_not_contact, false) then now() + make_interval(days => p_reengage_days) else null end,
         contact_deadline_at = case when p_stage in ('contacted','qualified','quote_sent','won','lost') then null else contact_deadline_at end,
         next_follow_up_at = case when p_stage in ('won','lost') then null else next_follow_up_at end
   where id = p_customer_id;

  if p_stage in ('contacted','qualified','quote_sent','won','lost') then
    update public.crm_tasks set status = 'done', completed_at = now() where customer_id = p_customer_id and status = 'open' and kind in ('follow_up', 'overdue_contact');
  end if;
  if p_stage in ('won', 'lost') then
    -- stop active sales reminders
    update public.followup_tasks set status = 'cancelled', outcome = 'lead_' || p_stage, completed_at = now(), updated_at = now()
     where customer_id = p_customer_id and status = 'pending' and kind in ('quote_follow_up', 'lead_reactivation', 'new_lead_callback');
    update public.callbacks set status = 'cancelled', outcome = 'lead_' || p_stage, auto_call = false, completed_at = now(), updated_at = now()
     where customer_id = p_customer_id and status not in ('completed', 'cancelled');
    update public.quotes set status = case when p_stage = 'won' then 'accepted' else 'declined' end, closed_at = now(), next_follow_up_at = null
     where customer_id = p_customer_id and status = 'issued';
  end if;
  if p_stage = 'won' then
    perform public.zella_create_task(c.business_id, p_customer_id, 'onboarding', 'Start onboarding for ' || coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'the new customer'), null, 'normal', now() + interval '1 day', c.assigned_to, 'automation');
  end if;
  return p_stage;
end $$;
create or replace function public.zella_assign_lead(p_customer_id uuid, p_user_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_b uuid;
begin
  select business_id into v_b from public.customers where id = p_customer_id;
  if v_b is null or not public.zella_is_member(v_b) then raise exception 'NOT_ALLOWED'; end if;
  if p_user_id is not null and not exists (select 1 from public.business_members where business_id = v_b and user_id = p_user_id and status = 'active') then raise exception 'NOT_A_MEMBER'; end if;
  update public.customers set assigned_to = p_user_id, updated_at = now() where id = p_customer_id;
  update public.crm_tasks set assigned_to = p_user_id where customer_id = p_customer_id and status = 'open';
  return true;
end $$;
revoke all on function public.zella_set_lead_stage(uuid, text, text, integer) from public, anon;
revoke all on function public.zella_assign_lead(uuid, uuid) from public, anon;
grant execute on function public.zella_set_lead_stage(uuid, text, text, integer) to authenticated, service_role;
grant execute on function public.zella_assign_lead(uuid, uuid) to authenticated, service_role;

-- n8n (scheduled): leads not contacted by their deadline -> overdue task + notify owner, escalate if configured.
create or replace function public.zella_flag_overdue_leads() returns integer
language plpgsql security definer set search_path = public as $$
declare c record; n integer := 0; v_esc integer; v_auto record;
begin
  for c in select * from public.customers x
            where x.lead_stage = 'new' and x.contact_deadline_at is not null and x.contact_deadline_at < now() and x.last_contacted_at is null loop
    select a.* into v_auto from public.automations a where a.business_id = c.business_id and a.trigger_type = 'new_lead_callback' and a.status = 'active' limit 1;
    v_esc := nullif(v_auto.trigger_config ->> 'escalate_after_minutes', '')::integer;
    if public.zella_create_task(c.business_id, c.id, 'overdue_contact', 'Overdue: contact ' || coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'this lead'),
         'This lead was not contacted in time.', 'high', now(), c.assigned_to, 'automation') is not null then
      perform public.zella_notify(c.business_id, 'lead_overdue', 'Lead not contacted in time', coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'A lead') || ' is waiting.', 'warning', 'tasks', c.id, c.assigned_to);
      n := n + 1;
    end if;
    if v_esc is not null and c.contact_deadline_at < now() - make_interval(mins => v_esc) then
      update public.crm_tasks set escalated_at = now(), priority = 'urgent'
       where customer_id = c.id and kind = 'overdue_contact' and status = 'open' and escalated_at is null;
      if found then
        perform public.zella_notify(c.business_id, 'lead_escalated', 'Escalated: lead still not contacted', coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'A lead') || ' has waited too long.', 'urgent', 'tasks', c.id);
      end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.zella_flag_overdue_leads() from public, anon, authenticated;
grant execute on function public.zella_flag_overdue_leads() to service_role;

-- ---- quotes -----------------------------------------------------------------
create or replace function public.zella_issue_quote(p_customer_id uuid, p_title text, p_expires_in_days integer default 30) returns uuid
language plpgsql security definer set search_path = public as $$
declare c record; v_id uuid; v_auto record;
begin
  select * into c from public.customers where id = p_customer_id;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  select a.* into v_auto from public.automations a where a.business_id = c.business_id and a.trigger_type = 'quote_follow_up' and a.status = 'active' limit 1;
  insert into public.quotes (business_id, customer_id, title, expires_at, max_follow_ups, follow_up_every_days, next_follow_up_at, created_by)
  values (c.business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Quote'), now() + make_interval(days => greatest(1, coalesce(p_expires_in_days, 30))),
          coalesce((v_auto.trigger_config ->> 'max_follow_ups')::integer, 3), coalesce((v_auto.trigger_config ->> 'every_days')::integer, 3),
          case when v_auto.id is not null then now() + make_interval(days => coalesce((v_auto.trigger_config ->> 'every_days')::integer, 3)) end, auth.uid())
  returning id into v_id;
  update public.customers set lead_stage = 'quote_sent', contact_deadline_at = null, updated_at = now() where id = p_customer_id and coalesce(lead_stage, 'new') not in ('won', 'lost');
  return v_id;
end $$;
create or replace function public.zella_set_quote_status(p_quote_id uuid, p_status text) returns text
language plpgsql security definer set search_path = public as $$
declare q record;
begin
  select * into q from public.quotes where id = p_quote_id for update;
  if not found or not public.zella_is_member(q.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_status not in ('accepted', 'declined', 'expired') then raise exception 'BAD_STATUS'; end if;
  update public.quotes set status = p_status, closed_at = now(), next_follow_up_at = null where id = p_quote_id and status = 'issued';
  update public.followup_tasks set status = 'cancelled', outcome = 'quote_' || p_status, completed_at = now(), updated_at = now()
   where entity_ref = p_quote_id and status = 'pending';
  return p_status;
end $$;
-- n8n (scheduled): follow up on open quotes, stop when closed / expired / customer opted out / limit reached.
create or replace function public.zella_queue_quote_followups() returns integer
language plpgsql security definer set search_path = public as $$
declare q record; v_tz text; n integer := 0; c record; v_auto record;
begin
  for q in select * from public.quotes where status = 'issued' and next_follow_up_at is not null and next_follow_up_at <= now() for update skip locked loop
    if q.expires_at is not null and q.expires_at < now() then
      update public.quotes set status = 'expired', closed_at = now(), next_follow_up_at = null where id = q.id; continue;
    end if;
    select * into c from public.customers where id = q.customer_id;
    select a.* into v_auto from public.automations a where a.business_id = q.business_id and a.trigger_type = 'quote_follow_up' and a.status = 'active' limit 1;
    if c.id is null or coalesce(c.do_not_contact, false) or c.lead_stage in ('won', 'lost') or v_auto.id is null then
      update public.quotes set next_follow_up_at = null where id = q.id; continue;
    end if;
    if q.follow_ups_sent >= q.max_follow_ups then
      update public.quotes set next_follow_up_at = null where id = q.id;
      perform public.zella_create_task(q.business_id, q.customer_id, 'quote_review', 'Quote still open after ' || q.follow_ups_sent || ' follow-ups: ' || q.title, 'Decide whether to close it.', 'normal', now(), c.assigned_to, 'automation', q.id);
      continue;
    end if;
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = q.business_id;
    insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, entity_ref)
    values (q.business_id, q.customer_id, 'quote_follow_up', case when v_auto.trigger_config ->> 'channel' = 'call' then 'call' else 'sms' end, public.zella_next_call_time(now(), v_tz), 1, q.id);
    update public.quotes set follow_ups_sent = follow_ups_sent + 1, next_follow_up_at = now() + make_interval(days => q.follow_up_every_days) where id = q.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_issue_quote(uuid, text, integer) from public, anon;
revoke all on function public.zella_set_quote_status(uuid, text) from public, anon;
revoke all on function public.zella_queue_quote_followups() from public, anon, authenticated;
grant execute on function public.zella_issue_quote(uuid, text, integer) to authenticated, service_role;
grant execute on function public.zella_set_quote_status(uuid, text) to authenticated, service_role;
grant execute on function public.zella_queue_quote_followups() to service_role;

-- ---- reactivation (only for businesses that switched it on, and only with permission) -----
create or replace function public.zella_queue_lead_reactivation(p_limit integer default 25) returns integer
language plpgsql security definer set search_path = public as $$
declare c record; v_auto record; n integer := 0; v_tz text; v_days integer;
begin
  for v_auto in select * from public.automations a where a.trigger_type = 'lead_reactivation' and a.status = 'active' loop
    v_days := coalesce((v_auto.trigger_config ->> 'inactive_days')::integer, 60);
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b
     where b.id = v_auto.business_id and b.suspended_at is null and b.cancelled_at is null;
    if v_tz is null then continue; end if;
    for c in select x.* from public.customers x
              where x.business_id = v_auto.business_id and not coalesce(x.do_not_contact, false) and public.zella_digits(x.phone) is not null
                and ((x.lead_stage = 'lost' and x.reactivate_after is not null and x.reactivate_after <= now())
                  or (x.lead_stage in ('new','contacted','qualified','unqualified') and coalesce(x.last_contacted_at, x.created_at) < now() - make_interval(days => v_days)))
                and not exists (select 1 from public.followup_tasks f where f.customer_id = x.id and f.kind = 'lead_reactivation' and f.created_at > now() - interval '90 days')
              limit greatest(1, least(coalesce(p_limit, 25), 100)) loop
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts)
      values (c.business_id, c.id, 'lead_reactivation', case when v_auto.trigger_config ->> 'channel' = 'call' then 'call' else 'sms' end, public.zella_next_call_time(now(), v_tz), 1);
      update public.customers set reactivate_after = null where id = c.id and reactivate_after is not null;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.zella_queue_lead_reactivation(integer) from public, anon, authenticated;
grant execute on function public.zella_queue_lead_reactivation(integer) to service_role;


-- =========================================================
-- Zella workflows, part 3: appointments. Booking states, reminders
-- that follow reschedules/cancellations, safe booking + rescheduling,
-- cancellation slot recovery with a waitlist, staff-unavailable handling,
-- post-appointment follow-up.
-- Run AFTER parts 1 and 2. Safe to re-run.
-- =========================================================

alter table public.appointments
  add column if not exists booking_state text not null default 'confirmed',
  add column if not exists hold_expires_at timestamptz,
  add column if not exists original_start_time timestamptz,
  add column if not exists rescheduled_at timestamptz,
  add column if not exists reschedule_count integer not null default 0,
  add column if not exists reschedule_requested_by text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancel_reason text,
  add column if not exists conflict_note text;
do $$ begin
  alter table public.appointments add constraint appointments_booking_state_chk check (booking_state in ('requested', 'tentative', 'confirmed'));
exception when duplicate_object then null; end $$;

create table if not exists public.appointment_reminders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  customer_id uuid,
  kind text not null check (kind in ('reminder', 'confirmation', 'confirmation_request')),
  channel text not null default 'sms',
  hours_before numeric,
  reason text,                         -- booked | rescheduled
  due_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'cancelled', 'skipped')),
  attempts integer not null default 0,
  sent_at timestamptz,
  error text,
  created_at timestamptz not null default now()
);
create index if not exists appointment_reminders_due_idx on public.appointment_reminders (due_at) where status = 'pending';
create index if not exists appointment_reminders_appt_idx on public.appointment_reminders (appointment_id);
create unique index if not exists appointment_reminders_one_live_idx
  on public.appointment_reminders (appointment_id, kind, coalesce(hours_before, 0)) where status in ('pending', 'sending');
-- older installs
alter table public.appointment_reminders add column if not exists channel text not null default 'sms';
do $$ begin alter table public.appointment_reminders drop constraint if exists appointment_reminders_kind_check;
  alter table public.appointment_reminders add constraint appointment_reminders_kind_check check (kind in ('reminder', 'confirmation', 'confirmation_request')); end $$;
alter table public.appointment_reminders enable row level security;
drop policy if exists appointment_reminders_select on public.appointment_reminders;
create policy appointment_reminders_select on public.appointment_reminders for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.appointment_reminders from anon;
revoke insert, update, delete on public.appointment_reminders from authenticated;
grant select on public.appointment_reminders to authenticated;

create table if not exists public.waitlist_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  title text,                          -- service / reason
  duration_minutes integer not null default 30,
  earliest_at timestamptz,
  latest_at timestamptz,
  staff_id uuid,
  notes text,
  status text not null default 'waiting' check (status in ('waiting', 'offered', 'booked', 'removed')),
  offered_start timestamptz,
  offered_end timestamptz,
  offered_staff_id uuid,
  offer_expires_at timestamptz,
  appointment_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists waitlist_biz_idx on public.waitlist_entries (business_id, status, created_at);
create unique index if not exists waitlist_one_active_idx on public.waitlist_entries (business_id, customer_id, coalesce(title, '')) where status in ('waiting', 'offered');
alter table public.waitlist_entries enable row level security;
drop policy if exists waitlist_select on public.waitlist_entries;
create policy waitlist_select on public.waitlist_entries for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.waitlist_entries from anon;
revoke insert, update, delete on public.waitlist_entries from authenticated;
grant select on public.waitlist_entries to authenticated;

-- ---- reminders ------------------------------------------------------------
create or replace function public.zella_replace_reminders(p_appointment_id uuid, p_send_confirmation boolean default false, p_reason text default 'booked')
returns void language plpgsql security definer set search_path = public as $$
declare a record; v_rem record; v_conf record; v_hours numeric[]; h numeric;
begin
  update public.appointment_reminders set status = 'cancelled', error = 'replaced' where appointment_id = p_appointment_id and status in ('pending');
  select * into a from public.appointments where id = p_appointment_id;
  if not found or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or a.start_time <= now() then return; end if;

  select x.* into v_rem from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_reminder' and x.status = 'active' limit 1;
  if v_rem.id is not null then
    v_hours := case when v_rem.trigger_config ? 'hours_before' and jsonb_typeof(v_rem.trigger_config -> 'hours_before') = 'array'
                    then array(select jsonb_array_elements_text(v_rem.trigger_config -> 'hours_before')::numeric) else array[24]::numeric[] end;
    foreach h in array v_hours loop
      if a.start_time - make_interval(secs => h * 3600) > now() then
        insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
        values (a.business_id, a.id, a.customer_id, 'reminder', h, p_reason, a.start_time - make_interval(secs => h * 3600), coalesce(v_rem.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
      end if;
    end loop;
  end if;
  select x.* into v_conf from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_confirmation' and x.status = 'active' limit 1;
  if v_conf.id is not null then
    if p_send_confirmation then
      insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, reason, due_at, channel)
      values (a.business_id, a.id, a.customer_id, 'confirmation', p_reason, now(), coalesce(v_conf.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
    end if;
    -- later, ask them to confirm they are still coming
    h := coalesce((v_conf.trigger_config ->> 'hours_before')::numeric, 24);
    if a.start_time - make_interval(secs => h * 3600) > now() then
      insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
      values (a.business_id, a.id, a.customer_id, 'confirmation_request', h, p_reason, a.start_time - make_interval(secs => h * 3600), coalesce(v_conf.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
    end if;
  end if;
end $$;
revoke all on function public.zella_replace_reminders(uuid, boolean, text) from public, anon, authenticated;

create or replace function public.zella_appointment_before() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.start_time is distinct from old.start_time then
      new.original_start_time := coalesce(old.original_start_time, old.start_time);
      new.rescheduled_at := now();
      new.reschedule_count := coalesce(old.reschedule_count, 0) + 1;
      new.conflict_note := null;
    end if;
    if new.status = 'cancelled' and old.status is distinct from 'cancelled' then new.cancelled_at := now(); end if;
  end if;
  return new;
end $$;
drop trigger if exists zella_appointment_before_trg on public.appointments;
create trigger zella_appointment_before_trg before update on public.appointments for each row execute function public.zella_appointment_before();

-- ---- cancellation: offer the freed slot to the waitlist ----------------------------
create or replace function public.zella_offer_slot(p_business_id uuid, p_start timestamptz, p_end timestamptz, p_staff_id uuid, p_exclude_customer uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_auto record; w record; v_n integer := 0; v_max integer; v_tz text; v_mins integer;
begin
  select a.* into v_auto from public.automations a where a.business_id = p_business_id and a.trigger_type = 'waitlist_offer' and a.status = 'active' limit 1;
  if v_auto.id is null or p_start <= now() then return 0; end if;
  v_max := coalesce((v_auto.trigger_config ->> 'offers')::integer, 1);
  v_mins := coalesce((v_auto.trigger_config ->> 'offer_minutes')::integer, 30);
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then return 0; end if;
  for w in
    select e.* from public.waitlist_entries e join public.customers c on c.id = e.customer_id
     where e.business_id = p_business_id and e.status = 'waiting'
       and (p_exclude_customer is null or e.customer_id <> p_exclude_customer)
       and (e.earliest_at is null or e.earliest_at <= p_start) and (e.latest_at is null or e.latest_at >= p_end)
       and (e.staff_id is null or p_staff_id is null or e.staff_id = p_staff_id)
       and e.duration_minutes <= extract(epoch from (p_end - p_start)) / 60
       and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null
     order by e.created_at limit v_max for update of e skip locked
  loop
    update public.waitlist_entries set status = 'offered', offered_start = p_start, offered_end = p_start + make_interval(mins => w.duration_minutes),
           offered_staff_id = p_staff_id, offer_expires_at = now() + make_interval(mins => v_mins) where id = w.id;
    -- the customer is only asked; nothing is reserved until they say yes
    insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, entity_ref)
    values (p_business_id, w.customer_id, 'waitlist_offer', 'sms', public.zella_next_call_time(now(), v_tz), 1, w.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.zella_offer_slot(uuid, timestamptz, timestamptz, uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_offer_slot(uuid, timestamptz, timestamptz, uuid, uuid) to service_role;

create or replace function public.zella_appointment_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end; v_new jsonb := to_jsonb(new);
        v_time_changed boolean := tg_op = 'UPDATE' and new.start_time is distinct from old.start_time;
        v_status_changed boolean := tg_op = 'UPDATE' and new.status is distinct from old.status;
        v_state_changed boolean := tg_op = 'UPDATE' and coalesce(v_new ->> 'booking_state', '') is distinct from coalesce(v_old ->> 'booking_state', '');
        v_auto record; v_tz text; v_who text;
begin
  select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), new.title) into v_who from public.customers c where c.id = new.customer_id;
  v_who := coalesce(v_who, new.title);

  if tg_op = 'INSERT' then
    if new.status in ('scheduled', 'confirmed') then perform public.zella_replace_reminders(new.id, true, 'booked'); end if;
    return new;
  end if;

  if new.status in ('cancelled', 'no_show', 'completed') and v_status_changed then
    update public.appointment_reminders set status = 'cancelled', error = 'appointment_' || new.status where appointment_id = new.id and status = 'pending';
  end if;

  if new.status = 'cancelled' and v_status_changed then
    perform public.zella_notify(new.business_id, 'appointment_cancelled', 'Appointment cancelled', v_who || ' cancelled.' || coalesce(' ' || new.cancel_reason, ''), 'info', 'calendar', new.id);
    -- release the slot: offer it to people on the waitlist if the business turned that on
    perform public.zella_offer_slot(new.business_id, new.start_time, new.end_time, new.staff_id, new.customer_id);
  elsif new.status in ('scheduled', 'confirmed') and (v_time_changed or (v_status_changed and old.status in ('cancelled', 'no_show')) or (v_state_changed and new.booking_state = 'confirmed')) then
    perform public.zella_replace_reminders(new.id, v_time_changed or v_state_changed, case when v_time_changed then 'rescheduled' else 'booked' end);
    if v_time_changed then
      perform public.zella_notify(new.business_id, 'appointment_rescheduled', 'Appointment rescheduled', v_who || ' moved to a new time.', 'info', 'calendar', new.id);
      -- the old slot is free again
      if old.start_time > now() then perform public.zella_offer_slot(new.business_id, old.start_time, old.end_time, old.staff_id, new.customer_id); end if;
    end if;
  end if;

  -- post-appointment follow-up (feedback, thank you, maintenance reminder)
  if new.status = 'completed' and v_status_changed and new.customer_id is not null then
    select x.* into v_auto from public.automations x where x.business_id = new.business_id and x.trigger_type = 'post_appointment_follow_up' and x.status = 'active' limit 1;
    if v_auto.id is not null and exists (select 1 from public.customers c where c.id = new.customer_id and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null) then
      select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = new.business_id;
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      values (new.business_id, new.customer_id, new.id, 'post_appointment_follow_up', case when v_auto.trigger_config ->> 'channel' = 'call' then 'call' else 'sms' end,
              public.zella_next_call_time(now() + make_interval(hours => coalesce((v_auto.trigger_config ->> 'hours_after')::integer, 24)), v_tz), 1) on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists zella_appointment_after_trg on public.appointments;
create trigger zella_appointment_after_trg after insert or update on public.appointments for each row execute function public.zella_appointment_after();

-- n8n: take reminders / confirmations that are due.
create or replace function public.zella_claim_reminders(p_limit integer default 25) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_res jsonb := '[]'::jsonb; r record; a record; c record; b record; v_staff text;
begin
  for r in select * from public.appointment_reminders where status = 'pending' and due_at <= now() order by due_at
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
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $$;
create or replace function public.zella_complete_reminder(p_reminder_id uuid, p_ok boolean, p_error text default null) returns text
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from public.appointment_reminders where id = p_reminder_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'sending' then return r.status; end if;
  if p_ok then update public.appointment_reminders set status = 'sent', sent_at = now(), error = null where id = p_reminder_id; return 'sent'; end if;
  if r.attempts < 2 then
    update public.appointment_reminders set status = 'pending', due_at = now() + interval '10 minutes', error = left(p_error, 300) where id = p_reminder_id; return 'retry';
  end if;
  update public.appointment_reminders set status = 'failed', error = left(p_error, 300) where id = p_reminder_id;
  perform public.zella_notify(r.business_id, 'reminder_failed', 'A customer message was not delivered', 'A ' || r.kind || ' could not be sent. Contact them another way.', 'warning', 'calendar', r.appointment_id);
  return 'failed';
end $$;
-- The customer answered a reminder.
create or replace function public.zella_reminder_response(p_appointment_id uuid, p_response text, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_response = 'confirm' then
    update public.appointments set status = 'confirmed', updated_at = now() where id = p_appointment_id and status = 'scheduled'; return 'confirmed';
  elsif p_response = 'cancel' then
    update public.appointments set status = 'cancelled', cancel_reason = coalesce(nullif(p_note, ''), 'Customer cancelled'), updated_at = now() where id = p_appointment_id and status in ('scheduled', 'confirmed'); return 'cancelled';
  elsif p_response = 'reschedule' then
    perform public.zella_create_callback(a.business_id, null, 'appointment_request', 'normal', coalesce(nullif(p_note, ''), 'Customer asked to reschedule.'), null, a.customer_id, null, a.id, 'ai'); return 'reschedule_requested';
  end if;
  return 'no_change';
end $$;
revoke all on function public.zella_claim_reminders(integer) from public, anon, authenticated;
revoke all on function public.zella_complete_reminder(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.zella_reminder_response(uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_claim_reminders(integer) to service_role;
grant execute on function public.zella_complete_reminder(uuid, boolean, text) to service_role;
grant execute on function public.zella_reminder_response(uuid, text, text) to service_role;

-- ---- safe booking: a booking is confirmed only after the schedule accepts it ----------
create or replace function public.zella_book_appointment(
  p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamptz, p_duration_minutes integer default 30,
  p_staff_id uuid default null, p_party_size integer default null, p_notes text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_slot record; v_tz text; v_id uuid;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  select * into v_slot from public.zella_available_slots(p_business_id, p_start, p_start, p_duration_minutes, p_staff_id, 5, 1, null) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, staff_id, party_size, description, booking_state)
  values (p_business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Appointment'), v_slot.slot_start, v_slot.slot_end, v_tz, 'scheduled', v_slot.staff_id, p_party_size, p_notes, 'confirmed')
  returning id into v_id;
  if p_customer_id is not null then perform public.zella_stop_callbacks_for(p_business_id, p_customer_id, null, 'booked'); end if;
  return v_id;
end $$;

-- The AI could not verify a slot: record a REQUEST (never a booking) and ask staff to finish it.
create or replace function public.zella_request_appointment(
  p_business_id uuid, p_customer_id uuid, p_phone text, p_title text, p_preferred_start timestamptz default null, p_notes text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_tz text; v_id uuid; v_start timestamptz := coalesce(p_preferred_start, now() + interval '1 day');
begin
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, description, booking_state)
  values (p_business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Appointment request'), v_start, v_start + interval '30 minutes', v_tz, 'scheduled', p_notes, 'requested')
  returning id into v_id;
  perform public.zella_create_callback(p_business_id, p_phone, 'appointment_request', 'normal',
    'Appointment request: ' || coalesce(p_title, 'a visit') || coalesce('. ' || p_notes, '') || '. Not booked yet.', p_preferred_start, p_customer_id, null, v_id, 'ai');
  return v_id;
end $$;

-- Staff finish a request: check the schedule, then confirm it.
create or replace function public.zella_confirm_requested_appointment(p_appointment_id uuid, p_start timestamptz, p_duration_minutes integer default 30, p_staff_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare a record; v_slot record;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found or not public.zella_is_member(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.booking_state = 'confirmed' then raise exception 'ALREADY_CONFIRMED'; end if;
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  select * into v_slot from public.zella_available_slots(a.business_id, p_start, p_start, p_duration_minutes, p_staff_id, 5, 1, p_appointment_id) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  update public.appointments set start_time = v_slot.slot_start, end_time = v_slot.slot_end, staff_id = v_slot.staff_id, booking_state = 'confirmed', hold_expires_at = null, updated_at = now() where id = p_appointment_id;
  update public.callbacks set status = 'completed', outcome = 'booked', completed_at = now(), auto_call = false, updated_at = now()
   where appointment_id = p_appointment_id and reason = 'appointment_request' and status not in ('completed', 'cancelled');
  return p_appointment_id;
end $$;

-- Reschedule: moves the SAME appointment after the schedule accepts the new time.
create or replace function public.zella_reschedule_appointment(p_appointment_id uuid, p_start timestamptz, p_staff_id uuid default null, p_requested_by text default 'customer')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; v_dur integer; v_slot record;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is not null and not public.zella_is_member(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.status in ('cancelled', 'completed') then raise exception 'NOT_RESCHEDULABLE'; end if;
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  select * into v_slot from public.zella_available_slots(a.business_id, p_start, p_start, v_dur, coalesce(p_staff_id, a.staff_id), 5, 1, p_appointment_id) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  update public.appointments set start_time = v_slot.slot_start, end_time = v_slot.slot_end, staff_id = coalesce(v_slot.staff_id, staff_id),
         status = case when status in ('no_show') then 'scheduled' else status end,
         reschedule_requested_by = case when p_requested_by in ('customer', 'staff', 'ai') then p_requested_by else 'staff' end, updated_at = now()
   where id = p_appointment_id;
  return jsonb_build_object('appointment_id', p_appointment_id, 'original_start', a.start_time, 'new_start', v_slot.slot_start);
end $$;

-- tentative holds that were never confirmed
create or replace function public.zella_expire_holds() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.appointments set status = 'cancelled', cancel_reason = 'Hold expired', updated_at = now()
   where booking_state = 'tentative' and hold_expires_at < now() and status in ('scheduled', 'confirmed');
  get diagnostics n = row_count; return n;
end $$;
create or replace function public.zella_hold_slot(p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamptz, p_duration_minutes integer default 30, p_staff_id uuid default null, p_hold_minutes integer default 15)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_slot record; v_tz text; v_id uuid;
begin
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  select * into v_slot from public.zella_available_slots(p_business_id, p_start, p_start, p_duration_minutes, p_staff_id, 5, 1, null) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, staff_id, booking_state, hold_expires_at)
  values (p_business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Appointment'), v_slot.slot_start, v_slot.slot_end, v_tz, 'scheduled', v_slot.staff_id, 'tentative', now() + make_interval(mins => greatest(5, p_hold_minutes)))
  returning id into v_id;
  return v_id;
end $$;
-- the customer said yes to a held slot
create or replace function public.zella_confirm_hold(p_appointment_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is not null and not public.zella_is_member(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.booking_state <> 'tentative' or a.status <> 'scheduled' or a.hold_expires_at < now() then raise exception 'HOLD_EXPIRED'; end if;
  update public.appointments set booking_state = 'confirmed', hold_expires_at = null, updated_at = now() where id = p_appointment_id;
  return p_appointment_id;
end $$;
revoke all on function public.zella_book_appointment(uuid, uuid, text, timestamptz, integer, uuid, integer, text) from public, anon;
revoke all on function public.zella_request_appointment(uuid, uuid, text, text, timestamptz, text) from public, anon, authenticated;
revoke all on function public.zella_confirm_requested_appointment(uuid, timestamptz, integer, uuid) from public, anon;
revoke all on function public.zella_reschedule_appointment(uuid, timestamptz, uuid, text) from public, anon;
revoke all on function public.zella_expire_holds() from public, anon, authenticated;
revoke all on function public.zella_hold_slot(uuid, uuid, text, timestamptz, integer, uuid, integer) from public, anon, authenticated;
revoke all on function public.zella_confirm_hold(uuid) from public, anon;
grant execute on function public.zella_book_appointment(uuid, uuid, text, timestamptz, integer, uuid, integer, text) to authenticated, service_role;
grant execute on function public.zella_request_appointment(uuid, uuid, text, text, timestamptz, text) to service_role;
grant execute on function public.zella_confirm_requested_appointment(uuid, timestamptz, integer, uuid) to authenticated, service_role;
grant execute on function public.zella_reschedule_appointment(uuid, timestamptz, uuid, text) to authenticated, service_role;
grant execute on function public.zella_expire_holds() to service_role;
grant execute on function public.zella_hold_slot(uuid, uuid, text, timestamptz, integer, uuid, integer) to service_role;
grant execute on function public.zella_confirm_hold(uuid) to authenticated, service_role;

-- ---- waitlist ------------------------------------------------------------------------------
create or replace function public.zella_join_waitlist(p_business_id uuid, p_customer_id uuid, p_title text default null, p_duration_minutes integer default 30,
  p_earliest timestamptz default null, p_latest timestamptz default null, p_staff_id uuid default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.waitlist_entries (business_id, customer_id, title, duration_minutes, earliest_at, latest_at, staff_id, notes)
  values (p_business_id, p_customer_id, nullif(trim(p_title), ''), greatest(5, coalesce(p_duration_minutes, 30)), p_earliest, p_latest, p_staff_id, left(p_notes, 500))
  on conflict (business_id, customer_id, coalesce(title, '')) where status in ('waiting', 'offered') do update set earliest_at = excluded.earliest_at, latest_at = excluded.latest_at, notes = excluded.notes
  returning id into v_id;
  return v_id;
end $$;
create or replace function public.zella_remove_waitlist_entry(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_b uuid;
begin
  select business_id into v_b from public.waitlist_entries where id = p_id;
  if v_b is null or not public.zella_is_member(v_b) then raise exception 'NOT_ALLOWED'; end if;
  update public.waitlist_entries set status = 'removed' where id = p_id and status in ('waiting', 'offered');
  return found;
end $$;
-- The customer said yes: re-check the slot, then book. A taken slot is never double-booked.
create or replace function public.zella_accept_waitlist_offer(p_entry_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare e record; v_id uuid;
begin
  select * into e from public.waitlist_entries where id = p_entry_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if e.status <> 'offered' or e.offer_expires_at < now() then raise exception 'OFFER_EXPIRED'; end if;
  begin
    v_id := public.zella_book_appointment(e.business_id, e.customer_id, coalesce(e.title, 'Appointment'), e.offered_start, e.duration_minutes, e.offered_staff_id, null, e.notes);
  exception when others then
    if sqlerrm = 'SLOT_TAKEN' then
      update public.waitlist_entries set status = 'waiting', offered_start = null, offered_end = null, offer_expires_at = null where id = p_entry_id;
    end if;
    raise;
  end;
  update public.waitlist_entries set status = 'booked', appointment_id = v_id where id = p_entry_id;
  return v_id;
end $$;
create or replace function public.zella_decline_waitlist_offer(p_entry_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e record;
begin
  select * into e from public.waitlist_entries where id = p_entry_id for update;
  if not found or e.status <> 'offered' then return; end if;
  update public.waitlist_entries set status = 'waiting', offered_start = null, offered_end = null, offer_expires_at = null where id = p_entry_id;
  perform public.zella_offer_slot(e.business_id, e.offered_start, e.offered_end, e.offered_staff_id, e.customer_id);
end $$;
-- offers nobody answered go to the next person
create or replace function public.zella_expire_waitlist_offers() returns integer
language plpgsql security definer set search_path = public as $$
declare e record; n integer := 0;
begin
  for e in select * from public.waitlist_entries where status = 'offered' and offer_expires_at < now() for update skip locked loop
    update public.waitlist_entries set status = 'waiting', offered_start = null, offered_end = null, offer_expires_at = null where id = e.id;
    perform public.zella_offer_slot(e.business_id, e.offered_start, e.offered_end, e.offered_staff_id, e.customer_id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_join_waitlist(uuid, uuid, text, integer, timestamptz, timestamptz, uuid, text) from public, anon;
revoke all on function public.zella_remove_waitlist_entry(uuid) from public, anon;
revoke all on function public.zella_accept_waitlist_offer(uuid) from public, anon, authenticated;
revoke all on function public.zella_decline_waitlist_offer(uuid) from public, anon, authenticated;
revoke all on function public.zella_expire_waitlist_offers() from public, anon, authenticated;
grant execute on function public.zella_join_waitlist(uuid, uuid, text, integer, timestamptz, timestamptz, uuid, text) to authenticated, service_role;
grant execute on function public.zella_remove_waitlist_entry(uuid) to authenticated, service_role;
grant execute on function public.zella_accept_waitlist_offer(uuid) to service_role;
grant execute on function public.zella_decline_waitlist_offer(uuid) to service_role;
grant execute on function public.zella_expire_waitlist_offers() to service_role;

-- ---- staff or resource unavailable -------------------------------------------------------------
create or replace function public.zella_handle_staff_unavailable(p_business_id uuid, p_staff_id uuid, p_from timestamptz, p_to timestamptz, p_reason text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare a record; v_alt text; v_n integer := 0; v_auto record; v_tz text; v_who text; v_staff_name text;
begin
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  select name into v_staff_name from public.staff_members where id = p_staff_id;
  select x.* into v_auto from public.automations x where x.business_id = p_business_id and x.trigger_type = 'staff_unavailable' and x.status = 'active' limit 1;
  for a in select * from public.appointments ap
            where ap.business_id = p_business_id and ap.status in ('scheduled', 'confirmed') and coalesce(ap.booking_state, 'confirmed') = 'confirmed'
              and ap.start_time > now() and ap.start_time < p_to and ap.end_time > p_from
              and (p_staff_id is null or ap.staff_id = p_staff_id) and ap.conflict_note is null loop
    select string_agg(to_char(s.slot_start at time zone v_tz, 'Dy Mon DD HH12:MI AM') || coalesce(' with ' || s.staff_name, ''), '; ' order by s.slot_start) into v_alt
      from public.zella_available_slots(p_business_id, greatest(now(), p_from), greatest(now(), p_from) + interval '7 days',
             greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int), null, 30, 3, a.id) s
     where s.slot_start >= p_to or s.slot_start + (a.end_time - a.start_time) <= p_from;
    select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), a.title) into v_who from public.customers c where c.id = a.customer_id;
    v_who := coalesce(v_who, a.title);
    update public.appointments set conflict_note = left(coalesce(v_staff_name, 'The team') || ' is unavailable' || coalesce(' (' || p_reason || ')', '') || '.', 200) where id = a.id;
    perform public.zella_create_task(p_business_id, a.customer_id, 'staff_unavailable', 'Reschedule ' || v_who || ': ' || coalesce(v_staff_name, 'staff') || ' is unavailable',
      'Appointment ' || to_char(a.start_time at time zone v_tz, 'Dy Mon DD HH12:MI AM') || '. ' || case when v_alt is null then 'No alternative found yet.' else 'Possible times: ' || v_alt || '.' end,
      'high', a.start_time - interval '1 day', null, 'automation', a.id);
    -- ask the customer only when the business enabled it; never move them without their confirmation
    if v_auto.id is not null and a.customer_id is not null and exists (select 1 from public.customers c where c.id = a.customer_id and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null) then
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      values (p_business_id, a.customer_id, a.id, 'reschedule_offer', case when v_auto.trigger_config ->> 'channel' = 'sms' then 'sms' else 'call' end, public.zella_next_call_time(now(), v_tz), 2) on conflict do nothing;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    perform public.zella_notify(p_business_id, 'staff_unavailable', v_n || (case when v_n = 1 then ' appointment is' else ' appointments are' end) || ' affected',
      coalesce(v_staff_name, 'Someone') || ' is unavailable. Review the tasks to rebook them.', 'warning', 'tasks', null);
  end if;
  return v_n;
end $$;
revoke all on function public.zella_handle_staff_unavailable(uuid, uuid, timestamptz, timestamptz, text) from public, anon, authenticated;
grant execute on function public.zella_handle_staff_unavailable(uuid, uuid, timestamptz, timestamptz, text) to service_role;

create or replace function public.zella_block_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.zella_handle_staff_unavailable(new.business_id, new.staff_id, new.start_time, new.end_time, nullif(new.reason, ''));
  return new;
end $$;
drop trigger if exists zella_block_trg on public.blocked_times;
create trigger zella_block_trg after insert or update of start_time, end_time, staff_id on public.blocked_times for each row execute function public.zella_block_trigger();

create or replace function public.zella_staff_deactivated() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.is_active and not new.is_active then
    perform public.zella_handle_staff_unavailable(new.business_id, new.id, now(), now() + interval '365 days', 'no longer available');
  end if;
  return new;
end $$;
drop trigger if exists zella_staff_deactivated_trg on public.staff_members;
create trigger zella_staff_deactivated_trg after update of is_active on public.staff_members for each row execute function public.zella_staff_deactivated();


-- =========================================================
-- Zella workflows, part 4: AI-receptionist maintenance and
-- platform-owner (Zella admin) automations.
-- Run AFTER parts 1-3. Safe to re-run.
-- =========================================================

-- ---------- platform settings and alerts (Zella admins only) ----------
create table if not exists public.platform_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into public.platform_settings (key, value) values
  ('invitation_reminder_hours', '[24, 72]'),
  ('setup_incomplete_after_days', '3'),
  ('trial_notice_days', '[7, 3, 1]'),
  ('payment_grace_days', '7'),
  ('payment_suspend_after_days', '14'),
  ('payment_auto_suspend', 'false'),
  ('retention_days', '90'),
  ('transfer_failure_threshold', '3')
on conflict (key) do nothing;
alter table public.platform_settings enable row level security;
revoke all on public.platform_settings from anon, authenticated;
create or replace function public.zella_setting(p_key text, p_default jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.platform_settings where key = p_key), p_default);
$$;
revoke all on function public.zella_setting(text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_setting(text, jsonb) to service_role;

create table if not exists public.platform_alerts (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  severity text not null default 'warning' check (severity in ('info', 'warning', 'urgent')),
  business_id uuid references public.businesses(id) on delete cascade,
  title text not null,
  detail text,
  meta jsonb not null default '{}'::jsonb,
  dedupe_key text not null default '',
  status text not null default 'open' check (status in ('open', 'acknowledged', 'resolved')),
  occurrences integer not null default 1,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  notified_at timestamptz,
  acknowledged_by uuid, acknowledged_at timestamptz,
  resolved_by uuid, resolved_at timestamptz, resolution_note text
);
create unique index if not exists platform_alerts_one_open_idx on public.platform_alerts (kind, coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), dedupe_key) where status <> 'resolved';
create index if not exists platform_alerts_status_idx on public.platform_alerts (status, last_seen_at desc);
alter table public.platform_alerts enable row level security;
revoke all on public.platform_alerts from anon, authenticated;
do $$ begin
  if to_regclass('public.platform_admins') is not null then
    drop policy if exists platform_alerts_admin_select on public.platform_alerts;
    create policy platform_alerts_admin_select on public.platform_alerts for select to authenticated
      using (exists (select 1 from public.platform_admins p where p.user_id = auth.uid() and p.is_active));
    grant select on public.platform_alerts to authenticated;
  end if;
end $$;

create or replace function public.zella_platform_alert(p_kind text, p_title text, p_detail text default null, p_severity text default 'warning',
  p_business_id uuid default null, p_dedupe_key text default '', p_meta jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.platform_alerts (kind, title, detail, severity, business_id, dedupe_key, meta)
  values (p_kind, p_title, left(p_detail, 1000), case when p_severity in ('info','urgent') then p_severity else 'warning' end, p_business_id, coalesce(p_dedupe_key, ''), coalesce(p_meta, '{}'::jsonb))
  on conflict (kind, coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), dedupe_key) where status <> 'resolved'
  do update set occurrences = platform_alerts.occurrences + 1, last_seen_at = now(), detail = coalesce(excluded.detail, platform_alerts.detail), meta = platform_alerts.meta || excluded.meta
  returning id into v_id;
  return v_id;
end $$;
create or replace function public.zella_resolve_platform_alerts(p_kind text, p_business_id uuid, p_dedupe_key text default null, p_note text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = left(p_note, 300)
   where kind = p_kind and business_id is not distinct from p_business_id and status <> 'resolved' and (p_dedupe_key is null or dedupe_key = p_dedupe_key);
  get diagnostics n = row_count; return n;
end $$;
-- n8n: alerts that still need to be emailed to platform admins, with who to email.
create or replace function public.zella_claim_platform_alerts(p_limit integer default 25) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_alerts jsonb; v_emails jsonb := '[]'::jsonb;
begin
  with c as (
    update public.platform_alerts a set notified_at = now()
     where a.id in (select s.id from public.platform_alerts s where s.notified_at is null and s.status = 'open' order by s.first_seen_at limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked)
    returning a.*)
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into v_alerts from c;
  if to_regclass('auth.users') is not null and to_regclass('public.platform_admins') is not null then
    execute 'select coalesce(jsonb_agg(u.email), ''[]''::jsonb) from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null' into v_emails;
  end if;
  return jsonb_build_object('alerts', v_alerts, 'admin_emails', v_emails);
end $$;
create or replace function public.zella_set_alert_status(p_id uuid, p_status text, p_user uuid default null, p_note text default null) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('acknowledged', 'resolved') then raise exception 'BAD_STATUS'; end if;
  update public.platform_alerts set status = p_status,
         acknowledged_by = case when p_status = 'acknowledged' then p_user else acknowledged_by end, acknowledged_at = case when p_status = 'acknowledged' then now() else acknowledged_at end,
         resolved_by = case when p_status = 'resolved' then p_user else resolved_by end, resolved_at = case when p_status = 'resolved' then now() else resolved_at end,
         resolution_note = coalesce(left(p_note, 300), resolution_note)
   where id = p_id and status <> 'resolved';
  return found;
end $$;
revoke all on function public.zella_platform_alert(text, text, text, text, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.zella_resolve_platform_alerts(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.zella_claim_platform_alerts(integer) from public, anon, authenticated;
revoke all on function public.zella_set_alert_status(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.zella_platform_alert(text, text, text, text, uuid, text, jsonb) to service_role;
grant execute on function public.zella_resolve_platform_alerts(text, uuid, text, text) to service_role;
grant execute on function public.zella_claim_platform_alerts(integer) to service_role;
grant execute on function public.zella_set_alert_status(uuid, text, uuid, text) to service_role;

-- tell a business's owners something (not every member)
create or replace function public.zella_notify_owners(p_business_id uuid, p_kind text, p_title text, p_body text, p_severity text default 'warning', p_page_key text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.zella_notify(p_business_id, p_kind, p_title, p_body, p_severity, p_page_key, null, null);
end $$;
revoke all on function public.zella_notify_owners(uuid, text, text, text, text, text) from public, anon, authenticated;

-- =========================================================
-- A. AI receptionist maintenance
-- =========================================================
alter table public.integrations add column if not exists last_error text, add column if not exists last_checked_at timestamptz, add column if not exists error_count integer not null default 0;
alter table public.calls add column if not exists failure_reason text, add column if not exists failure_context jsonb;

-- 3. repeated failed transfers (n8n, e.g. every 15 minutes)
create or replace function public.zella_detect_transfer_failures() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_n integer; v_thr integer := (public.zella_setting('transfer_failure_threshold', '3'))::text::integer; v_found integer := 0; v_cfg record; v_auto boolean;
begin
  for b in
    select c.business_id, count(*) as n from public.calls c
     where c.transfer_status in ('failed', 'no_one_available') and c.created_at > now() - interval '24 hours'
     group by c.business_id having count(*) >= v_thr
  loop
    v_found := v_found + 1;
    perform public.zella_platform_alert('repeated_transfer_failures', 'Transfers keep failing', b.n || ' transfers failed in 24 hours.', 'warning', b.business_id, to_char(now(), 'YYYY-MM-DD'), jsonb_build_object('failures', b.n));
    -- an authorised fallback route is applied automatically; otherwise it is only recommended
    select cfg.* into v_cfg from public.ai_agent_configs cfg join public.ai_agents ag on ag.id = cfg.agent_id where ag.business_id = b.business_id and ag.is_default limit 1;
    v_auto := coalesce((v_cfg.escalation_rules ->> 'auto_fallback')::boolean, false) and nullif(v_cfg.escalation_rules ->> 'fallback_number', '') is not null;
    if exists (select 1 from public.staff_notifications where business_id = b.business_id and kind in ('transfer_fallback_applied', 'transfer_failures') and created_at > now() - interval '24 hours') then
      continue;   -- the owner was already told today
    end if;
    if v_auto and coalesce(v_cfg.escalation_rules ->> 'transfer_route', '') <> 'fallback' then
      update public.ai_agent_configs set escalation_rules = coalesce(escalation_rules, '{}'::jsonb) || '{"transfer_route":"fallback"}'::jsonb, updated_at = now() where id = v_cfg.id;
      perform public.zella_notify_owners(b.business_id, 'transfer_fallback_applied', 'Switched to your backup number', 'Transfers kept failing, so Zella is now sending callers to your backup route.', 'urgent', 'receptionist');
    else
      perform public.zella_notify_owners(b.business_id, 'transfer_failures', 'Transfers keep failing', 'Callers asking for a person are not getting through. Check your transfer number or add a backup.', 'urgent', 'receptionist');
    end if;
  end loop;
  return v_found;
end $$;

-- 4. phone connection failure (Telnyx / Vapi report their state here)
create or replace function public.zella_report_telephony_event(p_business_id uuid, p_provider text, p_state text, p_error text default null, p_retryable boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_i record; v_retry boolean := false;
begin
  if p_state not in ('connected', 'error', 'disconnected') then raise exception 'BAD_STATE'; end if;
  select * into v_i from public.integrations where business_id = p_business_id and provider = p_provider limit 1;
  if v_i.id is null then raise exception 'INTEGRATION_NOT_FOUND'; end if;
  if p_state = 'connected' then
    update public.integrations set status = 'active', last_error = null, error_count = 0, last_checked_at = now() where id = v_i.id;
    perform public.zella_resolve_platform_alerts('integration_disconnected', p_business_id, p_provider, 'Reconnected');
    return jsonb_build_object('status', 'active', 'retry', false);
  end if;
  update public.integrations set status = case when p_state = 'error' then 'error' else 'disconnected' end, last_error = left(p_error, 300), error_count = error_count + 1, last_checked_at = now() where id = v_i.id;
  -- retry only where it is safe: transient errors, a few times
  v_retry := coalesce(p_retryable, false) and v_i.error_count + 1 <= 3;
  if not v_retry then
    perform public.zella_platform_alert('integration_disconnected', initcap(p_provider) || ' connection problem', p_error, 'urgent', p_business_id, p_provider, jsonb_build_object('state', p_state));
    perform public.zella_notify_owners(p_business_id, 'integration_down', initcap(p_provider) || ' needs reconnecting', 'Your ' || p_provider || ' connection is ' || p_state || '. Open Integrations to reconnect it.', 'urgent', 'integrations');
  end if;
  return jsonb_build_object('status', p_state, 'retry', v_retry, 'retry_in_minutes', case when v_retry then 5 * (v_i.error_count + 1) end);
end $$;

-- 5. a call could not be completed normally
create or replace function public.zella_report_call_failure(p_business_id uuid, p_call_id uuid, p_error text, p_context jsonb default '{}'::jsonb, p_phone text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_phone text := p_phone; v_cb uuid; v_cust uuid; v_recent integer;
begin
  if p_call_id is not null then
    update public.calls set failure_reason = left(p_error, 300), failure_context = p_context where id = p_call_id and business_id = p_business_id
      returning customer_id, coalesce(v_phone, (to_jsonb(calls) ->> 'from_number')) into v_cust, v_phone;
  end if;
  -- fallback: a person follows up, with the error and context kept on the call
  if nullif(trim(coalesce(v_phone, '')), '') is not null then
    v_cb := public.zella_create_callback(p_business_id, v_phone, 'needs_human', 'high', 'The call could not be completed normally. Please call them back.', null, v_cust, p_call_id, null, 'system');
  end if;
  select count(*) into v_recent from public.calls where business_id = p_business_id and failure_reason is not null and created_at > now() - interval '1 hour';
  if v_recent >= 3 then
    perform public.zella_platform_alert('agent_failures', 'The AI receptionist keeps failing calls', v_recent || ' calls failed in the last hour. Last error: ' || left(p_error, 200), 'urgent', p_business_id, to_char(now(), 'YYYY-MM-DD-HH24'));
    perform public.zella_notify_owners(p_business_id, 'agent_failures', 'Some calls could not be handled', 'Several calls failed in the last hour. Zella has queued callbacks for them.', 'urgent', 'callbacks');
  end if;
  return v_cb;
end $$;

-- 6. agent configuration versions: save -> validate -> publish (owners/admins/managers only)
create table if not exists public.agent_config_versions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  agent_id uuid not null references public.ai_agents(id) on delete cascade,
  version integer not null,
  config jsonb not null,
  status text not null default 'draft' check (status in ('draft', 'valid', 'invalid', 'published', 'superseded')),
  validation_errors jsonb not null default '[]'::jsonb,
  sync_status text not null default 'none' check (sync_status in ('none', 'pending', 'live', 'failed')),
  sync_error text,
  created_by uuid, published_by uuid, published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (agent_id, version)
);
alter table public.agent_config_versions enable row level security;
drop policy if exists agent_config_versions_select on public.agent_config_versions;
create policy agent_config_versions_select on public.agent_config_versions for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.agent_config_versions from anon;
revoke insert, update, delete on public.agent_config_versions from authenticated;
grant select on public.agent_config_versions to authenticated;

create or replace function public.zella_can_manage(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'admin', 'manager'));
$$;
revoke all on function public.zella_can_manage(uuid) from public, anon;
grant execute on function public.zella_can_manage(uuid) to authenticated, service_role;

create or replace function public.zella_save_agent_config_draft(p_agent_id uuid, p_config jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_b uuid; v_v integer; v_id uuid; v_allowed text[] := array['system_prompt','personality','tone','goals','capabilities','knowledge_base','escalation_rules','appointment_rules','voice_config','business_context'];
begin
  select business_id into v_b from public.ai_agents where id = p_agent_id;
  if v_b is null or not public.zella_can_manage(v_b) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(max(version), 0) + 1 into v_v from public.agent_config_versions where agent_id = p_agent_id;
  insert into public.agent_config_versions (business_id, agent_id, version, config, created_by)
  values (v_b, p_agent_id, v_v, (select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) from jsonb_each(p_config) e where e.key = any (v_allowed)), auth.uid()) returning id into v_id;
  return v_id;
end $$;
create or replace function public.zella_validate_agent_config(p_version_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v record; v_errs jsonb := '[]'::jsonb; c jsonb;
begin
  select * into v from public.agent_config_versions where id = p_version_id for update;
  if not found or (auth.uid() is not null and not public.zella_can_manage(v.business_id)) then raise exception 'NOT_ALLOWED'; end if;
  if v.status in ('published', 'superseded') then raise exception 'ALREADY_PUBLISHED'; end if;
  c := v.config;
  if length(coalesce(trim(c ->> 'system_prompt'), '')) < 20 then v_errs := v_errs || '["The instructions are missing or too short."]'::jsonb; end if;
  if coalesce(c ->> 'system_prompt', '') ~* '(sk-[a-z0-9]{16,}|api[_-]?key|password\s*[:=])' then v_errs := v_errs || '["The instructions contain what looks like a secret key or password. Remove it."]'::jsonb; end if;
  if c ? 'capabilities' and jsonb_typeof(c -> 'capabilities') not in ('object', 'array') then v_errs := v_errs || '["Capabilities are not in a valid format."]'::jsonb; end if;
  if c ? 'escalation_rules' and jsonb_typeof(c -> 'escalation_rules') <> 'object' then v_errs := v_errs || '["Escalation rules are not in a valid format."]'::jsonb; end if;
  if not (c ? 'escalation_rules') or coalesce(c -> 'escalation_rules', '{}'::jsonb) = '{}'::jsonb then v_errs := v_errs || '["Say how callers reach a person (escalation rules)."]'::jsonb; end if;
  update public.agent_config_versions set status = case when jsonb_array_length(v_errs) = 0 then 'valid' else 'invalid' end, validation_errors = v_errs where id = p_version_id;
  return v_errs;
end $$;
create or replace function public.zella_publish_agent_config(p_version_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v record; c jsonb;
begin
  select * into v from public.agent_config_versions where id = p_version_id for update;
  if not found or not public.zella_can_manage(v.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v.status <> 'valid' then raise exception 'NOT_VALID'; end if;   -- only a validated version can go live
  c := v.config;
  update public.ai_agent_configs set system_prompt = coalesce(c ->> 'system_prompt', system_prompt), personality = coalesce(c ->> 'personality', personality), tone = coalesce(c ->> 'tone', tone),
         goals = coalesce(c -> 'goals', goals), capabilities = coalesce(c -> 'capabilities', capabilities), knowledge_base = coalesce(c -> 'knowledge_base', knowledge_base),
         escalation_rules = coalesce(c -> 'escalation_rules', escalation_rules), appointment_rules = coalesce(c -> 'appointment_rules', appointment_rules),
         voice_config = coalesce(c -> 'voice_config', voice_config), business_context = coalesce(c -> 'business_context', business_context), updated_at = now()
   where agent_id = v.agent_id;
  update public.agent_config_versions set status = 'superseded' where agent_id = v.agent_id and status = 'published';
  update public.agent_config_versions set status = 'published', published_by = auth.uid(), published_at = now(), sync_status = 'pending' where id = p_version_id;
  perform public.zella_notify_owners(v.business_id, 'agent_config_published', 'AI receptionist updated', 'Version ' || v.version || ' was published. It goes live once it has synced.', 'info', 'receptionist');
  return v.version;
end $$;
create or replace function public.zella_claim_agent_syncs(p_limit integer default 10) returns setof public.agent_config_versions
language plpgsql security definer set search_path = public as $$
begin
  return query select v.* from public.agent_config_versions v where v.status = 'published' and v.sync_status = 'pending' order by v.published_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked;
end $$;
create or replace function public.zella_complete_agent_sync(p_version_id uuid, p_ok boolean, p_error text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.agent_config_versions where id = p_version_id for update;
  if not found or v.status <> 'published' then return; end if;
  update public.agent_config_versions set sync_status = case when p_ok then 'live' else 'failed' end, sync_error = case when p_ok then null else left(p_error, 300) end where id = p_version_id;
  if not p_ok then
    perform public.zella_platform_alert('agent_sync_failed', 'An AI receptionist update did not go live', p_error, 'warning', v.business_id, p_version_id::text);
    perform public.zella_notify_owners(v.business_id, 'agent_sync_failed', 'Your latest AI changes are not live yet', 'We could not apply version ' || v.version || '. The previous version is still answering calls.', 'warning', 'receptionist');
  end if;
end $$;
revoke all on function public.zella_detect_transfer_failures() from public, anon, authenticated;
revoke all on function public.zella_report_telephony_event(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.zella_report_call_failure(uuid, uuid, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.zella_save_agent_config_draft(uuid, jsonb) from public, anon;
revoke all on function public.zella_validate_agent_config(uuid) from public, anon;
revoke all on function public.zella_publish_agent_config(uuid) from public, anon;
revoke all on function public.zella_claim_agent_syncs(integer) from public, anon, authenticated;
revoke all on function public.zella_complete_agent_sync(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.zella_detect_transfer_failures() to service_role;
grant execute on function public.zella_report_telephony_event(uuid, text, text, text, boolean) to service_role;
grant execute on function public.zella_report_call_failure(uuid, uuid, text, jsonb, text) to service_role;
grant execute on function public.zella_save_agent_config_draft(uuid, jsonb) to authenticated, service_role;
grant execute on function public.zella_validate_agent_config(uuid) to authenticated, service_role;
grant execute on function public.zella_publish_agent_config(uuid) to authenticated, service_role;
grant execute on function public.zella_claim_agent_syncs(integer) to service_role;
grant execute on function public.zella_complete_agent_sync(uuid, boolean, text) to service_role;

-- 7. activation check: go live only when the required checks pass
create table if not exists public.activation_tests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  ok boolean not null,
  detail text,
  created_at timestamptz not null default now()
);
alter table public.activation_tests enable row level security;
drop policy if exists activation_tests_select on public.activation_tests;
create policy activation_tests_select on public.activation_tests for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.activation_tests from anon; revoke insert, update, delete on public.activation_tests from authenticated; grant select on public.activation_tests to authenticated;
-- n8n runs the test call and reports here
create or replace function public.zella_record_activation_test(p_business_id uuid, p_ok boolean, p_detail text default null) returns void
language sql security definer set search_path = public as $$
  insert into public.activation_tests (business_id, ok, detail) values (p_business_id, p_ok, left(p_detail, 300));
$$;
create or replace function public.zella_activation_report(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_checks jsonb := '[]'::jsonb; v_ok boolean; v_all boolean := true; r record;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  for r in
    select * from (values
      ('owner', 'An owner has accepted their invitation', exists (select 1 from public.business_members m where m.business_id = p_business_id and m.status = 'active')),
      ('phone', 'Phone line connected', exists (select 1 from public.integrations i where i.business_id = p_business_id and i.provider = 'telnyx' and i.status = 'active')),
      ('assistant', 'AI assistant connected', exists (select 1 from public.integrations i where i.business_id = p_business_id and i.provider = 'vapi' and i.status = 'active')),
      ('agent', 'AI receptionist has instructions', exists (select 1 from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id where ag.business_id = p_business_id and ag.is_default and length(coalesce(cfg.system_prompt, '')) >= 20)),
      ('transfer', 'A way for callers to reach a person', exists (select 1 from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id where ag.business_id = p_business_id and ag.is_default and coalesce(cfg.escalation_rules, '{}'::jsonb) <> '{}'::jsonb)),
      ('knowledge', 'At least one approved answer is ready', exists (select 1 from public.knowledge_items k where k.business_id = p_business_id and k.status = 'ready')),
      ('automations', 'At least one automation switched on', exists (select 1 from public.automations a where a.business_id = p_business_id and a.status in ('active', 'paused'))),
      ('test_call', 'A test call passed', coalesce((select t.ok from public.activation_tests t where t.business_id = p_business_id order by t.created_at desc limit 1), false))
    ) as t(key, label, ok)
  loop
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('key', r.key, 'label', r.label, 'ok', r.ok));
    v_all := v_all and r.ok;
  end loop;
  return jsonb_build_object('ready', v_all, 'live', exists (select 1 from public.businesses where id = p_business_id and onboarding_status = 'active'), 'checks', v_checks);
end $$;
-- The business asks to go live. It only happens when every check passes.
create or replace function public.zella_request_activation(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rep jsonb;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if exists (select 1 from public.businesses where id = p_business_id and (suspended_at is not null or cancelled_at is not null)) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  v_rep := public.zella_activation_report(p_business_id);
  if (v_rep ->> 'ready')::boolean then
    update public.businesses set onboarding_status = 'active', is_active = true, updated_at = now() where id = p_business_id;
    update public.automations set status = 'active', updated_at = now() where business_id = p_business_id and status = 'paused';
    perform public.zella_resolve_platform_alerts('setup_incomplete', p_business_id, null, 'Went live');
    perform public.zella_notify_owners(p_business_id, 'went_live', 'You are live', 'Your AI receptionist is now answering calls.', 'info', 'today');
  end if;
  return v_rep;
end $$;
revoke all on function public.zella_record_activation_test(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.zella_activation_report(uuid) from public, anon;
revoke all on function public.zella_request_activation(uuid) from public, anon;
grant execute on function public.zella_record_activation_test(uuid, boolean, text) to service_role;
grant execute on function public.zella_activation_report(uuid) to authenticated, service_role;
grant execute on function public.zella_request_activation(uuid) to authenticated, service_role;

-- 8. performance review: what happened, and what to look at
create or replace function public.zella_performance_review(p_business_id uuid, p_days integer default 7) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
        v_calls integer; v_missed integer; v_ai integer; v_tf integer; v_fail integer; v_gaps integer; v_booked integer; v_cb_open integer; v_cb_review integer; v_noshow integer; v_issues jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select count(*), count(*) filter (where status = 'missed'), count(*) filter (where coalesce(ai_handled, false)),
         count(*) filter (where transfer_status in ('failed', 'no_one_available')), count(*) filter (where failure_reason is not null)
    into v_calls, v_missed, v_ai, v_tf, v_fail from public.calls where business_id = p_business_id and created_at >= v_since;
  select count(*) into v_gaps from public.knowledge_gaps where business_id = p_business_id and status = 'open';
  select count(*) into v_booked from public.appointments where business_id = p_business_id and created_at >= v_since and coalesce(booking_state, 'confirmed') = 'confirmed';
  select count(*) filter (where status not in ('completed', 'cancelled', 'needs_review')), count(*) filter (where status = 'needs_review') into v_cb_open, v_cb_review from public.callbacks where business_id = p_business_id;
  select count(*) into v_noshow from public.appointments where business_id = p_business_id and status = 'no_show' and start_time >= v_since;
  if v_calls > 0 and v_missed::numeric / v_calls > 0.2 then v_issues := v_issues || to_jsonb(v_missed || ' of ' || v_calls || ' calls were missed.'); end if;
  if v_tf > 0 then v_issues := v_issues || to_jsonb(v_tf || ' transfer(s) to a person failed.'); end if;
  if v_fail > 0 then v_issues := v_issues || to_jsonb(v_fail || ' call(s) could not be completed.'); end if;
  if v_gaps > 0 then v_issues := v_issues || to_jsonb(v_gaps || ' question(s) Zella could not answer need your review.'); end if;
  if v_cb_review > 0 then v_issues := v_issues || to_jsonb(v_cb_review || ' callback(s) need a person.'); end if;
  if v_noshow > 0 then v_issues := v_issues || to_jsonb(v_noshow || ' no-show(s).'); end if;
  return jsonb_build_object('days', p_days, 'calls', v_calls, 'missed', v_missed, 'ai_handled', v_ai, 'transfers_failed', v_tf, 'failed_calls', v_fail,
    'unanswered_questions', v_gaps, 'appointments_booked', v_booked, 'callbacks_open', v_cb_open, 'callbacks_needing_review', v_cb_review, 'no_shows', v_noshow, 'issues', v_issues);
end $$;
-- n8n (weekly): post each live business's review to its owners
create or replace function public.zella_post_weekly_reviews() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_rev jsonb; n integer := 0;
begin
  for b in select id from public.businesses where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_rev := public.zella_performance_review(b.id, 7);
    if (v_rev ->> 'calls')::int > 0 or jsonb_array_length(v_rev -> 'issues') > 0 then
      perform public.zella_notify_owners(b.id, 'weekly_review', 'Your week with Zella',
        (v_rev ->> 'calls') || ' calls, ' || (v_rev ->> 'appointments_booked') || ' booked.' || case when jsonb_array_length(v_rev -> 'issues') > 0 then ' To look at: ' || (select string_agg(x, ' ') from jsonb_array_elements_text(v_rev -> 'issues') x) else ' Nothing needs attention.' end,
        case when jsonb_array_length(v_rev -> 'issues') > 0 then 'warning' else 'info' end, 'reports');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.zella_performance_review(uuid, integer) from public, anon;
revoke all on function public.zella_post_weekly_reviews() from public, anon, authenticated;
grant execute on function public.zella_performance_review(uuid, integer) to authenticated, service_role;
grant execute on function public.zella_post_weekly_reviews() to service_role;

-- =========================================================
-- B. Platform-owner workflows
-- =========================================================
alter table public.business_invitations add column if not exists reminder_count integer not null default 0, add column if not exists last_reminded_at timestamptz;
alter table public.subscriptions add column if not exists status_changed_at timestamptz not null default now(),
  add column if not exists past_due_since timestamptz, add column if not exists trial_notice_days integer[] not null default '{}';
alter table public.businesses add column if not exists retention_until timestamptz;
alter table public.automations add column if not exists paused_by_suspension boolean not null default false;

-- 1. provisioning tracker: the edge function reports each stage
create table if not exists public.provisioning_steps (
  business_id uuid not null references public.businesses(id) on delete cascade,
  step text not null,
  status text not null default 'pending' check (status in ('pending', 'done', 'failed')),
  error text,
  updated_at timestamptz not null default now(),
  primary key (business_id, step)
);
alter table public.provisioning_steps enable row level security;
revoke all on public.provisioning_steps from anon, authenticated;
create or replace function public.zella_track_provisioning(p_business_id uuid, p_step text, p_status text, p_error text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.provisioning_steps (business_id, step, status, error) values (p_business_id, p_step, p_status, left(p_error, 300))
  on conflict (business_id, step) do update set status = excluded.status, error = excluded.error, updated_at = now();
  if p_status = 'failed' then
    perform public.zella_platform_alert('provisioning_failed', 'Setup failed at: ' || p_step, p_error, 'urgent', p_business_id, p_step);
  else
    perform public.zella_resolve_platform_alerts('provisioning_failed', p_business_id, p_step, 'Step completed');
  end if;
end $$;
-- After a retry, check the result really is complete
create or replace function public.zella_verify_provisioning(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_missing text[] := '{}';
begin
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id) then v_missing := array_append(v_missing, 'owner'); end if;
  if not exists (select 1 from public.business_modules bm where bm.business_id = p_business_id) then v_missing := array_append(v_missing, 'modules'); end if;
  if not exists (select 1 from public.ai_agents a where a.business_id = p_business_id) then v_missing := array_append(v_missing, 'ai_agent'); end if;
  if not exists (select 1 from public.automations a where a.business_id = p_business_id) then v_missing := array_append(v_missing, 'automations'); end if;
  if cardinality(v_missing) = 0 and not exists (select 1 from public.provisioning_steps where business_id = p_business_id and status = 'failed') then
    perform public.zella_resolve_platform_alerts('provisioning_failed', p_business_id, null, 'Verified complete');
  end if;
  return jsonb_build_object('complete', cardinality(v_missing) = 0, 'missing', to_jsonb(v_missing));
end $$;
create or replace function public.zella_business_status_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- failed provisioning shows up for admins
  if new.onboarding_status = 'failed' and old.onboarding_status is distinct from 'failed' then
    perform public.zella_platform_alert('provisioning_failed', 'Business setup failed', 'Open the business to see the failed step and retry.', 'urgent', new.id, 'status');
  elsif old.onboarding_status = 'failed' and new.onboarding_status <> 'failed' then
    perform public.zella_resolve_platform_alerts('provisioning_failed', new.id, 'status', 'Status changed');
  end if;
  -- suspension: stop what must not run, keep every record
  if new.suspended_at is not null and old.suspended_at is null then
    update public.automations set status = 'paused', paused_by_suspension = true where business_id = new.id and status = 'active';
    update public.callbacks set status = 'needs_review', outcome = 'business_suspended', auto_call = false, updated_at = now() where business_id = new.id and status in ('scheduled', 'retry_scheduled', 'due', 'new');
    update public.followup_tasks set status = 'cancelled', outcome = 'business_suspended', completed_at = now(), updated_at = now() where business_id = new.id and status = 'pending';
    update public.appointment_reminders set status = 'cancelled', error = 'business_suspended' where business_id = new.id and status = 'pending';
    update public.waitlist_entries set status = 'waiting', offered_start = null, offered_end = null, offer_expires_at = null where business_id = new.id and status = 'offered';
    perform public.zella_platform_alert('business_suspended', 'Business suspended', new.suspension_reason, 'info', new.id, to_char(new.suspended_at, 'YYYY-MM-DD'));
  elsif new.suspended_at is null and old.suspended_at is not null then
    update public.automations set status = 'active', paused_by_suspension = false where business_id = new.id and paused_by_suspension;
    perform public.zella_resolve_platform_alerts('business_suspended', new.id, null, 'Reinstated');
  end if;
  return new;
end $$;
-- retention_until is set before the row is written, so use a BEFORE trigger for it
create or replace function public.zella_business_before_trigger() returns trigger
language plpgsql set search_path = public as $$
declare v_days integer;
begin
  if new.cancelled_at is not null and old.cancelled_at is null then
    v_days := coalesce((select (value)::text::integer from public.platform_settings where key = 'retention_days'), 90);
    new.retention_until := new.cancelled_at + make_interval(days => v_days);
  end if;
  return new;
end $$;
drop trigger if exists zella_business_before_trg on public.businesses;
create trigger zella_business_before_trg before update of cancelled_at on public.businesses for each row execute function public.zella_business_before_trigger();
drop trigger if exists zella_business_status_trg on public.businesses;
create trigger zella_business_status_trg after update of onboarding_status, suspended_at on public.businesses for each row execute function public.zella_business_status_trigger();

-- records past their retention date are listed for a person to review. Nothing is deleted automatically.
create or replace function public.zella_retention_due() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('business_id', id, 'name', name, 'retention_until', retention_until)), '[]'::jsonb)
    from public.businesses where cancelled_at is not null and retention_until is not null and retention_until < now();
$$;

-- 2. invitations: remind on a schedule, flag expired ones
create or replace function public.zella_check_invitations() returns jsonb
language plpgsql security definer set search_path = public as $$
declare i record; v_hours jsonb := public.zella_setting('invitation_reminder_hours', '[24, 72]'); v_due jsonb := '[]'::jsonb; v_next numeric; v_expired integer := 0;
begin
  for i in select * from public.business_invitations where status in ('pending', 'sent', 'failed') for update skip locked loop
    if i.expires_at is not null and i.expires_at < now() then
      update public.business_invitations set status = 'expired', updated_at = now() where id = i.id; v_expired := v_expired + 1;
      perform public.zella_platform_alert('invitation_expired', 'Owner invitation expired', i.email, 'warning', i.business_id, i.id::text);
      continue;
    end if;
    if i.reminder_count < jsonb_array_length(v_hours) then
      v_next := (v_hours ->> i.reminder_count)::numeric;
      if coalesce(i.last_reminded_at, i.invited_at, i.created_at) <= now() - make_interval(secs => v_next * 3600)
         and coalesce(i.invited_at, i.created_at) <= now() - make_interval(secs => v_next * 3600) then
        v_due := v_due || jsonb_build_array(jsonb_build_object('invitation_id', i.id, 'business_id', i.business_id, 'email', i.email, 'owner_name', i.owner_name, 'reminder_no', i.reminder_count + 1));
      end if;
    end if;
  end loop;
  return jsonb_build_object('reminders_due', v_due, 'expired', v_expired);
end $$;
create or replace function public.zella_mark_invitation_reminded(p_invitation_id uuid) returns void
language sql security definer set search_path = public as $$
  update public.business_invitations set reminder_count = reminder_count + 1, last_reminded_at = now(), updated_at = now() where id = p_invitation_id;
$$;

-- 3. setup incomplete
create or replace function public.zella_check_setup_incomplete() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_days integer := (public.zella_setting('setup_incomplete_after_days', '3'))::text::integer; v_rep jsonb; v_missing text; n integer := 0;
begin
  for b in select * from public.businesses where onboarding_status not in ('active', 'paused', 'failed') and suspended_at is null and cancelled_at is null and created_at < now() - make_interval(days => v_days) loop
    v_rep := public.zella_activation_report(b.id);
    select string_agg(c ->> 'label', ', ') into v_missing from jsonb_array_elements(v_rep -> 'checks') c where not (c ->> 'ok')::boolean;
    if v_missing is not null then
      perform public.zella_platform_alert('setup_incomplete', b.name || ' has not finished setup', 'Still missing: ' || v_missing, 'warning', b.id, to_char(now(), 'IYYY-IW'));
      -- the business owner is told too, once a week
      if not exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'setup_incomplete' and created_at > now() - interval '7 days') then
        perform public.zella_notify_owners(b.id, 'setup_incomplete', 'Finish setting up Zella', 'Still to do: ' || v_missing, 'info', 'receptionist');
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- 5/6. subscriptions: payment failures and trials (no prices anywhere)
create or replace function public.zella_subscription_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
    new.past_due_since := case when new.status = 'past_due' then coalesce(old.past_due_since, now()) when new.status in ('active', 'trial') then null else old.past_due_since end;
  end if;
  return new;
end $$;
drop trigger if exists zella_subscription_before_trg on public.subscriptions;
create trigger zella_subscription_before_trg before update on public.subscriptions for each row execute function public.zella_subscription_trigger();
create or replace function public.zella_subscription_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'past_due' and old.status is distinct from 'past_due' then
    perform public.zella_platform_alert('payment_failed', 'A payment failed', null, 'urgent', new.business_id, 'payment');
    perform public.zella_notify_owners(new.business_id, 'payment_failed', 'Your payment did not go through', 'Please update your billing details to keep Zella running.', 'urgent', 'settings');
  elsif new.status in ('active', 'trial') and old.status in ('past_due', 'grace_period') then
    perform public.zella_resolve_platform_alerts('payment_failed', new.business_id, 'payment', 'Payment recovered');
    perform public.zella_resolve_platform_alerts('payment_overdue', new.business_id, 'payment', 'Payment recovered');
  end if;
  return new;
end $$;
drop trigger if exists zella_subscription_after_trg on public.subscriptions;
create trigger zella_subscription_after_trg after update of status on public.subscriptions for each row execute function public.zella_subscription_after();

-- the payment provider (via n8n) reports a result
create or replace function public.zella_record_payment_result(p_business_id uuid, p_ok boolean, p_provider_ref text default null, p_error text default null) returns text
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from public.subscriptions where business_id = p_business_id order by created_at desc limit 1 for update;
  if not found then raise exception 'SUBSCRIPTION_NOT_FOUND'; end if;
  if p_ok then update public.subscriptions set status = 'active' where id = s.id and status in ('past_due', 'grace_period', 'renewal_due', 'trial'); return 'active'; end if;
  update public.subscriptions set status = 'past_due' where id = s.id and status in ('active', 'renewal_due', 'trial', 'past_due');
  perform public.zella_platform_alert('payment_failed', 'A payment failed', left(p_error, 300), 'urgent', p_business_id, 'payment', jsonb_build_object('provider_ref', p_provider_ref));
  return 'past_due';
end $$;
-- configured policy: after the grace period move to grace_period, and (only if switched on) suspend later
create or replace function public.zella_apply_payment_policy() returns integer
language plpgsql security definer set search_path = public as $$
declare s record; v_grace integer := (public.zella_setting('payment_grace_days', '7'))::text::integer; v_susp integer := (public.zella_setting('payment_suspend_after_days', '14'))::text::integer;
        v_auto boolean := (public.zella_setting('payment_auto_suspend', 'false'))::text::boolean; n integer := 0;
begin
  for s in select * from public.subscriptions where status in ('past_due', 'grace_period') and past_due_since is not null for update skip locked loop
    if s.status = 'past_due' and s.past_due_since < now() - make_interval(days => v_grace) then
      update public.subscriptions set status = 'grace_period' where id = s.id;
      perform public.zella_notify_owners(s.business_id, 'payment_overdue', 'Your account is overdue', 'Update your billing details soon to avoid your service being paused.', 'urgent', 'settings');
      perform public.zella_platform_alert('payment_overdue', 'Payment overdue', null, 'urgent', s.business_id, 'payment');
      n := n + 1;
    end if;
    if v_auto and s.past_due_since < now() - make_interval(days => v_susp) then
      update public.businesses set suspended_at = now(), suspension_reason = 'Payment overdue' where id = s.business_id and suspended_at is null and cancelled_at is null;
      if found then n := n + 1; end if;
    end if;
  end loop;
  return n;
end $$;
-- trial ending: notices at the configured days; stops when the plan changes or the subscription ends
create or replace function public.zella_check_trials() returns integer
language plpgsql security definer set search_path = public as $$
declare s record; v_days jsonb := public.zella_setting('trial_notice_days', '[7, 3, 1]'); d integer; v_left numeric; n integer := 0;
begin
  for s in select * from public.subscriptions where status = 'trial' and trial_end_at is not null for update skip locked loop
    v_left := extract(epoch from (s.trial_end_at - now())) / 86400.0;
    if v_left <= 0 then
      perform public.zella_platform_alert('trial_ended', 'A trial has ended', null, 'warning', s.business_id, to_char(s.trial_end_at, 'YYYY-MM-DD'));
      perform public.zella_notify_owners(s.business_id, 'trial_ended', 'Your trial has ended', 'Choose a plan to keep using Zella.', 'urgent', 'settings');
      n := n + 1; continue;
    end if;
    select min(x::integer) into d from jsonb_array_elements_text(v_days) x where v_left <= x::integer;
    if d is not null and not (d = any (s.trial_notice_days)) then
      -- remember every threshold already passed so only one notice goes out
      update public.subscriptions set trial_notice_days = array(select distinct unnest(trial_notice_days || array(select x::integer from jsonb_array_elements_text(v_days) x where x::integer >= d))) where id = s.id;
      perform public.zella_notify_owners(s.business_id, 'trial_ending', 'Your trial ends in ' || ceil(v_left)::int || ' day(s)', 'Choose a plan to keep your AI receptionist running.', 'warning', 'settings');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- 9. new platform administrator: validate the role, record an audit event, tell the owners
do $$ begin
  if to_regclass('public.platform_admins') is not null then
    create or replace function public.zella_platform_admin_trigger() returns trigger
    language plpgsql security definer set search_path = public as $f$
    begin
      if tg_op in ('INSERT', 'UPDATE') then
        if new.role not in ('super_admin', 'zella_owner') then raise exception 'INVALID_ADMIN_ROLE'; end if;
      end if;
      return new;
    end $f$;
    create or replace function public.zella_platform_admin_audit() returns trigger
    language plpgsql security definer set search_path = public as $f$
    declare v_action text;
    begin
      if tg_op = 'INSERT' and new.is_active then v_action := 'platform_admin_granted';
      elsif tg_op = 'UPDATE' and new.is_active and not old.is_active then v_action := 'platform_admin_reactivated';
      elsif tg_op = 'UPDATE' and not new.is_active and old.is_active then v_action := 'platform_admin_removed';
      elsif tg_op = 'UPDATE' and new.role is distinct from old.role then v_action := 'platform_admin_role_changed';
      else return new; end if;
      insert into public.audit_logs (user_id, action, entity_type, entity_id, old_data, new_data)
      values (auth.uid(), v_action, 'platform_admin', new.user_id, case when tg_op = 'UPDATE' then jsonb_build_object('role', old.role, 'is_active', old.is_active) end, jsonb_build_object('role', new.role, 'is_active', new.is_active));
      perform public.zella_platform_alert('platform_admin_change', replace(v_action, '_', ' '), 'Role: ' || new.role, 'info', null, new.user_id::text || ':' || v_action || ':' || to_char(now(), 'YYYYMMDDHH24MISS'));
      return new;
    end $f$;
    drop trigger if exists zella_platform_admin_before_trg on public.platform_admins;
    create trigger zella_platform_admin_before_trg before insert or update on public.platform_admins for each row execute function public.zella_platform_admin_trigger();
    drop trigger if exists zella_platform_admin_after_trg on public.platform_admins;
    create trigger zella_platform_admin_after_trg after insert or update on public.platform_admins for each row execute function public.zella_platform_admin_audit();
  end if;
end $$;

-- 10. platform service incident: only VERIFIED health signals create one
create or replace function public.zella_report_service_health(p_service text, p_ok boolean, p_detail text default null, p_verified boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_ok then
    perform public.zella_resolve_platform_alerts('service_incident', null, p_service, 'Service healthy again');
    return null;
  end if;
  if not coalesce(p_verified, false) then return null; end if;   -- a single unverified blip is not an incident
  v_id := public.zella_platform_alert('service_incident', initcap(p_service) || ' is having problems', p_detail, 'urgent', null, p_service);
  return v_id;
end $$;

revoke all on function public.zella_track_provisioning(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.zella_verify_provisioning(uuid) from public, anon, authenticated;
revoke all on function public.zella_business_status_trigger() from public, anon, authenticated;
revoke all on function public.zella_retention_due() from public, anon, authenticated;
revoke all on function public.zella_check_invitations() from public, anon, authenticated;
revoke all on function public.zella_mark_invitation_reminded(uuid) from public, anon, authenticated;
revoke all on function public.zella_check_setup_incomplete() from public, anon, authenticated;
revoke all on function public.zella_subscription_after() from public, anon, authenticated;
revoke all on function public.zella_record_payment_result(uuid, boolean, text, text) from public, anon, authenticated;
revoke all on function public.zella_apply_payment_policy() from public, anon, authenticated;
revoke all on function public.zella_check_trials() from public, anon, authenticated;
revoke all on function public.zella_report_service_health(text, boolean, text, boolean) from public, anon, authenticated;
grant execute on function public.zella_track_provisioning(uuid, text, text, text) to service_role;
grant execute on function public.zella_verify_provisioning(uuid) to service_role;
grant execute on function public.zella_retention_due() to service_role;
grant execute on function public.zella_check_invitations() to service_role;
grant execute on function public.zella_mark_invitation_reminded(uuid) to service_role;
grant execute on function public.zella_check_setup_incomplete() to service_role;
grant execute on function public.zella_record_payment_result(uuid, boolean, text, text) to service_role;
grant execute on function public.zella_apply_payment_policy() to service_role;
grant execute on function public.zella_check_trials() to service_role;
grant execute on function public.zella_report_service_health(text, boolean, text, boolean) to service_role;


