-- =====================================================================================================================
-- Zella Voice: target database schema
-- =====================================================================================================================
-- What this is : the required database design of docs/ARCHITECTURE.md (§6 isolation, §7 domain model, §29 schema),
--                written as executable Postgres DDL for Supabase.
-- What it is NOT: a migration for the current production database. NEVER apply it to production. It is the target
--                the new build is created from (phase 2 of the build sequence, §24), one reviewed migration at a time.
-- How to check : sql/target/test.sh loads it into the isolated local test database and runs the three-business
--                isolation suite (sql/target/test_isolation.sql, architecture §6.12).
-- Rules        : ZELLA_VOICE_RULES.md (TEN-*, SEC-*, DB-*). Postgres 15+ (Supabase runs 17).
--
-- Conventions for every tenant-owned table (TEN-1, TEN-5, TEN-10, REQ-DB-ISO-*):
--   * id uuid primary key; business_id uuid NOT NULL references businesses; unique (business_id, id)
--   * every reference to another tenant table is a COMPOSITE foreign key (business_id, x_id), so a row can never
--     point at another business's row
--   * uniqueness on business data always includes business_id
--   * created_at / updated_at timestamptz (UTC)
--   * row-level security enabled; clients (role "authenticated") may only SELECT rows of businesses they are active
--     members of, with role limits on sensitive tables; ALL writes go through server-side functions (§30), which
--     check membership and role first. Clients never write tables directly.
--   * the anon role gets nothing.
-- Ownership scopes (TEN-10): tenant-owned (business_id NOT NULL), platform-owned (no business_id), mixed (scope column
-- with a check constraint tying scope to business_id).
-- =====================================================================================================================

begin;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;   -- uuid equality inside the booking exclusion constraint

-- Helper functions live in a schema the API never exposes.
create schema if not exists app_private;
revoke all on schema app_private from public;
grant usage on schema app_private to authenticated, service_role;

-- Zella Voice's own sales pipeline is a separate schema, never joined to tenant data (REQ-TEN-06).
create schema if not exists growth;
revoke all on schema growth from public, anon, authenticated;
grant usage on schema growth to service_role;

set local search_path = public, extensions;

-- =====================================================================================================================
-- 1. Platform-owned reference data (no business_id)
-- =====================================================================================================================

create table industries (
  key            text primary key check (key ~ '^[a-z0-9_]{2,40}$'),
  name           text not null,
  regulated      boolean not null default false,          -- healthcare, dental, legal, financial, insurance, childcare
  terminology    jsonb not null default '{}'::jsonb,       -- {"customer": "patient", "appointment": "visit", ...}
  defaults       jsonb not null default '{}'::jsonb,       -- capabilities, modules, message policy, safety lines
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table plans (                                      -- values are defined by the owner later (BIL-1, BIL-8)
  id             uuid primary key default gen_random_uuid(),
  key            text not null unique,
  name           text not null,
  active         boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table plan_limits (                                -- one row per plan dimension (§17.1)
  plan_id        uuid not null references plans(id) on delete cascade,
  dimension      text not null check (dimension in (
                   'ai_minutes_inbound','ai_minutes_outbound','callbacks_per_month','attempts_per_sequence',
                   'lead_sequences_per_month','sms_segments_per_month','emails_per_month','ai_conversations_per_month',
                   'ai_drafts_per_month','team_seats','phone_numbers','locations','languages','premium_voices','integrations')),
  limit_value    numeric,                                  -- null = unlimited for numeric dimensions
  feature_value  jsonb,                                    -- for feature dimensions, e.g. {"languages": ["en","es"]}
  primary key (plan_id, dimension)
);

create table platform_settings (                          -- live switches, ceilings, defaults (server only)
  key            text primary key,
  value          jsonb not null,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

create table platform_permissions (
  role           text not null check (role in ('zella_voice_owner','platform_operations','billing_admin','support_admin',
                                               'security_admin','read_only_admin','growth')),
  permission     text not null check (permission in ('businesses.view','businesses.manage','telephony.manage','comms.manage',
                   'ai.configure','integrations.manage','billing.view','billing.manage','plans.manage','support.manage',
                   'security.view','security.manage','audit.view','analytics.view','growth.manage','platform.owner')),
  primary key (role, permission)
);

create table platform_admins (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  role           text not null,
  active         boolean not null default true,
  mfa_required   boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table provider_health (
  provider       text primary key,
  status         text not null check (status in ('ok','degraded','down','unknown')),
  checked_at     timestamptz,
  detail         text
);

create table quarantined_events (                         -- unmapped or ambiguous provider events (TEN-12)
  id             uuid primary key default gen_random_uuid(),
  provider       text not null,
  provider_ref   text not null,
  reason         text not null check (reason in ('unmapped','ambiguous','bad_signature','malformed')),
  payload_ref    text,                                     -- pointer to stored raw event, never the content in logs
  resolved_at    timestamptz,
  resolution     text,
  created_at     timestamptz not null default now(),
  unique (provider, provider_ref)
);

create table platform_incidents (
  id             uuid primary key default gen_random_uuid(),
  severity       text not null check (severity in ('sev1','sev2','sev3')),
  title          text not null,
  public_message text,
  status         text not null default 'open' check (status in ('open','monitoring','resolved')),
  started_at     timestamptz not null default now(),
  resolved_at    timestamptz
);

-- =====================================================================================================================
-- 2. Tenancy: businesses, locations, members
-- =====================================================================================================================

create table businesses (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null check (length(name) between 1 and 200),
  industry_key       text not null references industries(key),
  status             text not null default 'draft'
                     check (status in ('draft','setup','testing','live','paused','suspended','cancelling','cancelled')),
  primary_time_zone  text not null default 'America/New_York',
  country            text not null default 'US' check (country ~ '^[A-Z]{2}$'),
  primary_language   text not null default 'en' check (primary_language in ('en','es')),
  plan_id            uuid references plans(id),
  creation_key       text unique,                          -- idempotent Create Business (no duplicates on double submit)
  created_by         uuid,                                 -- platform admin who created it (BIZ-9)
  cancelled_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table locations (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  name         text not null,
  address      jsonb not null default '{}'::jsonb,
  time_zone    text not null,
  status       text not null default 'active' check (status in ('active','inactive')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, name)
);

create table business_members (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  user_id      uuid not null references auth.users(id),
  role         text not null check (role in ('owner','admin','manager','staff','viewer')),
  status       text not null default 'active' check (status in ('invited','active','removed')),
  display_name text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, user_id)
);

create table member_locations (                           -- if a member has rows here, they only see these locations
  business_id  uuid not null,
  member_id    uuid not null,
  location_id  uuid not null,
  primary key (business_id, member_id, location_id),
  foreign key (business_id, member_id)   references business_members (business_id, id) on delete cascade,
  foreign key (business_id, location_id) references locations (business_id, id) on delete cascade
);

create table business_invitations (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  email        text not null check (email = lower(email) and email like '%@%'),
  role         text not null check (role in ('owner','admin','manager','staff','viewer')),
  token_hash   text not null unique,
  expires_at   timestamptz not null,
  status       text not null default 'pending' check (status in ('pending','sent','accepted','revoked','expired','failed')),
  invited_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id)
);
create unique index business_invitations_one_open on business_invitations (business_id, email) where status in ('pending','sent');

create table business_settings (
  business_id  uuid not null references businesses(id),
  key          text not null,
  value        jsonb not null,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (business_id, key)
);

create table transfer_destinations (                      -- who receives transferred calls (AI-20); numbers never reach the AI model
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  location_id  uuid,
  label        text not null,
  phone_e164   text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  member_id    uuid,
  hours        jsonb not null default '{}'::jsonb,       -- weekly schedule; empty = always
  priority     smallint not null default 1,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, location_id) references locations (business_id, id),
  foreign key (business_id, member_id)   references business_members (business_id, id)
);

-- =====================================================================================================================
-- 3. Customers, consent, leads
-- =====================================================================================================================

create table customers (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  first_name       text,
  last_name        text,
  lifecycle        text not null default 'lead' check (lifecycle in ('lead','customer','inactive')),
  lead_status      text check (lead_status in ('new','working','contacted','qualified','booked','converted',
                                               'not_interested','unreachable','lost')),
  source           text,
  owner_member_id  uuid,
  time_zone        text,
  language         text check (language in ('en','es')),
  do_not_contact   boolean not null default false,
  merged_into_id   uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, owner_member_id) references business_members (business_id, id),
  foreign key (business_id, merged_into_id)  references customers (business_id, id)
);
create index customers_lists on customers (business_id, lifecycle, lead_status);

create table customer_contacts (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references businesses(id),
  customer_id       uuid not null,
  kind              text not null check (kind in ('phone','email')),
  value_normalised  text not null,                       -- E.164 for phones, lower-case for emails
  is_primary        boolean not null default false,
  valid             boolean not null default true,
  created_at        timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, kind, value_normalised),         -- one person per contact value, per business (dedupe)
  foreign key (business_id, customer_id) references customers (business_id, id) on delete cascade
);

