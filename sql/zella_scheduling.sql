-- Release 2: scheduling, capacity and dispatch (7 Nov 2026).
--
-- Builds on what exists: appointments and their conflict guard (staff and restaurant tables, under the booking lock),
-- staff_members, blocked_times, arrival windows (zella_arrival_window) and the "dispatch" capability. Adds:
--
--   * resources: rooms, chairs, service bays, equipment, boarding spaces, vehicles. An appointment uses resources
--     (appointments.resource_ids). A resource with capacity 1 takes one booking at a time; a larger capacity (a boarding
--     area, a class room) takes as many people as it holds. Its own buffer keeps turnover time free. A resource can be
--     blocked (blocked_times.resource_id: maintenance, cleaning). All of this is enforced by a trigger on appointments,
--     under the same booking lock as the staff and table checks, so two bookings can never take the same chair at once,
--     whoever writes them (the app, the AI receptionist, an import).
--   * service needs: "a colour needs a chair", "a boarding stay needs a kennel". A booking for that service that names
--     no resource gets free ones picked automatically, or is refused (SLOT_TAKEN) when none is free.
--   * crews: appointments.crew_staff_ids (people besides the lead, staff_id). Nobody can be on two overlapping jobs,
--     as lead or crew.
--   * dispatch (job_dispatch): assigned -> on the way -> on site (pause) -> completed / needs a return visit, with
--     timestamps, a completion checklist (required items must be done to complete), and return visits linked to the
--     original job. The board shows each technician's day with arrival windows and the unassigned jobs.
--   * recurring plans: "every 2 weeks on Tuesday at 9:00", "monthly on the 15th". Generating visits is safe to repeat:
--     each date is booked once (recurring_visits), and a date that clashes is recorded as skipped with the reason,
--     never forced. Generated visits are saved as planned (booking_state 'tentative', no hold expiry), so they hold
--     the time but queue no customer messages; the team confirms them.
--
-- Nothing here sends a message, places a call or turns on a scheduler: generation runs when someone asks for it.
-- Safe to run twice. Undo: sql/rollback/zella_scheduling_rollback.sql (keeps every row). Needs the owner's approval.

-- ===================================================== resources
create table if not exists public.resources (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  kind text not null,
  capacity integer not null default 1,
  buffer_minutes integer not null default 0,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint resources_name_len check (length(trim(name)) between 1 and 80),
  constraint resources_kind check (kind in ('room', 'chair', 'bay', 'equipment', 'space', 'vehicle', 'other')),
  constraint resources_capacity check (capacity between 1 and 500),
  constraint resources_buffer check (buffer_minutes between 0 and 240),
  constraint resources_notes_len check (length(coalesce(notes, '')) <= 300)
);
create index if not exists resources_business on public.resources (business_id, sort_order);
create unique index if not exists resources_one_name on public.resources (business_id, lower(trim(name))) where is_active;

-- a service that needs resources of a kind ("colour" needs 1 chair)
create table if not exists public.resource_needs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  service text not null,
  kind text not null,
  quantity integer not null default 1,
  created_at timestamptz not null default now(),
  constraint resource_needs_service_len check (length(trim(service)) between 2 and 80),
  constraint resource_needs_kind check (kind in ('room', 'chair', 'bay', 'equipment', 'space', 'vehicle', 'other')),
  constraint resource_needs_quantity check (quantity between 1 and 10)
);
create unique index if not exists resource_needs_one on public.resource_needs (business_id, lower(trim(service)), kind);

alter table public.appointments add column if not exists resource_ids uuid[];
alter table public.appointments add column if not exists crew_staff_ids uuid[];
alter table public.blocked_times add column if not exists resource_id uuid references public.resources(id) on delete cascade;
-- after an undo and a fresh apply the column is already there without its link to the new table: link it again
-- (not valid: rows from before the undo keep their old ids; every new or changed block is checked)
do $$ begin
  if not exists (select 1 from pg_constraint c where c.conrelid = 'public.blocked_times'::regclass and c.contype = 'f' and c.confrelid = 'public.resources'::regclass) then
    alter table public.blocked_times add constraint blocked_times_resource_fk foreign key (resource_id) references public.resources(id) on delete cascade not valid;
  end if;
end $$;
create index if not exists appointments_resource_ids on public.appointments using gin (resource_ids) where resource_ids is not null;
create index if not exists appointments_crew on public.appointments using gin (crew_staff_ids) where crew_staff_ids is not null;

