-- Zella: complaints, data corrections and privacy (data access / deletion) requests.
-- Each one is logged once, routed to the right person, given a due time and watched until it is closed.
-- Zella never changes or deletes customer data by itself because of one of these: people do the work, Zella tracks it.
-- Privacy requests start as "waiting_verification": nothing is released or removed until a person has checked who is asking.

create table if not exists public.customer_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  call_id uuid,
  kind text not null check (kind in ('complaint', 'correction', 'data_access', 'data_deletion')),
  summary text not null check (length(summary) between 3 and 1000),
  source text not null default 'staff' check (source in ('phone', 'web', 'email', 'sms', 'staff')),
  status text not null default 'open' check (status in ('open', 'in_progress', 'waiting_verification', 'resolved', 'rejected')),
  priority text not null default 'normal' check (priority in ('normal', 'high', 'urgent')),
  assigned_to uuid,
  due_at timestamptz not null,
  resolution_note text,
  resolved_at timestamptz,
  overdue_notified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists customer_requests_open_idx on public.customer_requests (business_id, status, due_at);
alter table public.customer_requests enable row level security;
revoke all on public.customer_requests from anon, authenticated;
grant select on public.customer_requests to authenticated;
do $$ begin
  create policy customer_requests_member_read on public.customer_requests for select to authenticated
    using (exists (select 1 from public.business_members m where m.business_id = customer_requests.business_id and m.user_id = auth.uid() and m.status = 'active'));
exception when duplicate_object then null; end $$;

-- Log a request (from the phone assistant, a web form, email or staff). Repeats of the same open request within a day
-- are not duplicated. Privacy requests go to owners/admins only; complaints are urgent-notified.
create or replace function public.zella_log_customer_request(p_business_id uuid, p_customer_id uuid, p_kind text, p_summary text,
  p_source text default 'staff', p_call_id uuid default null, p_priority text default 'normal')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_summary text := left(regexp_replace(trim(coalesce(p_summary, '')), '\s+', ' ', 'g'), 1000); v_id uuid; v_user uuid; v_due timestamptz; v_status text; u record;
begin
  if p_kind not in ('complaint', 'correction', 'data_access', 'data_deletion') then raise exception 'INVALID_KIND'; end if;
  if length(v_summary) < 3 then raise exception 'EMPTY_SUMMARY'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then p_customer_id := null; end if;
  select id into v_id from public.customer_requests
   where business_id = p_business_id and kind = p_kind and status in ('open', 'in_progress', 'waiting_verification')
     and customer_id is not distinct from p_customer_id and created_at > now() - interval '24 hours' limit 1;
  if v_id is not null then return v_id; end if;

  v_due := now() + case p_kind when 'complaint' then case when p_priority = 'urgent' then interval '4 hours' else interval '24 hours' end
                                when 'correction' then interval '3 days' else interval '30 days' end;
  v_status := case when p_kind in ('data_access', 'data_deletion') then 'waiting_verification' else 'open' end;
  if p_kind in ('data_access', 'data_deletion') then
    select user_id into v_user from public.business_members where business_id = p_business_id and status = 'active' and role in ('owner', 'admin') order by created_at limit 1;
  else
    v_user := public.zella_pick_assignee(p_business_id);
    if v_user is not null then perform public.zella_mark_assigned(p_business_id, v_user); end if;
  end if;
  insert into public.customer_requests (business_id, customer_id, call_id, kind, summary, source, status, priority, assigned_to, due_at)
  values (p_business_id, p_customer_id, p_call_id, p_kind, v_summary, case when p_source in ('phone', 'web', 'email', 'sms', 'staff') then p_source else 'staff' end,
          v_status, case when p_priority in ('normal', 'high', 'urgent') then p_priority else 'normal' end, v_user, v_due) returning id into v_id;

  if p_kind in ('data_access', 'data_deletion') or v_user is null then
    for u in select user_id from public.business_members where business_id = p_business_id and status = 'active' and role in ('owner', 'admin') loop
      perform public.zella_notify(p_business_id, 'customer_request', case p_kind when 'complaint' then 'New complaint' when 'correction' then 'Data correction request' when 'data_access' then 'Privacy request: access to data' else 'Privacy request: deletion' end,
        left(v_summary, 200), case when p_kind = 'complaint' then 'warning' else 'info' end, 'customers', v_id, u.user_id);
    end loop;
  else
    perform public.zella_notify(p_business_id, 'customer_request', case p_kind when 'complaint' then 'New complaint for you' else 'Data correction request for you' end,
      left(v_summary, 200), case when p_kind = 'complaint' then 'warning' else 'info' end, 'customers', v_id, v_user);
  end if;
  return v_id;