create table contact_consents (                           -- append-only history (PRV-6); per business (NN-8)
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  customer_id   uuid,
  address       text not null,                           -- normalised phone or email
  channel       text not null check (channel in ('call','sms','email')),
  purpose       text not null check (purpose in ('service','marketing')),
  status        text not null check (status in ('granted','withdrawn')),
  evidence      jsonb not null,                          -- text shown, version, source, form id, call id, ip...
  source        text not null,
  recorded_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id)
);
create index contact_consents_lookup on contact_consents (business_id, address, channel, purpose, recorded_at desc);

create table suppressions (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references businesses(id),
  channel             text not null check (channel in ('call','sms','email','all')),
  address_normalised  text not null,
  reason              text not null check (reason in ('opt_out','invalid','bounced','complaint','legal','do_not_contact')),
  created_at          timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, channel, address_normalised)
);

create table lead_events (                                -- every lead arrival, from every source, stored once
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  customer_id      uuid,
  source           text not null check (source in ('google_ads','meta','website_form','inbound_call','inbound_sms',
                                                   'inbound_email','manual','import','api')),
  source_ref       text,
  payload          jsonb not null,
  consent_evidence jsonb,
  idempotency_key  text not null,
  created_at       timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, idempotency_key),
  foreign key (business_id, customer_id) references customers (business_id, id)
);

create table customer_notes (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  customer_id  uuid not null,
  author_id    uuid,
  body         text not null,
  created_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id) on delete cascade,
  foreign key (business_id, author_id)   references business_members (business_id, id)
);

create table tags (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  name         text not null,
  unique (business_id, id),
  unique (business_id, name)
);

create table customer_tags (
  business_id  uuid not null,
  customer_id  uuid not null,
  tag_id       uuid not null,
  primary key (business_id, customer_id, tag_id),
  foreign key (business_id, customer_id) references customers (business_id, id) on delete cascade,
  foreign key (business_id, tag_id)      references tags (business_id, id) on delete cascade
);

-- =====================================================================================================================
-- 4. Voice: numbers, assistants, calls
-- =====================================================================================================================

create table phone_numbers (                              -- a dedicated Zella Voice number per business and location (COM-11)
  id                       uuid primary key default gen_random_uuid(),
  business_id              uuid not null references businesses(id),
  location_id              uuid not null,
  e164                     text not null unique check (e164 ~ '^\+[1-9][0-9]{7,14}$'),  -- one number → exactly one business
  provider                 text not null default 'telnyx',
  provider_ref             text,
  mode                     text not null check (mode in ('new_number','forwarding_target')),
  forwarded_from_e164      text check (forwarded_from_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  forwarding_verified_at   timestamptz,
  purpose                  text not null default 'both' check (purpose in ('inbound','outbound','both')),
  sms_registration_status  text not null default 'not_started'
                           check (sms_registration_status in ('not_started','pending','approved','rejected')),
  status                   text not null default 'pending' check (status in ('pending','active','released')),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, location_id) references locations (business_id, id),
  check (mode = 'new_number' or forwarded_from_e164 is not null)
);

create table assistants (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  location_id   uuid,
  kind          text not null check (kind in ('inbound','outbound')),
  provider_ref  text unique,                              -- provider assistant id → exactly one business
  version       integer not null default 1,
  config_hash   text,
  status        text not null default 'draft' check (status in ('draft','published','retired')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, location_id) references locations (business_id, id)
);

