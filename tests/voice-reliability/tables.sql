-- Staging fixture: the live production definitions (2026-10-27) of the tables the voice and booking functions use.
-- Columns, defaults, checks, primary keys and indexes as reported by the production catalog. No data. FKs, RLS and
-- triggers are not reproduced (the functions under test don't depend on them).
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create or replace function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'service_role') $$;
create or replace function public.zella_digits(p text) returns text language sql immutable as $f$ select null::text $f$;  -- replaced by the live body below

create table public.ai_agent_configs (id uuid default gen_random_uuid() not null, agent_id uuid not null, system_prompt text, personality text, tone text,
  goals jsonb default '[]'::jsonb not null, capabilities jsonb default '[]'::jsonb not null, knowledge_base jsonb default '{}'::jsonb not null,
  escalation_rules jsonb default '{}'::jsonb not null, appointment_rules jsonb default '{}'::jsonb not null, voice_config jsonb default '{}'::jsonb not null,
  business_context jsonb default '{}'::jsonb not null, created_at timestamptz default now() not null, updated_at timestamptz default now() not null, primary key (id));
create unique index ai_agent_configs_agent_id_key on public.ai_agent_configs (agent_id);
create table public.ai_agents (id uuid default gen_random_uuid() not null, business_id uuid not null, name text not null, agent_type text not null, description text,
  status text default 'active' not null, channels text[] default '{}' not null, is_default boolean default false not null,
  created_at timestamptz default now() not null, updated_at timestamptz default now() not null,
  check (agent_type = any (array['receptionist','sales','support','follow_up','appointments','custom'])), primary key (id),
  check (status = any (array['active','paused','disabled'])));
create table public.ai_tool_calls (id uuid default gen_random_uuid() not null, business_id uuid not null, provider_call_id text, tool text not null,
  idempotency_key text, arg_keys text[] default '{}' not null, status text default 'started' not null, result_status text, verified boolean, error text,
  result jsonb, created_at timestamptz default now() not null, finished_at timestamptz, primary key (id));
create index ai_tool_calls_business_idx on public.ai_tool_calls (business_id, created_at desc);
create unique index ai_tool_calls_idem_idx on public.ai_tool_calls (business_id, idempotency_key) where idempotency_key is not null and status = 'done';
create table public.appointments (id uuid default gen_random_uuid() not null, business_id uuid not null, customer_id uuid, assigned_to uuid, title text not null,
  description text, appointment_type text, status text default 'scheduled' not null, start_time timestamptz not null, end_time timestamptz not null,
  timezone text default 'America/New_York' not null, location text, meeting_url text, external_event_id text, reminder_sent boolean default false not null,
  metadata jsonb default '{}'::jsonb not null, created_at timestamptz default now() not null, updated_at timestamptz default now() not null,
  checked_in_at timestamptz, internal_notes text, party_size integer, staff_id uuid, booking_state text default 'confirmed' not null, hold_expires_at timestamptz,
  original_start_time timestamptz, rescheduled_at timestamptz, reschedule_count integer default 0 not null, reschedule_requested_by text, cancelled_at timestamptz,
  cancel_reason text, conflict_note text, arrived_at timestamptz, in_service_at timestamptz, attendance_source text, attendance_by uuid, attendance_note text,
  check ((attendance_source is null) or (attendance_source = any (array['staff','integration']))),
  check (booking_state = any (array['requested','tentative','confirmed'])), check ((party_size is null) or (party_size > 0)), primary key (id),
  check (status = any (array['scheduled','confirmed','completed','cancelled','no_show'])));
create index appointments_business_status_idx on public.appointments (business_id, status, start_time);
create index appointments_customer_idx on public.appointments (customer_id, start_time);
create table public.automations (id uuid default gen_random_uuid() not null, business_id uuid not null, name text not null, description text, trigger_type text not null,
  status text default 'active' not null, trigger_config jsonb default '{}'::jsonb not null, actions jsonb default '[]'::jsonb not null,
  conditions jsonb default '[]'::jsonb not null, created_by uuid, created_at timestamptz default now() not null, updated_at timestamptz default now() not null,
  paused_by_suspension boolean default false not null, primary key (id), check (status = any (array['active','paused','disabled'])));
