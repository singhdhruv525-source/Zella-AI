-- Zella Voice: the owner onboarding journey (docs/ADMIN_AUDIT_2026-11-16.md, add on task; contract in
-- docs/OWNER_ONBOARDING_CONTRACT.md).
--
-- Purpose. Once a business is created and its owner invited, the owner goes through seven steps: welcome, password and
-- two step sign in, check your details, verify your identity, your plan, pay or start a trial, you're all set. This
-- file stores the progress per business and holds every rule of the journey in the database (NN-6):
--   1. Tables (row security on; only the business's owner and admins read them; nobody writes them directly):
--      owner_onboarding (one row per business: current step, pause, identity attempts, accepted plan),
--      owner_onboarding_steps (when each step was reached and completed), owner_onboarding_sections (the owner's
--      answer per detail section, with a fingerprint of what they saw), identity_verification_events (provider events,
--      server only, each processed once).
--   2. zella_onboarding_rules(): the owner's four open decisions, taken at the recommended defaults, as one constant.
--   3. Owner functions (signed in, active owner of THAT business; aal2 from step 3 on): zella_owner_onboarding_list,
--      _get, _complete_step, _section, _plan_accept, _identity_status, _payment_status, _finish_later, _resume, and
--      zella_owner_identity_upload_check (used by the owner-onboarding edge function). Every write is idempotent and
--      audited with before and after (DB-13).
--   4. Admin functions (platform permission through zella_admin_can): zella_admin_onboarding_overview, _progress
--      (businesses.view) and _change_done (businesses.manage, audited).
--   5. Server only: zella_owner_identity_document_add (the owner's new document, from the edge function) and
--      zella_identity_provider_event (the provider webhook; off while identity_provider is 'none').
--   6. A trigger on business_verification_documents counts a rejected required document as a failed identity check
--      while the owner is on step 4 (retry, then manual review).
--   7. The go live gate (REQ-LC-14): zella_activation_report gains two checks, "Owner identity verified" and "First
--      payment confirmed"; zella_request_activation re-checks both itself before switching the business live. Both
--      functions are archived first and must match production's fingerprint (16 Nov 2026), otherwise VERSION_MISMATCH.
--      Nothing is loosened: every earlier check stays.
-- Depends on: zella_billing_allowances.sql (business_plans), zella_onboarding.sql (business_verification_documents),
--   zella_model_defaults.sql (zella_function_archive), platform alerts and zella_admin_can (applied).
-- Who can do what after it: owners read and act on their own business's journey only; other team members can't read
--   it; Zella Voice admins read it with businesses.view and mark changes done with businesses.manage; only the server
--   key records documents and provider events; nobody can write the tables directly.
-- Verify: tests/owner_onboarding/run.sh on an isolated copy. Rollback: sql/rollback/zella_owner_onboarding_rollback.sql
--   (restores both activation functions exactly; keeps any onboarding rows in an archive table, never deletes them).
begin;

do $$
declare
  s text; d text;
  known constant jsonb := jsonb_build_object(
    'public.zella_activation_report(uuid)',   jsonb_build_array('65d1ba6e6671bbfe2fc1b2ea304475d8', '20d3c8c4b5ddebd1d89db877e22a8a74'),
    'public.zella_request_activation(uuid)',  jsonb_build_array('0db1467ab6c0c6cba7bc300bbb5946f5', '41ab61c937ec1fd0b05b7fbd91b8353f'));
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.business_plans') is null
     or to_regclass('public.business_verification_documents') is null or to_regclass('public.payments') is null
     or to_regclass('public.platform_alerts') is null or to_regprocedure('public.zella_admin_can(text)') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regclass('public.owner_onboarding') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'owner_onboarding' and column_name = 'identity_reference') then
    raise exception 'VERSION_MISMATCH: a different owner_onboarding table already exists';
  end if;
  for s in select jsonb_object_keys(known) loop
    if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then          -- production's version: archive it for the rollback
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_owner_onboarding', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then      -- nor this file's version (already applied)
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists public.owner_onboarding (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  current_step text not null default 'welcome'
    check (current_step in ('welcome', 'security', 'details', 'identity', 'plan', 'payment', 'done')),
  started_by uuid references auth.users (id) on delete set null,
  started_at timestamptz not null default now(),
  paused_at timestamptz,
  resumed_at timestamptz,
  completed_at timestamptz,
  identity_attempts integer not null default 0 check (identity_attempts between 0 and 1000),
  -- what an identity provider is given to send back (never the business id); binds its events to this business
  identity_reference text not null unique default replace(gen_random_uuid()::text, '-', '') check (identity_reference ~ '^[0-9a-f]{32}$'),
  identity_provider_status text check (identity_provider_status in ('approved', 'declined', 'needs_review')),
  identity_provider_at timestamptz,
  plan_accepted_version integer,
  plan_accepted_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint owner_onboarding_plan_fk foreign key (business_id, plan_accepted_version)
    references public.business_plans (business_id, version),
  constraint owner_onboarding_plan_pair check ((plan_accepted_version is null) = (plan_accepted_at is null))
);

create table if not exists public.owner_onboarding_steps (
  business_id uuid not null references public.owner_onboarding (business_id) on delete cascade,
  step text not null check (step in ('welcome', 'security', 'details', 'identity', 'plan', 'payment', 'done')),
  reached_at timestamptz not null default now(),
  completed_at timestamptz,
  completed_by uuid references auth.users (id) on delete set null,
  primary key (business_id, step)
);
create index if not exists owner_onboarding_started_by_idx on public.owner_onboarding (started_by);
create index if not exists owner_onboarding_steps_completed_by_idx on public.owner_onboarding_steps (completed_by);

create table if not exists public.owner_onboarding_sections (
  business_id uuid not null references public.owner_onboarding (business_id) on delete cascade,
  section text not null check (section in ('business', 'hours_services', 'team', 'receptionist_phone')),
  status text not null check (status in ('looks_right', 'change_requested', 'updated')),
  note text check (note is null or length(note) between 1 and 1000),
  admin_note text check (admin_note is null or length(admin_note) between 1 and 500),
  confirmed_hash text check (confirmed_hash is null or confirmed_hash ~ '^[0-9a-f]{32}$'),
  answered_by uuid references auth.users (id) on delete set null,
  answered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (business_id, section),
  check ((status = 'change_requested') = (note is not null)),
  check (status <> 'looks_right' or confirmed_hash is not null)
);
create index if not exists owner_onboarding_sections_answered_by_idx on public.owner_onboarding_sections (answered_by);

-- Provider events: mixed scope (TEN-10). An event whose reference matches no business is kept as unmapped (TEN-12).
create table if not exists public.identity_verification_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  event_id text not null check (length(event_id) between 1 and 200),
  scope text not null check (scope in ('business', 'unmapped')),
  business_id uuid references public.businesses (id) on delete cascade,
  outcome text not null check (outcome in ('approved', 'declined', 'needs_review', 'pending', 'other')),
  subject text check (subject is null or length(subject) between 1 and 200),   -- the provider's check (a Persona inquiry)
  occurred_at timestamptz,
  result text not null check (result in ('applied', 'ignored', 'unmapped')),
  received_at timestamptz not null default now(),
  unique (provider, event_id),
  check ((scope = 'business') = (business_id is not null))
);
create index if not exists identity_verification_events_business_idx on public.identity_verification_events (business_id, received_at desc);