create table calls (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  location_id      uuid,
  customer_id      uuid,
  phone_number_id  uuid,
  direction        text not null check (direction in ('inbound','outbound')),
  from_e164        text,
  to_e164          text,
  provider_call_id text not null,
  status           text not null default 'started' check (status in ('started','ringing','in_progress','ended')),
  end_reason       text,
  classification   text check (classification in ('answered_ai_resolved','answered_ai_unresolved','answered_human',
                     'transfer_failed','abandoned_before_answer','not_answered','failed','voicemail_left','spam','unknown')),
  started_at       timestamptz,
  answered_at      timestamptz,
  ended_at         timestamptz,
  duration_s       integer check (duration_s >= 0),
  handled_by       text check (handled_by in ('ai','staff')),
  transfer_status  text check (transfer_status in ('not_needed','attempted','connected','failed','no_one_available')),
  summary          text,
  language         text,
  correlation_id   uuid not null default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, provider_call_id),
  foreign key (business_id, location_id)     references locations (business_id, id),
  foreign key (business_id, customer_id)     references customers (business_id, id),
  foreign key (business_id, phone_number_id) references phone_numbers (business_id, id)
);
create index calls_recent on calls (business_id, created_at desc);

create table call_tool_calls (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  call_id          uuid not null,
  tool             text not null,
  idempotency_key  text not null,
  arg_keys         text[] not null default '{}',
  status           text not null default 'running' check (status in ('running','done','failed')),
  result           jsonb,
  verified         boolean,
  created_at       timestamptz not null default now(),
  finished_at      timestamptz,
  unique (business_id, id),
  unique (business_id, idempotency_key),
  foreign key (business_id, call_id) references calls (business_id, id) on delete cascade
);

create table voicemails (                                 -- caller-chosen recorded message (AI-21), private, 30 days
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  call_id       uuid not null,
  customer_id   uuid,
  storage_path  text not null,
  transcript    text,
  duration_s    integer,
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, call_id)     references calls (business_id, id) on delete cascade,
  foreign key (business_id, customer_id) references customers (business_id, id),
  check (storage_path like business_id::text || '/%')
);

create table call_artifacts (                             -- recordings (off until legal review) and transcripts
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  call_id       uuid not null,
  kind          text not null check (kind in ('recording','transcript')),
  storage_path  text,
  content       text,
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, call_id, kind),
  foreign key (business_id, call_id) references calls (business_id, id) on delete cascade,
  check (storage_path is null or storage_path like business_id::text || '/%')
);

-- =====================================================================================================================
-- 5. Outreach: sequences, callbacks, attempts
-- =====================================================================================================================

create table sequences (                                  -- one missed-call or lead follow-up journey
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references businesses(id),
  customer_id       uuid not null,
  kind              text not null check (kind in ('missed_call','lead')),
  status            text not null default 'active'
                    check (status in ('active','paused','waiting_reply','completed','exhausted','stopped')),
  owner             text not null default 'ai' check (owner in ('ai','staff')),
  attempts_made     integer not null default 0 check (attempts_made >= 0),
  attempts_allowed  integer not null check (attempts_allowed >= 0),   -- from the plan, capped by the platform ceiling
  next_due_at       timestamptz,
  stop_reason       text,
  correlation_id    uuid not null default gen_random_uuid(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id),
  check (attempts_made <= attempts_allowed)
);
create unique index sequences_one_open on sequences (business_id, customer_id, kind)
  where status in ('active','paused','waiting_reply');

create table callbacks (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references businesses(id),
  location_id         uuid,
  sequence_id         uuid,
  customer_id         uuid,
  call_id             uuid,
  contact_e164        text,
  reason              text not null check (reason in ('missed_call','new_lead','needs_person','transfer_failed',
                                                      'requested','voicemail','anonymous_missed')),
  priority            text not null default 'normal' check (priority in ('normal','high','urgent')),
  status              text not null default 'open' check (status in ('open','scheduled','in_progress','paused',
                        'waiting_reply','needs_person','resolved','closed','cancelled')),
  assignee_member_id  uuid,
  due_at              timestamptz,
  outcome             text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, location_id)        references locations (business_id, id),
  foreign key (business_id, sequence_id)        references sequences (business_id, id),
  foreign key (business_id, customer_id)        references customers (business_id, id),
  foreign key (business_id, call_id)            references calls (business_id, id),
  foreign key (business_id, assignee_member_id) references business_members (business_id, id)
);
create index callbacks_queue on callbacks (business_id, status, due_at);

create table call_attempts (                              -- every attempt, traceable (REQ-OUT-20)
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id),
  callback_id           uuid not null,
  attempt_no            integer not null check (attempt_no >= 1),
  scheduled_at          timestamptz,
  started_at            timestamptz,
  from_e164             text,
  provider_call_id      text,
  provider_status       text,
  attempt_outcome       text check (attempt_outcome in ('scheduled','attempting','ringing','answered','no_answer','busy',
                          'voicemail','invalid_number','rejected','failed','unknown','cancelled','skipped')),
  conversation_outcome  text check (conversation_outcome in ('booked','resolved','callback_requested','message_taken',
                          'transferred','not_interested','opted_out','wrong_person','language_barrier','no_conversation',
                          'hung_up_early')),
  duration_s            integer,
  handler               text check (handler in ('ai','staff')),
  handler_ref           text,                            -- assistant version or member id
  summary               text,
  policy_decision       jsonb,                           -- which checks passed at claim time
  failure_reason        text,
  next_action           text,
  next_due_at           timestamptz,
  counts_toward_limit   boolean not null default true,   -- provider failures don't count (§13.7)
  correlation_id        uuid not null,
  created_at            timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, callback_id, attempt_no),
  unique (business_id, provider_call_id),
  foreign key (business_id, callback_id) references callbacks (business_id, id) on delete cascade
);

-- =====================================================================================================================
-- 6. Messaging
-- =====================================================================================================================

create table sender_identities (                          -- numbers and email senders registered to a business
  id                   uuid primary key default gen_random_uuid(),
  business_id          uuid not null references businesses(id),
  location_id          uuid,
  channel              text not null check (channel in ('sms','email')),
  value                text not null,
  registration_status  text not null default 'pending' check (registration_status in ('pending','approved','rejected')),
  created_at           timestamptz not null default now(),
  unique (business_id, id),
  unique (channel, value),                              -- a sender belongs to exactly one business
  foreign key (business_id, location_id) references locations (business_id, id)
);

create table message_templates (                          -- mixed scope: platform / industry defaults, business overrides
  id              uuid primary key default gen_random_uuid(),
  scope           text not null check (scope in ('platform','industry','business')),
  business_id     uuid references businesses(id),
  industry_key    text references industries(key),
  kind            text not null,
  channel         text not null check (channel in ('sms','email','voice')),
  language        text not null default 'en' check (language in ('en','es')),
  subject         text,
  body            text not null,
  protected_parts jsonb not null default '[]'::jsonb,   -- compliance text that must remain (REQ-MSG-06)
  version         integer not null default 1,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  check ((scope = 'business') = (business_id is not null)),
  check ((scope = 'industry') = (industry_key is not null))
);
create unique index message_templates_version on message_templates
  (scope, coalesce(business_id::text, ''), coalesce(industry_key, ''), kind, channel, language, version);