create table public.blocked_times (id uuid default gen_random_uuid() not null, business_id uuid not null, title text default 'Blocked' not null, reason text,
  start_time timestamptz not null, end_time timestamptz not null, all_day boolean default false not null, staff_id uuid, created_by uuid,
  created_at timestamptz default now() not null, source text, external_id text, connection_id uuid, primary key (id), check (end_time > start_time));
create table public.business_closures (id uuid default gen_random_uuid() not null, business_id uuid not null, starts_on date not null, ends_on date not null,
  label text default 'Closed' not null, opens time, closes time, created_at timestamptz default now() not null,
  check (ends_on >= starts_on), check ((opens is null) = (closes is null)), primary key (id));
create table public.business_hours (id uuid default gen_random_uuid() not null, business_id uuid not null, weekday smallint not null, opens time not null,
  closes time not null, created_at timestamptz default now() not null, check (closes > opens), primary key (id), check (weekday >= 0 and weekday <= 6));
create table public.business_members (id uuid default gen_random_uuid() not null, business_id uuid not null, user_id uuid not null, role text default 'staff' not null,
  status text default 'active' not null, created_at timestamptz default now() not null, accepts_work boolean default true not null, away_until timestamptz,
  last_assigned_at timestamptz, sms_alerts boolean default false not null, primary key (id),
  check (role = any (array['owner','admin','manager','staff','viewer'])), check (status = any (array['invited','active','suspended'])));
create unique index business_members_business_id_user_id_key on public.business_members (business_id, user_id);
create table public.business_phone_numbers (id uuid default gen_random_uuid() not null, business_id uuid not null, e164 text not null, vapi_phone_number_id text,
  label text, status text default 'active' not null, created_at timestamptz default now() not null, check (e164 ~ '^\+[1-9][0-9]{7,14}$'), primary key (id),
  check (status = any (array['active','paused'])));
create unique index business_phone_numbers_e164_key on public.business_phone_numbers (e164);
create unique index business_phone_numbers_vapi_phone_number_id_key on public.business_phone_numbers (vapi_phone_number_id);
create table public.businesses (id uuid default gen_random_uuid() not null, name text not null, legal_name text, industry_id uuid, business_type text, website text,
  email text, phone text, address_line_1 text, address_line_2 text, city text, state text, postal_code text, country text default 'US',
  timezone text default 'America/New_York', logo_url text, onboarding_status text default 'started' not null, is_active boolean default true not null,
  created_at timestamptz default now() not null, updated_at timestamptz default now() not null, terminology_overrides jsonb default '{}'::jsonb not null,
  setup_data jsonb default '{}'::jsonb not null, suspended_at timestamptz, suspension_reason text, cancel_at timestamptz, cancel_requested_at timestamptz,
  cancellation_reason text, cancelled_at timestamptz, retention_until timestamptz, inbound_email_token text, business_size text, description text,
  alternate_phone text, primary key (id));
create table public.call_messages (id uuid default gen_random_uuid() not null, business_id uuid not null, call_id uuid, customer_id uuid, kind text default 'message' not null,
  caller_name text, caller_phone text, message text not null, after_hours boolean default false not null, status text default 'new' not null, handled_by uuid,
  handled_at timestamptz, created_at timestamptz default now() not null, check (kind = any (array['message','voicemail','emergency'])), primary key (id),
  check (status = any (array['new','read','handled'])));