alter table public.owner_onboarding enable row level security;
alter table public.owner_onboarding_steps enable row level security;
alter table public.owner_onboarding_sections enable row level security;
alter table public.identity_verification_events enable row level security;
revoke all on table public.owner_onboarding, public.owner_onboarding_steps, public.owner_onboarding_sections,
  public.identity_verification_events from public, anon, authenticated;
grant all on table public.owner_onboarding, public.owner_onboarding_steps, public.owner_onboarding_sections,
  public.identity_verification_events to service_role;
-- signed in people read only; the identity reference stays server side
grant select (business_id, current_step, started_at, paused_at, resumed_at, completed_at, identity_attempts,
  identity_provider_status, identity_provider_at, plan_accepted_version, plan_accepted_at, updated_at)
  on public.owner_onboarding to authenticated;
grant select on public.owner_onboarding_steps, public.owner_onboarding_sections to authenticated;

-- read: that business's active owner, or a Zella Voice admin allowed to view businesses; nobody else (team members of
-- every other role included)
drop policy if exists owner_onboarding_read on public.owner_onboarding;
create policy owner_onboarding_read on public.owner_onboarding for select to authenticated
  using (public.zella_has_role(business_id, array['owner']) or public.zella_admin_can('businesses.view'));
drop policy if exists owner_onboarding_steps_read on public.owner_onboarding_steps;
create policy owner_onboarding_steps_read on public.owner_onboarding_steps for select to authenticated
  using (public.zella_has_role(business_id, array['owner']) or public.zella_admin_can('businesses.view'));
drop policy if exists owner_onboarding_sections_read on public.owner_onboarding_sections;
create policy owner_onboarding_sections_read on public.owner_onboarding_sections for select to authenticated
  using (public.zella_has_role(business_id, array['owner']) or public.zella_admin_can('businesses.view'));
-- the same restrictive two step sign in policy every table carries
drop policy if exists zella_mfa_required on public.owner_onboarding;
create policy zella_mfa_required on public.owner_onboarding as restrictive to authenticated
  using ((select public.zella_mfa_satisfied())) with check ((select public.zella_mfa_satisfied()));
drop policy if exists zella_mfa_required on public.owner_onboarding_steps;
create policy zella_mfa_required on public.owner_onboarding_steps as restrictive to authenticated
  using ((select public.zella_mfa_satisfied())) with check ((select public.zella_mfa_satisfied()));
drop policy if exists zella_mfa_required on public.owner_onboarding_sections;
create policy zella_mfa_required on public.owner_onboarding_sections as restrictive to authenticated
  using ((select public.zella_mfa_satisfied())) with check ((select public.zella_mfa_satisfied()));
drop policy if exists zella_mfa_required on public.identity_verification_events;
create policy zella_mfa_required on public.identity_verification_events as restrictive to authenticated
  using ((select public.zella_mfa_satisfied())) with check ((select public.zella_mfa_satisfied()));

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The rules (the owner's open decisions, at the recommended defaults). Change a value here, in a new migration.
--    Stable, not immutable, so a changed value is never folded into a plan cached before the change.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_onboarding_rules() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'identity_provider', 'none',              -- manual upload, checked in Verification; later 'persona'
    'plan_choice', 'accept_only',             -- the owner accepts the plan Zella Voice set
    'first_payment', 'pay_before_live',       -- or 'trial_with_card' (not built)
    'failed_check', 'retry_then_review',      -- or 'stop_and_contact_support' (set identity_attempts to 1)
    'identity_attempts', 2,                   -- failed checks on step 4 before manual review
    'payments_connected', false);             -- Stripe Checkout is not built
$$;

create or replace function public.zella_onboarding_step_keys() returns text[]
language sql immutable set search_path = '' as $$
  select array['welcome', 'security', 'details', 'identity', 'plan', 'payment', 'done'];
$$;

create or replace function public.zella_onboarding_section_keys() returns text[]
language sql immutable set search_path = '' as $$
  select array['business', 'hours_services', 'team', 'receptionist_phone'];
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Internal helpers (server side only; called by the functions below)
-- ---------------------------------------------------------------------------------------------------------------

