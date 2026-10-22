-- Call outcome tracking: who is looking after a call, what the result was,
-- turn an unknown caller into a lead, and book a callback that stays linked
-- to the call. The browser calls these functions; each checks the caller
-- belongs to the call's business.

alter table public.calls add column if not exists assigned_to uuid;
alter table public.calls add column if not exists outcome text;
alter table public.calls add column if not exists outcome_note text;
alter table public.calls add column if not exists outcome_at timestamptz;
do $$ begin
  alter table public.calls add constraint calls_outcome_chk
    check (outcome is null or outcome in ('resolved', 'booked', 'callback_needed', 'left_message', 'wrong_number', 'spam', 'other'));
exception when duplicate_object then null; end $$;

-- Set a call's outcome and/or owner. p_unassign clears the owner; p_clear_outcome clears the outcome.
create or replace function public.zella_call_update(
  p_call_id uuid, p_outcome text default null, p_note text default null, p_assign_to uuid default null,
  p_unassign boolean default false, p_clear_outcome boolean default false
) returns boolean
language plpgsql security definer set search_path = public as $$
declare c public.calls;
begin
  select * into c from public.calls where id = p_call_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_outcome is not null and p_outcome not in ('resolved', 'booked', 'callback_needed', 'left_message', 'wrong_number', 'spam', 'other') then raise exception 'BAD_OUTCOME'; end if;
  if p_assign_to is not null and not exists (select 1 from public.business_members where business_id = c.business_id and user_id = p_assign_to and status = 'active') then
    raise exception 'NOT_A_MEMBER';
  end if;
  update public.calls
     set outcome = case when p_clear_outcome then null else coalesce(p_outcome, outcome) end,
         outcome_note = case when p_clear_outcome then null when p_outcome is not null then nullif(trim(coalesce(p_note, '')), '') else outcome_note end,
         outcome_at = case when p_clear_outcome then null when p_outcome is not null then now() else outcome_at end,
         assigned_to = case when p_unassign then null else coalesce(p_assign_to, assigned_to) end,
         updated_at = now()
   where id = p_call_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (c.business_id, auth.uid(), 'call.updated', 'call', p_call_id,
          jsonb_build_object('outcome', c.outcome, 'assigned_to', c.assigned_to),
          jsonb_build_object('outcome', case when p_clear_outcome then null else coalesce(p_outcome, c.outcome) end,
                             'assigned_to', case when p_unassign then null else coalesce(p_assign_to, c.assigned_to) end));
  return true;
end $$;

-- Turn the caller into a lead (or link the call to the person already on file).
create or replace function public.zella_call_create_lead(p_call_id uuid, p_first_name text default null, p_last_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.calls; v_res jsonb; v_cust uuid;
begin
  select * into c from public.calls where id = p_call_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if c.customer_id is not null then return jsonb_build_object('result', 'already_linked', 'customer_id', c.customer_id); end if;
  if public.zella_digits(c.from_number) is null then raise exception 'NO_CONTACT'; end if;
  v_res := public.zella_capture_lead(c.business_id, p_first_name, p_last_name, c.from_number, null, 'phone_call', left(c.summary, 500), null);
  v_cust := nullif(v_res ->> 'customer_id', '')::uuid;
  if v_cust is not null and (v_res ->> 'result') in ('created', 'matched') then
    update public.calls set customer_id = v_cust, updated_at = now() where id = p_call_id;
  end if;
  return v_res;
end $$;

-- Book a callback for this call's caller, linked to the call.
create or replace function public.zella_call_schedule_callback(p_call_id uuid, p_preferred_at timestamptz default null, p_summary text default null, p_priority text default 'normal') returns uuid
language plpgsql security definer set search_path = public as $$
declare c public.calls; v_phone text;
begin
  select * into c from public.calls where id = p_call_id;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(cu.phone, c.from_number) into v_phone from (select 1) x left join public.customers cu on cu.id = c.customer_id;
  if public.zella_digits(v_phone) is null then raise exception 'NO_CONTACT'; end if;
  return public.zella_create_callback(c.business_id, v_phone, 'requested', coalesce(p_priority, 'normal'),
           coalesce(nullif(trim(p_summary), ''), c.summary), p_preferred_at, c.customer_id, p_call_id, null, 'staff');
end $$;

revoke all on function public.zella_call_update(uuid, text, text, uuid, boolean, boolean) from public, anon;
revoke all on function public.zella_call_create_lead(uuid, text, text) from public, anon;
revoke all on function public.zella_call_schedule_callback(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.zella_call_update(uuid, text, text, uuid, boolean, boolean) to authenticated, service_role;
grant execute on function public.zella_call_create_lead(uuid, text, text) to authenticated, service_role;
grant execute on function public.zella_call_schedule_callback(uuid, timestamptz, text, text) to authenticated, service_role;