create table public.callbacks (id uuid default gen_random_uuid() not null, business_id uuid not null, customer_id uuid, call_id uuid, appointment_id uuid,
  reason text default 'other' not null, priority text default 'normal' not null, status text default 'new' not null, contact_number text, summary text,
  preferred_at timestamptz, due_at timestamptz, assigned_to uuid, assigned_team text, auto_call boolean default false not null, attempts integer default 0 not null,
  max_attempts integer default 3 not null, retry_delay_minutes integer default 120 not null, outcome text, note text, locked_at timestamptz,
  created_by text default 'ai' not null, completed_at timestamptz, created_at timestamptz default now() not null, updated_at timestamptz default now() not null,
  overdue_notified_at timestamptz, overdue_escalated_at timestamptz, reminder_sent_at timestamptz, primary key (id),
  check (priority = any (array['normal','high','urgent'])),
  check (reason = any (array['missed_call','new_lead','requested','needs_human','transfer_failed','appointment_request','booking_failed','after_hours','other'])),
  check (status = any (array['new','scheduled','due','in_progress','contacted','reschedule_requested','retry_scheduled','waiting_on_customer','completed','cancelled','escalated','needs_review'])));
create table public.calls (id uuid default gen_random_uuid() not null, business_id uuid not null, customer_id uuid, conversation_id uuid, direction text not null,
  status text default 'initiated' not null, from_number text, to_number text, started_at timestamptz, answered_at timestamptz, ended_at timestamptz,
  duration_seconds integer, recording_url text, transcript text, ai_handled boolean default false not null, external_call_id text,
  metadata jsonb default '{}'::jsonb not null, created_at timestamptz default now() not null, updated_at timestamptz default now() not null,
  needs_human boolean default false not null, escalation_reason text, escalated_at timestamptz, escalation_resolved_at timestamptz, escalation_resolved_by uuid,
  summary text, transfer_status text, failure_reason text, failure_context jsonb, assigned_to uuid, outcome text, outcome_note text, outcome_at timestamptz,
  escalation_acknowledged_at timestamptz, escalation_acknowledged_by uuid, escalation_reminded_at timestamptz,
  check (direction = any (array['inbound','outbound'])),
  check ((outcome is null) or (outcome = any (array['resolved','booked','callback_needed','left_message','wrong_number','spam','other']))), primary key (id),
  check (status = any (array['initiated','ringing','answered','completed','missed','failed'])),
  check ((transfer_status is null) or (transfer_status = any (array['not_needed','attempted','connected','failed','no_one_available']))));
create index calls_business_status_idx on public.calls (business_id, status, created_at desc);
create table public.crm_tasks (id uuid default gen_random_uuid() not null, business_id uuid not null, customer_id uuid, kind text default 'follow_up' not null,
  title text not null, body text, priority text default 'normal' not null, status text default 'open' not null, due_at timestamptz, assigned_to uuid,
  source text default 'automation' not null, entity_id uuid, escalated_at timestamptz, completed_at timestamptz, created_at timestamptz default now() not null,
  overdue_notified_at timestamptz, primary key (id), check (priority = any (array['normal','high','urgent'])),
  check (source = any (array['automation','ai','staff'])), check (status = any (array['open','done','cancelled'])));
create unique index crm_tasks_one_open_idx on public.crm_tasks (business_id, customer_id, kind)
  where status = 'open' and customer_id is not null and kind = any (array['overdue_contact','duplicate_review','onboarding','quote_review']);
create table public.customers (id uuid default gen_random_uuid() not null, business_id uuid not null, first_name text, last_name text, email text, phone text,
  company_name text, status text default 'active' not null, source text, notes text, metadata jsonb default '{}'::jsonb not null,
  created_at timestamptz default now() not null, updated_at timestamptz default now() not null, do_not_call boolean default false not null,
  do_not_sms boolean default false not null, do_not_email boolean default false not null, preferred_contact_method text, last_contacted_at timestamptz,
  do_not_contact boolean default false not null, tags text[] default '{}' not null, date_of_birth date, address text, preferred_contact text, lead_stage text,
  assigned_to uuid, priority text, qualification jsonb default '{}'::jsonb not null, qualification_result text, contact_deadline_at timestamptz,
  next_follow_up_at timestamptz, lost_reason text, lost_at timestamptz, reactivate_after timestamptz, converted_at timestamptz, email_suppressed_at timestamptz,
  email_suppressed_reason text, preferred_channel text,
  check ((lead_stage is null) or (lead_stage = any (array['new','contacted','qualified','unqualified','quote_sent','won','lost']))), primary key (id),
  check ((preferred_channel is null) or (preferred_channel = any (array['sms','email']))),
  check ((preferred_contact_method is null) or (preferred_contact_method = any (array['voice','sms','email']))),
  check ((priority is null) or (priority = any (array['normal','high','urgent']))), check (status = any (array['active','inactive','archived'])));