create table conversations (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references businesses(id),
  customer_id         uuid not null,
  channel             text not null check (channel in ('sms','email')),
  state               text not null default 'open' check (state in ('open','closed')),
  owner               text not null default 'ai' check (owner in ('ai','staff')),   -- staff takeover pauses the AI
  assignee_member_id  uuid,
  last_message_at     timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, customer_id)        references customers (business_id, id),
  foreign key (business_id, assignee_member_id) references business_members (business_id, id)
);
create unique index conversations_one_open on conversations (business_id, customer_id, channel) where state = 'open';

create table messages (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  conversation_id  uuid,
  customer_id      uuid,
  sender_id        uuid,
  channel          text not null check (channel in ('sms','email')),
  direction        text not null check (direction in ('outbound','inbound')),
  purpose          text not null check (purpose in ('service','marketing','reply','internal')),
  kind             text not null,
  template_id      uuid references message_templates(id),
  language         text,
  to_address       text not null,
  body             text,
  status           text not null check (status in ('scheduled','queued','attempting','provider_accepted','sent',
                     'delivered','failed','unknown','cancelled','skipped','dry_run','received')),
  status_reason    text,
  provider_id      text,
  delivered_at     timestamptz,
  dedupe_key       text not null,
  correlation_id   uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, dedupe_key),
  foreign key (business_id, conversation_id) references conversations (business_id, id),
  foreign key (business_id, customer_id)     references customers (business_id, id),
  foreign key (business_id, sender_id)       references sender_identities (business_id, id)
);
create index messages_customer on messages (business_id, customer_id, created_at desc);

-- =====================================================================================================================
-- 7. Scheduling: services, resources, appointments, reservations
-- =====================================================================================================================

create table services (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references businesses(id),
  name               text not null,
  duration_min       integer not null check (duration_min between 5 and 1440),
  price_minor        bigint check (price_minor >= 0),        -- entered by the business; integer minor units (DB-11)
  currency           text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  buffer_before_min  integer not null default 0 check (buffer_before_min >= 0),
  buffer_after_min   integer not null default 0 check (buffer_after_min >= 0),
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, name)
);

-- Resources are what a booking uses up. Several bookings at the same time are normal: two stylists, five technicians,
-- twenty restaurant tables are separate resources. capacity = how many units it can serve at once:
--   1  : exclusive (a stylist, a chair, a technician, one restaurant table holds one party)
--   >1 : shared (a stylist who can overlap 2 clients, a class with 12 spots, a dining area taking 40 covers)
create table resources (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  location_id  uuid not null,
  kind         text not null check (kind in ('staff','room','chair','table','dining_area','class','vehicle','equipment','technician')),
  member_id    uuid,
  name         text not null,
  capacity     integer not null default 1 check (capacity >= 1),
  seats_min    integer check (seats_min >= 1),            -- restaurant tables: party sizes this table fits
  seats_max    integer check (seats_max >= 1),
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, location_id, name),
  foreign key (business_id, location_id) references locations (business_id, id),
  foreign key (business_id, member_id)   references business_members (business_id, id),
  check (seats_min is null or seats_max is null or seats_min <= seats_max),
  check (kind <> 'table' or (seats_max is not null and capacity = 1))
);

-- Restaurant tables that can be joined for a larger party (e.g. T1 + T2 seat 8). Booking a combination reserves
-- every table in it, so each table's own exclusivity still applies.
create table table_combinations (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  location_id  uuid not null,
  name         text not null,
  seats_min    integer not null check (seats_min >= 1),
  seats_max    integer not null check (seats_max >= seats_min),
  active       boolean not null default true,
  unique (business_id, id),
  unique (business_id, location_id, name),
  foreign key (business_id, location_id) references locations (business_id, id)
);

create table table_combination_members (
  business_id     uuid not null,
  combination_id  uuid not null,
  resource_id     uuid not null,
  primary key (business_id, combination_id, resource_id),
  foreign key (business_id, combination_id) references table_combinations (business_id, id) on delete cascade,
  foreign key (business_id, resource_id)    references resources (business_id, id)
);

create table service_locations (
  business_id  uuid not null,
  service_id   uuid not null,
  location_id  uuid not null,
  primary key (business_id, service_id, location_id),
  foreign key (business_id, service_id)  references services (business_id, id) on delete cascade,
  foreign key (business_id, location_id) references locations (business_id, id) on delete cascade
);

create table service_resource_needs (
  business_id    uuid not null,
  service_id     uuid not null,
  resource_kind  text not null,
  quantity       integer not null default 1 check (quantity >= 1),
  primary key (business_id, service_id, resource_kind),
  foreign key (business_id, service_id) references services (business_id, id) on delete cascade
);

create table opening_hours (
  business_id  uuid not null,
  location_id  uuid not null,
  weekday      smallint not null check (weekday between 0 and 6),
  opens        time not null,
  closes       time not null,
  primary key (business_id, location_id, weekday, opens),
  foreign key (business_id, location_id) references locations (business_id, id) on delete cascade,
  check (closes > opens)
);

create table closures (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  location_id  uuid not null,
  period       tstzrange not null,
  reason       text,
  unique (business_id, id),
  foreign key (business_id, location_id) references locations (business_id, id) on delete cascade
);

create table appointments (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references businesses(id),
  location_id     uuid not null,
  customer_id     uuid not null,
  service_id      uuid,
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  status          text not null default 'booked' check (status in ('requested','booked','confirmed','checked_in',
                    'in_service','completed','no_show','cancelled','declined')),
  source          text not null check (source in ('ai_call','ai_message','staff','link','import','api')),
  party_size      integer not null default 1 check (party_size between 1 and 500),   -- guests (restaurants), people (classes)
  request_key     text,                                   -- idempotent booking (REQ-APT-ISO-04)
  record_id       uuid,
  arrived_at      timestamptz,
  checked_in_at   timestamptz,
  completed_at    timestamptz,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, request_key),
  foreign key (business_id, location_id) references locations (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id),
  foreign key (business_id, service_id)  references services (business_id, id),
  check (ends_at > starts_at)
);
create index appointments_calendar on appointments (business_id, location_id, starts_at);