-- ===================================================== dispatch and recurring plans
create table if not exists public.job_dispatch (
  appointment_id uuid primary key references public.appointments(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  status text not null default 'assigned',
  en_route_at timestamptz,
  on_site_at timestamptz,
  finished_at timestamptz,
  checklist jsonb not null default '[]'::jsonb,
  return_of uuid references public.appointments(id) on delete set null,
  note text,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint job_dispatch_status check (status in ('assigned', 'en_route', 'on_site', 'paused', 'completed', 'needs_return')),
  constraint job_dispatch_checklist check (jsonb_typeof(checklist) = 'array' and jsonb_array_length(checklist) <= 40),
  constraint job_dispatch_note_len check (length(coalesce(note, '')) <= 500)
);
create index if not exists job_dispatch_business on public.job_dispatch (business_id, status);
create index if not exists job_dispatch_return_of on public.job_dispatch (return_of) where return_of is not null;

create table if not exists public.recurring_plans (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  record_id uuid references public.crm_records(id) on delete set null,
  title text not null,
  service text,
  duration_minutes integer not null default 60,
  frequency text not null,
  interval_count integer not null default 1,
  weekday smallint,
  month_day smallint,
  start_at time not null,
  staff_id uuid references public.staff_members(id) on delete set null,
  resource_ids uuid[],
  starts_on date not null,
  ends_on date,
  is_active boolean not null default true,
  notes text,
  generated_through date,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recurring_plans_title_len check (length(trim(title)) between 1 and 120),
  constraint recurring_plans_service_len check (length(coalesce(service, '')) <= 80),
  constraint recurring_plans_duration check (duration_minutes between 5 and 720),
  constraint recurring_plans_frequency check (frequency in ('weekly', 'monthly')),
  constraint recurring_plans_interval check (interval_count between 1 and 12),
  -- spelled with coalesce: a missing day must fail the check, not slip through as unknown
  constraint recurring_plans_day check (coalesce((frequency = 'weekly' and weekday between 0 and 6 and month_day is null)
                                              or (frequency = 'monthly' and month_day between 1 and 28 and weekday is null), false)),
  constraint recurring_plans_dates check (ends_on is null or ends_on >= starts_on),
  constraint recurring_plans_notes_len check (length(coalesce(notes, '')) <= 500)
);
create index if not exists recurring_plans_business on public.recurring_plans (business_id, is_active);

create table if not exists public.recurring_visits (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.recurring_plans(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  occurs_on date not null,
  appointment_id uuid references public.appointments(id) on delete set null,
  outcome text not null,
  reason text,
  created_at timestamptz not null default now(),
  constraint recurring_visits_outcome check (outcome in ('booked', 'skipped')),
  constraint recurring_visits_reason_len check (length(coalesce(reason, '')) <= 300)
);
create unique index if not exists recurring_visits_one on public.recurring_visits (plan_id, occurs_on);

-- ===================================================== access: members read; writes go through the functions below
alter table public.resources enable row level security;
alter table public.resource_needs enable row level security;
alter table public.job_dispatch enable row level security;
alter table public.recurring_plans enable row level security;
alter table public.recurring_visits enable row level security;
revoke all on public.resources, public.resource_needs, public.job_dispatch, public.recurring_plans, public.recurring_visits from public, anon, authenticated;
grant select on public.resources, public.resource_needs, public.job_dispatch, public.recurring_plans, public.recurring_visits to authenticated;
grant all on public.resources, public.resource_needs, public.job_dispatch, public.recurring_plans, public.recurring_visits to service_role;
do $$ declare t text; begin
  foreach t in array array['resources', 'resource_needs', 'job_dispatch', 'recurring_plans', 'recurring_visits'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_business_member(business_id))', t || '_read', t);
    if not exists (select 1 from pg_policies where tablename = t and policyname = 'zella_mfa_required') then
      execute format('create policy zella_mfa_required on public.%I as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())', t);
    end if;
  end loop;
end $$;

-- ===================================================== helpers
-- how much of a resource one booking uses: one slot of a single-use resource, or one place per person of a shared one
create or replace function public.zella_resource_usage(p_capacity integer, p_party integer) returns integer
language sql immutable set search_path = '' as $$
  select case when p_capacity <= 1 then 1 else greatest(coalesce(p_party, 1), 1) end $$;

-- the resource's places used between p_start and p_end (its buffer included), not counting p_ignore
create or replace function public.zella_resource_used(p_resource uuid, p_start timestamptz, p_end timestamptz, p_ignore uuid) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum(public.zella_resource_usage(r.capacity, a.party_size)), 0)::int
    from public.resources r
    join public.appointments a on a.business_id = r.business_id and p_resource = any (a.resource_ids)
   where r.id = p_resource and a.id is distinct from p_ignore
     and public.zella_appointment_holds_time(a.status, a.booking_state, a.hold_expires_at)
     and a.start_time < p_end + make_interval(mins => r.buffer_minutes)
     and a.end_time + make_interval(mins => r.buffer_minutes) > p_start $$;

-- is the resource free enough for a booking of p_party between p_start and p_end?
create or replace function public.zella_resource_free(p_resource uuid, p_start timestamptz, p_end timestamptz, p_party integer, p_ignore uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select r.is_active
     and not exists (select 1 from public.blocked_times b where b.resource_id = r.id and b.start_time < p_end and b.end_time > p_start)
     and public.zella_resource_used(r.id, p_start, p_end, p_ignore) + public.zella_resource_usage(r.capacity, p_party) <= r.capacity
    from public.resources r where r.id = p_resource $$;

-- the resources a booking of this service needs that are free, or null when a need can't be met
create or replace function public.zella_resource_pick(p_business_id uuid, p_service text, p_start timestamptz, p_end timestamptz, p_party integer, p_ignore uuid)
returns uuid[] language plpgsql stable security definer set search_path = public as $$
declare n record; v_out uuid[] := '{}'; v_got uuid[];
begin
  for n in select kind, max(quantity) as quantity from public.resource_needs
            where business_id = p_business_id and length(coalesce(p_service, '')) > 0
              and position(lower(trim(service)) in lower(p_service)) > 0
            group by kind loop
    select coalesce(array_agg(id), '{}') into v_got from (
      select r.id from public.resources r
       where r.business_id = p_business_id and r.kind = n.kind and r.is_active
         and public.zella_resource_free(r.id, p_start, p_end, p_party, p_ignore)
       order by r.sort_order, r.name limit n.quantity) x;
    if cardinality(v_got) < n.quantity then return null; end if;
    v_out := v_out || v_got;
  end loop;
  return v_out;
end $$;

-- ===================================================== the guard on appointments
create or replace function public.zella_resource_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_crew uuid[]; v_bad uuid; v_name text; v_service text; v_picked uuid[]; v_clash uuid;
begin
  -- the lists hold distinct, non-empty ids
  v_ids := (select array_agg(distinct x) from unnest(new.resource_ids) x where x is not null);
  v_crew := (select array_agg(distinct x) from unnest(new.crew_staff_ids) x where x is not null and x is distinct from new.staff_id);
  new.resource_ids := v_ids; new.crew_staff_ids := v_crew;
  -- they belong to this business (whatever the time; a moved booking keeps them)
  select x into v_bad from unnest(coalesce(v_ids, '{}')) x
   where not exists (select 1 from public.resources r where r.id = x and r.business_id = new.business_id) limit 1;
  if v_bad is not null then raise exception 'TENANT_MISMATCH: resource_ids has a resource of another business' using errcode = '23514'; end if;
  select x into v_bad from unnest(coalesce(v_crew, '{}')) x
   where not exists (select 1 from public.staff_members s where s.id = x and s.business_id = new.business_id) limit 1;
  if v_bad is not null then raise exception 'TENANT_MISMATCH: crew_staff_ids has someone who is not on this team' using errcode = '23514'; end if;

  if not public.zella_appointment_holds_time(new.status, new.booking_state, new.hold_expires_at) then return new; end if;
  if new.end_time <= now() then return new; end if;   -- history and imports of past visits never clash
  if tg_op = 'UPDATE' and new.start_time = old.start_time and new.end_time = old.end_time
     and new.resource_ids is not distinct from old.resource_ids and new.crew_staff_ids is not distinct from old.crew_staff_ids
     and new.staff_id is not distinct from old.staff_id and new.party_size is not distinct from old.party_size
     and public.zella_appointment_holds_time(old.status, old.booking_state, old.hold_expires_at) then
    return new;   -- nothing about its time, resources or people changed
  end if;
  perform public.zella_booking_lock(new.business_id);   -- the lock every booking path takes: concurrent writes queue here

  -- a service that needs resources: pick free ones when none were chosen
  v_service := trim(coalesce(new.appointment_type, '') || ' ' || coalesce(new.title, ''));
  if v_ids is null and exists (select 1 from public.resource_needs n where n.business_id = new.business_id
                                  and position(lower(trim(n.service)) in lower(v_service)) > 0) then
    v_picked := public.zella_resource_pick(new.business_id, v_service, new.start_time, new.end_time, new.party_size, new.id);
    if v_picked is null then
      raise exception 'SLOT_TAKEN' using detail = 'no free room, chair or other resource this service needs then', hint = 'Pick another time, or free a resource.';
    end if;
    new.resource_ids := nullif(v_picked, '{}');
  end if;

  -- every resource is free enough (capacity, buffer, blocks)
  select r.name into v_name from public.resources r
   where r.id = any (coalesce(new.resource_ids, '{}'))
     and not public.zella_resource_free(r.id, new.start_time, new.end_time, new.party_size, new.id)
   order by r.sort_order, r.name limit 1;
  if v_name is not null then
    raise exception 'SLOT_TAKEN' using detail = v_name || ' is booked, full or blocked then', hint = 'Pick another time or another resource.';
  end if;

  -- nobody on two overlapping jobs as lead or crew (lead against lead is the existing staff check)
  if new.crew_staff_ids is not null or new.staff_id is not null then
    select a.id into v_clash from public.appointments a
     where a.business_id = new.business_id and a.id <> new.id
       and public.zella_appointment_holds_time(a.status, a.booking_state, a.hold_expires_at)
       and a.start_time < new.end_time and a.end_time > new.start_time
       and ((new.crew_staff_ids is not null and (a.staff_id = any (new.crew_staff_ids) or a.crew_staff_ids && new.crew_staff_ids))
         or (new.staff_id is not null and new.staff_id = any (coalesce(a.crew_staff_ids, '{}'))))
     limit 1;
    if v_clash is not null then
      raise exception 'SLOT_TAKEN' using detail = 'someone on this crew is on another job then', hint = 'Pick another time or other people.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists zella_resource_guard on public.appointments;
create trigger zella_resource_guard before insert or update of start_time, end_time, status, booking_state, hold_expires_at, resource_ids, crew_staff_ids, staff_id, party_size, appointment_type, title
  on public.appointments for each row execute function public.zella_resource_guard();

-- a resource block belongs to the business of its resource
create or replace function public.zella_resource_block_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.resource_id is not null and not exists (select 1 from public.resources r where r.id = new.resource_id and r.business_id = new.business_id) then
    raise exception 'TENANT_MISMATCH: resource_id is not a resource of this business' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists zella_resource_block_guard on public.blocked_times;
create trigger zella_resource_block_guard before insert or update of resource_id, business_id on public.blocked_times
  for each row execute function public.zella_resource_block_guard();

-- ===================================================== audit
create or replace function public.zella_schedule_audit(p_business_id uuid, p_action text, p_entity text, p_id uuid, p_new jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), p_action, p_entity, p_id, p_new) $$;

-- may this person set up resources and plans? (owners, admins, managers; business not paused)
create or replace function public.zella_schedule_can_manage(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_can_manage(p_business_id)
     and exists (select 1 from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null) $$;

-- may they work jobs? (staff and above; business not paused)
create or replace function public.zella_schedule_can_work(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_can_edit(p_business_id)
     and exists (select 1 from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null) $$;

-- ===================================================== resources: save and needs
create or replace function public.zella_resource_save(p_business_id uuid, p_id uuid, p_name text, p_kind text, p_capacity integer default 1,
  p_buffer_minutes integer default 0, p_notes text default null, p_sort_order integer default 0, p_active boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.zella_schedule_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_id is null then
    insert into public.resources (business_id, name, kind, capacity, buffer_minutes, notes, sort_order, is_active)
    values (p_business_id, trim(p_name), p_kind, coalesce(p_capacity, 1), coalesce(p_buffer_minutes, 0), nullif(trim(coalesce(p_notes, '')), ''), coalesce(p_sort_order, 0), coalesce(p_active, true))
    returning id into v_id;
  else
    update public.resources set name = trim(p_name), kind = p_kind, capacity = coalesce(p_capacity, 1), buffer_minutes = coalesce(p_buffer_minutes, 0),
           notes = nullif(trim(coalesce(p_notes, '')), ''), sort_order = coalesce(p_sort_order, 0), is_active = coalesce(p_active, true), updated_at = now()
     where id = p_id and business_id = p_business_id returning id into v_id;
    if v_id is null then raise exception 'NOT_FOUND'; end if;
  end if;
  perform public.zella_schedule_audit(p_business_id, case when p_id is null then 'resource_added' else 'resource_updated' end, 'resource', v_id,
    jsonb_build_object('name', trim(p_name), 'kind', p_kind, 'capacity', p_capacity, 'active', coalesce(p_active, true)));
  return v_id;
end $$;

-- replace what each service needs: [{"service": "colour", "kind": "chair", "quantity": 1}, ...]
create or replace function public.zella_resource_needs_save(p_business_id uuid, p_needs jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.zella_schedule_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(coalesce(p_needs, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_needs, '[]'::jsonb)) > 60 then raise exception 'NOT_VALID'; end if;
  delete from public.resource_needs where business_id = p_business_id;
  insert into public.resource_needs (business_id, service, kind, quantity)
  select p_business_id, trim(e ->> 'service'), e ->> 'kind', coalesce((e ->> 'quantity')::int, 1)
    from jsonb_array_elements(coalesce(p_needs, '[]'::jsonb)) e;
  get diagnostics n = row_count;
  perform public.zella_schedule_audit(p_business_id, 'resource_needs_saved', 'resource_needs', null, jsonb_build_object('count', n));
  return n;
end $$;

-- one day of resources: each resource with its bookings and blocks
create or replace function public.zella_resource_day(p_business_id uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_from timestamptz; v_to timestamptz;
begin
  if not public.is_business_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = p_business_id;
  v_from := (p_day::timestamp) at time zone v_tz; v_to := ((p_day + 1)::timestamp) at time zone v_tz;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'kind', r.kind, 'capacity', r.capacity, 'buffer_minutes', r.buffer_minutes,
      'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'start', a.start_time, 'end', a.end_time, 'party_size', a.party_size,
                    'state', a.booking_state, 'customer', nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '')) order by a.start_time)
                  from public.appointments a left join public.customers c on c.id = a.customer_id
                 where a.business_id = p_business_id and r.id = any (a.resource_ids) and a.start_time < v_to and a.end_time > v_from
                   and public.zella_appointment_holds_time(a.status, a.booking_state, a.hold_expires_at)), '[]'::jsonb),
      'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'title', b.title, 'start', b.start_time, 'end', b.end_time) order by b.start_time)
                  from public.blocked_times b where b.resource_id = r.id and b.start_time < v_to and b.end_time > v_from), '[]'::jsonb))
    order by r.sort_order, r.name) from public.resources r where r.business_id = p_business_id and r.is_active), '[]'::jsonb);
