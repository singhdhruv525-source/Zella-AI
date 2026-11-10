create table public.activation_tests (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  ok boolean not null,
  detail text,
  created_at timestamp with time zone default now() not null
);
create table public.admin_alert_prefs (
  user_id uuid not null,
  email_enabled boolean default true not null,
  updated_at timestamp with time zone default now() not null
);
create table public.agent_config_versions (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  agent_id uuid not null,
  version integer not null,
  config jsonb not null,
  status text default 'draft'::text not null,
  validation_errors jsonb default '[]'::jsonb not null,
  sync_status text default 'none'::text not null,
  sync_error text,
  created_by uuid,
  published_by uuid,
  published_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.ai_agent_configs (
  id uuid default gen_random_uuid() not null,
  agent_id uuid not null,
  system_prompt text,
  personality text,
  tone text,
  goals jsonb default '[]'::jsonb not null,
  capabilities jsonb default '[]'::jsonb not null,
  knowledge_base jsonb default '{}'::jsonb not null,
  escalation_rules jsonb default '{}'::jsonb not null,
  appointment_rules jsonb default '{}'::jsonb not null,
  voice_config jsonb default '{}'::jsonb not null,
  business_context jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.ai_agents (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  name text not null,
  agent_type text not null,
  description text,
  status text default 'active'::text not null,
  channels text[] default '{}'::text[] not null,
  is_default boolean default false not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.ai_answer_reports (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  call_id uuid,
  reported_by uuid,
  what_was_wrong text not null,
  correct_answer text,
  status text default 'open'::text not null,
  knowledge_item_id uuid,
  created_at timestamp with time zone default now() not null
);
create table public.ai_eval_cases (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  question text not null,
  expect_contains text[] default '{}'::text[] not null,
  expect_none boolean default false not null,
  created_at timestamp with time zone default now() not null
);
create table public.ai_response_samples (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  call_id uuid not null,
  verdict text,
  note text,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.ai_tool_calls (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  provider_call_id text,
  tool text not null,
  idempotency_key text,
  arg_keys text[] default '{}'::text[] not null,
  status text default 'started'::text not null,
  result_status text,
  verified boolean,
  error text,
  result jsonb,
  created_at timestamp with time zone default now() not null,
  finished_at timestamp with time zone
);
create table public.appointment_reminders (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  appointment_id uuid not null,
  customer_id uuid,
  kind text not null,
  channel text default 'sms'::text not null,
  hours_before numeric,
  reason text,
  due_at timestamp with time zone not null,
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  sent_at timestamp with time zone,
  error text,
  created_at timestamp with time zone default now() not null
);
create table public.appointment_reschedule_links (
  id uuid default gen_random_uuid() not null,
  appointment_id uuid not null,
  business_id uuid not null,
  token_hash text not null,
  created_at timestamp with time zone default now() not null,
  last_used_at timestamp with time zone,
  uses integer default 0 not null,
  purpose text default 'reschedule'::text not null,
  expires_at timestamp with time zone
);
create table public.appointments (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  assigned_to uuid,
  title text not null,
  description text,
  appointment_type text,
  status text default 'scheduled'::text not null,
  start_time timestamp with time zone not null,
  end_time timestamp with time zone not null,
  timezone text default 'America/New_York'::text not null,
  location text,
  meeting_url text,
  external_event_id text,
  reminder_sent boolean default false not null,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  checked_in_at timestamp with time zone,
  internal_notes text,
  party_size integer,
  staff_id uuid,
  booking_state text default 'confirmed'::text not null,
  hold_expires_at timestamp with time zone,
  original_start_time timestamp with time zone,
  rescheduled_at timestamp with time zone,
  reschedule_count integer default 0 not null,
  reschedule_requested_by text,
  cancelled_at timestamp with time zone,
  cancel_reason text,
  conflict_note text,
  arrived_at timestamp with time zone,
  in_service_at timestamp with time zone,
  attendance_source text,
  attendance_by uuid,
  attendance_note text
);
create table public.assignment_rules (
  business_id uuid not null,
  mode text default 'round_robin'::text not null,
  roles text[] default ARRAY['owner'::text, 'admin'::text, 'manager'::text, 'staff'::text] not null,
  unassigned_alert_minutes integer default 10 not null,
  updated_at timestamp with time zone default now() not null
);
create table public.audit_logs (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  user_id uuid,
  action text not null,
  entity_type text,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamp with time zone default now() not null
);
create table public.automation_dead_letters (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  source_table text not null,
  source_id uuid not null,
  event_id uuid,
  reason text not null,
  error_category text,
  status text default 'open'::text not null,
  created_at timestamp with time zone default now() not null,
  resolved_by uuid,
  resolved_at timestamp with time zone
);
create table public.automation_events (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  event_type text not null,
  schema_version integer default 1 not null,
  source text not null,
  provider_event_id text,
  idempotency_key text not null,
  correlation_id uuid default gen_random_uuid() not null,
  causation_id uuid,
  payload jsonb default '{}'::jsonb not null,
  status text default 'received'::text not null,
  attempts integer default 0 not null,
  next_attempt_at timestamp with time zone,
  claimed_at timestamp with time zone,
  error_category text,
  error_message text,
  received_at timestamp with time zone default now() not null,
  processed_at timestamp with time zone
);
create table public.automation_runs (
  id uuid default gen_random_uuid() not null,
  automation_id uuid not null,
  business_id uuid not null,
  status text default 'running'::text not null,
  trigger_data jsonb default '{}'::jsonb not null,
  execution_log jsonb default '[]'::jsonb not null,
  error_message text,
  started_at timestamp with time zone default now() not null,
  completed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  customer_id uuid,
  current_action_index integer default 0 not null,
  next_run_at timestamp with time zone,
  attempt_count integer default 0 not null,
  last_action_status text
);
create table public.automations (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  name text not null,
  description text,
  trigger_type text not null,
  status text default 'active'::text not null,
  trigger_config jsonb default '{}'::jsonb not null,
  actions jsonb default '[]'::jsonb not null,
  conditions jsonb default '[]'::jsonb not null,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  paused_by_suspension boolean default false not null
);
create table public.billing_events (
  id uuid default gen_random_uuid() not null,
  provider text not null,
  external_event_id text not null,
  type text not null,
  business_id uuid,
  subscription_id uuid,
  data jsonb default '{}'::jsonb not null,
  status text default 'processed'::text not null,
  error text,
  received_at timestamp with time zone default now() not null
);
create table public.blocked_times (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  title text default 'Blocked'::text not null,
  reason text,
  start_time timestamp with time zone not null,
  end_time timestamp with time zone not null,
  all_day boolean default false not null,
  staff_id uuid,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  source text,
  external_id text,
  connection_id uuid
);
create table public.business_closures (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  starts_on date not null,
  ends_on date not null,
  label text default 'Closed'::text not null,
  opens time without time zone,
  closes time without time zone,
  created_at timestamp with time zone default now() not null
);
create table public.business_hours (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  weekday smallint not null,
  opens time without time zone not null,
  closes time without time zone not null,
  created_at timestamp with time zone default now() not null
);
create table public.business_invitations (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  email text not null,
  owner_name text not null,
  invited_by uuid not null,
  status text default 'pending'::text not null,
  auth_user_id uuid,
  invited_at timestamp with time zone,
  accepted_at timestamp with time zone,
  expires_at timestamp with time zone,
  last_error text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  reminder_count integer default 0 not null,
  last_reminded_at timestamp with time zone,
  role text default 'owner'::text not null
);
create table public.business_languages (
  business_id uuid not null,
  primary_language text default 'en-US'::text not null,
  extra_languages text[] default '{}'::text[] not null,
  greeting text,
  updated_by uuid,
  updated_at timestamp with time zone default now() not null
);
create table public.business_members (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  user_id uuid not null,
  role text default 'staff'::text not null,
  status text default 'active'::text not null,
  created_at timestamp with time zone default now() not null,
  accepts_work boolean default true not null,
  away_until timestamp with time zone,
  last_assigned_at timestamp with time zone,
  sms_alerts boolean default true not null
);
create table public.business_modules (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  module_id uuid not null,
  enabled boolean default true not null,
  configuration jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table public.business_phone_numbers (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  e164 text not null,
  vapi_phone_number_id text,
  label text,
  status text default 'active'::text not null,
  created_at timestamp with time zone default now() not null
);
create table public.business_usage_preferences (
  business_id uuid not null,
  notify_thresholds integer[] default '{70,90,100}'::integer[] not null,
  overage_mode text default 'stop'::text not null,
  spend_limit_cents bigint,
  fallback text default 'take_message'::text not null,
  authorized_by uuid,
  authorized_at timestamp with time zone,
  notified jsonb default '{}'::jsonb not null,
  updated_at timestamp with time zone default now() not null
);
create table public.business_verification_documents (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  kind text not null,
  file_path text not null,
  file_name text not null,
  mime_type text not null,
  size_bytes integer not null,
  status text default 'pending_review'::text not null,
  review_note text,
  uploaded_by uuid,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.business_voice (
  business_id uuid not null,
  voice_id text not null,
  updated_by uuid,
  updated_at timestamp with time zone default now() not null
);
create table public.businesses (
  id uuid default gen_random_uuid() not null,
  name text not null,
  legal_name text,
  industry_id uuid,
  business_type text,
  website text,
  email text,
  phone text,
  address_line_1 text,
  address_line_2 text,
  city text,
  state text,
  postal_code text,
  country text default 'US'::text,
  timezone text default 'America/New_York'::text,
  logo_url text,
  onboarding_status text default 'started'::text not null,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  terminology_overrides jsonb default '{}'::jsonb not null,
  setup_data jsonb default '{}'::jsonb not null,
  suspended_at timestamp with time zone,
  suspension_reason text,
  cancel_at timestamp with time zone,
  cancel_requested_at timestamp with time zone,
  cancellation_reason text,
  cancelled_at timestamp with time zone,
  retention_until timestamp with time zone,
  inbound_email_token text default encode(extensions.gen_random_bytes(16), 'hex'::text),
  business_size text,
  description text,
  alternate_phone text
);
create table public.calendar_connections (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  provider text default 'google'::text not null,
  status text default 'active'::text not null,
  calendar_id text default 'primary'::text not null,
  account_email text,
  vault_secret_name text,
  connected_at timestamp with time zone default now() not null,
  last_pushed_at timestamp with time zone,
  last_pulled_at timestamp with time zone,
  busy_refresh_due_at timestamp with time zone,
  last_error text
);
create table public.calendar_sync_queue (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  appointment_id uuid not null,
  action text not null,
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  due_at timestamp with time zone default now() not null,
  claimed_at timestamp with time zone,
  event_id text,
  error text,
  created_at timestamp with time zone default now() not null,
  completed_at timestamp with time zone
);
create table public.call_insights (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  call_id uuid not null,
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  claimed_at timestamp with time zone,
  intent text,
  sentiment text,
  urgency text,
  summary text,
  details jsonb default '{}'::jsonb not null,
  unresolved jsonb default '[]'::jsonb not null,
  model text,
  error text,
  review_status text default 'new'::text not null,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  processed_at timestamp with time zone
);
create table public.call_messages (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  call_id uuid,
  customer_id uuid,
  kind text default 'message'::text not null,
  caller_name text,
  caller_phone text,
  message text not null,
  after_hours boolean default false not null,
  status text default 'new'::text not null,
  handled_by uuid,
  handled_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.callback_attempts (
  id uuid default gen_random_uuid() not null,
  callback_id uuid not null,
  business_id uuid not null,
  attempt_no integer not null,
  attempted_at timestamp with time zone default now() not null,
  outcome text not null,
  provider_ref text,
  error text,
  notes text,
  next_attempt_at timestamp with time zone,
  initiated_by text default 'system'::text not null
);
create table public.callbacks (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  call_id uuid,
  appointment_id uuid,
  reason text default 'other'::text not null,
  priority text default 'normal'::text not null,
  status text default 'new'::text not null,
  contact_number text,
  summary text,
  preferred_at timestamp with time zone,
  due_at timestamp with time zone,
  assigned_to uuid,
  assigned_team text,
  auto_call boolean default false not null,
  attempts integer default 0 not null,
  max_attempts integer default 3 not null,
  retry_delay_minutes integer default 120 not null,
  outcome text,
  note text,
  locked_at timestamp with time zone,
  created_by text default 'ai'::text not null,
  completed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  overdue_notified_at timestamp with time zone,
  overdue_escalated_at timestamp with time zone,
  reminder_sent_at timestamp with time zone
);
create table public.calls (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  conversation_id uuid,
  direction text not null,
  status text default 'initiated'::text not null,
  from_number text,
  to_number text,
  started_at timestamp with time zone,
  answered_at timestamp with time zone,
  ended_at timestamp with time zone,
  duration_seconds integer,
  recording_url text,
  transcript text,
  ai_handled boolean default false not null,
  external_call_id text,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  needs_human boolean default false not null,
  escalation_reason text,
  escalated_at timestamp with time zone,
  escalation_resolved_at timestamp with time zone,
  escalation_resolved_by uuid,
  summary text,
  transfer_status text,
  failure_reason text,
  failure_context jsonb,
  assigned_to uuid,
  outcome text,
  outcome_note text,
  outcome_at timestamp with time zone,
  escalation_acknowledged_at timestamp with time zone,
  escalation_acknowledged_by uuid,
  escalation_reminded_at timestamp with time zone
);
create table public.contact_consents (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  phone_digits text,
  email_lower text,
  channel text not null,
  purpose text default 'marketing'::text not null,
  status text not null,
  source text not null,
  keyword text,
  evidence jsonb default '{}'::jsonb not null,
  recorded_by uuid,
  recorded_at timestamp with time zone default clock_timestamp() not null
);
create table public.conversation_messages (
  id uuid default gen_random_uuid() not null,
  conversation_id uuid not null,
  sender_type text not null,
  message_type text default 'text'::text not null,
  content text,
  external_message_id text,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table public.conversation_notes (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  conversation_id uuid not null,
  author_id uuid,
  author_name text,
  body text not null,
  created_at timestamp with time zone default now() not null
);
create table public.conversations (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  channel text not null,
  status text default 'open'::text not null,
  subject text,
  assigned_to uuid,
  ai_handled boolean default false not null,
  last_message_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  priority text default 'normal'::text not null,
  last_read_at timestamp with time zone,
  last_inbound_at timestamp with time zone,
  handover_at timestamp with time zone
);
create table public.crm_record_events (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  record_id uuid not null,
  kind text not null,
  detail text,
  actor uuid,
  created_at timestamp with time zone default now() not null
);
create table public.crm_record_types (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  key text not null,
  singular text not null,
  plural text not null,
  icon text default 'folder'::text not null,
  title_label text default 'Name'::text not null,
  link_person boolean default true not null,
  statuses jsonb not null,
  closed_statuses text[] default '{}'::text[] not null,
  fields jsonb default '[]'::jsonb not null,
  columns text[] default '{}'::text[] not null,
  notice text,
  enabled boolean default true not null,
  "position" integer default 0 not null,
  preset_key text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.crm_records (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  type_key text not null,
  title text not null,
  status text not null,
  customer_id uuid,
  assigned_to uuid,
  due_at timestamp with time zone,
  data jsonb default '{}'::jsonb not null,
  unique_key text,
  source text default 'staff'::text not null,
  created_by uuid,
  closed_at timestamp with time zone,
  archived_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.crm_tasks (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  kind text default 'follow_up'::text not null,
  title text not null,
  body text,
  priority text default 'normal'::text not null,
  status text default 'open'::text not null,
  due_at timestamp with time zone,
  assigned_to uuid,
  source text default 'automation'::text not null,
  entity_id uuid,
  escalated_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  overdue_notified_at timestamp with time zone
);
create table public.cross_sell_rules (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  after_service text not null,
  suggestion text not null,
  delay_days integer default 14 not null,
  active boolean default true not null,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.customer_requests (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  call_id uuid,
  kind text not null,
  summary text not null,
  source text default 'staff'::text not null,
  status text default 'open'::text not null,
  priority text default 'normal'::text not null,
  assigned_to uuid,
  due_at timestamp with time zone not null,
  resolution_note text,
  resolved_at timestamp with time zone,
  overdue_notified_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.customers (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  first_name text,
  last_name text,
  email text,
  phone text,
  company_name text,
  status text default 'active'::text not null,
  source text,
  notes text,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  do_not_call boolean default false not null,
  do_not_sms boolean default false not null,
  do_not_email boolean default false not null,
  preferred_contact_method text,
  last_contacted_at timestamp with time zone,
  do_not_contact boolean default false not null,
  tags text[] default '{}'::text[] not null,
  date_of_birth date,
  address text,
  preferred_contact text,
  lead_stage text,
  assigned_to uuid,
  priority text,
  qualification jsonb default '{}'::jsonb not null,
  qualification_result text,
  contact_deadline_at timestamp with time zone,
  next_follow_up_at timestamp with time zone,
  lost_reason text,
  lost_at timestamp with time zone,
  reactivate_after timestamp with time zone,
  converted_at timestamp with time zone,
  email_suppressed_at timestamp with time zone,
  email_suppressed_reason text,
  preferred_channel text
);
create table public.data_rights_requests (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  kind text not null,
  requester_name text,
  requester_contact text,
  note text,
  status text default 'open'::text not null,
  due_at timestamp with time zone default (now() + '30 days'::interval) not null,
  reminded_at timestamp with time zone,
  created_by uuid,
  handled_by uuid,
  handled_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.duplicate_reviews (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  incoming jsonb not null,
  status text default 'open'::text not null,
  resolved_by uuid,
  resolved_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.email_events (
  id uuid default gen_random_uuid() not null,
  provider_event_id text not null,
  type text not null,
  email_message_id uuid,
  business_id uuid,
  to_email text,
  detail jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table public.email_messages (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  conversation_id uuid,
  direction text not null,
  status text default 'queued'::text not null,
  from_email text,
  to_email text,
  cc text,
  bcc text,
  subject text,
  body_text text,
  body_html text,
  external_message_id text,
  sent_at timestamp with time zone,
  delivered_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.email_unsubscribe_tokens (
  token text default encode(gen_random_bytes(16), 'hex'::text) not null,
  business_id uuid not null,
  customer_id uuid not null,
  created_at timestamp with time zone default now() not null
);
create table public.followup_tasks (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  appointment_id uuid,
  call_id uuid,
  kind text not null,
  channel text default 'call'::text not null,
  due_at timestamp with time zone not null,
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  max_attempts integer default 2 not null,
  outcome text,
  outcome_notes text,
  provider_call_id text,
  claimed_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  entity_ref uuid,
  vars jsonb default '{}'::jsonb not null
);
create table public.industries (
  id uuid default gen_random_uuid() not null,
  name text not null,
  slug text not null,
  description text,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null
);
create table public.industry_automation_defaults (
  industry_id uuid not null,
  trigger_type text not null,
  enabled boolean default true not null,
  config jsonb default '{}'::jsonb not null
);
create table public.industry_automation_presets (
  id uuid default gen_random_uuid() not null,
  industry_key text not null,
  name text not null,
  checklist_no integer,
  description text,
  trigger_type text not null,
  trigger_config jsonb not null
);
create table public.industry_automation_runs (
  automation_id uuid not null,
  record_id uuid not null,
  step text not null,
  ran_at timestamp with time zone default now() not null
);
create table public.industry_configurations (
  id uuid default gen_random_uuid() not null,
  industry_id uuid not null,
  terminology jsonb default '{}'::jsonb not null,
  statuses jsonb default '{}'::jsonb not null,
  features jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.industry_crm_presets (
  key text not null,
  match text[] not null,
  config jsonb not null,
  updated_at timestamp with time zone default now() not null
);
create table public.industry_modules (
  id uuid default gen_random_uuid() not null,
  industry_id uuid not null,
  name text not null,
  slug text not null,
  description text,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null
);
create table public.integration_secrets (
  integration_id uuid not null,
  credentials jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.integrations (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  provider text not null,
  integration_type text not null,
  status text default 'active'::text not null,
  account_email text,
  external_account_id text,
  credentials jsonb default '{}'::jsonb not null,
  configuration jsonb default '{}'::jsonb not null,
  last_synced_at timestamp with time zone,
  error_message text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  last_error text,
  last_checked_at timestamp with time zone,
  error_count integer default 0 not null
);
create table public.knowledge_gaps (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  call_id uuid,
  customer_id uuid,
  question text not null,
  question_key text not null,
  times_asked integer default 1 not null,
  status text default 'open'::text not null,
  knowledge_item_id uuid,
  notified_at timestamp with time zone,
  resolved_by uuid,
  resolved_at timestamp with time zone,
  first_asked_at timestamp with time zone default now() not null,
  last_asked_at timestamp with time zone default now() not null,
  suggested_title text,
  suggested_answer text,
  suggested_kind text,
  suggestion_source text,
  suggestion_confidence text,
  suggestion_attempts integer default 0 not null,
  suggested_at timestamp with time zone,
  repeat_notified_at timestamp with time zone,
  report_notified_at timestamp with time zone
);
create table public.knowledge_items (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  kind text default 'faq'::text not null,
  title text not null,
  question text,
  answer text not null,
  status text default 'processing'::text not null,
  version integer default 1 not null,
  error text,
  gap_id uuid,
  created_by uuid,
  approved_by uuid,
  approved_at timestamp with time zone,
  ready_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  source_page_id uuid,
  source_url text,
  source_key text,
  conflicts_with uuid,
  source_stale boolean default false not null,
  sync_attempts integer default 0 not null,
  search tsvector generated always as (to_tsvector('english'::regconfig, ((((COALESCE(title, ''::text) || ' '::text) || COALESCE(question, ''::text)) || ' '::text) || COALESCE(answer, ''::text)))) stored
);
create table public.knowledge_versions (
  id uuid default gen_random_uuid() not null,
  item_id uuid not null,
  business_id uuid not null,
  version integer not null,
  title text,
  question text,
  answer text,
  status text,
  changed_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.lead_questions (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  key text not null,
  question text not null,
  required boolean default false not null,
  qualifies_when jsonb,
  sort_order integer default 0 not null,
  is_active boolean default true not null
);
create table public.lead_rules (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  name text not null,
  sort_order integer default 0 not null,
  match jsonb default '{}'::jsonb not null,
  assign_to uuid,
  set_priority text,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null
);
create table public.lead_submissions (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  form_id uuid,
  kind text not null,
  channel text default 'website'::text not null,
  status text not null,
  customer_id uuid,
  callback_id uuid,
  source jsonb default '{}'::jsonb not null,
  summary text,
  urgent boolean default false not null,
  created_at timestamp with time zone default now() not null
);
create table public.legal_acceptances (
  id uuid default gen_random_uuid() not null,
  document_id uuid not null,
  business_id uuid,
  user_id uuid not null,
  accepted_at timestamp with time zone default now() not null
);
create table public.legal_documents (
  id uuid default gen_random_uuid() not null,
  kind text not null,
  version text not null,
  title text not null,
  body text default ''::text not null,
  status text default 'draft'::text not null,
  requires_acceptance boolean default false not null,
  effective_at timestamp with time zone,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  published_by uuid,
  published_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.live_notices (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  kind text not null,
  message text not null,
  ends_at timestamp with time zone not null,
  created_by uuid,
  cleared_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.message_drafts (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid not null,
  body text not null,
  reason text,
  entity_id uuid,
  status text default 'pending'::text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.message_templates (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  industry_id uuid,
  key text not null,
  channel text not null,
  purpose text default 'transactional'::text not null,
  locale text default 'en-US'::text not null,
  subject text,
  body text not null,
  version integer default 1 not null,
  status text default 'active'::text not null,
  created_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.meta_connections (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  page_id text not null,
  page_name text,
  instagram_id text,
  whatsapp_phone_id text,
  waba_id text,
  status text default 'connected'::text not null,
  token_secret text,
  granted_permissions text[] default '{}'::text[] not null,
  call_consent_confirmed boolean default false not null,
  auto_acknowledge boolean default true not null,
  comment_keywords text[] default '{}'::text[] not null,
  last_checked_at timestamp with time zone,
  next_check_at timestamp with time zone default now() not null,
  last_error text,
  created_at timestamp with time zone default now() not null,
  qualify_flow boolean default false not null
);
create table public.meta_contacts (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  channel text not null,
  external_id text not null,
  display_name text,
  customer_id uuid,
  conversation_id uuid,
  last_ack_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.meta_events (
  id uuid default gen_random_uuid() not null,
  event_key text not null,
  kind text not null,
  page_id text,
  business_id uuid,
  status text default 'pending'::text not null,
  payload jsonb default '{}'::jsonb not null,
  attempts integer default 0 not null,
  next_try_at timestamp with time zone default now() not null,
  last_error text,
  claimed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.meta_outbox (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  page_id text not null,
  channel text not null,
  kind text default 'message'::text not null,
  recipient text not null,
  text_body text not null,
  template_name text,
  conversation_id uuid,
  status text default 'queued'::text not null,
  attempts integer default 0 not null,
  next_try_at timestamp with time zone default now() not null,
  claimed_at timestamp with time zone,
  external_id text,
  last_error text,
  created_at timestamp with time zone default now() not null,
  template_language text
);
create table public.meta_templates (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  name text not null,
  language text default 'en_US'::text not null,
  category text,
  body text,
  status text default 'unknown'::text not null,
  synced_at timestamp with time zone default now() not null
);
create table public.n8n_dispatch_state (
  workflow text not null,
  last_triggered_at timestamp with time zone,
  last_count integer default 0 not null,
  consecutive_same integer default 0 not null,
  triggers_total bigint default 0 not null
);
create table public.notification_preferences (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  user_id uuid not null,
  notification_type text not null,
  email_enabled boolean default true not null,
  sms_enabled boolean default false not null,
  push_enabled boolean default true not null,
  in_app_enabled boolean default true not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.notifications (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  user_id uuid,
  type text not null,
  title text not null,
  message text,
  is_read boolean default false not null,
  action_url text,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table public.offer_events (
  id uuid default gen_random_uuid() not null,
  offer_id uuid,
  business_id uuid,
  kind text not null,
  from_status text,
  to_status text,
  actor uuid,
  detail jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table public.offer_job_runs (
  id uuid default gen_random_uuid() not null,
  job text not null,
  trigger text default 'schedule'::text not null,
  status text default 'running'::text not null,
  processed integer default 0 not null,
  failures integer default 0 not null,
  error text,
  detail jsonb default '{}'::jsonb not null,
  started_by uuid,
  started_at timestamp with time zone default now() not null,
  finished_at timestamp with time zone
);
create table public.offer_redemptions (
  id uuid default gen_random_uuid() not null,
  offer_id uuid not null,
  business_id uuid not null,
  status text default 'pending'::text not null,
  source text not null,
  idempotency_key text not null,
  terms jsonb default '{}'::jsonb not null,
  discount_cents bigint,
  payment_id uuid,
  hold_until timestamp with time zone,
  claimed_by uuid,
  note text,
  created_at timestamp with time zone default now() not null,
  confirmed_at timestamp with time zone,
  ended_at timestamp with time zone,
  updated_at timestamp with time zone default now() not null
);
create table public.offer_rules (
  key text not null,
  enabled boolean default false not null,
  config jsonb default '{}'::jsonb not null,
  updated_by uuid,
  updated_at timestamp with time zone default now() not null
);
create table public.offers (
  id uuid default gen_random_uuid() not null,
  name text not null,
  description text,
  internal_note text,
  offer_type text default 'percent_discount'::text not null,
  status text default 'draft'::text not null,
  discount_kind text default 'percent'::text not null,
  percent_off_bp integer,
  amount_off_cents bigint,
  currency text default 'usd'::text not null,
  duration text default 'once'::text not null,
  duration_months integer,
  timezone text default 'America/New_York'::text not null,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  eligibility jsonb default '{"match": "all", "rules": []}'::jsonb not null,
  max_redemptions integer,
  max_per_business integer default 1 not null,
  code text,
  code_case_sensitive boolean default false not null,
  stackable boolean default false not null,
  channels text[] default ARRAY['dashboard'::text] not null,
  needs_approval boolean default false not null,
  created_by uuid,
  submitted_by uuid,
  submitted_at timestamp with time zone,
  approved_by uuid,
  approved_at timestamp with time zone,
  activated_at timestamp with time zone,
  paused_at timestamp with time zone,
  expired_at timestamp with time zone,
  archived_at timestamp with time zone,
  version integer default 1 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.on_call_reminders_sent (
  shift_id uuid not null,
  starts_at timestamp with time zone not null,
  sent_at timestamp with time zone default now() not null
);
create table public.on_call_settings (
  business_id uuid not null,
  enabled boolean default false not null,
  scope text default 'after_hours'::text not null,
  updated_by uuid,
  updated_at timestamp with time zone default now() not null
);
create table public.on_call_shifts (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  staff_id uuid not null,
  kind text not null,
  weekday smallint,
  starts time without time zone,
  ends time without time zone,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  note text,
  created_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.payments (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  subscription_id uuid,
  amount numeric(10,2) not null,
  currency text default 'USD'::text not null,
  status text default 'pending'::text not null,
  provider text,
  external_payment_id text,
  payment_method text,
  failure_reason text,
  paid_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.plans (
  id uuid default gen_random_uuid() not null,
  name text not null,
  slug text not null,
  description text,
  price_monthly numeric(10,2) default 0 not null,
  price_yearly numeric(10,2) default 0 not null,
  currency text default 'USD'::text not null,
  features jsonb default '{}'::jsonb not null,
  limits jsonb default '{}'::jsonb not null,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.platform_admins (
  user_id uuid not null,
  role text default 'super_admin'::text not null,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  created_by uuid
);
create table public.platform_alerts (
  id uuid default gen_random_uuid() not null,
  kind text not null,
  severity text default 'warning'::text not null,
  business_id uuid,
  title text not null,
  detail text,
  meta jsonb default '{}'::jsonb not null,
  dedupe_key text default ''::text not null,
  status text default 'open'::text not null,
  occurrences integer default 1 not null,
  first_seen_at timestamp with time zone default now() not null,
  last_seen_at timestamp with time zone default now() not null,
  notified_at timestamp with time zone,
  acknowledged_by uuid,
  acknowledged_at timestamp with time zone,
  resolved_by uuid,
  resolved_at timestamp with time zone,
  resolution_note text
);
create table public.platform_incidents (
  id uuid default gen_random_uuid() not null,
  title text not null,
  detail text,
  status text default 'open'::text not null,
  notified_businesses integer default 0 not null,
  created_by uuid,
  resolution_note text,
  created_at timestamp with time zone default now() not null,
  resolved_at timestamp with time zone,
  is_public boolean default false not null,
  public_message text,
  component text
);
create table public.platform_role_permissions (
  role text not null,
  permission text not null,
  updated_by uuid,
  updated_at timestamp with time zone default now() not null
);
create table public.platform_settings (
  key text not null,
  value jsonb not null,
  updated_at timestamp with time zone default now() not null
);
create table public.profiles (
  id uuid not null,
  first_name text,
  last_name text,
  phone text,
  avatar_url text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  portal_id text
);
create table public.provider_health (
  provider text not null,
  ok boolean,
  detail text,
  checked_at timestamp with time zone,
  claimed_at timestamp with time zone,
  consecutive_failures integer default 0 not null,
  last_ok_at timestamp with time zone
);
create table public.provisioning_steps (
  business_id uuid not null,
  step text not null,
  status text default 'pending'::text not null,
  error text,
  updated_at timestamp with time zone default now() not null
);
create table public.quotes (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid not null,
  title text not null,
  status text default 'issued'::text not null,
  issued_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone,
  follow_ups_sent integer default 0 not null,
  max_follow_ups integer default 3 not null,
  follow_up_every_days integer default 3 not null,
  next_follow_up_at timestamp with time zone,
  closed_at timestamp with time zone,
  created_by uuid
);
create table public.rate_limits (
  key text not null,
  window_start timestamp with time zone not null,
  hits integer default 0 not null
);
create table public.review_sources (
  business_id uuid not null,
  provider text default 'google'::text not null,
  account_id text not null,
  location_id text not null,
  status text default 'active'::text not null,
  last_error text,
  consecutive_failures integer default 0 not null,
  last_fetched_at timestamp with time zone,
  next_fetch_at timestamp with time zone default now() not null,
  claimed_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.reviews (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  provider text not null,
  external_id text not null,
  site text,
  author_name text,
  rating smallint,
  body text,
  reviewed_at timestamp with time zone default now() not null,
  status text default 'drafted'::text not null,
  draft text,
  draft_source text,
  ai_status text default 'none'::text not null,
  ai_attempts integer default 0 not null,
  ai_claimed_at timestamp with time zone,
  reply text,
  existing_reply text,
  decided_by uuid,
  decided_at timestamp with time zone,
  post_attempts integer default 0 not null,
  post_claimed_at timestamp with time zone,
  post_error text,
  posted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.sensitive_approvals (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  action text not null,
  entity_id uuid,
  details jsonb default '{}'::jsonb not null,
  requested_by uuid,
  status text default 'pending'::text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone default (now() + '2 days'::interval) not null,
  used_at timestamp with time zone
);
create table public.sms_messages (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid,
  conversation_id uuid,
  direction text not null,
  status text default 'queued'::text not null,
  from_number text,
  to_number text,
  message_body text,
  external_message_id text,
  sent_at timestamp with time zone,
  delivered_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.social_flows (
  conversation_id uuid not null,
  business_id uuid not null,
  step text default 'ask_contact'::text not null,
  answers jsonb default '{}'::jsonb not null,
  offered jsonb default '[]'::jsonb not null,
  tries integer default 0 not null,
  updated_at timestamp with time zone default now() not null
);
create table public.spam_incident_events (
  id uuid default gen_random_uuid() not null,
  incident_id uuid not null,
  business_id uuid not null,
  kind text not null,
  actor uuid,
  from_status text,
  to_status text,
  note text,
  source_table text,
  source_id uuid,
  detail jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table public.spam_incidents (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  channel text not null,
  sender text not null,
  sender_display text,
  customer_id uuid,
  risk_score integer not null,
  risk_level text not null,
  reasons jsonb default '[]'::jsonb not null,
  action text not null,
  status text default 'new'::text not null,
  assigned_to uuid,
  occurrences integer default 1 not null,
  dedupe_key text not null,
  last_source_table text,
  last_source_id uuid,
  first_seen_at timestamp with time zone default now() not null,
  last_seen_at timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  workflow_status text default 'not_needed'::text not null,
  workflow_attempts integer default 0 not null,
  workflow_claim uuid,
  workflow_claimed_at timestamp with time zone,
  workflow_next_at timestamp with time zone,
  workflow_done_at timestamp with time zone,
  workflow_result jsonb default '{}'::jsonb not null
);
create table public.spam_list_entries (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  list text not null,
  channel text not null,
  value_type text not null,
  value text not null,
  reason text,
  source text default 'manual'::text not null,
  incident_id uuid,
  expires_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  removed_at timestamp with time zone,
  removed_by uuid
);
create table public.spam_settings (
  business_id uuid not null,
  enabled boolean default true not null,
  call_screening text default 'flag'::text not null,
  ai_spam_handling text default 'end_politely'::text not null,
  repeat_call_limit integer default 5 not null,
  repeat_window_minutes integer default 60 not null,
  sms_monitoring boolean default true not null,
  sms_flood_limit integer default 10 not null,
  email_monitoring boolean default true not null,
  email_flood_limit integer default 10 not null,
  booking_protection boolean default true not null,
  booking_daily_limit integer default 3 not null,
  auto_restrict boolean default true not null,
  notify_high_risk boolean default true not null,
  notify_medium boolean default false not null,
  weekly_report boolean default true not null,
  ai_review boolean default false not null,
  updated_at timestamp with time zone default now() not null,
  updated_by uuid
);
create table public.staff_handovers (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  from_user uuid,
  to_user uuid not null,
  note text,
  moved jsonb default '{}'::jsonb not null,
  created_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.staff_members (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  name text not null,
  title text,
  phone text,
  email text,
  color text default '#2563EB'::text not null,
  is_active boolean default true not null,
  working_hours jsonb default '{}'::jsonb not null,
  sort_order integer default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.staff_notifications (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  user_id uuid,
  kind text not null,
  severity text default 'info'::text not null,
  title text not null,
  body text,
  page_key text,
  entity_id uuid,
  delivery_status text default 'pending'::text not null,
  delivery_error text,
  delivered_at timestamp with time zone,
  read_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  claimed_at timestamp with time zone,
  sms_status text,
  sms_claimed_at timestamp with time zone
);
create table public.subscriptions (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  plan_id uuid not null,
  status text default 'trial'::text not null,
  billing_interval text default 'monthly'::text not null,
  provider text,
  external_subscription_id text,
  trial_start_at timestamp with time zone,
  trial_end_at timestamp with time zone,
  current_period_start timestamp with time zone,
  current_period_end timestamp with time zone,
  cancelled_at timestamp with time zone,
  expired_at timestamp with time zone,
  grace_period_end_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  status_changed_at timestamp with time zone default now() not null,
  past_due_since timestamp with time zone,
  trial_notice_days integer[] default '{}'::integer[] not null
);
create table public.support_tickets (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  created_by uuid,
  subject text not null,
  description text,
  status text default 'open'::text not null,
  priority text default 'normal'::text not null,
  category text,
  assigned_to uuid,
  resolved_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.time_off_requests (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  staff_id uuid not null,
  requested_by uuid,
  from_at timestamp with time zone not null,
  to_at timestamp with time zone not null,
  reason text,
  status text default 'pending'::text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  blocked_time_id uuid,
  created_at timestamp with time zone default now() not null
);
create table public.usage_processing_issues (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  call_id uuid,
  kind text not null,
  status text default 'open'::text not null,
  attempts integer default 0 not null,
  next_attempt_at timestamp with time zone default now() not null,
  last_error text,
  detail jsonb default '{}'::jsonb not null,
  escalated_at timestamp with time zone,
  resolved_at timestamp with time zone,
  resolution text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.usage_records (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  subscription_id uuid,
  usage_type text not null,
  quantity numeric(12,4) default 0 not null,
  unit text,
  period_start timestamp with time zone not null,
  period_end timestamp with time zone not null,
  source_id uuid,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  call_id uuid,
  provider_call_id text,
  provider_event_id text,
  idempotency_key text,
  entry_kind text default 'usage'::text not null,
  adjusts_record_id uuid,
  usage_category text,
  occurred_at timestamp with time zone,
  duration_seconds integer,
  billable_seconds integer,
  telephony_billed_seconds integer,
  included_minutes_consumed numeric(12,4),
  policy jsonb,
  period_source text,
  status text default 'recorded'::text not null,
  reconciliation_status text default 'ok'::text not null,
  processed_by text,
  updated_at timestamp with time zone default now() not null
);
create table public.usage_threshold_events (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  threshold_key text not null,
  period_key text not null,
  event_type text not null,
  usage_minutes numeric(12,4) not null,
  limit_minutes numeric(12,4),
  notification_id uuid,
  created_at timestamp with time zone default now() not null
);
create table public.usage_thresholds (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  measure text not null,
  value numeric(12,2) not null,
  event_type text not null,
  enabled boolean default true not null,
  created_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.vapi_request_receipts (
  signature_hash text not null,
  received_at timestamp with time zone default now() not null
);
create table public.voice_pricing (
  id uuid default gen_random_uuid() not null,
  provider text not null,
  component text default 'per_minute'::text not null,
  unit_cost numeric(12,6) not null,
  currency text default 'USD'::text not null,
  billing_increment_seconds integer default 60 not null,
  effective_from timestamp with time zone not null,
  note text,
  created_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.waitlist_entries (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  customer_id uuid not null,
  title text,
  duration_minutes integer default 30 not null,
  earliest_at timestamp with time zone,
  latest_at timestamp with time zone,
  staff_id uuid,
  notes text,
  status text default 'waiting'::text not null,
  offered_start timestamp with time zone,
  offered_end timestamp with time zone,
  offered_staff_id uuid,
  offer_expires_at timestamp with time zone,
  appointment_id uuid,
  created_at timestamp with time zone default now() not null
);
create table public.waitlist_offer_links (
  id uuid default gen_random_uuid() not null,
  entry_id uuid not null,
  business_id uuid not null,
  token_hash text not null,
  created_at timestamp with time zone default now() not null
);
create table public.website_forms (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  name text default 'Website'::text not null,
  public_key text default replace((gen_random_uuid())::text, '-'::text, ''::text) not null,
  allowed_origins text[] default '{}'::text[] not null,
  enabled boolean default true not null,
  created_at timestamp with time zone default now() not null
);
create table public.website_pages (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  source_id uuid not null,
  url text not null,
  status text default 'pending'::text not null,
  title text,
  content_hash text,
  text_excerpt text,
  http_status integer,
  fail_count integer default 0 not null,
  last_error text,
  found_via text default 'sitemap'::text not null,
  first_seen_at timestamp with time zone default now() not null,
  last_seen_at timestamp with time zone,
  last_fetched_at timestamp with time zone,
  last_ok_at timestamp with time zone,
  changed_at timestamp with time zone,
  next_fetch_at timestamp with time zone,
  claimed_at timestamp with time zone
);
create table public.website_sources (
  id uuid default gen_random_uuid() not null,
  business_id uuid not null,
  root_url text not null,
  host text not null,
  status text default 'pending_approval'::text not null,
  approved_by uuid,
  approved_at timestamp with time zone,
  auto_approve_new boolean default false not null,
  frequency_hours integer default 168 not null,
  max_pages integer default 25 not null,
  sitemap_urls text[] default '{}'::text[] not null,
  next_discovery_at timestamp with time zone,
  last_discovery_at timestamp with time zone,
  last_crawl_at timestamp with time zone,
  last_error text,
  created_at timestamp with time zone default now() not null
);
create table public.workflow_executions (
  id uuid default gen_random_uuid() not null,
  business_id uuid,
  workflow_key text not null,
  workflow_version text,
  event_id uuid,
  correlation_id uuid,
  status text default 'running'::text not null,
  current_step text,
  steps jsonb default '[]'::jsonb not null,
  provider_refs jsonb default '{}'::jsonb not null,
  retry_count integer default 0 not null,
  error_category text,
  error_message text,
  needs_manual boolean default false not null,
  started_at timestamp with time zone default now() not null,
  finished_at timestamp with time zone
);
create table public.zella_milestones (
  business_id uuid not null,
  key text not null,
  reached_at timestamp with time zone default now() not null
);