-- One table for both bookings and short holds, so every resource is protected in one place (DB-9):
--   * different businesses never conflict (business_id is part of every check);
--   * different resources of one business never conflict (two stylists, two tables at 10:00 are fine);
--   * an EXCLUSIVE resource (capacity 1) can't be reserved twice for overlapping periods: exclusion constraint;
--   * a SHARED resource (capacity > 1) accepts overlapping reservations until the units in use at any moment would
--     exceed its capacity: enforced by a trigger under a per-resource transaction lock, so concurrent bookings queue.
create table resource_reservations (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references businesses(id),
  resource_id     uuid not null,
  appointment_id  uuid,
  kind            text not null check (kind in ('booking','hold')),
  period          tstzrange not null check (not isempty(period)),
  units           integer not null default 1 check (units >= 1),   -- guests or spots used on a shared resource
  exclusive       boolean not null default true,                  -- set from the resource's capacity by trigger
  active          boolean not null default true,         -- set false on cancel/move; holds expire via a sweeper
  hold_expires_at timestamptz,
  call_id         uuid,
  created_at      timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, resource_id)    references resources (business_id, id),
  foreign key (business_id, appointment_id) references appointments (business_id, id) on delete cascade,
  foreign key (business_id, call_id)        references calls (business_id, id),
  check ((kind = 'booking') = (appointment_id is not null)),
  check ((kind = 'hold') = (hold_expires_at is not null)),
  constraint no_double_booking exclude using gist
    (business_id with =, resource_id with =, period with &&) where (active and exclusive)
);

-- Exclusivity comes from the resource, never from the caller; shared resources are checked against capacity.
create or replace function app_private.check_reservation_capacity() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_capacity integer; v_active boolean; v_peak integer;
begin
  select r.capacity, r.active into v_capacity, v_active from public.resources r
   where r.business_id = new.business_id and r.id = new.resource_id;
  if not found then return new; end if;                 -- not this business's resource: the composite FK rejects it
  if not v_active and new.active then raise exception 'resource_unavailable' using errcode = 'P0001'; end if;
  new.exclusive := (v_capacity = 1);
  if new.exclusive then new.units := 1; end if;          -- an exclusive resource holds one booking, whatever its size
  if new.units > v_capacity then raise exception 'over_capacity' using errcode = 'P0001'; end if;
  if new.active and not new.exclusive then
    -- serialise bookings of this resource: a concurrent booking waits here and then sees this one
    perform pg_advisory_xact_lock(hashtextextended(new.business_id::text || ':' || new.resource_id::text, 0));
    -- peak load inside the new period: check at the new start and at every overlapping reservation's start
    select max(load) into v_peak from (
      select p.at, coalesce(sum(o.units), 0) + new.units as load
        from (select lower(new.period) as at
              union select greatest(lower(o2.period), lower(new.period)) from public.resource_reservations o2
               where o2.business_id = new.business_id and o2.resource_id = new.resource_id and o2.active
                 and o2.id <> new.id and o2.period && new.period) p
        left join public.resource_reservations o
          on o.business_id = new.business_id and o.resource_id = new.resource_id and o.active
         and o.id <> new.id and o.period @> p.at
       group by p.at) x;
    if v_peak > v_capacity then raise exception 'over_capacity' using errcode = 'P0001'; end if;
  end if;
  return new;
end $$;
create trigger check_reservation_capacity before insert or update of resource_id, period, units, active
  on resource_reservations for each row execute function app_private.check_reservation_capacity();

create table external_busy (                              -- busy times from connected calendars
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references businesses(id),
  resource_id         uuid not null,
  period              tstzrange not null,
  provider_event_ref  text,
  fetched_at          timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, resource_id) references resources (business_id, id) on delete cascade
);

create table waitlist_entries (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  location_id  uuid not null,
  customer_id  uuid not null,
  service_id   uuid,
  preferences  jsonb not null default '{}'::jsonb,
  status       text not null default 'waiting' check (status in ('waiting','offered','booked','removed','expired')),
  created_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, location_id) references locations (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id),
  foreign key (business_id, service_id)  references services (business_id, id)
);

create table waitlist_offers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  entry_id     uuid not null,
  resource_id  uuid not null,
  period       tstzrange not null,
  token_hash   text not null unique,
  expires_at   timestamptz not null,
  state        text not null default 'open' check (state in ('open','accepted','declined','expired','withdrawn')),
  created_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, entry_id)    references waitlist_entries (business_id, id) on delete cascade,
  foreign key (business_id, resource_id) references resources (business_id, id)
);
create unique index waitlist_one_open_offer on waitlist_offers (business_id, resource_id, period) where state = 'open';

-- =====================================================================================================================
-- 8. Knowledge
-- =====================================================================================================================

create table knowledge_items (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  location_id      uuid,                                -- null = applies to every location
  title            text not null,
  language         text not null default 'en' check (language in ('en','es')),
  status           text not null default 'draft' check (status in ('draft','ready','archived')),
  current_version  integer not null default 1,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, location_id) references locations (business_id, id)
);

create table knowledge_versions (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  item_id      uuid not null,
  version      integer not null,
  body         text not null,
  origin       text not null default 'human' check (origin in ('human','ai_draft','website')),
  approved_by  uuid,
  approved_at  timestamptz,
  created_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, item_id, version),
  foreign key (business_id, item_id)     references knowledge_items (business_id, id) on delete cascade,
  foreign key (business_id, approved_by) references business_members (business_id, id)
);

create table knowledge_gaps (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references businesses(id),
  question          text not null,
  question_key      text not null,
  times_asked       integer not null default 1,
  status            text not null default 'open' check (status in ('open','drafted','answered','dismissed')),
  suggested_answer  text,
  last_call_id      uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, question_key),
  foreign key (business_id, last_call_id) references calls (business_id, id)
);

create table ai_eval_cases (                              -- mixed scope: platform/industry cases + business cases
  id            uuid primary key default gen_random_uuid(),
  scope         text not null check (scope in ('platform','industry','business')),
  business_id   uuid references businesses(id),
  industry_key  text references industries(key),
  scenario      text not null,
  input         jsonb not null,
  expected      jsonb not null,
  created_at    timestamptz not null default now(),
  check ((scope = 'business') = (business_id is not null)),
  check ((scope = 'industry') = (industry_key is not null))
);

-- =====================================================================================================================
-- 9. Industry records and money (no card data, NN-9)
-- =====================================================================================================================

create table record_types (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  key          text not null,
  name         text not null,
  schema       jsonb not null default '{}'::jsonb,       -- fields, statuses, unique fields, private fields
  enabled      boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, key)
);

