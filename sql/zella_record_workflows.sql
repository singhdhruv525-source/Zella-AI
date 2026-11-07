-- Release 3: industry workflow completion. Approvals and authorizations (estimates, additional work, change orders,
-- cost approvals, contracts and engagements, treatment plans, endorsements, refunds), milestones, deadlines and
-- renewals, inspections and checklists, exceptions (waiting on parts, the customer or a supplier, delays, weather,
-- damage, disputes, delivery problems, warranty comebacks, safety), and package or membership credits, on the
-- industry records every business already has (crm_records). Safe to run twice. Touches no existing data except
-- filling the new workflow setting on record types that have none, and changes no existing function.
-- Rollback: sql/rollback/zella_record_workflows_rollback.sql (keeps every row: tables renamed, the column kept).
--
-- Reused, not recreated: crm_records and their types, statuses and history (crm_record_events), estimates and their
-- payments (customer_charges: an approved estimate approval accepts the estimate, exactly as zella_set_charge_status
-- does), record files (evidence), authorized relationships with the "approve" permission (Release 1), staff, audit_logs.
-- Nothing here sends a message, places a call, charges a card or talks to a provider.

begin;

-- ===================================================== the workflow setting on each record type
alter table public.crm_record_types add column if not exists workflow jsonb not null default '{}'::jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'crm_record_types_workflow_object') then
    alter table public.crm_record_types add constraint crm_record_types_workflow_object check (jsonb_typeof(workflow) = 'object');
  end if;
end $$;

-- industry defaults: which workflow parts each preset record type uses
create table if not exists public.record_workflow_presets (
  preset_key text not null,
  type_key text not null,
  config jsonb not null check (jsonb_typeof(config) = 'object'),
  primary key (preset_key, type_key)
);

-- ===================================================== approvals and authorizations
create table if not exists public.record_approvals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  charge_id uuid references public.customer_charges(id) on delete set null,
  kind text not null,
  title text not null,
  amount_minor bigint,
  currency text,
  status text not null default 'requested',
  expires_on date,
  requested_by uuid,
  requested_at timestamptz not null default now(),
  approver_customer_id uuid references public.customers(id) on delete set null,
  approver_relationship_id uuid references public.customer_relationships(id) on delete set null,
  method text,
  file_id uuid references public.crm_record_files(id) on delete set null,
  decided_by uuid,
  decided_at timestamptz,
  note text,
  updated_at timestamptz not null default now(),
  constraint record_approvals_kind check (kind in ('estimate', 'additional_work', 'change_order', 'cost', 'contract', 'engagement', 'treatment_plan', 'endorsement', 'refund', 'other')),
  constraint record_approvals_status check (status in ('requested', 'approved', 'declined', 'withdrawn')),
  constraint record_approvals_title_len check (length(btrim(title)) between 2 and 120),
  constraint record_approvals_amount check (amount_minor is null or (amount_minor > 0 and amount_minor <= 100000000000)),
  constraint record_approvals_currency check ((amount_minor is null and currency is null) or (amount_minor is not null and currency ~ '^[A-Z]{3}$')),
  constraint record_approvals_method check (method is null or method in ('in_person', 'phone', 'email', 'text', 'signed_form', 'internal')),
  constraint record_approvals_note_len check (length(coalesce(note, '')) <= 500),
  constraint record_approvals_decided check ((status in ('approved', 'declined')) = (decided_at is not null and method is not null))
);
create index if not exists record_approvals_record on public.record_approvals (record_id, requested_at desc);
create index if not exists record_approvals_open on public.record_approvals (business_id, expires_on) where status = 'requested';

-- ===================================================== milestones, deadlines and renewals
create table if not exists public.record_milestones (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  kind text not null default 'milestone',
  title text not null,
  due_on date not null,
  staff_id uuid references public.staff_members(id) on delete set null,
  done_at timestamptz,
  done_by uuid,
  next_of uuid references public.record_milestones(id) on delete set null,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint record_milestones_kind check (kind in ('milestone', 'deadline', 'renewal', 'payment_due', 'delivery', 'follow_up')),
  constraint record_milestones_title_len check (length(btrim(title)) between 2 and 120),
  constraint record_milestones_note_len check (length(coalesce(note, '')) <= 500)
);
create index if not exists record_milestones_record on public.record_milestones (record_id, due_on);
create index if not exists record_milestones_open on public.record_milestones (business_id, due_on) where done_at is null;
-- a renewal is rolled forward once: a second "done, next on ..." never makes two next ones
create unique index if not exists record_milestones_one_next on public.record_milestones (next_of) where next_of is not null;

-- ===================================================== inspections and checklists
create table if not exists public.record_inspections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  appointment_id uuid references public.appointments(id) on delete set null,
  title text not null,
  items jsonb not null default '[]'::jsonb,
  outcome text not null default 'in_progress',
  staff_id uuid references public.staff_members(id) on delete set null,
  started_by uuid,
  started_at timestamptz not null default now(),
  finished_by uuid,
  finished_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint record_inspections_title_len check (length(btrim(title)) between 2 and 120),
  constraint record_inspections_items check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 60),
  constraint record_inspections_outcome check (outcome in ('in_progress', 'passed', 'failed')),
  constraint record_inspections_finished check ((outcome = 'in_progress') = (finished_at is null))
);
create index if not exists record_inspections_record on public.record_inspections (record_id, started_at desc);

-- ===================================================== exceptions
create table if not exists public.record_exceptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  kind text not null,
  detail text,
  expected_by date,
  inspection_id uuid references public.record_inspections(id) on delete set null,
  opened_by uuid,
  opened_at timestamptz not null default now(),
  resolved_by uuid,
  resolved_at timestamptz,
  resolution text,
  updated_at timestamptz not null default now(),
  constraint record_exceptions_kind check (kind in ('waiting_parts', 'waiting_customer', 'waiting_supplier', 'delayed', 'weather', 'damaged', 'disputed',
                                                    'delivery_issue', 'warranty', 'safety', 'inspection_failed', 'other')),
  constraint record_exceptions_detail_len check (length(coalesce(detail, '')) <= 300 and length(coalesce(resolution, '')) <= 300),
  constraint record_exceptions_resolved check ((resolved_at is null) = (resolved_by is null))
);
create index if not exists record_exceptions_record on public.record_exceptions (record_id, opened_at desc);
-- one open exception of each kind on a record
create unique index if not exists record_exceptions_one_open on public.record_exceptions (record_id, kind) where resolved_at is null;

