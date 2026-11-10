-- =========================================================
-- Zella: CRM details (check-ins, hand-offs to a human, profile fields)
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- Only adds new, optional columns. Nothing existing is changed or removed,
-- and the existing Row Level Security policies keep applying to them.
-- =========================================================

-- Check-ins: when a person arrived for their appointment.
alter table public.appointments
  add column if not exists checked_in_at timestamptz,
  add column if not exists internal_notes text,
  add column if not exists party_size integer check (party_size is null or party_size > 0);

-- Hand-offs: calls the AI receptionist (or staff) passed to a human.
alter table public.calls
  add column if not exists needs_human boolean not null default false,
  add column if not exists escalation_reason text,
  add column if not exists escalated_at timestamptz,
  add column if not exists escalation_resolved_at timestamptz,
  add column if not exists escalation_resolved_by uuid,
  add column if not exists summary text,
  add column if not exists recording_url text;

-- People: the small details a front desk likes to have.
alter table public.customers
  add column if not exists tags text[] not null default '{}',
  add column if not exists date_of_birth date,
  add column if not exists address text,
  add column if not exists preferred_contact text,
  add column if not exists do_not_contact boolean not null default false;

-- Fast lookup of open hand-offs per business.
create index if not exists calls_open_escalations_idx
  on public.calls (business_id, escalated_at desc)
  where needs_human and escalation_resolved_at is null;

-- Team members who serve customers (stylists, dentists, technicians...).
-- Each has their own working hours and breaks. Sign-in accounts stay in
-- business_members; these are the people customers book with.
create table if not exists public.staff_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  title text,
  phone text,
  email text,
  color text not null default '#2563EB',
  is_active boolean not null default true,
  -- {"mon":{"on":true,"start":"09:00","end":"17:00","break_start":"13:00","break_end":"14:00"}, ...}
  working_hours jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists staff_members_business_idx on public.staff_members (business_id, sort_order);

alter table public.staff_members enable row level security;

drop policy if exists staff_members_member_select on public.staff_members;
create policy staff_members_member_select on public.staff_members
  for select to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = staff_members.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists staff_members_member_insert on public.staff_members;
create policy staff_members_member_insert on public.staff_members
  for insert to authenticated
  with check (exists (select 1 from public.business_members m where m.business_id = staff_members.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists staff_members_member_update on public.staff_members;
create policy staff_members_member_update on public.staff_members
  for update to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = staff_members.business_id and m.user_id = auth.uid() and m.status = 'active'))
  with check (exists (select 1 from public.business_members m where m.business_id = staff_members.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists staff_members_member_delete on public.staff_members;
create policy staff_members_member_delete on public.staff_members
  for delete to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = staff_members.business_id and m.user_id = auth.uid() and m.status = 'active'));

grant select, insert, update, delete on public.staff_members to authenticated;

-- Which team member an appointment is with.
alter table public.appointments
  add column if not exists staff_id uuid references public.staff_members(id) on delete set null;

-- Blocked time: lunch, time off, holidays, training. The calendar shows these
-- and the AI receptionist must not book into them.
create table if not exists public.blocked_times (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  title text not null default 'Blocked',
  reason text,
  start_time timestamptz not null,
  end_time timestamptz not null,
  all_day boolean not null default false,
  -- null = the whole business is blocked; otherwise only this team member
  staff_id uuid references public.staff_members(id) on delete cascade,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint blocked_times_range check (end_time > start_time)
);

alter table public.blocked_times
  add column if not exists staff_id uuid references public.staff_members(id) on delete cascade;

create index if not exists blocked_times_business_start_idx
  on public.blocked_times (business_id, start_time);

alter table public.blocked_times enable row level security;

drop policy if exists blocked_times_member_select on public.blocked_times;
create policy blocked_times_member_select on public.blocked_times
  for select to authenticated using (exists (select 1 from public.business_members m where m.business_id = blocked_times.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists blocked_times_member_insert on public.blocked_times;
create policy blocked_times_member_insert on public.blocked_times
  for insert to authenticated with check (exists (select 1 from public.business_members m where m.business_id = blocked_times.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists blocked_times_member_update on public.blocked_times;
create policy blocked_times_member_update on public.blocked_times
  for update to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = blocked_times.business_id and m.user_id = auth.uid() and m.status = 'active'))
  with check (exists (select 1 from public.business_members m where m.business_id = blocked_times.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists blocked_times_member_delete on public.blocked_times;
create policy blocked_times_member_delete on public.blocked_times
  for delete to authenticated using (exists (select 1 from public.business_members m where m.business_id = blocked_times.business_id and m.user_id = auth.uid() and m.status = 'active'));

grant select, insert, update, delete on public.blocked_times to authenticated;