create table records (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  type_id      uuid not null,
  customer_id  uuid,
  location_id  uuid,
  status       text not null,
  data         jsonb not null default '{}'::jsonb,       -- never holds private values (record_secrets)
  unique_value text,                                   -- e.g. VIN, policy number (per type, per business)
  due_at       timestamptz,
  assignee_member_id uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, type_id, unique_value),
  foreign key (business_id, type_id)            references record_types (business_id, id),
  foreign key (business_id, customer_id)        references customers (business_id, id),
  foreign key (business_id, location_id)        references locations (business_id, id),
  foreign key (business_id, assignee_member_id) references business_members (business_id, id)
);
alter table appointments add foreign key (business_id, record_id) references records (business_id, id);

create table record_events (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  record_id    uuid not null,
  event        text not null,
  detail       jsonb not null default '{}'::jsonb,
  actor        uuid,
  created_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, record_id) references records (business_id, id) on delete cascade
);

create table record_secrets (                             -- access codes, member IDs, children's details (PRV-3)
  business_id  uuid not null,
  record_id    uuid not null,
  field        text not null,
  value        text not null,
  updated_at   timestamptz not null default now(),
  primary key (business_id, record_id, field),
  foreign key (business_id, record_id) references records (business_id, id) on delete cascade
);

create table record_files (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  record_id     uuid not null,
  storage_path  text not null,
  scan_status   text not null default 'checking' check (scan_status in ('checking','clean','rejected')),
  created_at    timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, record_id) references records (business_id, id) on delete cascade,
  check (storage_path like business_id::text || '/%')
);

create table charges (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  customer_id   uuid not null,
  record_id     uuid,
  description   text not null,
  amount_minor  bigint not null check (amount_minor >= 0),
  currency      text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  status        text not null default 'open' check (status in ('open','partially_paid','paid','void')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id),
  foreign key (business_id, record_id)   references records (business_id, id)
);

create table charge_payments (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  charge_id        uuid not null,
  amount_minor     bigint not null,                    -- negative = refund
  method_label     text not null check (method_label in ('cash','card_in_person','bank_transfer','check','other')),
  idempotency_key  text not null,
  recorded_by      uuid,
  created_at       timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, idempotency_key),
  foreign key (business_id, charge_id) references charges (business_id, id)
);

-- =====================================================================================================================
-- 10. Automation engine: rules, events (outbox), work items, dead letters
-- =====================================================================================================================

create table automation_rules (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  kind         text not null,
  enabled      boolean not null default false,
  settings     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, kind)
);

create table events (                                     -- outbox: written in the same transaction as the change (REQ-AUT-01)
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  type             text not null,
  payload          jsonb not null,
  idempotency_key  text not null,
  correlation_id   uuid,
  status           text not null default 'pending' check (status in ('pending','processed','failed')),
  occurred_at      timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, idempotency_key)
);
create index events_pending on events (status, occurred_at) where status = 'pending';

create table work_items (                                 -- every queued piece of work (REQ-AUT-02) with its envelope (TEN-13)
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references businesses(id),
  queue             text not null,
  automation_id     uuid,
  event_id          uuid,
  subject_type      text,
  subject_id        uuid,
  due_at            timestamptz not null,
  status            text not null default 'scheduled' check (status in ('scheduled','claimed','succeeded','skipped',
                      'dry_run','unknown','failed','dead_letter','cancelled')),
  attempts          integer not null default 0,
  max_attempts      integer not null default 3,
  claim_token       uuid,
  claim_expires_at  timestamptz,
  last_error        text,
  cancel_reason     text,
  result            jsonb,
  idempotency_key   text not null,
  correlation_id    uuid,
  restored          boolean not null default false,       -- set on backup restore: never re-send without review
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, idempotency_key),
  foreign key (business_id, automation_id) references automation_rules (business_id, id),
  foreign key (business_id, event_id)      references events (business_id, id),
  check ((status = 'claimed') = (claim_token is not null))
);
create index work_items_due on work_items (queue, due_at) where status = 'scheduled';

create table dead_letters (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  work_item_id  uuid not null,
  reason        text not null,
  detail        jsonb,
  resolved_at   timestamptz,
  created_at    timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, work_item_id) references work_items (business_id, id)
);

-- =====================================================================================================================
-- 11. Billing and usage (plans defined later; metering from day one, BIL-9)
-- =====================================================================================================================

create table subscriptions (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  plan_id      uuid not null references plans(id),
  status       text not null check (status in ('trialing','active','past_due','read_only','suspended','cancelled')),
  period       tstzrange not null,
  provider_ref text,
  created_at   timestamptz not null default now(),
  unique (business_id, id)
);
create unique index subscriptions_one_active on subscriptions (business_id)
  where status in ('trialing','active','past_due','read_only');

create table usage_ledger (                               -- append-only (BIL-2); adjustments are new rows
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id),
  dimension             text not null,
  quantity              numeric not null,
  unit                  text not null,
  entry_kind            text not null check (entry_kind in ('usage','adjustment')),
  source_ref            text not null,
  billable              boolean not null default true,  -- false for our failures (BIL-4)
  estimated_cost_minor  bigint,
  period_month          date not null,
  idempotency_key       text not null,
  created_at            timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, idempotency_key)
);

create table usage_budgets (
  business_id    uuid not null references businesses(id),
  dimension      text not null,
  monthly_limit  numeric not null,
  thresholds     numeric[] not null default '{0.75,0.9,1.0}',
  primary key (business_id, dimension)
);

-- =====================================================================================================================
-- 12. Operations, support, integrations, privacy
-- =====================================================================================================================

create table notifications (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  member_id        uuid not null,
  type             text not null,
  title            text not null,
  body             text,
  link             text,
  urgency          text not null default 'normal' check (urgency in ('info','normal','high','urgent')),
  read_at          timestamptz,
  acknowledged_at  timestamptz,
  created_at       timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, member_id) references business_members (business_id, id) on delete cascade
);
create index notifications_inbox on notifications (business_id, member_id, read_at);

create table support_tickets (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  opened_by    uuid,
  subject      text not null,
  status       text not null default 'open' check (status in ('open','waiting','closed')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, opened_by) references business_members (business_id, id)
);

create table integrations (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id),
  provider       text not null check (provider in ('google_calendar','microsoft_calendar','google_ads','meta','shopify',
                                                   'google_business_profile')),
  status         text not null default 'connected' check (status in ('connected','error','disconnected')),
  secret_ref     text,                                   -- name of the Vault secret; never the token itself
  last_error     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, provider)
);