-- Refuses anyone but a signed in, active owner of this business. Unknown businesses get the same answer (no oracle).
create or replace function public.zella_onboarding_authorize(p_business_id uuid, p_write boolean, p_need_aal2 boolean)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if p_business_id is null or not exists (
       select 1 from public.business_members m
        where m.business_id = p_business_id and m.user_id = auth.uid() and m.role = 'owner' and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  if not public.zella_mfa_satisfied() then raise exception 'MFA_REQUIRED'; end if;
  if p_need_aal2 and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then raise exception 'MFA_REQUIRED'; end if;
  if p_write and exists (select 1 from public.businesses b where b.id = p_business_id and (b.suspended_at is not null or b.cancelled_at is not null)) then
    raise exception 'BUSINESS_NOT_AVAILABLE';
  end if;
end $$;

create or replace function public.zella_onboarding_audit(p_business_id uuid, p_user uuid, p_action text, p_old jsonb, p_new jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_user, p_action, 'owner_onboarding', p_business_id, p_old, p_new);
$$;

-- The receptionist settings the details screens show: the default receptionist's config, if any.
create or replace function public.zella_onboarding_config(p_business_id uuid)
returns table (agent_name text, knowledge_base jsonb, escalation_rules jsonb, appointment_rules jsonb, voice_config jsonb)
language sql stable security definer set search_path = public as $$
  select ag.name, coalesce(cfg.knowledge_base, '{}'), coalesce(cfg.escalation_rules, '{}'), coalesce(cfg.appointment_rules, '{}'), coalesce(cfg.voice_config, '{}')
    from public.ai_agents ag left join public.ai_agent_configs cfg on cfg.agent_id = ag.id
   where ag.business_id = p_business_id
   order by ag.is_default desc nulls last, ag.created_at
   limit 1;
$$;

-- What the owner checks in one section: a snapshot of saved data, never secrets or internal ids.
create or replace function public.zella_onboarding_section_data(p_business_id uuid, p_section text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b record; c record; v jsonb;
  txt constant text := '^(true|false)$';
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then return null; end if;
  select * into c from public.zella_onboarding_config(p_business_id);
  if p_section = 'business' then
    return jsonb_build_object('name', b.name, 'legal_name', b.legal_name,
      'industry', (select i.name from public.industries i where i.id = b.industry_id),
      'phone', b.phone, 'email', b.email, 'website', b.website,
      'address', jsonb_build_object('line_1', b.address_line_1, 'line_2', b.address_line_2, 'city', b.city,
                                    'state', b.state, 'postal_code', b.postal_code, 'country', b.country),
      'timezone', b.timezone, 'description', b.description);
  elsif p_section = 'hours_services' then
    v := case when jsonb_typeof(c.knowledge_base -> 'services') = 'array' then c.knowledge_base -> 'services' else '[]'::jsonb end;
    return jsonb_build_object(
      'hours', coalesce((select jsonb_agg(jsonb_build_object('weekday', h.weekday, 'opens', to_char(h.opens, 'HH24:MI'), 'closes', to_char(h.closes, 'HH24:MI')) order by h.weekday, h.opens)
                           from public.business_hours h where h.business_id = p_business_id), '[]'::jsonb),
      'services', coalesce((select jsonb_agg(jsonb_build_object('name', s ->> 'name', 'duration', nullif(s ->> 'duration', ''), 'price', nullif(s ->> 'price', '')) order by n)
                              from jsonb_array_elements(v) with ordinality x(s, n) where jsonb_typeof(s) = 'object' and coalesce(s ->> 'name', '') <> ''), '[]'::jsonb),
      'takes_bookings', case when coalesce(c.appointment_rules ->> 'takes_bookings', '') ~ txt then (c.appointment_rules ->> 'takes_bookings')::boolean
                             when coalesce(b.setup_data #>> '{operations,appointments}', '') ~ txt then (b.setup_data #>> '{operations,appointments}')::boolean end);
  elsif p_section = 'team' then
    return jsonb_build_object('members', coalesce((select jsonb_agg(jsonb_build_object('name', s.name, 'title', s.title, 'email', s.email, 'phone', s.phone) order by s.sort_order, s.name)
                                                     from public.staff_members s where s.business_id = p_business_id and s.is_active), '[]'::jsonb));
  elsif p_section = 'receptionist_phone' then
    return jsonb_build_object('name', c.agent_name,
      'greeting', nullif(c.voice_config ->> 'greeting', ''), 'language', nullif(c.voice_config ->> 'language', ''),
      'voice_id', (select v2.voice_id from public.business_voice v2 where v2.business_id = p_business_id),
      'transfer_to', jsonb_build_object('type', c.escalation_rules #>> '{transfer_to,type}', 'name', c.escalation_rules #>> '{transfer_to,name}',
                                        'phone', c.escalation_rules #>> '{transfer_to,phone}'),
      'fallback_number', nullif(c.escalation_rules ->> 'fallback_number', ''),
      'phone_setup', jsonb_build_object('mode', b.setup_data #>> '{integrations,phone,mode}', 'forward_from', nullif(b.setup_data #>> '{integrations,phone,forward_from}', ''),
                                        'area_code', nullif(b.setup_data #>> '{integrations,phone,area_code}', '')),
      'numbers', coalesce((select jsonb_agg(jsonb_build_object('e164', p.e164, 'status', p.status) order by p.created_at)
                             from public.business_phone_numbers p where p.business_id = p_business_id), '[]'::jsonb));
  end if;
  return null;
end $$;

-- Identity, from the verification documents (manual path) and the provider's result (later). Pure read.
create or replace function public.zella_onboarding_identity(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  o record; v_docs jsonb; v_status text; v_kinds text[] := '{}'; k text; d record;
  v_all_verified boolean := true; v_missing boolean := false; v_rejected boolean := false;
  v_allowed integer := (public.zella_onboarding_rules() ->> 'identity_attempts')::integer;
  required constant text[] := array['owner_identity', 'business_registration'];
begin
  select * into o from public.owner_onboarding where business_id = p_business_id;
  foreach k in array required loop
    select * into d from public.business_verification_documents
     where business_id = p_business_id and kind = k and status <> 'replaced' order by created_at desc, id desc limit 1;
    if not found then v_missing := true; v_all_verified := false; v_kinds := v_kinds || k;
    elsif d.status = 'rejected' then v_rejected := true; v_all_verified := false; v_kinds := v_kinds || k;
    elsif d.status <> 'verified' then v_all_verified := false;
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'status', x.status, 'review_note', x.review_note,
                                               'uploaded_at', x.created_at, 'reviewed_at', x.reviewed_at) order by x.kind), '[]'::jsonb)
    into v_docs
    from (select distinct on (kind) * from public.business_verification_documents
           where business_id = p_business_id and status <> 'replaced' order by kind, created_at desc, id desc) x;
  v_status := case
    when coalesce(o.identity_provider_status = 'approved', false) or v_all_verified then 'verified'
    when coalesce(o.identity_attempts, 0) >= v_allowed or coalesce(o.identity_provider_status = 'needs_review', false) then 'in_review'
    when v_rejected or coalesce(o.identity_provider_status = 'declined', false) then 'try_again'
    when v_missing then 'needed'
    else 'checking' end;
  return jsonb_build_object('status', v_status, 'attempts_used', coalesce(o.identity_attempts, 0), 'attempts_allowed', v_allowed,
    'can_upload', v_status in ('needed', 'try_again') and coalesce(o.current_step = 'identity', false) and cardinality(v_kinds) > 0,
    'upload_kinds', case when v_status in ('needed', 'try_again') and coalesce(o.current_step = 'identity', false) then to_jsonb(v_kinds) else '[]'::jsonb end,
    'documents', v_docs);
end $$;

create or replace function public.zella_onboarding_identity_passed(p_business_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.zella_onboarding_identity(p_business_id) ->> 'status' = 'verified';
$$;

-- When the first payment was confirmed, by the owner's rule; null while it isn't. Only the server writes payments.
create or replace function public.zella_onboarding_payment_confirmed_at(p_business_id uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select case public.zella_onboarding_rules() ->> 'first_payment'
    when 'pay_before_live' then (select min(p.paid_at) from public.payments p
                                  where p.business_id = p_business_id and p.status = 'succeeded'
                                    and p.provider is not null and p.paid_at is not null)
    else null end;   -- 'trial_with_card': the saved card trial setup is not built, so nothing counts yet
$$;

create or replace function public.zella_onboarding_payment(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_at timestamptz := public.zella_onboarding_payment_confirmed_at(p_business_id); v_identity_done boolean;
begin
  v_identity_done := exists (select 1 from public.owner_onboarding_steps where business_id = p_business_id and step = 'identity' and completed_at is not null);
  return jsonb_build_object(
    'status', case when v_at is not null then 'confirmed' when not v_identity_done then 'locked' else 'waiting' end,
    'reason', case when v_at is not null then null when not v_identity_done then 'identity_first'
                   when not (public.zella_onboarding_rules() ->> 'payments_connected')::boolean then 'payments_not_connected'
                   else 'checkout_not_started' end,
    'checkout_available', false,   -- true only once Stripe Checkout is built and identity is verified
    'confirmed_at', v_at);
end $$;

create or replace function public.zella_onboarding_plan(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p record; o record;
begin
  select * into o from public.owner_onboarding where business_id = p_business_id;
  select * into p from public.business_plans where business_id = p_business_id order by version desc limit 1;
  return jsonb_build_object(
    'available', p.id is not null,
    'accepted', p.id is not null and o.plan_accepted_version is not distinct from p.version,
    'accepted_version', o.plan_accepted_version, 'accepted_at', o.plan_accepted_at,
    'current', case when p.id is null then null else jsonb_build_object('version', p.version, 'tier', p.tier,
      'billing_interval', p.billing_interval, 'price_cents', p.price_cents, 'setup_fee_cents', p.setup_fee_cents,
      'currency', p.currency, 'minutes', p.minutes, 'texts', p.texts, 'emails', p.emails, 'team_seats', p.team_seats,
      'phone_numbers', p.phone_numbers, 'locations', p.locations, 'languages', to_jsonb(p.languages),
      'trial_enabled', p.trial_enabled, 'overage_cents_per_minute', p.overage_cents_per_minute) end);
end $$;

-- A section's answer as the screens see it: no answer = to_review; looks right on details that changed = updated.
create or replace function public.zella_onboarding_sections(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k text; r record; v_data jsonb; v_status text; v_out jsonb := '[]'::jsonb; v_all boolean := true;
begin
  foreach k in array public.zella_onboarding_section_keys() loop
    v_data := public.zella_onboarding_section_data(p_business_id, k);
    select * into r from public.owner_onboarding_sections where business_id = p_business_id and section = k;
    v_status := case when r.section is null then 'to_review'
                     when r.status = 'looks_right' and r.confirmed_hash is distinct from md5(v_data::text) then 'updated'
                     else r.status end;
    v_all := v_all and v_status = 'looks_right';
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', k, 'status', v_status, 'note', r.note, 'admin_note', r.admin_note,
                                                           'answered_at', r.answered_at, 'data', v_data, 'data_hash', md5(v_data::text)));
  end loop;
  return jsonb_build_object('sections', v_out, 'all_looks_right', v_all);
end $$;

-- The whole journey for one business (contract 5.2). The caller is authorized before this is called.
create or replace function public.zella_onboarding_state(p_business_id uuid, p_for_admin boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o record; b record; v_steps jsonb := '[]'::jsonb; k text; n integer := 0; s record; v_current text; v_report jsonb;
  v_password boolean; v_factor boolean; v_owner uuid; v_details jsonb;
begin
  v_details := public.zella_onboarding_sections(p_business_id);
  if p_for_admin then   -- team members' phone and email are shown to the business's owner only
    v_details := jsonb_set(v_details, '{sections}', (
      select jsonb_agg(case when x ->> 'key' = 'team' then jsonb_set(x, '{data,members}', coalesce((
               select jsonb_agg(m - 'email' - 'phone' order by j) from jsonb_array_elements(x #> '{data,members}') with ordinality y(m, j)), '[]'::jsonb))
             else x end order by i)
        from jsonb_array_elements(v_details -> 'sections') with ordinality z(x, i)));
  end if;
  select * into b from public.businesses where id = p_business_id;
  select * into o from public.owner_onboarding where business_id = p_business_id;
  v_current := coalesce(o.current_step, 'welcome');
  foreach k in array public.zella_onboarding_step_keys() loop
    n := n + 1;
    select * into s from public.owner_onboarding_steps where business_id = p_business_id and step = k;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object('key', k, 'number', n,
      'state', case when s.completed_at is not null then 'done' when k = v_current then 'current' else 'locked' end,
      'reached_at', s.reached_at, 'completed_at', s.completed_at));
  end loop;
  -- two step sign in, from the auth records of the business's owner (the caller, for an owner)
  v_owner := case when p_for_admin then (select m.user_id from public.business_members m where m.business_id = p_business_id and m.role = 'owner' and m.status = 'active' order by m.created_at limit 1)
                  else auth.uid() end;
  select coalesce(u.encrypted_password, '') <> '' into v_password from auth.users u where u.id = v_owner;
  v_factor := exists (select 1 from auth.mfa_factors f where f.user_id = v_owner and f.status = 'verified');
  v_report := public.zella_activation_checks(p_business_id);
  return jsonb_build_object(
    'business_id', p_business_id, 'business_name', b.name, 'rules', public.zella_onboarding_rules(),
    'started', o.business_id is not null,
    'current_step', v_current, 'current_step_number', array_position(public.zella_onboarding_step_keys(), v_current),
    'steps_total', cardinality(public.zella_onboarding_step_keys()),
    'started_at', o.started_at, 'paused_at', o.paused_at, 'resumed_at', o.resumed_at, 'completed_at', o.completed_at,
    'business_available', b.suspended_at is null and b.cancelled_at is null,
    'steps', v_steps,
    'security', jsonb_build_object('password_set', coalesce(v_password, false), 'authenticator', v_factor,
      'session_verified', case when p_for_admin then null else coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' end,
      'ready', coalesce(v_password, false) and v_factor and (p_for_admin or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')),
    'details', v_details,
    'identity', public.zella_onboarding_identity(p_business_id),
    'plan', public.zella_onboarding_plan(p_business_id),
    'payment', public.zella_onboarding_payment(p_business_id),
    'go_live', jsonb_build_object('ready', v_report -> 'ready', 'live', v_report -> 'live', 'checks', v_report -> 'checks'));
end $$;

-- The journey's row, created on the first write (welcome reached then), locked for this transaction.
create or replace function public.zella_onboarding_ensure(p_business_id uuid, p_user uuid)
returns public.owner_onboarding language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding;
begin
  insert into public.owner_onboarding (business_id, started_by) values (p_business_id, p_user) on conflict (business_id) do nothing;
  insert into public.owner_onboarding_steps (business_id, step) values (p_business_id, 'welcome') on conflict do nothing;
  select * into o from public.owner_onboarding where business_id = p_business_id for update;
  return o;
end $$;

-- Marks a step done and the next one reached. Callers check order and the step's own rule first.
create or replace function public.zella_onboarding_advance(p_business_id uuid, p_step text, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare keys constant text[] := public.zella_onboarding_step_keys(); v_next text;
begin
  -- the steps after the plan need the plan's current version accepted (a new version saved later must be accepted first)
  if array_position(keys, p_step) > array_position(keys, 'plan')
     and not (public.zella_onboarding_plan(p_business_id) ->> 'accepted')::boolean then
    raise exception 'PLAN_CHANGED';
  end if;
  v_next := keys[array_position(keys, p_step) + 1];
  update public.owner_onboarding_steps set completed_at = now(), completed_by = p_user
   where business_id = p_business_id and step = p_step and completed_at is null;
  if v_next is not null then
    insert into public.owner_onboarding_steps (business_id, step) values (p_business_id, v_next) on conflict do nothing;
  end if;
  update public.owner_onboarding set current_step = coalesce(v_next, p_step),
         completed_at = case when v_next is null then now() else completed_at end,
         resumed_at = case when paused_at is not null then now() else resumed_at end, paused_at = null, updated_at = now()
   where business_id = p_business_id;
end $$;

-- Order of steps for a write: STEP_LOCKED for a later step; true when this step is already done (nothing to do).
create or replace function public.zella_onboarding_step_done(p_business_id uuid, p_step text, p_current text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from public.owner_onboarding_steps where business_id = p_business_id and step = p_step and completed_at is not null) then
    return true;
  end if;
  if p_step <> p_current then raise exception 'STEP_LOCKED'; end if;
  return false;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Owner functions (contract section 5)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_owner_onboarding_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if not public.zella_mfa_satisfied() then raise exception 'MFA_REQUIRED'; end if;
  return jsonb_build_object('businesses', coalesce((
    select jsonb_agg(jsonb_build_object('business_id', b.id, 'business_name', b.name,
             'current_step', coalesce(o.current_step, 'welcome'), 'completed', o.completed_at is not null) order by b.created_at, b.id)
      from public.business_members m join public.businesses b on b.id = m.business_id
      left join public.owner_onboarding o on o.business_id = b.id
     where m.user_id = auth.uid() and m.role = 'owner' and m.status = 'active' and b.cancelled_at is null), '[]'::jsonb));
end $$;

create or replace function public.zella_owner_onboarding_get(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  return public.zella_onboarding_state(p_business_id);
end $$;

create or replace function public.zella_owner_onboarding_identity_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  return public.zella_onboarding_identity(p_business_id);
end $$;

create or replace function public.zella_owner_onboarding_payment_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  return public.zella_onboarding_payment(p_business_id);
end $$;

create or replace function public.zella_owner_onboarding_complete_step(p_business_id uuid, p_step text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding; v_pos integer := array_position(public.zella_onboarding_step_keys(), p_step);
  v_missing text[] := '{}'; v_details jsonb; v_plan jsonb;
begin
  -- the step decides whether a code verified session is needed (from step 3 on), so it is read first
  perform public.zella_onboarding_authorize(p_business_id, true, coalesce(v_pos, 3) >= 3);
  if v_pos is null then raise exception 'INVALID_INPUT'; end if;
  o := public.zella_onboarding_ensure(p_business_id, auth.uid());
  if public.zella_onboarding_step_done(p_business_id, p_step, o.current_step) then
    return jsonb_build_object('changed', false, 'state', public.zella_onboarding_state(p_business_id));
  end if;

  if p_step = 'security' then
    if not exists (select 1 from auth.users u where u.id = auth.uid() and coalesce(u.encrypted_password, '') <> '') then v_missing := v_missing || 'password'::text; end if;
    if not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified') then v_missing := v_missing || 'authenticator'::text; end if;
    if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then v_missing := v_missing || 'code'::text; end if;
    if cardinality(v_missing) > 0 then raise exception using message = 'SECURITY_INCOMPLETE', detail = array_to_string(v_missing, ','); end if;
  elsif p_step = 'details' then
    v_details := public.zella_onboarding_sections(p_business_id);
    if not (v_details ->> 'all_looks_right')::boolean then
      raise exception using message = 'SECTIONS_NOT_CONFIRMED',
        detail = (select string_agg(x ->> 'key', ',') from jsonb_array_elements(v_details -> 'sections') x where x ->> 'status' <> 'looks_right');
    end if;
  elsif p_step = 'identity' then
    if not public.zella_onboarding_identity_passed(p_business_id) then raise exception 'IDENTITY_NOT_VERIFIED'; end if;
  elsif p_step = 'plan' then
    v_plan := public.zella_onboarding_plan(p_business_id);
    if not (v_plan ->> 'available')::boolean then raise exception 'PLAN_MISSING'; end if;
    if not (v_plan ->> 'accepted')::boolean then raise exception 'PLAN_CHANGED'; end if;
  elsif p_step = 'payment' then
    if public.zella_onboarding_payment_confirmed_at(p_business_id) is null then raise exception 'PAYMENT_NOT_CONFIRMED'; end if;
  end if;

  perform public.zella_onboarding_advance(p_business_id, p_step, auth.uid());
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.step_completed',
    jsonb_build_object('current_step', o.current_step, 'paused_at', o.paused_at),
    jsonb_build_object('step', p_step, 'current_step', (select current_step from public.owner_onboarding where business_id = p_business_id)));
  return jsonb_build_object('changed', true, 'state', public.zella_onboarding_state(p_business_id));
end $$;

-- p_seen_hash: the section's data_hash the owner was shown, required with Looks right (INVALID_INPUT without it). Looks
-- right is refused (DETAILS_CHANGED) when the details changed since, so the owner never confirms details they didn't see.
drop function if exists public.zella_owner_onboarding_section(uuid, text, text, text);
create or replace function public.zella_owner_onboarding_section(p_business_id uuid, p_section text, p_decision text, p_note text default null,
  p_seen_hash text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding; r record; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_hash text; v_name text;
  labels constant jsonb := '{"business": "Business details", "hours_services": "Hours and services", "team": "Team", "receptionist_phone": "AI receptionist and phone"}';
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_section is null or not (p_section = any (public.zella_onboarding_section_keys())) or p_decision is null or p_decision not in ('looks_right', 'change') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_decision = 'change' and v_note is null then raise exception 'NOTE_REQUIRED'; end if;
  if p_decision = 'change' and length(v_note) > 1000 then raise exception using message = 'NOTE_REQUIRED', detail = 'too_long'; end if;
  o := public.zella_onboarding_ensure(p_business_id, auth.uid());
  if o.current_step <> 'details' then
    if exists (select 1 from public.owner_onboarding_steps where business_id = p_business_id and step = 'details' and completed_at is not null) then
      raise exception 'STEP_CLOSED';
    end if;
    raise exception 'STEP_LOCKED';
  end if;
  select * into r from public.owner_onboarding_sections where business_id = p_business_id and section = p_section;
  v_hash := md5(public.zella_onboarding_section_data(p_business_id, p_section)::text);

  if p_decision = 'looks_right' then
    if p_seen_hash is null or p_seen_hash !~ '^[0-9a-f]{32}$' then raise exception 'INVALID_INPUT'; end if;
    if p_seen_hash <> v_hash then raise exception 'DETAILS_CHANGED'; end if;
    if r.status = 'looks_right' and r.confirmed_hash = v_hash then
      return jsonb_build_object('changed', false, 'state', public.zella_onboarding_state(p_business_id));
    end if;
    insert into public.owner_onboarding_sections as t (business_id, section, status, note, admin_note, confirmed_hash, answered_by, answered_at, updated_at)
    values (p_business_id, p_section, 'looks_right', null, null, v_hash, auth.uid(), now(), now())
    on conflict (business_id, section) do update set status = 'looks_right', note = null, admin_note = null, confirmed_hash = excluded.confirmed_hash,
      answered_by = excluded.answered_by, answered_at = now(), updated_at = now();
    if r.status = 'change_requested' then
      perform public.zella_resolve_platform_alerts('onboarding_change_requested', p_business_id, p_section, 'The owner said the details look right');
    end if;
    perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.section_looks_right',
      jsonb_build_object('section', p_section, 'status', coalesce(r.status, 'to_review'), 'note', r.note),
      jsonb_build_object('section', p_section, 'status', 'looks_right'));
  else
    if r.status = 'change_requested' and r.note = v_note then
      return jsonb_build_object('changed', false, 'state', public.zella_onboarding_state(p_business_id));
    end if;
    insert into public.owner_onboarding_sections as t (business_id, section, status, note, admin_note, confirmed_hash, answered_by, answered_at, updated_at)
    values (p_business_id, p_section, 'change_requested', v_note, null, null, auth.uid(), now(), now())
    on conflict (business_id, section) do update set status = 'change_requested', note = excluded.note, admin_note = null, confirmed_hash = null,
      answered_by = excluded.answered_by, answered_at = now(), updated_at = now();
    select name into v_name from public.businesses where id = p_business_id;
    perform public.zella_platform_alert('onboarding_change_requested', coalesce(v_name, 'A business') || ' asked for a change during onboarding',
      (labels ->> p_section) || ': ' || v_note, 'info', p_business_id, p_section, jsonb_build_object('section', p_section));
    perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.change_requested',
      jsonb_build_object('section', p_section, 'status', coalesce(r.status, 'to_review'), 'note', r.note),
      jsonb_build_object('section', p_section, 'status', 'change_requested', 'note', v_note));
  end if;
  update public.owner_onboarding set updated_at = now() where business_id = p_business_id;
  return jsonb_build_object('changed', true, 'state', public.zella_onboarding_state(p_business_id));
end $$;

create or replace function public.zella_owner_onboarding_plan_accept(p_business_id uuid, p_plan_version integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding; p record;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_plan_version is null or p_plan_version < 1 then raise exception 'INVALID_INPUT'; end if;
  o := public.zella_onboarding_ensure(p_business_id, auth.uid());
  select * into p from public.business_plans where business_id = p_business_id order by version desc limit 1;
  if public.zella_onboarding_step_done(p_business_id, 'plan', o.current_step) then
    if o.plan_accepted_version = p_plan_version then
      return jsonb_build_object('changed', false, 'state', public.zella_onboarding_state(p_business_id));
    end if;
    -- Zella Voice saved a new version after the owner accepted: the owner accepts the current one (never an old one)
    if o.completed_at is not null then raise exception 'STEP_CLOSED'; end if;
    if p.id is null then raise exception 'PLAN_MISSING'; end if;
    if p.version <> p_plan_version then raise exception 'PLAN_CHANGED'; end if;
    update public.owner_onboarding set plan_accepted_version = p.version, plan_accepted_at = now(), updated_at = now() where business_id = p_business_id;
    perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.plan_accepted',
      jsonb_build_object('accepted_version', o.plan_accepted_version, 'current_step', o.current_step),
      jsonb_build_object('accepted_version', p.version, 'tier', p.tier, 'billing_interval', p.billing_interval,
                         'price_cents', p.price_cents, 'currency', p.currency, 'current_step', o.current_step));
    return jsonb_build_object('changed', true, 'state', public.zella_onboarding_state(p_business_id));
  end if;
  if p.id is null then raise exception 'PLAN_MISSING'; end if;
  if p.version <> p_plan_version then raise exception 'PLAN_CHANGED'; end if;
  update public.owner_onboarding set plan_accepted_version = p.version, plan_accepted_at = now(), updated_at = now() where business_id = p_business_id;
  perform public.zella_onboarding_advance(p_business_id, 'plan', auth.uid());
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.plan_accepted',
    jsonb_build_object('accepted_version', o.plan_accepted_version, 'current_step', o.current_step),
    jsonb_build_object('accepted_version', p.version, 'tier', p.tier, 'billing_interval', p.billing_interval,
                       'price_cents', p.price_cents, 'currency', p.currency, 'current_step', 'payment'));
  return jsonb_build_object('changed', true, 'state', public.zella_onboarding_state(p_business_id));
end $$;

create or replace function public.zella_owner_onboarding_finish_later(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  o := public.zella_onboarding_ensure(p_business_id, auth.uid());
  if o.paused_at is not null or o.completed_at is not null then
    return jsonb_build_object('changed', false, 'state', public.zella_onboarding_state(p_business_id));
  end if;
  update public.owner_onboarding set paused_at = now(), updated_at = now() where business_id = p_business_id;
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.finish_later',
    jsonb_build_object('paused_at', null, 'current_step', o.current_step), jsonb_build_object('paused_at', now(), 'current_step', o.current_step));
  return jsonb_build_object('changed', true, 'state', public.zella_onboarding_state(p_business_id));
end $$;

create or replace function public.zella_owner_onboarding_resume(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  o := public.zella_onboarding_ensure(p_business_id, auth.uid());
  if o.paused_at is null then
    return jsonb_build_object('changed', false, 'state', public.zella_onboarding_state(p_business_id));
  end if;
  update public.owner_onboarding set paused_at = null, resumed_at = now(), updated_at = now() where business_id = p_business_id;
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.resumed',
    jsonb_build_object('paused_at', o.paused_at, 'current_step', o.current_step), jsonb_build_object('paused_at', null, 'current_step', o.current_step));
  return jsonb_build_object('changed', true, 'state', public.zella_onboarding_state(p_business_id));
end $$;

-- The owner-onboarding edge function asks this with the owner's own session before handing out an upload link and
-- before recording the file: owner of this business, code verified session, on step 4, and a kind the owner may send.
-- It answers with the caller's own id, so the function never takes the owner's identity from the request.
create or replace function public.zella_owner_identity_upload_check(p_business_id uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o record; v jsonb;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_kind is null or p_kind not in ('owner_identity', 'business_registration') then raise exception 'INVALID_INPUT'; end if;
  select * into o from public.owner_onboarding where business_id = p_business_id;
  if coalesce(o.current_step, 'welcome') <> 'identity' then
    if exists (select 1 from public.owner_onboarding_steps where business_id = p_business_id and step = 'identity' and completed_at is not null) then
      raise exception 'UPLOAD_NOT_ALLOWED';
    end if;
    raise exception 'STEP_LOCKED';
  end if;
  v := public.zella_onboarding_identity(p_business_id);
  if not (v ->> 'can_upload')::boolean or not (v -> 'upload_kinds') ? p_kind then raise exception 'UPLOAD_NOT_ALLOWED'; end if;
  return jsonb_build_object('ok', true, 'user_id', auth.uid());   -- the edge function records the document for this person
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Server only
-- ---------------------------------------------------------------------------------------------------------------

-- Records the owner's new document (the edge function has verified the session and called the check above with the
-- owner's own token; this re-checks everything except the session level, which only that token carries).
create or replace function public.zella_owner_identity_document_add(p_business_id uuid, p_user uuid, p_kind text, p_path text,
  p_file_name text, p_mime text, p_size integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding; v jsonb; d record;
begin
  if p_user is null or p_business_id is null or not exists (select 1 from public.business_members m
       where m.business_id = p_business_id and m.user_id = p_user and m.role = 'owner' and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  if exists (select 1 from public.businesses b where b.id = p_business_id and (b.suspended_at is not null or b.cancelled_at is not null)) then
    raise exception 'BUSINESS_NOT_AVAILABLE';
  end if;
  if p_kind is null or p_kind not in ('owner_identity', 'business_registration')
     or p_path is null or p_path !~ ('^' || p_business_id::text || '/' || p_kind || '/[0-9a-f-]{36}\.(pdf|jpg|png|webp|heic)$')
     or p_mime is null or p_mime not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic')
     or p_size is null or p_size not between 1 and 10485760
     or p_file_name is null or length(p_file_name) not between 1 and 200 then
    raise exception 'INVALID_INPUT';
  end if;
  select * into o from public.owner_onboarding where business_id = p_business_id for update;
  if not found or o.current_step <> 'identity' then raise exception 'STEP_LOCKED'; end if;
  v := public.zella_onboarding_identity(p_business_id);
  if not (v ->> 'can_upload')::boolean or not (v -> 'upload_kinds') ? p_kind then raise exception 'UPLOAD_NOT_ALLOWED'; end if;
  if exists (select 1 from public.business_verification_documents where file_path = p_path) then raise exception 'INVALID_INPUT'; end if;

  update public.business_verification_documents set status = 'replaced', updated_at = now()
   where business_id = p_business_id and kind = p_kind and status <> 'replaced';
  insert into public.business_verification_documents (business_id, kind, file_path, file_name, mime_type, size_bytes, uploaded_by)
  values (p_business_id, p_kind, p_path, p_file_name, p_mime, p_size, p_user)
  returning id, kind, status, review_note, created_at, reviewed_at into d;
  perform public.zella_onboarding_audit(p_business_id, p_user, 'onboarding.document_uploaded',
    jsonb_build_object('kind', p_kind, 'identity_status', v ->> 'status'),
    jsonb_build_object('kind', p_kind, 'file_name', p_file_name, 'document_id', d.id));
  update public.owner_onboarding set updated_at = now() where business_id = p_business_id;
  return jsonb_build_object('document', jsonb_build_object('kind', d.kind, 'status', d.status, 'review_note', d.review_note,
                                                           'uploaded_at', d.created_at, 'reviewed_at', d.reviewed_at),
                            'identity', public.zella_onboarding_identity(p_business_id));
end $$;

-- One identity provider event, processed once (unique provider + event id). Bound to a business only through the
-- reference this business gave the provider; an unknown reference is kept as unmapped and alerted (TEN-12).
-- p_subject: the provider's own id for one check (a Persona inquiry). A declined check counts as one failed try once,
-- however many declined events the provider sends for it; delivery retries are already one row per event id.
drop function if exists public.zella_identity_provider_event(text, text, text, text, timestamptz);
create or replace function public.zella_identity_provider_event(p_provider text, p_event_id text, p_reference text,
  p_outcome text, p_occurred_at timestamptz, p_subject text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rules jsonb := public.zella_onboarding_rules(); o public.owner_onboarding; v_id uuid; v_result text; v_old text; v_attempts integer;
  v_counted boolean;
begin
  if p_provider is null or p_provider = 'none' or p_provider is distinct from v_rules ->> 'identity_provider' then
    return jsonb_build_object('result', 'off');
  end if;
  if p_event_id is null or length(p_event_id) not between 1 and 200 or p_outcome is null
     or p_outcome not in ('approved', 'declined', 'needs_review', 'pending', 'other')
     or (p_subject is not null and length(p_subject) not between 1 and 200) then
    raise exception 'INVALID_INPUT';
  end if;
  select * into o from public.owner_onboarding where identity_reference = p_reference for update;
  v_result := case when o.business_id is null then 'unmapped'
                   when p_outcome in ('pending', 'other') then 'ignored'
                   when o.identity_provider_at is not null and p_occurred_at is not null and p_occurred_at < o.identity_provider_at then 'ignored'   -- older than what we have
                   else 'applied' end;
  -- this check's decline was counted already (an earlier declined event for the same subject)
  v_counted := p_subject is not null and exists (select 1 from public.identity_verification_events e
    where e.provider = p_provider and e.subject = p_subject and e.business_id = o.business_id and e.outcome = 'declined' and e.result = 'applied');
  insert into public.identity_verification_events (provider, event_id, scope, business_id, outcome, subject, occurred_at, result)
  values (p_provider, p_event_id, case when o.business_id is null then 'unmapped' else 'business' end, o.business_id, p_outcome, p_subject, p_occurred_at, v_result)
  on conflict (provider, event_id) do nothing returning id into v_id;
  if v_id is null then return jsonb_build_object('result', 'duplicate'); end if;
  if v_result = 'unmapped' then
    perform public.zella_platform_alert('identity_event_unmapped', 'An identity check result matched no business',
      'Provider ' || p_provider || ' sent a result for a reference Zella Voice does not know.', 'warning', null, p_provider, jsonb_build_object('event', v_id));
    return jsonb_build_object('result', 'unmapped');
  end if;
  if v_result = 'applied' then
    v_old := o.identity_provider_status;
    update public.owner_onboarding set identity_provider_status = p_outcome, identity_provider_at = coalesce(p_occurred_at, now()),
           -- a declined check is counted once per subject; one without a subject can't be told apart, so it isn't counted
           identity_attempts = identity_attempts + case when p_outcome = 'declined' and current_step = 'identity' and p_subject is not null and not v_counted then 1 else 0 end,
           updated_at = now()
     where business_id = o.business_id
    returning identity_attempts into v_attempts;
    if p_outcome = 'needs_review' or (p_outcome = 'declined' and v_attempts = (v_rules ->> 'identity_attempts')::integer and v_attempts > o.identity_attempts) then
      perform public.zella_platform_alert('onboarding_identity_review', 'A business needs a manual identity review',
        'The identity provider could not confirm the owner. Review the documents in Verification.', 'warning',
        o.business_id, 'identity', jsonb_build_object('attempts', v_attempts, 'provider', p_provider));
    elsif p_outcome = 'approved' then
      perform public.zella_resolve_platform_alerts('onboarding_identity_review', o.business_id, 'identity', 'Identity verified');
    end if;
    perform public.zella_onboarding_audit(o.business_id, null, 'onboarding.identity_provider_result',
      jsonb_build_object('provider_status', v_old, 'attempts', o.identity_attempts),
      jsonb_build_object('provider_status', p_outcome, 'provider', p_provider, 'event', v_id));
  end if;
  return jsonb_build_object('result', v_result);
end $$;

-- A rejected required document is a failed identity check while the owner is on step 4 (retry, then manual review).
-- When the last allowed attempt fails, Zella Voice is alerted to review it by hand in Verification; the alert is
-- resolved once identity passes there.
create or replace function public.zella_onboarding_document_rejected_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_attempts integer; v_name text;
begin
  if new.status = 'rejected' and old.status is distinct from 'rejected' and new.kind in ('owner_identity', 'business_registration') then
    update public.owner_onboarding set identity_attempts = identity_attempts + 1, updated_at = now()
     where business_id = new.business_id and current_step = 'identity'
    returning identity_attempts into v_attempts;
    if v_attempts = (public.zella_onboarding_rules() ->> 'identity_attempts')::integer then
      select name into v_name from public.businesses where id = new.business_id;
      perform public.zella_platform_alert('onboarding_identity_review', coalesce(v_name, 'A business') || ' needs a manual identity review',
        'The owner''s identity check failed ' || v_attempts || ' times. Review the documents in Verification.', 'warning',
        new.business_id, 'identity', jsonb_build_object('attempts', v_attempts));
    end if;
  elsif new.status = 'verified' and old.status is distinct from 'verified' and public.zella_onboarding_identity_passed(new.business_id) then
    perform public.zella_resolve_platform_alerts('onboarding_identity_review', new.business_id, 'identity', 'Identity verified');
  end if;
  return null;
end $$;
drop trigger if exists zella_onboarding_document_rejected on public.business_verification_documents;
create trigger zella_onboarding_document_rejected after update of status on public.business_verification_documents
  for each row execute function public.zella_onboarding_document_rejected_trg();

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Admin functions (contract section 6)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_onboarding_admin_check(p_permission text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if not public.zella_admin_can(p_permission) then raise exception 'NOT_PERMITTED'; end if;
  if not public.zella_mfa_satisfied() then raise exception 'MFA_REQUIRED'; end if;
end $$;

create or replace function public.zella_admin_onboarding_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_admin_check('businesses.view');
  return jsonb_build_object('businesses', coalesce((
    select jsonb_agg(jsonb_build_object('business_id', o.business_id, 'business_name', b.name, 'current_step', o.current_step,
             'current_step_number', array_position(public.zella_onboarding_step_keys(), o.current_step),
             'steps_total', cardinality(public.zella_onboarding_step_keys()),
             'identity_status', public.zella_onboarding_identity(o.business_id) ->> 'status',
             'payment_status', public.zella_onboarding_payment(o.business_id) ->> 'status',
             'change_requests', (select count(*) from public.owner_onboarding_sections s where s.business_id = o.business_id and s.status = 'change_requested'),
             'paused_at', o.paused_at, 'completed_at', o.completed_at, 'updated_at', o.updated_at) order by o.updated_at desc)
      from public.owner_onboarding o join public.businesses b on b.id = o.business_id), '[]'::jsonb));
end $$;

create or replace function public.zella_admin_onboarding_progress(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_admin_check('businesses.view');
  if p_business_id is null or not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  return public.zella_onboarding_state(p_business_id, true);
end $$;

create or replace function public.zella_admin_onboarding_change_done(p_business_id uuid, p_section text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.zella_onboarding_admin_check('businesses.manage');
  if p_section is null or not (p_section = any (public.zella_onboarding_section_keys())) or v_note is null or length(v_note) > 500 then
    raise exception 'INVALID_INPUT';
  end if;
  select * into r from public.owner_onboarding_sections where business_id = p_business_id and section = p_section for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'change_requested' then return jsonb_build_object('changed', false); end if;
  update public.owner_onboarding_sections set status = 'updated', note = null, admin_note = v_note, confirmed_hash = null, updated_at = now()
   where business_id = p_business_id and section = p_section;
  perform public.zella_resolve_platform_alerts('onboarding_change_requested', p_business_id, p_section, 'Change made');
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.change_done',
    jsonb_build_object('section', p_section, 'status', r.status, 'note', r.note),
    jsonb_build_object('section', p_section, 'status', 'updated', 'admin_note', v_note));
  return jsonb_build_object('changed', true);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. The go live gate (REQ-LC-14): two more checks; every earlier check stays
-- ---------------------------------------------------------------------------------------------------------------
-- The checklist itself, without the caller check, so the admin progress view can show it too. Server side only.
create or replace function public.zella_activation_checks(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_checks jsonb := '[]'::jsonb; v_all boolean := true; r record;
begin
  for r in
    select * from (values
      ('owner', 'An owner has accepted their invitation', exists (select 1 from public.business_members m where m.business_id = p_business_id and m.status = 'active')),
      ('phone', 'Phone line connected', exists (select 1 from public.integrations i where i.business_id = p_business_id and i.provider = 'telnyx' and i.status = 'active')),
      ('assistant', 'AI assistant connected', exists (select 1 from public.integrations i where i.business_id = p_business_id and i.provider = 'vapi' and i.status = 'active')),
      ('agent', 'AI receptionist has instructions', exists (select 1 from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id where ag.business_id = p_business_id and ag.is_default and length(coalesce(cfg.system_prompt, '')) >= 20)),
      ('transfer', 'A way for callers to reach a person', exists (select 1 from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id where ag.business_id = p_business_id and ag.is_default and coalesce(cfg.escalation_rules, '{}'::jsonb) <> '{}'::jsonb)),
      ('knowledge', 'At least one approved answer is ready', exists (select 1 from public.knowledge_items k where k.business_id = p_business_id and k.status = 'ready')),
      ('automations', 'At least one automation switched on', exists (select 1 from public.automations a where a.business_id = p_business_id and a.status in ('active', 'paused'))),
      ('test_call', 'A test call passed', coalesce((select t.ok from public.activation_tests t where t.business_id = p_business_id order by t.created_at desc limit 1), false)),
      -- owner onboarding (sql/zella_owner_onboarding.sql): identity checked, and the first payment by the owner's rule
      ('identity', 'Owner identity verified', public.zella_onboarding_identity_passed(p_business_id)),
      ('payment', 'First payment confirmed', public.zella_onboarding_payment_confirmed_at(p_business_id) is not null)
    ) as t(key, label, ok)
  loop
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('key', r.key, 'label', r.label, 'ok', r.ok));
    v_all := v_all and r.ok;
  end loop;
  return jsonb_build_object('ready', v_all, 'live', exists (select 1 from public.businesses where id = p_business_id and onboarding_status = 'active'), 'checks', v_checks);
end $$;

CREATE OR REPLACE FUNCTION public.zella_activation_report(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rep jsonb; v_others jsonb;
begin
  -- members of the business, and Zella Voice admins who may view businesses (as for onboarding progress)
  if auth.uid() is not null and not public.zella_is_member(p_business_id) and not public.zella_admin_can('businesses.view') then
    raise exception 'NOT_ALLOWED';
  end if;
  -- the same checks as before, plus the owner onboarding gate (zella_activation_checks)
  v_rep := public.zella_activation_checks(p_business_id);
  -- The owner's identity and payment results are for the owner and those admins. Members who can switch the business
  -- live (zella_can_manage) see one check, "The owner finished their setup", in their place, because going live waits
  -- for it; other members see neither result, nor ready (which would tell), only the other checks.
  if auth.uid() is not null and not public.zella_admin_can('businesses.view') and not exists (
       select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.role = 'owner' and m.status = 'active') then
    v_others := coalesce((select jsonb_agg(c order by i) from jsonb_array_elements(v_rep -> 'checks') with ordinality x(c, i)
                           where c ->> 'key' not in ('identity', 'payment')), '[]'::jsonb);
    if public.zella_can_manage(p_business_id) then
      v_rep := jsonb_set(v_rep, '{checks}', v_others || jsonb_build_array(jsonb_build_object('key', 'owner_setup', 'label', 'The owner finished their setup',
        'ok', coalesce((select bool_and((c ->> 'ok')::boolean) from jsonb_array_elements(v_rep -> 'checks') c where c ->> 'key' in ('identity', 'payment')), true))));
    else
      v_rep := jsonb_set(jsonb_set(v_rep, '{checks}', v_others), '{ready}', 'null'::jsonb);
    end if;
  end if;
  return v_rep;
end $function$;

CREATE OR REPLACE FUNCTION public.zella_request_activation(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rep jsonb;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if exists (select 1 from public.businesses where id = p_business_id and (suspended_at is not null or cancelled_at is not null)) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  perform 1 from public.businesses where id = p_business_id for update;   -- one go live at a time per business
  v_rep := public.zella_activation_report(p_business_id);
  -- the owner onboarding gate is checked here too, so no later change to the report can skip it
  if (v_rep ->> 'ready')::boolean and public.zella_onboarding_identity_passed(p_business_id)
     and public.zella_onboarding_payment_confirmed_at(p_business_id) is not null then
    update public.businesses set onboarding_status = 'active', is_active = true, updated_at = now() where id = p_business_id;
    update public.automations set status = 'active', updated_at = now() where business_id = p_business_id and status = 'paused';
    perform public.zella_resolve_platform_alerts('setup_incomplete', p_business_id, null, 'Went live');
    perform public.zella_notify_owners(p_business_id, 'went_live', 'You are live', 'Your AI receptionist is now answering calls.', 'info', 'today');
  end if;
  return v_rep;
end $function$;

-- ---------------------------------------------------------------------------------------------------------------
-- Grants: execute is revoked from everyone and granted deliberately (SEC-6, SEC-7)
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare s text;
begin
  foreach s in array array[
    'zella_onboarding_rules()', 'zella_onboarding_step_keys()', 'zella_onboarding_section_keys()',
    'zella_onboarding_authorize(uuid,boolean,boolean)', 'zella_onboarding_audit(uuid,uuid,text,jsonb,jsonb)',
    'zella_onboarding_config(uuid)', 'zella_onboarding_section_data(uuid,text)', 'zella_onboarding_identity(uuid)',
    'zella_onboarding_identity_passed(uuid)', 'zella_onboarding_payment_confirmed_at(uuid)', 'zella_onboarding_payment(uuid)',
    'zella_onboarding_plan(uuid)', 'zella_onboarding_sections(uuid)', 'zella_onboarding_state(uuid,boolean)',
    'zella_onboarding_ensure(uuid,uuid)', 'zella_onboarding_advance(uuid,text,uuid)', 'zella_onboarding_step_done(uuid,text,text)',
    'zella_onboarding_document_rejected_trg()', 'zella_onboarding_admin_check(text)', 'zella_activation_checks(uuid)',
    'zella_owner_identity_document_add(uuid,uuid,text,text,text,text,integer)',
    'zella_identity_provider_event(text,text,text,text,timestamptz,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', s);
  end loop;
  foreach s in array array[
    'zella_owner_onboarding_list()', 'zella_owner_onboarding_get(uuid)', 'zella_owner_onboarding_identity_status(uuid)',
    'zella_owner_onboarding_payment_status(uuid)', 'zella_owner_onboarding_complete_step(uuid,text)',
    'zella_owner_onboarding_section(uuid,text,text,text,text)', 'zella_owner_onboarding_plan_accept(uuid,integer)',
    'zella_owner_onboarding_finish_later(uuid)', 'zella_owner_onboarding_resume(uuid)',
    'zella_owner_identity_upload_check(uuid,text)', 'zella_admin_onboarding_overview()',
    'zella_admin_onboarding_progress(uuid)', 'zella_admin_onboarding_change_done(uuid,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon', s);
    execute format('grant execute on function public.%s to authenticated', s);
  end loop;
  grant execute on function public.zella_owner_identity_document_add(uuid,uuid,text,text,text,text,integer) to service_role;
  grant execute on function public.zella_identity_provider_event(text,text,text,text,timestamptz,text) to service_role;
end $$;

commit;