end $$;

-- Staff move a request along or close it. Only members of the business; only the final states are recorded with a note.
create or replace function public.zella_update_customer_request(p_id uuid, p_status text, p_note text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from public.customer_requests where id = p_id;
  if not found or not public.zella_is_member(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_status not in ('open', 'in_progress', 'waiting_verification', 'resolved', 'rejected') then raise exception 'INVALID_STATUS'; end if;
  if p_status in ('resolved', 'rejected') and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  if r.kind in ('data_access', 'data_deletion') and p_status = 'resolved' and not exists (select 1 from public.business_members where business_id = r.business_id and user_id = auth.uid() and status = 'active' and role in ('owner', 'admin')) then raise exception 'NOT_ALLOWED'; end if;
  update public.customer_requests set status = p_status, resolution_note = case when p_status in ('resolved', 'rejected') then left(p_note, 1000) else resolution_note end,
         resolved_at = case when p_status in ('resolved', 'rejected') then now() else null end, updated_at = now() where id = p_id;
  return true;
end $$;

-- Timed job (hourly): one alert per overdue request to owners and admins.
create or replace function public.zella_check_customer_requests() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; u record; n integer := 0;
begin
  for r in select * from public.customer_requests where status in ('open', 'in_progress', 'waiting_verification') and due_at < now() and overdue_notified_at is null limit 100 loop
    for u in select user_id from public.business_members where business_id = r.business_id and status = 'active' and role in ('owner', 'admin') loop
      perform public.zella_notify(r.business_id, 'customer_request_overdue', 'A customer request is overdue',
        left(r.summary, 160), 'warning', 'customers', r.id, u.user_id);
    end loop;
    update public.customer_requests set overdue_notified_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.zella_log_customer_request(uuid, uuid, text, text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.zella_log_customer_request(uuid, uuid, text, text, text, uuid, text) to service_role;
revoke execute on function public.zella_check_customer_requests() from public, anon, authenticated;
grant execute on function public.zella_check_customer_requests() to service_role;
revoke execute on function public.zella_update_customer_request(uuid, text, text) from public, anon;
grant execute on function public.zella_update_customer_request(uuid, text, text) to authenticated, service_role;

-- Phone assistant tool: the caller wants to complain, correct their details, or ask for their data to be shown or removed.
-- The call decides the business and customer when it is known; otherwise the (already looked-up) business is used.
-- The answer to the assistant says only that the team will follow up, never that anything was changed or released.
create or replace function public.zella_ai_log_request(p_provider_call_id text, p_business_id uuid, p_kind text, p_summary text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_call_id uuid; v_call_biz uuid; v_cust uuid; v_biz uuid; v_id uuid;
begin
  if nullif(p_provider_call_id, '') is not null then
    select c.id, c.business_id, c.customer_id into v_call_id, v_call_biz, v_cust from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call_biz, p_business_id);
  if v_biz is null then return jsonb_build_object('ok', false, 'reason', 'unknown_business'); end if;
  begin
    v_id := public.zella_log_customer_request(v_biz, v_cust, p_kind, p_summary, 'phone', v_call_id, 'normal');
  exception when others then
    return jsonb_build_object('ok', false, 'reason', left(sqlerrm, 40));
  end;
  return jsonb_build_object('ok', true, 'kind', p_kind);
end $$;
revoke execute on function public.zella_ai_log_request(text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_ai_log_request(text, uuid, text, text) to service_role;