create table api_keys (                                   -- public API (§36): stored hashed, shown once
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  key_hash      text not null unique,
  key_prefix    text not null,
  scopes        text[] not null,
  revoked_at    timestamptz,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  unique (business_id, id)
);

create table webhook_endpoints (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  url           text not null check (url like 'https://%'),
  events        text[] not null,
  secret_ref    text not null,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (business_id, id)
);

create table link_tokens (                                -- customer self-service links (SEC-16), hashed at rest
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  purpose       text not null check (purpose in ('reschedule','waitlist','check_in','unsubscribe','continue_plan')),
  subject_id    uuid not null,
  token_hash    text not null unique,
  expires_at    timestamptz not null,
  used_at       timestamptz,
  revoked_at    timestamptz,
  created_at    timestamptz not null default now(),
  unique (business_id, id)
);

create table imports (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  file_hash        text not null,
  consent_basis    jsonb not null,
  status           text not null default 'pending' check (status in ('pending','running','done','failed','undone')),
  summary          jsonb,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, file_hash)
);

create table data_rights_requests (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id),
  customer_id   uuid,
  kind          text not null check (kind in ('access','correction','deletion')),
  status        text not null default 'open' check (status in ('open','in_progress','done','rejected')),
  due_at        timestamptz not null,
  created_at    timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, customer_id) references customers (business_id, id)
);

create table activation_tests (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id),
  check_key    text not null,
  passed       boolean not null,
  detail       jsonb,
  checked_at   timestamptz not null default now(),
  unique (business_id, id)
);

create table audit_logs (                                 -- append-only; mixed scope (platform actions have no business)
  id            bigint generated always as identity primary key,
  scope         text not null check (scope in ('business','platform')),
  business_id   uuid references businesses(id),
  actor_id      uuid,
  actor_kind    text not null check (actor_kind in ('member','platform_admin','system','api_key')),
  action        text not null,
  entity        text not null,
  entity_id     text,
  before        jsonb,
  after         jsonb,
  created_at    timestamptz not null default now(),
  check ((scope = 'business') = (business_id is not null))
);
create index audit_logs_business on audit_logs (business_id, created_at desc);

