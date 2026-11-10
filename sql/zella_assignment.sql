-- Zella: automatic assignment of new leads and callbacks, alerts for work nobody owns, and reassignment when
-- someone is away or leaves. Runs entirely in the database (a trigger plus two timed jobs); it costs no n8n runs.
-- Each business chooses how work is shared (assignment_rules). People can be marked away without leaving the team.

alter table public.business_members add column if not exists accepts_work boolean not null default true;
alter table public.business_members add column if not exists away_until timestamptz;
alter table public.business_members add column if not exists last_assigned_at timestamptz;

create table if not exists public.assignment_rules (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  mode text not null default 'round_robin' check (mode in ('off', 'round_robin', 'least_busy')),
  roles text[] not null default array['owner', 'admin', 'manager', 'staff'],
  unassigned_alert_minutes integer not null default 10 check (unassigned_alert_minutes between 5 and 1440),
  updated_at timestamptz not null default now()
);
alter table public.assignment_rules enable row level security;
revoke all on public.assignment_rules from anon, authenticated;
grant select on public.assignment_rules to authenticated;
do $$ begin
  create policy assignment_rules_member_read on public.assignment_rules for select to authenticated
    using (exists (select 1 from public.business_members m where m.business_id = assignment_rules.business_id and m.user_id = auth.uid() and m.status = 'active'));
exception when duplicate_object then null; end $$;