end $$;

-- ===================================================== dispatch
-- the board: each technician's jobs for the day, the unassigned ones, and the arrival window
create or replace function public.zella_dispatch_board(p_business_id uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_from timestamptz; v_to timestamptz; v_jobs jsonb;
begin
  if not public.is_business_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = p_business_id;
  v_from := (p_day::timestamp) at time zone v_tz; v_to := ((p_day + 1)::timestamp) at time zone v_tz;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'title', a.title, 'start', a.start_time, 'end', a.end_time, 'staff_id', a.staff_id, 'crew', coalesce(to_jsonb(a.crew_staff_ids), '[]'::jsonb),
      'appointment_status', a.status, 'booking_state', a.booking_state, 'location', a.location,
      'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), 'phone', c.phone) end,
      'record', case when x.id is null then null else jsonb_build_object('id', x.id, 'title', x.title, 'type_key', x.type_key) end,
      'status', case when d.status in ('completed', 'needs_return') then d.status when a.status = 'completed' then 'completed' when a.staff_id is null then 'unassigned'
                     else coalesce(d.status, 'assigned') end,
      'en_route_at', d.en_route_at, 'on_site_at', d.on_site_at, 'finished_at', d.finished_at,
      'checklist', coalesce(d.checklist, '[]'::jsonb), 'note', d.note, 'return_of', d.return_of, 'updated_at', d.updated_at,
      'returns', (select count(*) from public.job_dispatch r where r.return_of = a.id)) order by a.start_time), '[]'::jsonb)
    into v_jobs
    from public.appointments a
    left join public.job_dispatch d on d.appointment_id = a.id
    left join public.customers c on c.id = a.customer_id
    left join public.crm_records x on x.id = a.record_id
   where a.business_id = p_business_id and a.start_time < v_to and a.end_time > v_from and a.status in ('scheduled', 'confirmed', 'completed')
     and coalesce(a.booking_state, 'confirmed') <> 'requested';
  return jsonb_build_object('day', p_day, 'timezone', v_tz, 'arrival_window_minutes', public.zella_arrival_window(p_business_id),
    'technicians', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'title', s.title, 'color', s.color,
                       'time_off', exists (select 1 from public.blocked_times b where b.staff_id = s.id and b.start_time < v_to and b.end_time > v_from))
                     order by s.sort_order, s.name) from public.staff_members s where s.business_id = p_business_id and s.is_active), '[]'::jsonb),
    'jobs', v_jobs,
    'can_work', public.zella_schedule_can_work(p_business_id));
