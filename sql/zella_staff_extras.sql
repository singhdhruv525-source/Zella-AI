-- Zella - staff extras (checklist 185, 187, 191). Safe to run more than once.
--   185  time-off requests: a team member asks, a manager approves, and the time is blocked on the calendar
--        (existing appointments in that time are flagged for rebooking by the existing blocked-time rule).
--   187  overdue-task alerts: an open task past its due time reminds the person it belongs to (or the owners if nobody has it), once.
--   191  manager escalation: a task still open a day after it was due is marked urgent and the managers are told.
--        (Overdue leads already escalate through zella_flag_overdue_leads, so they are skipped here.)
insert into public.platform_settings (key, value) values ('task_overdue_grace_minutes', '60'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('task_escalate_hours', '24'::jsonb) on conflict (key) do nothing;

-- 1. Time off (185).
create table if not exists public.time_off_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id uuid not null references public.staff_members(id) on delete cascade,
  requested_by uuid,
  from_at timestamptz not null,
  to_at timestamptz not null,
  reason text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'cancelled')),
  decided_by uuid,
  decided_at timestamptz,
  blocked_time_id uuid,
  created_at timestamptz not null default now(),
  check (to_at > from_at)
);
create index if not exists time_off_requests_biz_idx on public.time_off_requests (business_id, status, from_at);
alter table public.time_off_requests enable row level security;
revoke all on public.time_off_requests from anon, authenticated;
drop policy if exists time_off_requests_read on public.time_off_requests;
create policy time_off_requests_read on public.time_off_requests for select to authenticated using (public.zella_is_member(business_id));
grant select on public.time_off_requests to authenticated;

create or replace function public.zella_request_time_off(p_business_id uuid, p_staff_id uuid, p_from timestamptz, p_to timestamptz, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select name into v_name from public.staff_members where id = p_staff_id and business_id = p_business_id and is_active;
  if v_name is null then raise exception 'UNKNOWN_STAFF'; end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to < now() or p_to - p_from > interval '60 days' then raise exception 'BAD_DATES'; end if;
  insert into public.time_off_requests (business_id, staff_id, requested_by, from_at, to_at, reason)
  values (p_business_id, p_staff_id, auth.uid(), p_from, p_to, v_reason) returning id into v_id;
  perform public.zella_notify_owners(p_business_id, 'time_off_request', 'Time off requested: ' || v_name, coalesce(v_reason, 'Open the calendar to approve or decline.'), 'info', 'calendar');
  return v_id;
end $$;
revoke execute on function public.zella_request_time_off(uuid, uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.zella_request_time_off(uuid, uuid, timestamptz, timestamptz, text) to authenticated, service_role;

create or replace function public.zella_decide_time_off(p_request_id uuid, p_approve boolean)
returns text language plpgsql security definer set search_path = public as $$
declare r public.time_off_requests%rowtype; v_name text; v_block uuid;
begin
  select * into r from public.time_off_requests where id = p_request_id;
  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  select name into v_name from public.staff_members where id = r.staff_id;
  if p_approve then
    insert into public.blocked_times (business_id, title, reason, start_time, end_time, staff_id, created_by, source)
    values (r.business_id, 'Time off: ' || coalesce(v_name, 'staff'), coalesce(r.reason, 'Time off'), r.from_at, r.to_at, r.staff_id, auth.uid(), 'time_off')
    returning id into v_block;
  end if;
  update public.time_off_requests set status = case when p_approve then 'approved' else 'declined' end, decided_by = auth.uid(), decided_at = now(), blocked_time_id = v_block where id = r.id;
  if r.requested_by is not null then
    perform public.zella_notify(r.business_id, 'time_off_decision', case when p_approve then 'Time off approved' else 'Time off declined' end,
      coalesce(v_name, 'Staff') || ': ' || to_char(r.from_at, 'Mon FMDD') || ' to ' || to_char(r.to_at, 'Mon FMDD'), 'info', 'calendar', r.id, r.requested_by);
  end if;
  return case when p_approve then 'approved' else 'declined' end;
end $$;
revoke execute on function public.zella_decide_time_off(uuid, boolean) from public, anon;
grant execute on function public.zella_decide_time_off(uuid, boolean) to authenticated, service_role;

-- 2. Overdue tasks and manager escalation (187, 191). Run every hour.
alter table public.crm_tasks add column if not exists overdue_notified_at timestamptz;

create or replace function public.zella_check_overdue_tasks(p_limit integer default 100)
returns integer language plpgsql security definer set search_path = public as $$
declare t record; n integer := 0;
  v_grace integer := greatest(5, coalesce((public.zella_setting('task_overdue_grace_minutes', '60'::jsonb) #>> '{}')::integer, 60));
  v_esc integer := greatest(1, coalesce((public.zella_setting('task_escalate_hours', '24'::jsonb) #>> '{}')::integer, 24));
begin
  for t in select k.* from public.crm_tasks k join public.businesses b on b.id = k.business_id and b.suspended_at is null and b.cancelled_at is null
            where k.status = 'open' and k.due_at is not null and k.due_at < now() - make_interval(mins => v_grace) and k.kind <> 'overdue_contact'
              and (k.overdue_notified_at is null or (k.escalated_at is null and k.due_at < now() - make_interval(hours => v_esc)))
            order by k.due_at limit greatest(1, least(coalesce(p_limit, 100), 500)) loop
    if t.overdue_notified_at is null then
      if t.assigned_to is not null then
        perform public.zella_notify(t.business_id, 'task_overdue', 'A task is overdue', left(t.title, 150), 'warning', 'tasks', t.id, t.assigned_to);
      else
        perform public.zella_notify_owners(t.business_id, 'task_overdue', 'An unassigned task is overdue', left(t.title, 150), 'warning', 'tasks');
      end if;
      update public.crm_tasks set overdue_notified_at = now() where id = t.id;
      n := n + 1;
    end if;
    if t.escalated_at is null and t.due_at < now() - make_interval(hours => v_esc) then
      update public.crm_tasks set escalated_at = now(), priority = 'urgent' where id = t.id and escalated_at is null;
      perform public.zella_notify_owners(t.business_id, 'task_escalated', 'Escalated: a task is a day late', left(t.title, 150), 'urgent', 'tasks');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.zella_check_overdue_tasks(integer) from public, anon, authenticated;
grant execute on function public.zella_check_overdue_tasks(integer) to service_role;