-- Open work a person currently holds: active leads, unfinished callbacks and open tasks.
create or replace function public.zella_open_workload(p_business_id uuid, p_user_id uuid) returns integer
language sql stable security definer set search_path = public as $$
  select (select count(*) from public.customers c where c.business_id = p_business_id and c.assigned_to = p_user_id and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent'))::int
       + (select count(*) from public.callbacks b where b.business_id = p_business_id and b.assigned_to = p_user_id and b.status not in ('completed', 'cancelled'))::int
       + (select count(*) from public.crm_tasks t where t.business_id = p_business_id and t.assigned_to = p_user_id and t.status = 'open')::int;
$$;

-- Who should get the next piece of work? Only active members of an allowed role who accept work and are not away.
-- round_robin: whoever was given work longest ago. least_busy: whoever holds the least open work. p_exclude skips one person.
create or replace function public.zella_pick_assignee(p_business_id uuid, p_exclude uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_mode text := 'round_robin'; v_roles text[] := array['owner', 'admin', 'manager', 'staff']; v_user uuid;
begin
  select r.mode, r.roles into v_mode, v_roles from public.assignment_rules r where r.business_id = p_business_id;
  if not found then v_mode := 'round_robin'; v_roles := array['owner', 'admin', 'manager', 'staff']; end if;
  if v_mode = 'off' then return null; end if;
  select m.user_id into v_user
    from public.business_members m
   where m.business_id = p_business_id and m.status = 'active' and m.role = any (v_roles) and m.accepts_work
     and (m.away_until is null or m.away_until <= now()) and (p_exclude is null or m.user_id <> p_exclude)
   order by case when v_mode = 'least_busy' then public.zella_open_workload(p_business_id, m.user_id) else 0 end,
            m.last_assigned_at nulls first, m.created_at, m.user_id
   limit 1;
  return v_user;
end $$;

create or replace function public.zella_mark_assigned(p_business_id uuid, p_user_id uuid) returns void
language sql security definer set search_path = public as $$
  update public.business_members set last_assigned_at = now() where business_id = p_business_id and user_id = p_user_id;
$$;

-- New lead or callback with no owner: give it to the next person (if the business uses assignment).
create or replace function public.zella_auto_assign_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if new.assigned_to is not null or new.lead_stage is null or new.lead_stage not in ('new', 'contacted', 'qualified', 'quote_sent') then return new; end if;
  v_user := public.zella_pick_assignee(new.business_id);
  if v_user is not null then
    new.assigned_to := v_user;
    perform public.zella_mark_assigned(new.business_id, v_user);
    perform public.zella_notify(new.business_id, 'lead_assigned', 'New lead assigned to you', left(coalesce(nullif(trim(coalesce(new.first_name, '') || ' ' || coalesce(new.last_name, '')), ''), 'A new lead') || ' is waiting for a first reply.', 200), 'info', 'customers', new.id, v_user);
  end if;
  return new;
end $$;
drop trigger if exists zella_auto_assign_lead_trg on public.customers;
create trigger zella_auto_assign_lead_trg before insert on public.customers for each row execute function public.zella_auto_assign_lead();

create or replace function public.zella_auto_assign_callback() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if new.assigned_to is not null or new.status in ('completed', 'cancelled') then return new; end if;
  v_user := public.zella_pick_assignee(new.business_id);
  if v_user is not null then
    new.assigned_to := v_user;
    perform public.zella_mark_assigned(new.business_id, v_user);
    perform public.zella_notify(new.business_id, 'callback_assigned', 'Callback assigned to you', left(coalesce(new.reason, 'A callback is due.'), 200), 'info', 'callbacks', new.id, v_user);
  end if;
  return new;
end $$;
drop trigger if exists zella_auto_assign_callback_trg on public.callbacks;
create trigger zella_auto_assign_callback_trg before insert on public.callbacks for each row execute function public.zella_auto_assign_callback();

-- Timed job (every 5 minutes): work held by someone who is now away, not accepting work or no longer active moves to
-- the next available person; work nobody owns gets an owner, or one grouped alert per business if nobody is available.
create or replace function public.zella_rebalance_assignments() returns integer
language plpgsql security definer set search_path = public as $$
declare w record; v_user uuid; v_moved integer := 0; r record;
begin
  -- 1. work held by someone who can no longer take it
  for w in
    select 'lead' kind, c.id, c.business_id, c.assigned_to from public.customers c
      join public.business_members m on m.business_id = c.business_id and m.user_id = c.assigned_to
     where c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent')
       and (m.status <> 'active' or not m.accepts_work or (m.away_until is not null and m.away_until > now()))
    union all
    select 'callback', b.id, b.business_id, b.assigned_to from public.callbacks b
      join public.business_members m on m.business_id = b.business_id and m.user_id = b.assigned_to
     where b.status not in ('completed', 'cancelled')
       and (m.status <> 'active' or not m.accepts_work or (m.away_until is not null and m.away_until > now()))
    limit 200
  loop
    v_user := public.zella_pick_assignee(w.business_id, w.assigned_to);
    if v_user is null then continue; end if;
    if w.kind = 'lead' then update public.customers set assigned_to = v_user, updated_at = now() where id = w.id;
    else update public.callbacks set assigned_to = v_user, updated_at = now() where id = w.id; end if;
    perform public.zella_mark_assigned(w.business_id, v_user);
    perform public.zella_notify(w.business_id, 'work_reassigned', 'Work moved to you', case w.kind when 'lead' then 'A lead was reassigned to you because its owner is away.' else 'A callback was reassigned to you because its owner is away.' end, 'info', case w.kind when 'lead' then 'customers' else 'callbacks' end, w.id, v_user);
    v_moved := v_moved + 1;
  end loop;

  -- 2. work with no owner (businesses with assignment on): give it an owner now
  for w in
    select 'lead' kind, c.id, c.business_id from public.customers c join public.assignment_rules a on a.business_id = c.business_id and a.mode <> 'off'
     where c.assigned_to is null and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent')
    union all
    select 'callback', b.id, b.business_id from public.callbacks b join public.assignment_rules a on a.business_id = b.business_id and a.mode <> 'off'
     where b.assigned_to is null and b.status not in ('completed', 'cancelled')
    limit 200
  loop
    v_user := public.zella_pick_assignee(w.business_id);
    if v_user is null then continue; end if;
    if w.kind = 'lead' then update public.customers set assigned_to = v_user, updated_at = now() where id = w.id;
    else update public.callbacks set assigned_to = v_user, updated_at = now() where id = w.id; end if;
    perform public.zella_mark_assigned(w.business_id, v_user);
    v_moved := v_moved + 1;
  end loop;
  return v_moved;
end $$;

-- Timed job (every 5 minutes): one alert per business (at most once every 6 hours) when leads or callbacks have waited
-- with no owner longer than the business allows. Goes to owners and admins.
create or replace function public.zella_check_unassigned_work() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; v_alerts integer := 0; u record;
begin
  for r in
    select b.id business_id, coalesce(a.unassigned_alert_minutes, 10) mins,
           (select count(*) from public.customers c where c.business_id = b.id and c.assigned_to is null and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent') and c.created_at < now() - make_interval(mins => coalesce(a.unassigned_alert_minutes, 10))) leads,
           (select count(*) from public.callbacks k where k.business_id = b.id and k.assigned_to is null and k.status not in ('completed', 'cancelled') and k.created_at < now() - make_interval(mins => coalesce(a.unassigned_alert_minutes, 10))) callbacks
      from public.businesses b left join public.assignment_rules a on a.business_id = b.id
     where b.suspended_at is null and b.cancelled_at is null
  loop
    if r.leads + r.callbacks = 0 then continue; end if;
    if exists (select 1 from public.staff_notifications n where n.business_id = r.business_id and n.kind = 'unassigned_work' and n.created_at > now() - interval '6 hours') then continue; end if;
    for u in select user_id from public.business_members where business_id = r.business_id and status = 'active' and role in ('owner', 'admin') loop
      perform public.zella_notify(r.business_id, 'unassigned_work', 'Work with no owner',
        r.leads || ' lead(s) and ' || r.callbacks || ' callback(s) have been waiting with nobody assigned. Check who is available.', 'warning', 'customers', null, u.user_id);
    end loop;
    v_alerts := v_alerts + 1;
  end loop;
  return v_alerts;
end $$;

-- Owner action from the app later: mark a person away until a time, or back.
create or replace function public.zella_set_member_away(p_business_id uuid, p_user_id uuid, p_until timestamptz)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_user_id <> auth.uid() and not exists (select 1 from public.business_members where business_id = p_business_id and user_id = auth.uid() and status = 'active' and role in ('owner', 'admin', 'manager')) then raise exception 'NOT_ALLOWED'; end if;
  update public.business_members set away_until = p_until where business_id = p_business_id and user_id = p_user_id and status = 'active';
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_open_workload(uuid,uuid)', 'zella_pick_assignee(uuid,uuid)', 'zella_mark_assigned(uuid,uuid)', 'zella_auto_assign_lead()',
      'zella_auto_assign_callback()', 'zella_rebalance_assignments()', 'zella_check_unassigned_work()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  revoke execute on function public.zella_set_member_away(uuid, uuid, timestamptz) from public, anon;
  grant execute on function public.zella_set_member_away(uuid, uuid, timestamptz) to authenticated, service_role;
end $$;
