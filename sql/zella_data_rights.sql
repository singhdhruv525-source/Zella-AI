-- Zella - data-rights requests (checklist 114). Safe to run more than once.
-- Needs zella_ops_extras.sql (export, erase) and zella_security_extras.sql (erase approval).
-- A customer asks to see, correct, stop using or erase their information. The request is logged with a 30 day deadline,
-- owners are reminded as it gets close, and an owner or admin can run the export or the erasure from the request.
create table if not exists public.data_rights_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  kind text not null check (kind in ('export', 'correct', 'stop_use', 'erase')),
  requester_name text,
  requester_contact text,
  note text,
  status text not null default 'open' check (status in ('open', 'done', 'rejected')),
  due_at timestamptz not null default now() + interval '30 days',
  reminded_at timestamptz,
  created_by uuid,
  handled_by uuid,
  handled_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists data_rights_open_idx on public.data_rights_requests (business_id, due_at) where status = 'open';
alter table public.data_rights_requests enable row level security;
drop policy if exists data_rights_read on public.data_rights_requests;
create policy data_rights_read on public.data_rights_requests for select to authenticated using (public.zella_has_role(business_id, array['owner', 'admin', 'manager']));
revoke all on public.data_rights_requests from anon;
grant select on public.data_rights_requests to authenticated;

create or replace function public.zella_log_data_rights_request(p_business_id uuid, p_kind text, p_customer_id uuid default null, p_name text default null, p_contact text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.data_rights_requests (business_id, customer_id, kind, requester_name, requester_contact, note, created_by)
  values (p_business_id, p_customer_id, p_kind, left(p_name, 200), left(p_contact, 200), left(p_note, 1000), auth.uid()) returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'data_rights_logged', 'data_rights_request', v_id, jsonb_build_object('kind', p_kind));
  perform public.zella_notify_owners(p_business_id, 'data_rights_request', 'A customer asked about their information', 'Reply within 30 days. Open the request to export or erase their details.', 'warning', 'customers');
  return v_id;
end $$;
revoke execute on function public.zella_log_data_rights_request(uuid, text, uuid, text, text, text) from public, anon;
grant execute on function public.zella_log_data_rights_request(uuid, text, uuid, text, text, text) to authenticated, service_role;

-- Carry out the request. Export returns the data; erase removes the details (and needs a second approval where the business has two owners/admins).
create or replace function public.zella_fulfil_data_rights_request(p_request_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.data_rights_requests; v_out jsonb := '{}'::jsonb;
begin
  select * into r from public.data_rights_requests where id = p_request_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(r.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'open' then raise exception 'ALREADY_HANDLED'; end if;
  if r.kind = 'export' then
    if r.customer_id is null then raise exception 'NO_CUSTOMER'; end if;
    v_out := public.zella_export_customer_data(r.business_id, r.customer_id);
  elsif r.kind = 'erase' then
    if r.customer_id is null then raise exception 'NO_CUSTOMER'; end if;
    perform public.zella_erase_customer(r.business_id, r.customer_id);
  end if;
  update public.data_rights_requests set status = 'done', handled_by = auth.uid(), handled_at = now(), note = coalesce(left(p_note, 1000), note) where id = r.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (r.business_id, auth.uid(), 'data_rights_done', 'data_rights_request', r.id, jsonb_build_object('kind', r.kind));
  return v_out;
end $$;
revoke execute on function public.zella_fulfil_data_rights_request(uuid, text) from public, anon;
grant execute on function public.zella_fulfil_data_rights_request(uuid, text) to authenticated, service_role;

create or replace function public.zella_reject_data_rights_request(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.data_rights_requests;
begin
  select * into r from public.data_rights_requests where id = p_request_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(r.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'open' then raise exception 'ALREADY_HANDLED'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED'; end if;
  update public.data_rights_requests set status = 'rejected', handled_by = auth.uid(), handled_at = now(), note = left(p_reason, 1000) where id = r.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (r.business_id, auth.uid(), 'data_rights_rejected', 'data_rights_request', r.id, jsonb_build_object('kind', r.kind));
end $$;
revoke execute on function public.zella_reject_data_rights_request(uuid, text) from public, anon;
grant execute on function public.zella_reject_data_rights_request(uuid, text) to authenticated, service_role;

-- Daily: open requests due within a week (or late) are flagged to owners, at most every 3 days per request.
create or replace function public.zella_check_data_rights_due() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select * from public.data_rights_requests where status = 'open' and due_at < now() + interval '7 days'
            and (reminded_at is null or reminded_at < now() - interval '3 days') loop
    perform public.zella_notify_owners(r.business_id, 'data_rights_due',
      case when r.due_at < now() then 'A customer information request is overdue' else 'A customer information request is due soon' end,
      'Due ' || to_char(r.due_at, 'Mon DD') || '. Open Customers to finish it.', case when r.due_at < now() then 'urgent' else 'warning' end, 'customers');
    update public.data_rights_requests set reminded_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_check_data_rights_due() from public, anon, authenticated;
grant execute on function public.zella_check_data_rights_due() to service_role;