-- ===================================================== package and membership credits (a ledger)
create table if not exists public.record_credits (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  kind text not null,
  units integer not null,
  appointment_id uuid references public.appointments(id) on delete set null,
  note text,
  actor uuid,
  created_at timestamptz not null default now(),
  constraint record_credits_kind check (kind in ('grant', 'use', 'refund', 'expire')),
  constraint record_credits_units check (units between 1 and 1000),
  constraint record_credits_note_len check (length(coalesce(note, '')) <= 300)
);
create index if not exists record_credits_record on public.record_credits (record_id, created_at);
-- one visit uses a package once
create unique index if not exists record_credits_one_use on public.record_credits (record_id, appointment_id) where kind = 'use' and appointment_id is not null;

-- ===================================================== access: members read through the record; writes only through the functions below
alter table public.record_workflow_presets enable row level security;
alter table public.record_approvals enable row level security;
alter table public.record_milestones enable row level security;
alter table public.record_inspections enable row level security;
alter table public.record_exceptions enable row level security;
alter table public.record_credits enable row level security;
revoke all on public.record_workflow_presets, public.record_approvals, public.record_milestones, public.record_inspections, public.record_exceptions, public.record_credits
  from public, anon, authenticated;
grant select on public.record_approvals, public.record_milestones, public.record_inspections, public.record_exceptions, public.record_credits to authenticated;
grant all on public.record_workflow_presets, public.record_approvals, public.record_milestones, public.record_inspections, public.record_exceptions, public.record_credits to service_role;
do $$ declare t text; begin
  foreach t in array array['record_approvals', 'record_milestones', 'record_inspections', 'record_exceptions', 'record_credits'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    if t = 'record_approvals' then
      -- amounts, like estimates and invoices (customer_charges), are for staff and above, not viewers
      execute format('create policy %I on public.%I for select to authenticated using (public.zella_can_edit(business_id) and exists (select 1 from public.crm_records r where r.id = record_id))', t || '_read', t);
    else
      -- whoever can see the record (a member; its type switched on) sees its workflow
      execute format('create policy %I on public.%I for select to authenticated using (exists (select 1 from public.crm_records r where r.id = record_id))', t || '_read', t);
    end if;
    if not exists (select 1 from pg_policies where tablename = t and policyname = 'zella_mfa_required') then
      execute format('create policy zella_mfa_required on public.%I as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())', t);
    end if;
  end loop;
end $$;

-- ===================================================== helpers
-- the record, locked, for a change by someone who may work on it (staff and above; business not paused)
create or replace function public.zella_workflow_record(p_record_id uuid, p_manager boolean default false) returns public.crm_records
language plpgsql security definer set search_path = public as $$
declare r public.crm_records;
begin
  select * into r from public.crm_records where id = p_record_id and archived_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists (select 1 from public.crm_record_types t where t.business_id = r.business_id and t.key = r.type_key and t.enabled) then raise exception 'NOT_FOUND'; end if;
  if not (case when p_manager then public.zella_schedule_can_manage(r.business_id) else public.zella_schedule_can_work(r.business_id) end) then raise exception 'NOT_ALLOWED'; end if;
  return r;
end $$;

-- history on the record (no amounts, no notes' content beyond a short title) and the audit log
create or replace function public.zella_workflow_log(p_business_id uuid, p_record_id uuid, p_kind text, p_detail text, p_entity text, p_entity_id uuid, p_data jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, p_record_id, p_kind, left(p_detail, 300), auth.uid());
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'workflow_' || p_kind, p_entity, p_entity_id, p_data);
$$;

-- move the record to a status its type has (when there is one and the record isn't closed); logged like any status change
create or replace function public.zella_workflow_move(r public.crm_records, p_status text, p_why text) returns boolean
language plpgsql security definer set search_path = public as $$
declare ty public.crm_record_types;
begin
  if p_status is null or r.status = p_status then return false; end if;
  select * into ty from public.crm_record_types where business_id = r.business_id and key = r.type_key;
  if r.status = any (ty.closed_statuses) or not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = p_status) then return false; end if;
  update public.crm_records set status = p_status, updated_at = now(),
    closed_at = case when p_status = any (ty.closed_statuses) then coalesce(closed_at, now()) else null end where id = r.id;
  insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (r.business_id, r.id, 'status', r.status || ' → ' || p_status || ' · ' || p_why, auth.uid());
  return true;
end $$;

-- ===================================================== approvals
create or replace function public.zella_approval_request(p_record_id uuid, p_kind text, p_title text, p_amount_minor bigint default null, p_currency text default null,
  p_expires_on date default null, p_charge_id uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.crm_records; c public.customer_charges; v uuid;
begin
  r := public.zella_workflow_record(p_record_id, p_kind = 'refund');
  if p_expires_on is not null and p_expires_on < current_date then raise exception 'BAD_DATE'; end if;
  if p_charge_id is not null then
    select * into c from public.customer_charges where id = p_charge_id;
    -- an estimate approval can point at the estimate itself; it must be this business's open estimate
    if not found or c.business_id <> r.business_id or c.kind <> 'estimate' or c.status <> 'proposed' or p_kind <> 'estimate' then raise exception 'NOT_VALID'; end if;
    if p_amount_minor is null then p_amount_minor := c.amount_minor; p_currency := c.currency; end if;
  end if;
  insert into public.record_approvals (business_id, record_id, charge_id, kind, title, amount_minor, currency, expires_on, requested_by, note)
  values (r.business_id, r.id, p_charge_id, p_kind, btrim(p_title), p_amount_minor, upper(nullif(btrim(p_currency), '')), p_expires_on, auth.uid(), nullif(btrim(p_note), ''))
  returning id into v;
  perform public.zella_workflow_log(r.business_id, r.id, 'approval', 'Approval asked for: ' || btrim(p_title), 'record_approval', v,
    jsonb_build_object('kind', p_kind, 'amount_minor', p_amount_minor, 'currency', p_currency, 'charge_id', p_charge_id));
  -- the record moves to its "waiting for approval" status when its type names one (main approvals only: asking about
  -- extra work or a change order doesn't send a job in progress back)
  if p_kind in ('estimate', 'contract', 'engagement', 'treatment_plan', 'endorsement') then
    perform public.zella_workflow_move(r, (select t.workflow ->> 'requested_status' from public.crm_record_types t where t.business_id = r.business_id and t.key = r.type_key), 'approval asked for');
  end if;
  return v;
end $$;

-- who may approve for this record: its own person, or someone with an in-force "approve" relationship to that person
-- or to the record (Release 1). Returns the relationship used (null when it is the person themselves).
create or replace function public.zella_approval_approver(r public.crm_records, p_customer_id uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if p_customer_id is null then raise exception 'NO_APPROVER'; end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.business_id = r.business_id) then raise exception 'NOT_VALID'; end if;
  if r.customer_id = p_customer_id then return null; end if;
  select cr.id into v from public.customer_relationships cr
   where cr.business_id = r.business_id and cr.related_customer_id = p_customer_id and 'approve' = any (cr.permissions)
     and public.zella_relationship_in_force(cr) and (cr.record_id = r.id or (r.customer_id is not null and cr.customer_id = r.customer_id))
   order by cr.verified_at desc limit 1;
  if v is null then raise exception 'NOT_AUTHORIZED_APPROVER'; end if;
  return v;
end $$;

create or replace function public.zella_approval_decide(p_id uuid, p_decision text, p_method text, p_approver_customer_id uuid default null,
  p_note text default null, p_file_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.record_approvals; r public.crm_records; ty public.crm_record_types; rel uuid; moved boolean := false;
begin
  select * into a from public.record_approvals where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  r := public.zella_workflow_record(a.record_id, a.kind = 'refund');
  select * into a from public.record_approvals where id = p_id for update;
  if a.status <> 'requested' then raise exception 'CHANGED'; end if;
  if p_decision not in ('approved', 'declined') then raise exception 'NOT_VALID'; end if;
  if a.expires_on is not null and a.expires_on < current_date then raise exception 'EXPIRED'; end if;
  if p_file_id is not null and not exists (select 1 from public.crm_record_files f where f.id = p_file_id and f.record_id = r.id and f.removed_at is null) then raise exception 'NOT_VALID'; end if;
  if a.kind = 'refund' then
    -- a refund is the business's own decision, taken by a manager or above; no customer approves it
    if p_method is distinct from 'internal' or p_approver_customer_id is not null then raise exception 'NOT_VALID'; end if;
  else
    if p_method is null or p_method = 'internal' then raise exception 'NOT_VALID'; end if;
    rel := public.zella_approval_approver(r, p_approver_customer_id);
  end if;
  update public.record_approvals set status = p_decision, method = p_method, approver_customer_id = p_approver_customer_id, approver_relationship_id = rel,
    file_id = p_file_id, decided_by = auth.uid(), decided_at = now(), note = coalesce(nullif(btrim(p_note), ''), note), updated_at = now() where id = a.id;
  -- the linked estimate follows the decision, exactly as when it is accepted or declined on its own
  if a.charge_id is not null then
    update public.customer_charges set status = case p_decision when 'approved' then 'accepted' else 'declined' end, updated_at = now()
     where id = a.charge_id and kind = 'estimate' and status in ('proposed', 'accepted', 'declined');
    -- the estimate was voided (or removed) meanwhile: nothing is decided
    if not found then raise exception 'CHANGED'; end if;
  end if;
  select * into ty from public.crm_record_types where business_id = r.business_id and key = r.type_key;
  -- the record moves on only for its main approval kinds (an approved extra or change order doesn't restart the job)
  if a.kind in ('estimate', 'contract', 'engagement', 'treatment_plan', 'endorsement') then
    moved := public.zella_workflow_move(r, ty.workflow ->> case p_decision when 'approved' then 'approved_status' else 'declined_status' end, 'approval ' || p_decision);
  end if;
  perform public.zella_workflow_log(r.business_id, r.id, 'approval', initcap(p_decision) || ': ' || a.title, 'record_approval', a.id,
    jsonb_build_object('decision', p_decision, 'method', p_method, 'approver_customer_id', p_approver_customer_id, 'relationship_id', rel, 'charge_id', a.charge_id));
  return jsonb_build_object('id', a.id, 'status', p_decision, 'record_moved', moved);
end $$;

create or replace function public.zella_approval_withdraw(p_id uuid, p_note text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare a public.record_approvals; r public.crm_records;
begin
  select * into a from public.record_approvals where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  r := public.zella_workflow_record(a.record_id, a.kind = 'refund');
  update public.record_approvals set status = 'withdrawn', note = coalesce(nullif(btrim(p_note), ''), note), updated_at = now() where id = p_id and status = 'requested';
  if not found then raise exception 'CHANGED'; end if;
  perform public.zella_workflow_log(r.business_id, r.id, 'approval', 'Withdrawn: ' || a.title, 'record_approval', a.id, jsonb_build_object('decision', 'withdrawn'));
  return true;
end $$;

-- the people who may approve for a record (for the picker): its person and their in-force "approve" relationships
create or replace function public.zella_approval_approvers(p_record_id uuid) returns table (customer_id uuid, name text, via text)
language plpgsql stable security definer set search_path = public as $$
declare r public.crm_records;
begin
  select * into r from public.crm_records where id = p_record_id and archived_at is null;
  if not found or not public.zella_can_edit(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  return query
    select c.id, nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''), 'self'::text from public.customers c where c.id = r.customer_id
    union all
    select c.id, nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''), cr.kind from public.customer_relationships cr join public.customers c on c.id = cr.related_customer_id
     where cr.business_id = r.business_id and 'approve' = any (cr.permissions) and public.zella_relationship_in_force(cr)
       and (cr.record_id = r.id or (r.customer_id is not null and cr.customer_id = r.customer_id));
end $$;

-- ===================================================== milestones
create or replace function public.zella_milestone_save(p_record_id uuid, p_id uuid, p_title text, p_due_on date, p_kind text default 'milestone',
  p_staff_id uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.crm_records; m public.record_milestones; v uuid;
begin
  r := public.zella_workflow_record(p_record_id);
  if p_due_on is null then raise exception 'BAD_DATE'; end if;
  if p_staff_id is not null and not exists (select 1 from public.staff_members s where s.id = p_staff_id and s.business_id = r.business_id) then raise exception 'NOT_VALID'; end if;
  if p_id is null then
    insert into public.record_milestones (business_id, record_id, kind, title, due_on, staff_id, note, created_by)
    values (r.business_id, r.id, coalesce(p_kind, 'milestone'), btrim(p_title), p_due_on, p_staff_id, nullif(btrim(p_note), ''), auth.uid()) returning id into v;
    perform public.zella_workflow_log(r.business_id, r.id, 'milestone', 'Added: ' || btrim(p_title) || ' (due ' || to_char(p_due_on, 'FMDD Mon YYYY') || ')', 'record_milestone', v, jsonb_build_object('kind', p_kind, 'due_on', p_due_on));
  else
    select * into m from public.record_milestones where id = p_id and record_id = r.id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if m.done_at is not null then raise exception 'CHANGED'; end if;
    update public.record_milestones set kind = coalesce(p_kind, kind), title = btrim(p_title), due_on = p_due_on, staff_id = p_staff_id, note = nullif(btrim(p_note), ''), updated_at = now()
     where id = p_id returning id into v;
    perform public.zella_workflow_log(r.business_id, r.id, 'milestone', 'Changed: ' || btrim(p_title) || ' (due ' || to_char(p_due_on, 'FMDD Mon YYYY') || ')', 'record_milestone', v, jsonb_build_object('due_on', p_due_on, 'was', m.due_on));
  end if;
  return v;
end $$;

-- done (or reopened). A renewal can roll forward: "done, the next one is due on ..." adds the next one, once.
create or replace function public.zella_milestone_done(p_id uuid, p_done boolean default true, p_next_due_on date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.record_milestones; r public.crm_records; v uuid;
begin
  select * into m from public.record_milestones where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  r := public.zella_workflow_record(m.record_id);
  select * into m from public.record_milestones where id = p_id for update;
  if p_done then
    if m.done_at is not null then raise exception 'CHANGED'; end if;
    if p_next_due_on is not null and p_next_due_on <= m.due_on then raise exception 'BAD_DATE'; end if;
    update public.record_milestones set done_at = now(), done_by = auth.uid(), updated_at = now() where id = p_id;
    perform public.zella_workflow_log(r.business_id, r.id, 'milestone', 'Done: ' || m.title, 'record_milestone', m.id, jsonb_build_object('done', true));
    if p_next_due_on is not null then
      insert into public.record_milestones (business_id, record_id, kind, title, due_on, staff_id, next_of, created_by)
      values (m.business_id, m.record_id, m.kind, m.title, p_next_due_on, m.staff_id, m.id, auth.uid())
      on conflict (next_of) where next_of is not null do nothing returning id into v;
      if v is not null then
        perform public.zella_workflow_log(r.business_id, r.id, 'milestone', 'Next: ' || m.title || ' (due ' || to_char(p_next_due_on, 'FMDD Mon YYYY') || ')', 'record_milestone', v, jsonb_build_object('next_of', m.id, 'due_on', p_next_due_on));
      end if;
    end if;
  else
    if m.done_at is null then raise exception 'CHANGED'; end if;
    update public.record_milestones set done_at = null, done_by = null, updated_at = now() where id = p_id;
    perform public.zella_workflow_log(r.business_id, r.id, 'milestone', 'Reopened: ' || m.title, 'record_milestone', m.id, jsonb_build_object('done', false));
  end if;
  return coalesce(v, m.id);
end $$;

-- ===================================================== inspections
-- items: [{"label": "Brakes", "result": "pass" | "fail" | "na" | null, "note": "..."}]; finishing needs every item answered.
-- A failed inspection opens an "inspection failed" exception on the record (one open at a time).
create or replace function public.zella_inspection_clean(p_items jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare out jsonb := '[]'::jsonb; i jsonb;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'NOT_VALID'; end if;
  for i in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(i) <> 'object' or length(btrim(coalesce(i ->> 'label', ''))) not between 1 and 120 or length(coalesce(i ->> 'note', '')) > 300
       or coalesce(i ->> 'result', 'x') not in ('pass', 'fail', 'na', 'x') then raise exception 'NOT_VALID'; end if;
    out := out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('label', btrim(i ->> 'label'), 'result', i ->> 'result', 'note', nullif(btrim(coalesce(i ->> 'note', '')), ''))));
  end loop;
  return out;
end $$;

create or replace function public.zella_inspection_save(p_record_id uuid, p_id uuid, p_title text, p_items jsonb, p_finish boolean default false,
  p_staff_id uuid default null, p_appointment_id uuid default null, p_expected_updated_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.crm_records; x public.record_inspections; v_items jsonb; v_failed int := 0; v_outcome text := 'in_progress'; exc uuid;
begin
  r := public.zella_workflow_record(p_record_id);
  v_items := public.zella_inspection_clean(p_items);
  if p_staff_id is not null and not exists (select 1 from public.staff_members s where s.id = p_staff_id and s.business_id = r.business_id) then raise exception 'NOT_VALID'; end if;
  if p_appointment_id is not null and not exists (select 1 from public.appointments ap where ap.id = p_appointment_id and ap.business_id = r.business_id) then raise exception 'NOT_VALID'; end if;
  if p_finish then
    if exists (select 1 from jsonb_array_elements(v_items) i where i ->> 'result' is null) then raise exception 'CHECKLIST_INCOMPLETE'; end if;
    v_failed := (select count(*) from jsonb_array_elements(v_items) i where i ->> 'result' = 'fail');
    v_outcome := case when v_failed > 0 then 'failed' else 'passed' end;
  end if;
  if p_id is null then
    insert into public.record_inspections (business_id, record_id, appointment_id, title, items, outcome, staff_id, started_by, finished_by, finished_at)
    values (r.business_id, r.id, p_appointment_id, btrim(p_title), v_items, v_outcome, p_staff_id, auth.uid(),
            case when p_finish then auth.uid() end, case when p_finish then now() end) returning * into x;
  else
    select * into x from public.record_inspections where id = p_id and record_id = r.id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    -- a finished inspection is a record of what was found; a stale screen changes nothing
    if x.outcome <> 'in_progress' or (p_expected_updated_at is not null and x.updated_at is distinct from p_expected_updated_at) then raise exception 'CHANGED'; end if;
    update public.record_inspections set title = btrim(p_title), items = v_items, outcome = v_outcome, staff_id = p_staff_id, appointment_id = p_appointment_id,
      finished_by = case when p_finish then auth.uid() end, finished_at = case when p_finish then now() end, updated_at = now()
     where id = p_id returning * into x;
  end if;
  if p_finish then
    perform public.zella_workflow_log(r.business_id, r.id, 'inspection', initcap(v_outcome) || ': ' || x.title, 'record_inspection', x.id, jsonb_build_object('outcome', v_outcome, 'failed', v_failed));
    if v_outcome = 'failed' then
      insert into public.record_exceptions (business_id, record_id, kind, detail, inspection_id, opened_by)
      values (r.business_id, r.id, 'inspection_failed', left(x.title || ': ' || (select string_agg(i ->> 'label', ', ') from jsonb_array_elements(v_items) i where i ->> 'result' = 'fail'), 300), x.id, auth.uid())
      on conflict (record_id, kind) where resolved_at is null do nothing returning id into exc;
      if exc is not null then perform public.zella_workflow_log(r.business_id, r.id, 'exception', 'Opened: inspection failed', 'record_exception', exc, jsonb_build_object('kind', 'inspection_failed')); end if;
    end if;
  end if;
  return jsonb_build_object('id', x.id, 'outcome', v_outcome, 'updated_at', x.updated_at, 'exception_id', exc);
end $$;

-- ===================================================== exceptions
create or replace function public.zella_exception_open(p_record_id uuid, p_kind text, p_detail text default null, p_expected_by date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.crm_records; v uuid;
begin
  r := public.zella_workflow_record(p_record_id);
  if p_kind = 'inspection_failed' then raise exception 'NOT_VALID'; end if;   -- opened by a failed inspection, not by hand
  insert into public.record_exceptions (business_id, record_id, kind, detail, expected_by, opened_by)
  values (r.business_id, r.id, p_kind, nullif(btrim(p_detail), ''), p_expected_by, auth.uid())
  on conflict (record_id, kind) where resolved_at is null do nothing returning id into v;
  if v is null then raise exception 'ALREADY_OPEN'; end if;
  perform public.zella_workflow_log(r.business_id, r.id, 'exception', 'Opened: ' || replace(p_kind, '_', ' '), 'record_exception', v, jsonb_build_object('kind', p_kind, 'expected_by', p_expected_by));
  return v;
end $$;

create or replace function public.zella_exception_resolve(p_id uuid, p_resolution text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare e public.record_exceptions; r public.crm_records;
begin
  select * into e from public.record_exceptions where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  r := public.zella_workflow_record(e.record_id);
  update public.record_exceptions set resolved_at = now(), resolved_by = auth.uid(), resolution = nullif(btrim(p_resolution), ''), updated_at = now()
   where id = p_id and resolved_at is null;
  if not found then raise exception 'CHANGED'; end if;
  perform public.zella_workflow_log(r.business_id, r.id, 'exception', 'Resolved: ' || replace(e.kind, '_', ' '), 'record_exception', e.id, jsonb_build_object('kind', e.kind));
  return true;
end $$;

-- ===================================================== credits
create or replace function public.zella_credit_balance(p_record_id uuid) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when kind in ('grant', 'refund') then units else -units end), 0)::int from public.record_credits where record_id = p_record_id $$;

-- grant and expire: managers and above; use and refund (of what was used): staff and above. The record row is locked, so two people using
-- the last credit at once can't both succeed. p_expected_balance (optional) refuses a change made from a stale screen.
create or replace function public.zella_credit_add(p_record_id uuid, p_kind text, p_units integer, p_appointment_id uuid default null,
  p_note text default null, p_expected_balance integer default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.crm_records; ty public.crm_record_types; bal int; v uuid; moved boolean := false;
begin
  if p_kind not in ('grant', 'use', 'refund', 'expire') then raise exception 'NOT_VALID'; end if;
  r := public.zella_workflow_record(p_record_id, p_kind in ('grant', 'expire'));
  select * into ty from public.crm_record_types where business_id = r.business_id and key = r.type_key;
  if ty.workflow -> 'credits' is null then raise exception 'NOT_VALID'; end if;
  bal := public.zella_credit_balance(r.id);
  if p_expected_balance is not null and p_expected_balance <> bal then raise exception 'CHANGED'; end if;
  if p_kind = 'use' and r.status = any (ty.closed_statuses) then raise exception 'NOT_OPEN'; end if;
  if p_kind in ('use', 'expire') and coalesce(p_units, 0) > bal then raise exception 'NO_CREDITS'; end if;
  -- giving credits back returns only what was used (adding new ones is a manager's "grant")
  if p_kind = 'refund' and coalesce(p_units, 0) > (select coalesce(sum(case kind when 'use' then units when 'refund' then -units else 0 end), 0)
                                                     from public.record_credits where record_id = r.id) then raise exception 'MORE_THAN_USED'; end if;
  if p_appointment_id is not null and not exists (select 1 from public.appointments ap where ap.id = p_appointment_id and ap.business_id = r.business_id) then raise exception 'NOT_VALID'; end if;
  begin
    insert into public.record_credits (business_id, record_id, kind, units, appointment_id, note, actor)
    values (r.business_id, r.id, p_kind, p_units, p_appointment_id, nullif(btrim(p_note), ''), auth.uid()) returning id into v;
  exception when unique_violation then raise exception 'ALREADY_USED';
  end;
  bal := public.zella_credit_balance(r.id);
  if bal = 0 and p_kind in ('use', 'expire') then moved := public.zella_workflow_move(r, ty.workflow #>> '{credits,used_up_status}', 'no credits left'); end if;
  perform public.zella_workflow_log(r.business_id, r.id, 'credit', initcap(p_kind) || ' ' || p_units || ' ' || coalesce(ty.workflow #>> '{credits,unit}', 'credits') || ' · ' || bal || ' left',
    'record_credit', v, jsonb_build_object('kind', p_kind, 'units', p_units, 'balance', bal, 'appointment_id', p_appointment_id));
  return jsonb_build_object('id', v, 'balance', bal, 'record_moved', moved);
end $$;

-- ===================================================== the record type's workflow setting
-- managers and above; only the keys this release understands are kept
create or replace function public.zella_workflow_clean(p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare out jsonb := '{}'::jsonb; k text;
begin
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'NOT_VALID'; end if;
  if p ? 'approvals' then
    if jsonb_typeof(p -> 'approvals') <> 'array' or exists (select 1 from jsonb_array_elements_text(p -> 'approvals') x
       where x not in ('estimate', 'additional_work', 'change_order', 'cost', 'contract', 'engagement', 'treatment_plan', 'endorsement', 'refund', 'other')) then raise exception 'NOT_VALID'; end if;
    out := out || jsonb_build_object('approvals', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements_text(p -> 'approvals') x));
  end if;
  foreach k in array array['requested_status', 'approved_status', 'declined_status'] loop
    if p ->> k is not null then out := out || jsonb_build_object(k, left(p ->> k, 40)); end if;
  end loop;
  if p ? 'inspection' and p -> 'inspection' <> 'null'::jsonb then
    if jsonb_typeof(p -> 'inspection') <> 'object' or length(btrim(coalesce(p #>> '{inspection,title}', ''))) not between 2 and 120
       or jsonb_typeof(p #> '{inspection,items}') <> 'array' or jsonb_array_length(p #> '{inspection,items}') not between 1 and 60
       or exists (select 1 from jsonb_array_elements(p #> '{inspection,items}') i where jsonb_typeof(i) <> 'string' or length(btrim(i #>> '{}')) not between 1 and 120) then raise exception 'NOT_VALID'; end if;
    out := out || jsonb_build_object('inspection', jsonb_build_object('title', btrim(p #>> '{inspection,title}'),
      'items', (select jsonb_agg(btrim(i #>> '{}')) from jsonb_array_elements(p #> '{inspection,items}') i)));
  end if;
  if p ? 'credits' and p -> 'credits' <> 'null'::jsonb then
    if jsonb_typeof(p -> 'credits') <> 'object' or length(btrim(coalesce(p #>> '{credits,unit}', ''))) not between 2 and 30 then raise exception 'NOT_VALID'; end if;
    out := out || jsonb_build_object('credits', jsonb_strip_nulls(jsonb_build_object('unit', btrim(p #>> '{credits,unit}'), 'used_up_status', left(p #>> '{credits,used_up_status}', 40))));
  end if;
  return out;
end $$;

create or replace function public.zella_record_workflow_save(p_business_id uuid, p_type_key text, p_workflow jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ty public.crm_record_types; w jsonb; k text;
begin
  if not public.zella_schedule_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into ty from public.crm_record_types where business_id = p_business_id and key = p_type_key for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  w := public.zella_workflow_clean(p_workflow);
  -- the statuses it names must be the type's own
  foreach k in array array['requested_status', 'approved_status', 'declined_status'] loop
    if w ->> k is not null and not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = w ->> k) then raise exception 'NOT_VALID'; end if;
  end loop;
  if w #>> '{credits,used_up_status}' is not null and not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = w #>> '{credits,used_up_status}') then raise exception 'NOT_VALID'; end if;
  -- an empty object is the "use the industry default" marker, so a business that turns everything off keeps an explicit choice
  if w = '{}'::jsonb then w := '{"custom": true}'::jsonb; else w := w || '{"custom": true}'::jsonb; end if;
  update public.crm_record_types set workflow = w, updated_at = now() where id = ty.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'record_workflow_saved', 'crm_record_type', ty.id, jsonb_build_object('workflow', ty.workflow), jsonb_build_object('workflow', w));
  return w;
end $$;

-- new record types get their industry's default workflow; a type that already has one (the business's choice) is never touched
create or replace function public.zella_record_workflow_defaults_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.workflow is null or new.workflow = '{}'::jsonb) and new.preset_key is not null then
    new.workflow := coalesce((select p.config from public.record_workflow_presets p where p.preset_key = new.preset_key and p.type_key = new.key), '{}'::jsonb);
  end if;
  return new;
end $$;
drop trigger if exists zella_record_workflow_defaults on public.crm_record_types;
create trigger zella_record_workflow_defaults before insert on public.crm_record_types for each row execute function public.zella_record_workflow_defaults_trg();

-- ===================================================== what needs following through (one business, for the page)
create or replace function public.zella_workflow_due(p_business_id uuid, p_days integer default 14) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d int := least(greatest(coalesce(p_days, 14), 1), 90); can_money boolean;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  can_money := public.zella_can_edit(p_business_id);
  return jsonb_build_object(
    'approvals', case when can_money then coalesce((select jsonb_agg(x order by x ->> 'expires_on' nulls last, x ->> 'requested_at') from (
        select jsonb_build_object('id', a.id, 'record_id', r.id, 'record', r.title, 'type_key', r.type_key, 'kind', a.kind, 'title', a.title, 'amount_minor', a.amount_minor,
          'currency', a.currency, 'expires_on', a.expires_on, 'expired', a.expires_on < current_date, 'requested_at', a.requested_at) x
          from public.record_approvals a join public.crm_records r on r.id = a.record_id
          join public.crm_record_types t on t.business_id = r.business_id and t.key = r.type_key and t.enabled
         where a.business_id = p_business_id and a.status = 'requested' and r.archived_at is null limit 200) q), '[]'::jsonb) else null end,
    'milestones', coalesce((select jsonb_agg(x order by x ->> 'due_on') from (
        select jsonb_build_object('id', m.id, 'record_id', r.id, 'record', r.title, 'type_key', r.type_key, 'kind', m.kind, 'title', m.title, 'due_on', m.due_on,
          'overdue', m.due_on < current_date, 'staff', s.name) x
          from public.record_milestones m join public.crm_records r on r.id = m.record_id
          join public.crm_record_types t on t.business_id = r.business_id and t.key = r.type_key and t.enabled
          left join public.staff_members s on s.id = m.staff_id
         where m.business_id = p_business_id and m.done_at is null and m.due_on <= current_date + d and r.archived_at is null limit 200) q), '[]'::jsonb),
    'exceptions', coalesce((select jsonb_agg(x order by x ->> 'opened_at') from (
        select jsonb_build_object('id', e.id, 'record_id', r.id, 'record', r.title, 'type_key', r.type_key, 'kind', e.kind, 'detail', e.detail, 'expected_by', e.expected_by,
          'late', e.expected_by < current_date, 'opened_at', e.opened_at) x
          from public.record_exceptions e join public.crm_records r on r.id = e.record_id
          join public.crm_record_types t on t.business_id = r.business_id and t.key = r.type_key and t.enabled
         where e.business_id = p_business_id and e.resolved_at is null and r.archived_at is null limit 200) q), '[]'::jsonb),
    'days', d, 'can_work', public.zella_schedule_can_work(p_business_id));
end $$;

-- ===================================================== industry defaults (record types from industry_crm_presets)
insert into public.record_workflow_presets (preset_key, type_key, config) values
 ('automotive', 'repair_orders', '{"approvals": ["estimate", "additional_work"], "requested_status": "estimate_sent", "approved_status": "approved", "inspection": {"title": "Vehicle inspection", "items": ["Brakes", "Tyres", "Lights", "Fluids", "Battery", "Wipers"]}}'),
 ('automotive', 'vehicles', '{}'),
 ('automotive', 'loaners', '{"inspection": {"title": "Loaner check-out", "items": ["Fuel level noted", "Mileage noted", "Damage check", "Licence checked"]}}'),
 ('beauty_salon', 'memberships', '{"approvals": ["contract"], "credits": {"unit": "visits"}}'),
 ('childcare', 'enrolments', '{"approvals": ["contract"], "approved_status": "enrolled"}'),
 ('childcare', 'incidents', '{}'),
 ('cleaning', 'visits', '{"inspection": {"title": "Quality check", "items": ["Kitchen", "Bathrooms", "Floors", "Bins emptied", "Before and after photos"]}}'),
 ('cleaning', 'plans', '{"approvals": ["contract", "change_order"]}'),
 ('dental', 'treatment_plans', '{"approvals": ["treatment_plan", "estimate"], "requested_status": "presented", "approved_status": "accepted", "declined_status": "declined"}'),
 ('dental', 'coverage', '{}'),
 ('ecommerce', 'orders', '{}'),
 ('ecommerce', 'returns', '{"approvals": ["refund"]}'),
 ('ecommerce', 'cases', '{"approvals": ["refund"]}'),
 ('education', 'applications', '{"approvals": ["contract"], "approved_status": "enrolled"}'),
 ('education', 'courses', '{}'),
 ('electrical', 'jobs', '{"approvals": ["estimate", "change_order"], "requested_status": "estimate", "approved_status": "approved", "inspection": {"title": "Safety test", "items": ["Circuits tested", "RCD test", "Earthing", "Polarity", "Certificate issued"]}}'),
 ('electrical', 'permits', '{}'),
 ('electrical', 'plans', '{"approvals": ["contract"]}'),
 ('financial_services', 'opportunities', '{"approvals": ["engagement"]}'),
 ('financial_services', 'requests', '{}'),
 ('financial_services', 'reviews', '{}'),
 ('fitness', 'memberships', '{"approvals": ["contract"], "credits": {"unit": "classes"}}'),
 ('fitness', 'freeze_requests', '{}'),
 ('healthcare', 'prior_auths', '{}'),
 ('healthcare', 'referrals', '{}'),
 ('healthcare', 'coverage', '{}'),
 ('home_services', 'jobs', '{"approvals": ["estimate", "change_order"], "requested_status": "estimate", "approved_status": "scheduled", "inspection": {"title": "Completion checklist", "items": ["Work complete", "Area cleaned", "Customer walkthrough", "Photos taken"]}}'),
 ('home_services', 'plans', '{"approvals": ["contract"], "credits": {"unit": "visits"}}'),
 ('hospitality', 'groups', '{"approvals": ["estimate", "contract"], "requested_status": "quoted", "approved_status": "confirmed"}'),
 ('hospitality', 'guest_requests', '{}'),
 ('hvac', 'jobs', '{"approvals": ["estimate", "additional_work"], "inspection": {"title": "Service checklist", "items": ["Filters", "Refrigerant level", "Electrical connections", "Thermostat", "Condensate drain", "Airflow"]}}'),
 ('hvac', 'equipment', '{}'),
 ('hvac', 'agreements', '{"approvals": ["contract"], "credits": {"unit": "visits"}}'),
 ('insurance', 'policies', '{"approvals": ["endorsement"]}'),
 ('insurance', 'claims', '{}'),
 ('insurance', 'quotes', '{"approvals": ["estimate"], "requested_status": "quoted", "approved_status": "accepted", "declined_status": "declined"}'),
 ('landscaping', 'jobs', '{"approvals": ["estimate", "change_order"], "requested_status": "quoted", "approved_status": "approved", "inspection": {"title": "Job completion", "items": ["Mowing", "Edging", "Cleanup", "Photos taken"]}}'),
 ('landscaping', 'plans', '{"approvals": ["contract"], "credits": {"unit": "visits"}}'),
 ('legal', 'matters', '{"approvals": ["engagement"], "approved_status": "accepted"}'),
 ('legal', 'deadlines', '{}'),
 ('other', 'records', '{"approvals": ["estimate", "other"]}'),
 ('pest_control', 'jobs', '{"approvals": ["estimate", "treatment_plan"], "requested_status": "quoted", "approved_status": "approved", "inspection": {"title": "Site inspection", "items": ["Entry points", "Activity found", "Treatment areas", "Safety notice given", "Pets and children kept away"]}}'),
 ('pest_control', 'plans', '{"approvals": ["contract"], "credits": {"unit": "treatments"}}'),
 ('pet_care', 'boarding', '{"approvals": ["contract"], "inspection": {"title": "Check-in", "items": ["Vaccinations checked", "Feeding notes", "Medication", "Authorized pickup confirmed"]}}'),
 ('pet_care', 'pets', '{}'),
 ('photography_events', 'bookings', '{"approvals": ["estimate", "contract"], "requested_status": "quoted", "approved_status": "booked"}'),
 ('photography_events', 'galleries', '{}'),
 ('plumbing', 'jobs', '{"approvals": ["estimate", "additional_work"], "requested_status": "quote_sent", "approved_status": "approved", "inspection": {"title": "Completion check", "items": ["Leak test", "Pressure test", "Area cleaned", "Warranty explained"]}}'),
 ('plumbing', 'plans', '{"approvals": ["contract"], "credits": {"unit": "visits"}}'),
 ('professional_services', 'opportunities', '{"approvals": ["estimate", "contract"], "requested_status": "proposal", "approved_status": "contract"}'),
 ('professional_services', 'projects', '{"approvals": ["change_order"], "credits": {"unit": "hours"}}'),
 ('property_management', 'requests', '{"approvals": ["cost"]}'),
 ('property_management', 'leases', '{"approvals": ["contract"]}'),
 ('property_management', 'units', '{"inspection": {"title": "Unit inspection", "items": ["Walls and floors", "Kitchen", "Bathroom", "Smoke alarms", "Keys returned"]}}'),
 ('property_management', 'vendors', '{}'),
 ('real_estate', 'deals', '{"approvals": ["contract"]}'),
 ('real_estate', 'properties', '{}'),
 ('restaurant', 'events', '{"approvals": ["estimate", "contract"], "requested_status": "quoted", "approved_status": "confirmed", "declined_status": "declined"}'),
 ('restaurant', 'catering', '{"approvals": ["estimate"], "approved_status": "confirmed"}'),
 ('spa_wellness', 'packages', '{"credits": {"unit": "sessions", "used_up_status": "used_up"}}'),
 ('spa_wellness', 'memberships', '{"approvals": ["contract"], "credits": {"unit": "sessions"}}'),
 ('spa_wellness', 'intake', '{}'),
 ('travel', 'trips', '{"approvals": ["estimate", "change_order"], "requested_status": "quoted", "approved_status": "booked"}'),
 ('travel', 'bookings', '{}'),
 ('travel', 'documents', '{}')
on conflict (preset_key, type_key) do update set config = excluded.config;

-- existing record types with no workflow yet get their industry's default (never a business's own choice)
update public.crm_record_types t set workflow = p.config, updated_at = now()
  from public.record_workflow_presets p
 where t.workflow = '{}'::jsonb and p.preset_key = t.preset_key and p.type_key = t.key and p.config <> '{}'::jsonb;

-- ===================================================== grants
revoke all on function public.zella_workflow_record(uuid, boolean), public.zella_workflow_log(uuid, uuid, text, text, text, uuid, jsonb),
  public.zella_workflow_move(public.crm_records, text, text), public.zella_approval_approver(public.crm_records, uuid), public.zella_inspection_clean(jsonb),
  public.zella_workflow_clean(jsonb), public.zella_record_workflow_defaults_trg(), public.zella_credit_balance(uuid),
  public.zella_approval_request(uuid, text, text, bigint, text, date, uuid, text), public.zella_approval_decide(uuid, text, text, uuid, text, uuid),
  public.zella_approval_withdraw(uuid, text), public.zella_approval_approvers(uuid), public.zella_milestone_save(uuid, uuid, text, date, text, uuid, text),
  public.zella_milestone_done(uuid, boolean, date), public.zella_inspection_save(uuid, uuid, text, jsonb, boolean, uuid, uuid, timestamptz),
  public.zella_exception_open(uuid, text, text, date), public.zella_exception_resolve(uuid, text), public.zella_credit_add(uuid, text, integer, uuid, text, integer),
  public.zella_record_workflow_save(uuid, text, jsonb), public.zella_workflow_due(uuid, integer) from public, anon, authenticated;
grant execute on function public.zella_approval_request(uuid, text, text, bigint, text, date, uuid, text), public.zella_approval_decide(uuid, text, text, uuid, text, uuid),
  public.zella_approval_withdraw(uuid, text), public.zella_approval_approvers(uuid), public.zella_milestone_save(uuid, uuid, text, date, text, uuid, text),
  public.zella_milestone_done(uuid, boolean, date), public.zella_inspection_save(uuid, uuid, text, jsonb, boolean, uuid, uuid, timestamptz),
  public.zella_exception_open(uuid, text, text, date), public.zella_exception_resolve(uuid, text), public.zella_credit_add(uuid, text, integer, uuid, text, integer),
  public.zella_record_workflow_save(uuid, text, jsonb), public.zella_workflow_due(uuid, integer) to authenticated, service_role;
grant execute on function public.zella_workflow_record(uuid, boolean), public.zella_workflow_log(uuid, uuid, text, text, text, uuid, jsonb),
  public.zella_workflow_move(public.crm_records, text, text), public.zella_approval_approver(public.crm_records, uuid), public.zella_inspection_clean(jsonb),
  public.zella_workflow_clean(jsonb), public.zella_credit_balance(uuid) to service_role;
commit;