end $$;

-- assign a job to a lead technician and crew (the guards check that nobody is double-booked)
create or replace function public.zella_dispatch_assign(p_appointment_id uuid, p_staff_id uuid, p_crew uuid[] default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.appointments;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found or not public.zella_schedule_can_work(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.status not in ('scheduled', 'confirmed') then raise exception 'NOT_OPEN'; end if;
  update public.appointments set staff_id = p_staff_id, crew_staff_ids = nullif(p_crew, '{}'), updated_at = now() where id = a.id;
  insert into public.job_dispatch (appointment_id, business_id, status, updated_by)
  values (a.id, a.business_id, 'assigned', auth.uid())
  on conflict (appointment_id) do update set updated_at = now(), updated_by = auth.uid(),
    status = case when job_dispatch.status in ('completed', 'needs_return') then job_dispatch.status else 'assigned' end;
  perform public.zella_schedule_audit(a.business_id, 'job_assigned', 'appointment', a.id, jsonb_build_object('staff_id', p_staff_id, 'crew', p_crew));
end $$;

-- move a job along: assigned -> en_route -> on_site <-> paused -> completed | needs_return. p_from is the status the
-- screen showed: if the job moved on meanwhile, nothing changes (CHANGED). Completing needs every required item done.
create or replace function public.zella_dispatch_status(p_appointment_id uuid, p_from text, p_to text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.appointments; d public.job_dispatch; v_cur text;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found or not public.zella_schedule_can_work(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.staff_id is null then raise exception 'NOT_ASSIGNED'; end if;
  select * into d from public.job_dispatch where appointment_id = a.id for update;
  v_cur := case when d.status in ('completed', 'needs_return') then d.status when a.status = 'completed' then 'completed' else coalesce(d.status, 'assigned') end;
  if v_cur is distinct from p_from then raise exception 'CHANGED'; end if;
  if not ((v_cur = 'assigned' and p_to in ('en_route', 'on_site'))
       or (v_cur = 'en_route' and p_to in ('on_site', 'assigned'))
       or (v_cur = 'on_site' and p_to in ('paused', 'completed', 'needs_return'))
       or (v_cur = 'paused' and p_to in ('on_site', 'needs_return'))) then
    raise exception 'BAD_STEP';
  end if;
  if a.status not in ('scheduled', 'confirmed') then raise exception 'NOT_OPEN'; end if;
  if p_to = 'completed' and exists (select 1 from jsonb_array_elements(coalesce(d.checklist, '[]'::jsonb)) e
                                     where coalesce((e ->> 'required')::boolean, false) and not coalesce((e ->> 'done')::boolean, false)) then
    raise exception 'CHECKLIST_INCOMPLETE';
  end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'NOTE_TOO_LONG'; end if;
  insert into public.job_dispatch (appointment_id, business_id, status, updated_by) values (a.id, a.business_id, p_to, auth.uid())
  on conflict (appointment_id) do update set status = p_to, updated_at = now(), updated_by = auth.uid(),
    note = coalesce(nullif(trim(coalesce(p_note, '')), ''), job_dispatch.note);
  update public.job_dispatch set
         en_route_at = case when p_to = 'en_route' then now() else en_route_at end,
         on_site_at = case when p_to = 'on_site' and on_site_at is null then now() else on_site_at end,
         finished_at = case when p_to in ('completed', 'needs_return') then now() else finished_at end
   where appointment_id = a.id;
  -- a finished job is a completed appointment, as when it's marked completed on the calendar
  if p_to in ('completed', 'needs_return') then
    update public.appointments set status = 'completed', updated_at = now() where id = a.id;
  end if;
  perform public.zella_schedule_audit(a.business_id, 'job_status', 'appointment', a.id, jsonb_build_object('from', v_cur, 'to', p_to));
end $$;

-- the completion checklist: [{"label": "Photos taken", "required": true, "done": false}, ...]
create or replace function public.zella_dispatch_checklist(p_appointment_id uuid, p_items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a public.appointments; v_items jsonb;
begin
  select * into a from public.appointments where id = p_appointment_id;
  if not found or not public.zella_schedule_can_work(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 40 then raise exception 'NOT_VALID'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e
              where length(trim(coalesce(e ->> 'label', ''))) not between 1 and 120) then raise exception 'NOT_VALID'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('label', trim(e ->> 'label'), 'required', coalesce((e ->> 'required')::boolean, false),
                                               'done', coalesce((e ->> 'done')::boolean, false))), '[]'::jsonb)
    into v_items from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e;
  insert into public.job_dispatch (appointment_id, business_id, status, checklist, updated_by)
  values (a.id, a.business_id, 'assigned', v_items, auth.uid())
  on conflict (appointment_id) do update set checklist = v_items, updated_at = now(), updated_by = auth.uid();
end $$;

-- book a return visit for a job (linked to it); the guards check the time like any booking
create or replace function public.zella_dispatch_return_visit(p_appointment_id uuid, p_start timestamptz, p_duration_minutes integer,
  p_staff_id uuid default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare a public.appointments; v_id uuid;
begin
  select * into a from public.appointments where id = p_appointment_id;
  if not found or not public.zella_schedule_can_work(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_start is null or p_start < now() - interval '5 minutes' then raise exception 'BAD_DATE'; end if;
  if coalesce(p_duration_minutes, 0) not between 5 and 720 then raise exception 'NOT_VALID'; end if;
  if length(coalesce(p_reason, '')) > 500 then raise exception 'NOTE_TOO_LONG'; end if;
  insert into public.appointments (business_id, customer_id, record_id, title, appointment_type, start_time, end_time, timezone, status, location,
                                   description, staff_id, resource_ids, metadata)
  values (a.business_id, a.customer_id, a.record_id, left('Return visit: ' || a.title, 200), a.appointment_type, p_start, p_start + make_interval(mins => p_duration_minutes),
          a.timezone, 'scheduled', a.location, nullif(trim(coalesce(p_reason, '')), ''), coalesce(p_staff_id, a.staff_id), a.resource_ids,
          jsonb_build_object('return_of', a.id))
  returning id into v_id;
  insert into public.job_dispatch (appointment_id, business_id, status, return_of, note, updated_by)
  values (v_id, a.business_id, 'assigned', a.id, nullif(trim(coalesce(p_reason, '')), ''), auth.uid());
  perform public.zella_schedule_audit(a.business_id, 'job_return_booked', 'appointment', v_id, jsonb_build_object('return_of', a.id, 'start', p_start));
  return v_id;
end $$;

-- ===================================================== recurring plans
create or replace function public.zella_recurring_save(p_business_id uuid, p_id uuid, p_plan jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_customer uuid := nullif(p_plan ->> 'customer_id', '')::uuid; v_record uuid := nullif(p_plan ->> 'record_id', '')::uuid;
  v_staff uuid := nullif(p_plan ->> 'staff_id', '')::uuid;
  v_res uuid[] := (select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p_plan -> 'resource_ids', '[]'::jsonb)) x);
begin
  if not public.zella_schedule_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_customer is not null and not exists (select 1 from public.customers c where c.id = v_customer and c.business_id = p_business_id) then raise exception 'NOT_VALID'; end if;
  if v_record is not null and not exists (select 1 from public.crm_records r where r.id = v_record and r.business_id = p_business_id) then raise exception 'NOT_VALID'; end if;
  if v_staff is not null and not exists (select 1 from public.staff_members s where s.id = v_staff and s.business_id = p_business_id) then raise exception 'NOT_VALID'; end if;
  if exists (select 1 from unnest(coalesce(v_res, '{}')) x where not exists (select 1 from public.resources r where r.id = x and r.business_id = p_business_id)) then raise exception 'NOT_VALID'; end if;
  if p_id is null then
    insert into public.recurring_plans (business_id, customer_id, record_id, title, service, duration_minutes, frequency, interval_count, weekday, month_day,
                                        start_at, staff_id, resource_ids, starts_on, ends_on, is_active, notes, created_by)
    values (p_business_id, v_customer, v_record, trim(p_plan ->> 'title'), nullif(trim(coalesce(p_plan ->> 'service', '')), ''),
            coalesce((p_plan ->> 'duration_minutes')::int, 60), p_plan ->> 'frequency', coalesce((p_plan ->> 'interval_count')::int, 1),
            (p_plan ->> 'weekday')::smallint, (p_plan ->> 'month_day')::smallint, (p_plan ->> 'start_at')::time, v_staff, v_res,
            (p_plan ->> 'starts_on')::date, nullif(p_plan ->> 'ends_on', '')::date, coalesce((p_plan ->> 'is_active')::boolean, true),
            nullif(trim(coalesce(p_plan ->> 'notes', '')), ''), auth.uid())
    returning id into v_id;
  else
    update public.recurring_plans set customer_id = v_customer, record_id = v_record, title = trim(p_plan ->> 'title'),
           service = nullif(trim(coalesce(p_plan ->> 'service', '')), ''), duration_minutes = coalesce((p_plan ->> 'duration_minutes')::int, 60),
           frequency = p_plan ->> 'frequency', interval_count = coalesce((p_plan ->> 'interval_count')::int, 1),
           weekday = (p_plan ->> 'weekday')::smallint, month_day = (p_plan ->> 'month_day')::smallint, start_at = (p_plan ->> 'start_at')::time,
           staff_id = v_staff, resource_ids = v_res, starts_on = (p_plan ->> 'starts_on')::date, ends_on = nullif(p_plan ->> 'ends_on', '')::date,
           is_active = coalesce((p_plan ->> 'is_active')::boolean, true), notes = nullif(trim(coalesce(p_plan ->> 'notes', '')), ''), updated_at = now()
     where id = p_id and business_id = p_business_id returning id into v_id;
    if v_id is null then raise exception 'NOT_FOUND'; end if;
  end if;
  perform public.zella_schedule_audit(p_business_id, case when p_id is null then 'recurring_plan_added' else 'recurring_plan_updated' end, 'recurring_plan', v_id,
    jsonb_build_object('frequency', p_plan ->> 'frequency', 'interval_count', p_plan ->> 'interval_count', 'active', coalesce((p_plan ->> 'is_active')::boolean, true)));
  return v_id;
end $$;

-- the dates a plan falls on between p_from and p_to
create or replace function public.zella_recurring_dates(p_plan public.recurring_plans, p_from date, p_to date) returns setof date
language sql stable set search_path = public as $$
  select d::date from generate_series(greatest(p_plan.starts_on, p_from)::timestamp, least(coalesce(p_plan.ends_on, p_to), p_to)::timestamp, interval '1 day') d
   where case p_plan.frequency
           when 'weekly' then extract(dow from d)::int = p_plan.weekday
                          and ((d::date - (p_plan.starts_on + ((p_plan.weekday - extract(dow from p_plan.starts_on)::int + 7) % 7))) / 7) % p_plan.interval_count = 0
                          and d::date >= p_plan.starts_on + ((p_plan.weekday - extract(dow from p_plan.starts_on)::int + 7) % 7)
           else extract(day from d)::int = p_plan.month_day
                and ((extract(year from d)::int * 12 + extract(month from d)::int)
                     - (extract(year from p_plan.starts_on)::int * 12 + extract(month from p_plan.starts_on)::int)) % p_plan.interval_count = 0
         end $$;

-- book a plan's visits up to p_through (at most 180 days ahead). Safe to repeat: each date is handled once. A date that
-- clashes (the person, a resource, a closure) is recorded as skipped with the reason; nothing is ever forced.
create or replace function public.zella_recurring_generate(p_business_id uuid, p_plan_id uuid default null, p_through date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.recurring_plans; v_tz text; v_today date; v_to date; v_day date; v_start timestamptz; v_appt uuid; v_booked int := 0; v_skipped int := 0; v_reason text;
begin
  if not public.zella_schedule_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = p_business_id;
  v_today := (now() at time zone v_tz)::date;
  v_to := least(coalesce(p_through, v_today + 28), v_today + 180);
  for p in select * from public.recurring_plans where business_id = p_business_id and is_active and (p_plan_id is null or id = p_plan_id) order by created_at for update loop
    for v_day in select * from public.zella_recurring_dates(p, v_today, v_to) loop
      continue when exists (select 1 from public.recurring_visits v where v.plan_id = p.id and v.occurs_on = v_day);
      v_start := (v_day + p.start_at) at time zone v_tz;
      continue when v_start <= now();
      v_appt := null; v_reason := null;
      if exists (select 1 from public.business_closures c where c.business_id = p_business_id and v_day between c.starts_on and coalesce(c.ends_on, c.starts_on)
                  and (c.opens is null or p.start_at < c.opens or p.start_at + make_interval(mins => p.duration_minutes) > coalesce(c.closes, time '23:59'))) then
        v_reason := 'The business is closed then (holiday or special hours).';
      else
        begin
          insert into public.appointments (business_id, customer_id, record_id, title, appointment_type, start_time, end_time, timezone, status, booking_state,
                                           staff_id, resource_ids, metadata)
          values (p_business_id, p.customer_id, p.record_id, p.title, p.service, v_start, v_start + make_interval(mins => p.duration_minutes), v_tz,
                  'scheduled', 'tentative', p.staff_id, p.resource_ids, jsonb_build_object('recurring_plan_id', p.id, 'planned', true))
          returning id into v_appt;
        exception when others then
          v_reason := case when sqlerrm like '%SLOT_TAKEN%' then 'That time is taken (someone, or a resource, is already booked).'
                           when sqlerrm like '%TENANT_MISMATCH%' then 'A person or resource on the plan is no longer part of this business.'
                           else 'It could not be booked: ' || left(sqlerrm, 120) end;
        end;
      end if;
      insert into public.recurring_visits (plan_id, business_id, occurs_on, appointment_id, outcome, reason)
      values (p.id, p_business_id, v_day, v_appt, case when v_appt is null then 'skipped' else 'booked' end, v_reason);
      if v_appt is null then v_skipped := v_skipped + 1; else v_booked := v_booked + 1; end if;
    end loop;
    update public.recurring_plans set generated_through = greatest(coalesce(generated_through, v_to), v_to), updated_at = now() where id = p.id;
  end loop;
  perform public.zella_schedule_audit(p_business_id, 'recurring_generated', 'recurring_plan', p_plan_id, jsonb_build_object('booked', v_booked, 'skipped', v_skipped, 'through', v_to));
  return jsonb_build_object('booked', v_booked, 'skipped', v_skipped, 'through', v_to);
end $$;

-- ===================================================== grants
revoke execute on function public.zella_resource_usage(integer, integer), public.zella_resource_used(uuid, timestamptz, timestamptz, uuid),
  public.zella_resource_free(uuid, timestamptz, timestamptz, integer, uuid), public.zella_resource_pick(uuid, text, timestamptz, timestamptz, integer, uuid),
  public.zella_resource_guard(), public.zella_resource_block_guard(), public.zella_schedule_audit(uuid, text, text, uuid, jsonb),
  public.zella_schedule_can_manage(uuid), public.zella_schedule_can_work(uuid),
  public.zella_resource_save(uuid, uuid, text, text, integer, integer, text, integer, boolean), public.zella_resource_needs_save(uuid, jsonb),
  public.zella_resource_day(uuid, date), public.zella_dispatch_board(uuid, date), public.zella_dispatch_assign(uuid, uuid, uuid[]),
  public.zella_dispatch_status(uuid, text, text, text), public.zella_dispatch_checklist(uuid, jsonb),
  public.zella_dispatch_return_visit(uuid, timestamptz, integer, uuid, text), public.zella_recurring_save(uuid, uuid, jsonb),
  public.zella_recurring_dates(public.recurring_plans, date, date), public.zella_recurring_generate(uuid, uuid, date) from public, anon;
revoke execute on function public.zella_resource_used(uuid, timestamptz, timestamptz, uuid), public.zella_resource_pick(uuid, text, timestamptz, timestamptz, integer, uuid),
  public.zella_resource_guard(), public.zella_resource_block_guard(), public.zella_schedule_audit(uuid, text, text, uuid, jsonb),
  public.zella_recurring_dates(public.recurring_plans, date, date) from authenticated;
grant execute on function public.zella_resource_usage(integer, integer), public.zella_resource_free(uuid, timestamptz, timestamptz, integer, uuid),
  public.zella_schedule_can_manage(uuid), public.zella_schedule_can_work(uuid),
  public.zella_resource_save(uuid, uuid, text, text, integer, integer, text, integer, boolean), public.zella_resource_needs_save(uuid, jsonb),
  public.zella_resource_day(uuid, date), public.zella_dispatch_board(uuid, date), public.zella_dispatch_assign(uuid, uuid, uuid[]),
  public.zella_dispatch_status(uuid, text, text, text), public.zella_dispatch_checklist(uuid, jsonb),
  public.zella_dispatch_return_visit(uuid, timestamptz, integer, uuid, text), public.zella_recurring_save(uuid, uuid, jsonb),
  public.zella_recurring_generate(uuid, uuid, date) to authenticated, service_role;
grant execute on function public.zella_resource_used(uuid, timestamptz, timestamptz, uuid), public.zella_resource_pick(uuid, text, timestamptz, timestamptz, integer, uuid),
  public.zella_schedule_audit(uuid, text, text, uuid, jsonb), public.zella_recurring_dates(public.recurring_plans, date, date) to service_role;