-- =====================================================================================================================
-- 13. Growth schema (Zella Voice's own prospects; platform staff only, server-side)
-- =====================================================================================================================

create table growth.prospects (
  id           uuid primary key default gen_random_uuid(),
  company      text,
  contact_name text,
  email        text,
  phone        text,
  stage        text not null default 'new' check (stage in ('new','contacted','demo','proposal','won','lost')),
  consent      jsonb,
  owner_admin  uuid,
  created_at   timestamptz not null default now()
);
create table growth.prospect_activities (
  id           uuid primary key default gen_random_uuid(),
  prospect_id  uuid not null references growth.prospects(id) on delete cascade,
  kind         text not null,
  detail       jsonb,
  created_at   timestamptz not null default now()
);
alter table growth.prospects enable row level security;
alter table growth.prospect_activities enable row level security;
revoke all on all tables in schema growth from public, anon, authenticated;

-- =====================================================================================================================
-- 14. Authorization helpers (security definer, fixed search_path, not exposed through the API)
-- =====================================================================================================================

create or replace function app_private.role_rank(p_role text) returns integer
language sql immutable set search_path = pg_catalog as $$
  select case p_role when 'owner' then 5 when 'admin' then 4 when 'manager' then 3 when 'staff' then 2 when 'viewer' then 1 else 0 end
$$;

-- Active membership of the signed-in user in a business, with at least the given role. Fails closed (SEC-9).
create or replace function app_private.has_role(p_business_id uuid, p_min_role text default 'viewer') returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(auth.uid() is not null and exists (
    select 1 from public.business_members m
     join public.businesses b on b.id = m.business_id
     where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active'
       and b.status not in ('suspended','cancelled')
       and app_private.role_rank(m.role) >= app_private.role_rank(p_min_role)), false)
$$;

-- Location restriction (TEN-14): owners and admins see every location; other members see all locations unless they
-- have member_locations rows, in which case only those. Rows without a location are visible to every member.
create or replace function app_private.can_see_location(p_business_id uuid, p_location_id uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select p_location_id is null
      or app_private.has_role(p_business_id, 'admin')
      or exists (select 1 from public.business_members m
                  where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active'
                    and (not exists (select 1 from public.member_locations ml where ml.business_id = m.business_id and ml.member_id = m.id)
                         or exists (select 1 from public.member_locations ml where ml.business_id = m.business_id
                                     and ml.member_id = m.id and ml.location_id = p_location_id)))
$$;

-- Business id from a storage path "<business_uuid>/...", or null if the path doesn't start with a UUID.
create or replace function app_private.path_business(p_name text) returns uuid
language plpgsql immutable set search_path = pg_catalog as $$
begin
  return split_part(p_name, '/', 1)::uuid;
exception when invalid_text_representation then
  return null;
end $$;

revoke all on function app_private.role_rank(text), app_private.has_role(uuid, text),
  app_private.can_see_location(uuid, uuid), app_private.path_business(text) from public;
grant execute on function app_private.role_rank(text), app_private.has_role(uuid, text),
  app_private.can_see_location(uuid, uuid), app_private.path_business(text) to authenticated, service_role;

-- =====================================================================================================================
-- 15. Integrity triggers
-- =====================================================================================================================

create or replace function app_private.touch_updated_at() returns trigger
language plpgsql set search_path = pg_catalog as $$
begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  for t in select c.table_name from information_schema.columns c
            where c.table_schema = 'public' and c.column_name = 'updated_at'
              and c.table_name in (select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE')
  loop
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function app_private.touch_updated_at()', t);
  end loop;
end $$;

-- A business always keeps at least one active owner.
create or replace function app_private.keep_an_owner() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if old.role = 'owner' and old.status = 'active'
     and (tg_op = 'DELETE' or new.role <> 'owner' or new.status <> 'active')
     and not exists (select 1 from public.business_members m where m.business_id = old.business_id and m.id <> old.id
                       and m.role = 'owner' and m.status = 'active') then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;
create trigger keep_an_owner before update or delete on business_members for each row execute function app_private.keep_an_owner();

-- Ledgers and audit are append-only.
create or replace function app_private.append_only() returns trigger
language plpgsql set search_path = pg_catalog as $$
begin raise exception 'append_only' using errcode = 'P0001'; end $$;
create trigger audit_logs_append_only before update or delete on audit_logs for each row execute function app_private.append_only();
create trigger usage_ledger_append_only before update or delete on usage_ledger for each row execute function app_private.append_only();
create trigger consents_append_only before update or delete on contact_consents for each row execute function app_private.append_only();

-- Privileged changes are audited (DB-13).
create or replace function app_private.audit_change() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_row    jsonb := to_jsonb(coalesce(new, old));
  -- never copy secret material into the audit log: private record values, key hashes, secret references
  v_redact text[] := array['value','key_hash','secret_ref'];
  v_before jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_after  jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
begin
  v_before := v_before - v_redact;
  v_after  := v_after - v_redact;
  insert into public.audit_logs (scope, business_id, actor_id, actor_kind, action, entity, entity_id, before, after)
  values ('business', (v_row ->> 'business_id')::uuid, auth.uid(),
          case when auth.uid() is null then 'system' else 'member' end,
          lower(tg_op), tg_table_name, coalesce(v_row ->> 'id', v_row ->> 'record_id'), v_before, v_after);
  return coalesce(new, old);
end $$;
do $$
declare t text;
begin
  foreach t in array array['business_members','member_locations','business_settings','transfer_destinations','phone_numbers',
                           'automation_rules','api_keys','webhook_endpoints','integrations','suppressions','record_secrets']
  loop
    execute format('create trigger audit_change after insert or update or delete on public.%I for each row execute function app_private.audit_change()', t);
  end loop;
end $$;

-- =====================================================================================================================
-- 16. Row-level security and grants
-- =====================================================================================================================
-- Every public table has RLS on. Clients read through the policies below; they write only through server functions.

do $$ declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- Platform reference data that members may read.
grant select on industries, plans, plan_limits to authenticated;
create policy read_industries on industries for select to authenticated using (true);
create policy read_plans on plans for select to authenticated using (active);
create policy read_plan_limits on plan_limits for select to authenticated
  using (exists (select 1 from plans p where p.id = plan_id and p.active));

-- Businesses: members read their own business.
grant select on businesses to authenticated;
create policy member_reads_business on businesses for select to authenticated using (app_private.has_role(id, 'viewer'));

-- Standard tenant tables: any active member (viewer and up) may read.
do $$ declare t text;
begin
  foreach t in array array['locations','business_members','member_locations','customers','customer_contacts','customer_notes',
      'tags','customer_tags','phone_numbers','assistants','sequences','conversations','messages','services','resources',
      'service_locations','service_resource_needs','opening_hours','closures','external_busy','waitlist_entries',
      'knowledge_items','knowledge_versions','record_types','records','record_events','record_files','automation_rules',
      'table_combinations','table_combination_members',
      'notifications','support_tickets','integrations','activation_tests','business_settings']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy member_read on public.%I for select to authenticated using (app_private.has_role(business_id, ''viewer''))', t);
  end loop;
end $$;

-- Location-scoped operational tables (TEN-14).
do $$ declare t text;
begin
  foreach t in array array['calls','appointments','callbacks']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy member_read on public.%I for select to authenticated using (app_private.has_role(business_id, ''viewer'') and app_private.can_see_location(business_id, location_id))', t);
  end loop;
end $$;

-- Staff and above (not viewers).
do $$ declare t text;
begin
  foreach t in array array['call_attempts','call_tool_calls','contact_consents','suppressions','lead_events',
                           'knowledge_gaps','waitlist_offers','resource_reservations','charges']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy staff_read on public.%I for select to authenticated using (app_private.has_role(business_id, ''staff''))', t);
  end loop;
end $$;

-- Managers and above: sensitive content (transcripts, recordings, voicemails, private record fields, payments, reports).
-- Owner opt-in for staff and regulated-industry rules are enforced by the server functions that read these.
do $$ declare t text;
begin
  foreach t in array array['call_artifacts','voicemails','record_secrets','charge_payments','usage_ledger','usage_budgets',
                           'subscriptions','dead_letters','data_rights_requests','imports']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy manager_read on public.%I for select to authenticated using (app_private.has_role(business_id, ''manager''))', t);
  end loop;
end $$;

-- Admins and above: transfer numbers, API keys, webhooks, audit log.
do $$ declare t text;
begin
  foreach t in array array['transfer_destinations','api_keys','webhook_endpoints']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy admin_read on public.%I for select to authenticated using (app_private.has_role(business_id, ''admin''))', t);
  end loop;
end $$;
grant select on audit_logs to authenticated;
create policy admin_read on audit_logs for select to authenticated
  using (scope = 'business' and app_private.has_role(business_id, 'admin'));

-- Mixed-scope tables: platform/industry rows readable by members; business rows only by that business.
grant select on message_templates, ai_eval_cases to authenticated;
create policy read_templates on message_templates for select to authenticated
  using (scope in ('platform','industry') or app_private.has_role(business_id, 'viewer'));
create policy read_eval_cases on ai_eval_cases for select to authenticated
  using (scope in ('platform','industry') or app_private.has_role(business_id, 'manager'));

-- Server-only tables (no client access at all): events, work_items, link_tokens, quarantined_events,
-- business_invitations (token hashes), sender_identities, platform_settings, platform_admins, platform_permissions,
-- provider_health, platform_incidents. RLS is on and no policy exists, so even a mistaken grant returns nothing.

-- Functions: nothing in public is callable by default; each API function is granted explicitly when written (§30).
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- =====================================================================================================================
-- 17. Storage (§6.10): private buckets, paths start with the business UUID, signed URLs issued by the server
-- =====================================================================================================================
insert into storage.buckets (id, name, public) values
  ('business-files', 'business-files', false),   -- documents, record files, knowledge files
  ('call-media',     'call-media',     false),   -- voicemails and (when enabled) recordings
  ('brand-assets',   'brand-assets',   true)     -- logos only; nothing sensitive
on conflict (id) do update set public = excluded.public;

create policy business_files_read on storage.objects for select to authenticated
  using (bucket_id = 'business-files' and app_private.has_role(app_private.path_business(name), 'staff'));
create policy call_media_read on storage.objects for select to authenticated
  using (bucket_id = 'call-media' and app_private.has_role(app_private.path_business(name), 'manager'));
-- No insert/update/delete policies: uploads and deletions use server-issued signed URLs only.

-- Realtime (REQ-DB-ISO-07): no table is added to the realtime publication. If Realtime is introduced, only RLS-filtered
-- postgres_changes or membership-checked private channels named per business are allowed.

commit;