create index customers_business_phone_idx on public.customers (business_id, phone);
create table public.duplicate_reviews (id uuid default gen_random_uuid() not null, business_id uuid not null, customer_id uuid, incoming jsonb not null,
  status text default 'open' not null, resolved_by uuid, resolved_at timestamptz, created_at timestamptz default now() not null, primary key (id),
  check (status = any (array['open','merged','kept_separate','dismissed'])));
create table public.knowledge_gaps (id uuid default gen_random_uuid() not null, business_id uuid not null, call_id uuid, customer_id uuid, question text not null,
  question_key text not null, times_asked integer default 1 not null, status text default 'open' not null, knowledge_item_id uuid, notified_at timestamptz,
  resolved_by uuid, resolved_at timestamptz, first_asked_at timestamptz default now() not null, last_asked_at timestamptz default now() not null,
  suggested_title text, suggested_answer text, suggested_kind text, suggestion_source text, suggestion_confidence text,
  suggestion_attempts integer default 0 not null, suggested_at timestamptz, repeat_notified_at timestamptz, report_notified_at timestamptz, primary key (id),
  check (status = any (array['open','answered','dismissed'])), check (suggestion_confidence = any (array['high','low','none'])));
create unique index knowledge_gaps_open_question_idx on public.knowledge_gaps (business_id, question_key) where status = 'open';
create table public.knowledge_items (id uuid default gen_random_uuid() not null, business_id uuid not null, kind text default 'faq' not null, title text not null,
  question text, answer text not null, status text default 'processing' not null, version integer default 1 not null, error text, gap_id uuid, created_by uuid,
  approved_by uuid, approved_at timestamptz, ready_at timestamptz, created_at timestamptz default now() not null, updated_at timestamptz default now() not null,
  source_page_id uuid, source_url text, source_key text, conflicts_with uuid, source_stale boolean default false not null, sync_attempts integer default 0 not null,
  search tsvector generated always as (to_tsvector('english'::regconfig, ((((coalesce(title, '') || ' ') || coalesce(question, '')) || ' ') || coalesce(answer, '')))) stored,
  primary key (id));
create table public.lead_questions (id uuid default gen_random_uuid() not null, business_id uuid not null, key text not null, question text not null,
  required boolean default false not null, qualifies_when jsonb, sort_order integer default 0 not null, is_active boolean default true not null, primary key (id));
create table public.lead_rules (id uuid default gen_random_uuid() not null, business_id uuid not null, name text not null, sort_order integer default 0 not null,
  match jsonb default '{}'::jsonb not null, assign_to uuid, set_priority text, is_active boolean default true not null, created_at timestamptz default now() not null,
  primary key (id), check (set_priority = any (array['normal','high','urgent'])));
create table public.platform_settings (key text not null, value jsonb not null, updated_at timestamptz default now() not null, primary key (key));
create table public.staff_members (id uuid default gen_random_uuid() not null, business_id uuid not null, name text not null, title text, phone text, email text,
  color text default '#2563EB' not null, is_active boolean default true not null, working_hours jsonb default '{}'::jsonb not null,
  sort_order integer default 0 not null, created_at timestamptz default now() not null, updated_at timestamptz default now() not null, primary key (id));
create table public.staff_notifications (id uuid default gen_random_uuid() not null, business_id uuid not null, user_id uuid, kind text not null,
  severity text default 'info' not null, title text not null, body text, page_key text, entity_id uuid, delivery_status text default 'pending' not null,
  delivery_error text, delivered_at timestamptz, read_at timestamptz, created_at timestamptz default now() not null, claimed_at timestamptz, sms_status text,
  sms_claimed_at timestamptz, primary key (id));
-- Supabase API roles (already present in this local cluster)
grant usage on schema public, auth to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant select on all tables in schema public to authenticated;
