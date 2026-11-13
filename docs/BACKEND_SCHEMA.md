# Zella Voice backend schema

The database is the single source of truth and the single enforcer of rules (`NN-6` in `ZELLA_VOICE_RULES.md`).
This is the reference for what is in it: every table and column, its keys, its row security policies and
triggers, and every function with who may call it. How the parts work together is in `docs/ARCHITECTURE.md`;
which migration is applied to production is in `docs/SCHEMA_STATUS.md`.

**Generated, do not edit by hand.** Run `docs/generators/backend_schema.py` against an isolated copy of the
production schema and commit the result with the migration that changed it. Table purposes live in that script.
It reads the catalog only, never rows.

## At a glance

| What | Count |
|---|---|
| Tables (schema `public`) | 170 |
| Tables with row security on | 170 of 170 |
| Row security policies | 340 |
| Columns | 2018 |
| Views | 1 |
| Functions | 885 (822 security definer, 26 callable by `anon`) |

Rules every table follows:

- Business data carries `business_id`; row security and every function check the caller's membership and role
  in that business. Hiding something in the app is never the protection.
- Row security is on for every table. A new table without it is a defect.
- Secrets (provider tokens, keys) are never in these tables: they live in Supabase Vault and edge function
  secrets. Tables keep only a reference or a hash.
- History tables (`audit_logs`, `contact_consents`, `usage_records`, `*_events`) are append-only.
- Nothing is dropped or recreated. Changes are new, version-guarded migrations with a rollback in `sql/rollback/`.

Other schemas Zella Voice uses: `auth` (Supabase sign-in users), `storage` (files), `vault` (secrets),
`cron` (timed jobs), `net` (outbound calls from the database to n8n).

### Storage buckets

| Bucket | Public | Holds |
|---|---|---|
| `brand-assets` | yes | Zella Voice and business logos and backgrounds (no private data) |
| `business-documents` | no | Business and owner verification documents |
| `record-files` | no | Files attached to industry records, checked after upload |

### Timed jobs (`cron.job`)

Each is a database job; most stay off until the owner approves going live (see `docs/MEMORY.md`).

| Job | Schedule (UTC) | Does |
|---|---|---|
| `zella_dispatch` | every minute | Wakes n8n workers only when work is due (`zella_dispatch_n8n`) |
| `zella_jobs_every5` | every 5 min | Overdue leads, expire held slots and waitlist offers, transfer failures |
| `zella_jobs_every15` | every 15 min | Quote follow-ups |
| `zella_jobs_hourly` | hourly | Daily summaries at each business's local 8am |
| `zella_jobs_daily` | 04:00 | Lead reactivation, setup incomplete, trials, payment policy |
| `zella_jobs_weekly` | Mon 08:00 | Weekly reviews |
| `zella_cron_cleanup` | 03:30 | Clears old job history |
| `zella_usage_thresholds` | hourly at :23 | Usage warnings |
| `zella_spam_hourly` | hourly at :17 | Spam follow-up work |
| `zella_billing_reconcile` | every 15 min | Applies billing events that arrived out of order |

## Contents

- [Tenancy, people and access](#tenancy-people-and-access): `businesses`, `business_members`, `business_invitations`, `profiles`, `staff_members`, `staff_handovers`, `time_off_requests`, `platform_admins`, `platform_role_permissions`, `sensitive_approvals`, `legal_documents`, `legal_acceptances`, `audit_logs`, `rate_limits`
- [Business setup and industry configuration](#business-setup-and-industry-configuration): `industries`, `industry_configurations`, `industry_modules`, `business_modules`, `business_capabilities`, `industry_crm_presets`, `industry_automation_presets`, `industry_automation_defaults`, `industry_automation_runs`, `industry_message_policy`, `business_hours`, `business_closures`, `business_languages`, `business_voice`, `business_phone_numbers`, `business_verification_documents`, `provisioning_steps`, `activation_tests`, `config_migration_snapshots`, `zella_milestones`, `platform_settings`, `business_usage_preferences`
- [Customers and CRM](#customers-and-crm): `customers`, `customer_relationships`, `customer_requests`, `customer_consents`, `contact_consents`, `duplicate_reviews`, `crm_tasks`, `crm_record_types`, `crm_records`, `crm_record_events`, `crm_record_files`, `crm_record_secrets`, `record_workflow_presets`, `record_approvals`, `record_milestones`, `record_inspections`, `record_exceptions`, `record_credits`, `quotes`, `customer_charges`, `customer_charge_payments`, `data_rights_requests`
- [Leads](#leads): `lead_rules`, `lead_questions`, `lead_submissions`, `website_forms`, `website_sources`, `website_pages`, `google_lead_keys`, `google_lead_events`, `assignment_rules`
- [Calls and the AI receptionist](#calls-and-the-ai-receptionist): `calls`, `call_messages`, `call_insights`, `callbacks`, `callback_attempts`, `ai_agents`, `ai_agent_configs`, `agent_config_versions`, `assistant_deliveries`, `ai_tool_calls`, `ai_answer_reports`, `ai_response_samples`, `ai_eval_cases`, `vapi_request_receipts`, `on_call_settings`, `on_call_shifts`, `on_call_reminders_sent`, `store_lookup_guards`
- [Knowledge](#knowledge): `knowledge_items`, `knowledge_versions`, `knowledge_gaps`
- [Scheduling](#scheduling): `appointments`, `appointment_reminders`, `appointment_reschedule_links`, `blocked_times`, `resources`, `resource_needs`, `recurring_plans`, `recurring_visits`, `job_dispatch`, `waitlist_entries`, `waitlist_offer_links`, `calendar_connections`, `calendar_sync_queue`, `restaurant_tables`, `table_combinations`, `table_states`, `table_blocks`, `table_events`
- [Messages and conversations](#messages-and-conversations): `conversations`, `conversation_messages`, `conversation_notes`, `message_templates`, `message_drafts`, `sms_messages`, `email_messages`, `email_events`, `email_unsubscribe_tokens`, `followup_tasks`, `automation_channel_reviews`, `meta_connections`, `meta_contacts`, `meta_events`, `meta_outbox`, `meta_templates`, `social_flows`, `live_notices`
- [Spam and abuse](#spam-and-abuse): `spam_settings`, `spam_incidents`, `spam_incident_events`, `spam_list_entries`
- [Automations and background work](#automations-and-background-work): `automations`, `automation_runs`, `automation_events`, `automation_dead_letters`, `workflow_executions`, `n8n_dispatch_state`, `integrations`, `integration_secrets`, `provider_health`
- [Offers, reviews and growth](#offers-reviews-and-growth): `offers`, `offer_rules`, `offer_redemptions`, `offer_events`, `offer_job_runs`, `cross_sell_rules`, `review_sources`, `reviews`
- [Billing and usage](#billing-and-usage): `plans`, `business_plans`, `billing_pack_catalog`, `billing_periods`, `allowance_buckets`, `pack_purchases`, `usage_charges`, `auto_reload_settings`, `subscriptions`, `payments`, `billing_events`, `usage_records`, `usage_thresholds`, `usage_threshold_events`, `usage_processing_issues`, `voice_pricing`
- [Notifications, reports and support](#notifications-reports-and-support): `notifications`, `notification_preferences`, `staff_notifications`, `admin_alert_prefs`, `platform_alerts`, `platform_incidents`, `business_report_schedules`, `business_report_runs`, `support_tickets`
- [Functions](#functions)

## Tenancy, people and access

### `businesses`

One row per business (tenant): name, industry, status, time zone, plan link.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `name` | text | yes |  |
| `legal_name` | text |  |  |
| `industry_id` | uuid |  |  |
| `business_type` | text |  |  |
| `website` | text |  |  |
| `email` | text |  |  |
| `phone` | text |  |  |
| `address_line_1` | text |  |  |
| `address_line_2` | text |  |  |
| `city` | text |  |  |
| `state` | text |  |  |
| `postal_code` | text |  |  |
| `country` | text |  | 'US' |
| `timezone` | text |  | 'America/New_York' |
| `logo_url` | text |  |  |
| `onboarding_status` | text | yes | 'started' |
| `is_active` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `terminology_overrides` | jsonb | yes | '{}' |
| `setup_data` | jsonb | yes | '{}' |
| `suspended_at` | timestamp with time zone |  |  |
| `suspension_reason` | text |  |  |
| `cancel_at` | timestamp with time zone |  |  |
| `cancel_requested_at` | timestamp with time zone |  |  |
| `cancellation_reason` | text |  |  |
| `cancelled_at` | timestamp with time zone |  |  |
| `retention_until` | timestamp with time zone |  |  |
| `inbound_email_token` | text |  | encode(extensions.gen_random_bytes(16... |
| `business_size` | text |  |  |
| `description` | text |  |  |
| `alternate_phone` | text |  |  |

- Primary key: `id`.
- `industry_id` → `public.industries` (on delete no action).
- Row security: on; policies: Members can view their business (select), zella_mfa_required (all).
- Triggers: `businesses_updated_at`, `zella_audit_privileged_trg`, `zella_business_before_trg`, `zella_business_lifecycle_trg`, `zella_business_status_trg`, `zella_business_welcome`, `zella_crm_on_industry`, `zella_industry_apply`.

### `business_members`

A person's membership in a business and their role (owner, admin, manager, staff, viewer).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `user_id` | uuid | yes |  |
| `role` | text | yes | 'staff' |
| `status` | text | yes | 'active' |
| `created_at` | timestamp with time zone | yes | now() |
| `accepts_work` | boolean | yes | true |
| `away_until` | timestamp with time zone |  |  |
| `last_assigned_at` | timestamp with time zone |  |  |
| `sms_alerts` | boolean | yes | true |

- Primary key: `id`.
- Unique: `(business_id, user_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `user_id` → `auth.users` (on delete cascade).
- Row security: on; policies: Users can view their memberships (select), zella_mfa_required (all).
- Triggers: `zella_audit_privileged_trg`.

### `business_invitations`

Team and owner invitations: email, role, token, expiry, who accepted.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `email` | text | yes |  |
| `owner_name` | text | yes |  |
| `invited_by` | uuid | yes |  |
| `status` | text | yes | 'pending' |
| `auth_user_id` | uuid |  |  |
| `invited_at` | timestamp with time zone |  |  |
| `accepted_at` | timestamp with time zone |  |  |
| `expires_at` | timestamp with time zone |  |  |
| `last_error` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `reminder_count` | integer | yes | 0 |
| `last_reminded_at` | timestamp with time zone |  |  |
| `role` | text | yes | 'owner' |

- Primary key: `id`.
- `auth_user_id` → `auth.users` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `invited_by` → `auth.users` (on delete no action).
- Row security: on; policies: zella_mfa_required (all).
- Triggers: `zella_team_capacity_trg`.

### `profiles`

One row per signed-in person: name, phone, preferences.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes |  |
| `first_name` | text |  |  |
| `last_name` | text |  |  |
| `phone` | text |  |  |
| `avatar_url` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `portal_id` | text |  |  |

- Primary key: `id`.
- `id` → `auth.users` (on delete cascade).
- Row security: on; policies: Users can update their own profile (update), Users can view their own profile (select), zella_mfa_required (all).
- Triggers: `profiles_updated_at`.

### `staff_members`

Staff who do the work (may or may not sign in): name, role, skills, colour.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `title` | text |  |  |
| `phone` | text |  |  |
| `email` | text |  |  |
| `color` | text | yes | '#2563EB' |
| `is_active` | boolean | yes | true |
| `working_hours` | jsonb | yes | '{}' |
| `sort_order` | integer | yes | 0 |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: staff_members_manager_delete (delete), staff_members_manager_insert (insert), staff_members_manager_update (update), staff_members_member_select (select), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_staff_deactivated_trg`.

### `staff_handovers`

Moving one person's open work to another person, with what was moved.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `from_user` | uuid |  |  |
| `to_user` | uuid | yes |  |
| `note` | text |  |  |
| `moved` | jsonb | yes | '{}' |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Row security: on; policies: staff_handovers_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `time_off_requests`

Staff time off, requested and decided by a manager.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `staff_id` | uuid | yes |  |
| `requested_by` | uuid |  |  |
| `from_at` | timestamp with time zone | yes |  |
| `to_at` | timestamp with time zone | yes |  |
| `reason` | text |  |  |
| `status` | text | yes | 'pending' |
| `decided_by` | uuid |  |  |
| `decided_at` | timestamp with time zone |  |  |
| `blocked_time_id` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `staff_id` → `public.staff_members` (on delete cascade).
- Row security: on; policies: time_off_requests_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `platform_admins`

Zella Voice staff who can use the platform admin, and their platform role.

| Column | Type | Required | Default |
|---|---|---|---|
| `user_id` | uuid | yes |  |
| `role` | text | yes | 'super_admin' |
| `is_active` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |
| `created_by` | uuid |  |  |

- Primary key: `user_id`.
- `created_by` → `auth.users` (on delete set null).
- `user_id` → `auth.users` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).
- Triggers: `zella_audit_privileged_trg`, `zella_platform_admin_after_trg`, `zella_platform_admin_before_trg`, `zella_platform_admin_email_check`.

### `platform_role_permissions`

Which named permissions each platform role has.

| Column | Type | Required | Default |
|---|---|---|---|
| `role` | text | yes |  |
| `permission` | text | yes |  |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `role, permission`.
- Row security: on; policies: zella_mfa_required (all).

### `sensitive_approvals`

Two-person approval for risky actions (exports, erasure, role changes).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `action` | text | yes |  |
| `entity_id` | uuid |  |  |
| `details` | jsonb | yes | '{}' |
| `requested_by` | uuid |  |  |
| `status` | text | yes | 'pending' |
| `decided_by` | uuid |  |  |
| `decided_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `expires_at` | timestamp with time zone | yes | (now() + '2 days'::interval) |
| `used_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Row security: on; policies: sensitive_approvals_read (select), zella_mfa_required (all).
- Triggers: `zella_approval_decided_trg`.

### `legal_documents`

Versions of the terms and policies people accept.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `kind` | text | yes |  |
| `version` | text | yes |  |
| `title` | text | yes |  |
| `body` | text | yes | '' |
| `status` | text | yes | 'draft' |
| `requires_acceptance` | boolean | yes | false |
| `effective_at` | timestamp with time zone |  |  |
| `reviewed_by` | uuid |  |  |
| `reviewed_at` | timestamp with time zone |  |  |
| `published_by` | uuid |  |  |
| `published_at` | timestamp with time zone |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(kind, version)`.
- Row security: on; policies: legal_documents_published_read (select), zella_mfa_required (all).

### `legal_acceptances`

Who accepted which legal document version, and when.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `document_id` | uuid | yes |  |
| `business_id` | uuid |  |  |
| `user_id` | uuid | yes |  |
| `accepted_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(document_id, business_id, user_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `document_id` → `public.legal_documents` (on delete no action).
- Row security: on; policies: legal_acceptances_read (select), zella_mfa_required (all).

### `audit_logs`

Append-only record of every privileged action. Only the server can write it.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `user_id` | uuid |  |  |
| `action` | text | yes |  |
| `entity_type` | text |  |  |
| `entity_id` | uuid |  |  |
| `old_data` | jsonb |  |  |
| `new_data` | jsonb |  |  |
| `ip_address` | inet |  |  |
| `user_agent` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `user_id` → `auth.users` (on delete set null).
- Row security: on; policies: business members can view audit logs (select), zella_mfa_required (all).

### `rate_limits`

Counters that slow down repeated requests per key and window.

| Column | Type | Required | Default |
|---|---|---|---|
| `key` | text | yes |  |
| `window_start` | timestamp with time zone | yes |  |
| `hits` | integer | yes | 0 |

- Primary key: `key, window_start`.
- Row security: on; policies: zella_mfa_required (all).

## Business setup and industry configuration

### `industries`

The 28 industries Zella Voice serves.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `name` | text | yes |  |
| `slug` | text | yes |  |
| `description` | text |  |  |
| `is_active` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(name)`.
- Unique: `(slug)`.
- Row security: on; policies: Anyone can view active industries (select), Authenticated users can view active industries (select), zella_mfa_required (all).

### `industry_configurations`

Each industry's versioned configuration (terms, booking model, defaults).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `industry_id` | uuid | yes |  |
| `terminology` | jsonb | yes | '{}' |
| `statuses` | jsonb | yes | '{}' |
| `features` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(industry_id)`.
- `industry_id` → `public.industries` (on delete cascade).
- Row security: on; policies: Authenticated users can view industry configurations (select), zella_mfa_required (all).

### `industry_modules`

CRM modules available per industry.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `industry_id` | uuid | yes |  |
| `name` | text | yes |  |
| `slug` | text | yes |  |
| `description` | text |  |  |
| `is_active` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(industry_id, slug)`.
- `industry_id` → `public.industries` (on delete cascade).
- Row security: on; policies: Authenticated users can view active industry modules (select), zella_mfa_required (all).

### `business_modules`

Which modules a business has switched on.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `module_id` | uuid | yes |  |
| `enabled` | boolean | yes | true |
| `configuration` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, module_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `module_id` → `public.industry_modules` (on delete cascade).
- Row security: on; policies: Members can view enabled business modules (select), zella_mfa_required (all).

### `business_capabilities`

Which kinds of work are on for a business (scheduling, check-ins, waitlist, dispatch, ...).

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `capability` | text | yes |  |
| `enabled` | boolean | yes |  |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id, capability`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business_capabilities_read (select).

### `industry_crm_presets`

Default record types and fields per industry.

| Column | Type | Required | Default |
|---|---|---|---|
| `key` | text | yes |  |
| `match` | text[] | yes |  |
| `config` | jsonb | yes |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `key`.
- Row security: on; policies: zella_mfa_required (all).

### `industry_automation_presets`

Default automations per industry.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `industry_key` | text | yes |  |
| `name` | text | yes |  |
| `checklist_no` | integer |  |  |
| `description` | text |  |  |
| `trigger_type` | text | yes |  |
| `trigger_config` | jsonb | yes |  |

- Primary key: `id`.
- Unique: `(industry_key, name)`.
- Row security: on; policies: zella_mfa_required (all).

### `industry_automation_defaults`

Default automation settings applied when a business is created.

| Column | Type | Required | Default |
|---|---|---|---|
| `industry_id` | uuid | yes |  |
| `trigger_type` | text | yes |  |
| `enabled` | boolean | yes | true |
| `config` | jsonb | yes | '{}' |

- Primary key: `industry_id, trigger_type`.
- `industry_id` → `public.industries` (on delete cascade).
- Row security: on; policies: signed in read industry defaults (select), zella_mfa_required (all).

### `industry_automation_runs`

Log of applying industry automation presets to a business.

| Column | Type | Required | Default |
|---|---|---|---|
| `automation_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `step` | text | yes |  |
| `ran_at` | timestamp with time zone | yes | now() |

- Primary key: `automation_id, record_id, step`.
- Row security: on; policies: zella_mfa_required (all).

### `industry_message_policy`

Per-industry message policy (for example drafts only in regulated industries).

| Column | Type | Required | Default |
|---|---|---|---|
| `industry_key` | text | yes |  |
| `policy` | jsonb | yes |  |
| `reason` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `industry_key`.
- Row security: on; policies: industry_message_policy_read (select).

### `business_hours`

Weekly opening hours per business (several ranges a day allowed).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `weekday` | smallint | yes |  |
| `opens` | time without time zone | yes |  |
| `closes` | time without time zone | yes |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business_hours_read (select), zella_mfa_required (all).

### `business_closures`

Holidays and one-off closures, whole or part day.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `starts_on` | date | yes |  |
| `ends_on` | date | yes |  |
| `label` | text | yes | 'Closed' |
| `opens` | time without time zone |  |  |
| `closes` | time without time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business_closures_read (select), zella_mfa_required (all).

### `business_languages`

Languages the receptionist offers for a business.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `primary_language` | text | yes | 'en-US' |
| `extra_languages` | text[] | yes | '{}'[] |
| `greeting` | text |  |  |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business_languages_read (select), zella_mfa_required (all).

### `business_voice`

The voice a business chose for its receptionist.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `voice_id` | text | yes |  |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `business_phone_numbers`

Phone numbers assigned to a business (and their Vapi number id).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `e164` | text | yes |  |
| `vapi_phone_number_id` | text |  |  |
| `label` | text |  |  |
| `status` | text | yes | 'active' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(e164)`.
- Unique: `(vapi_phone_number_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business_phone_numbers_member_read (select), zella_mfa_required (all).
- Triggers: `zella_phone_capacity_trg`.

### `business_verification_documents`

Business and owner verification documents (files in private storage).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `file_path` | text | yes |  |
| `file_name` | text | yes |  |
| `mime_type` | text | yes |  |
| `size_bytes` | integer | yes |  |
| `status` | text | yes | 'pending_review' |
| `review_note` | text |  |  |
| `uploaded_by` | uuid |  |  |
| `reviewed_by` | uuid |  |  |
| `reviewed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(file_path)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business_verification_documents_owner_read (select), zella_mfa_required (all).

### `provisioning_steps`

Progress of each Create Business wizard step.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `step` | text | yes |  |
| `status` | text | yes | 'pending' |
| `error` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id, step`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `activation_tests`

Results of the checks run before a business goes live.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `ok` | boolean | yes |  |
| `detail` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: activation_tests_select (select), zella_mfa_required (all).

### `config_migration_snapshots`

Copy of a business's settings before a configuration upgrade, so it can be restored.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `taken_at` | timestamp with time zone | yes | now() |
| `taken_by` | uuid |  |  |
| `languages` | jsonb |  |  |
| `escalation_rules` | jsonb |  |  |
| `setup_knowledge` | jsonb | yes | '[]' |
| `applied` | jsonb |  |  |
| `restored_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `zella_milestones`

First-time moments a business reached (first call answered, first booking, ...).

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `key` | text | yes |  |
| `reached_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id, key`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `platform_settings`

Platform-wide switches and settings (live switches, provider choices). No secrets.

| Column | Type | Required | Default |
|---|---|---|---|
| `key` | text | yes |  |
| `value` | jsonb | yes |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `key`.
- Row security: on; policies: zella_mfa_required (all).
- Triggers: `zella_audit_privileged_trg`.

### `business_usage_preferences`

What a business wants to happen near or over its usage limits.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `notify_thresholds` | integer[] | yes | '{80,100}'::integer[] |
| `overage_mode` | text | yes | 'stop' |
| `spend_limit_cents` | bigint |  |  |
| `fallback` | text | yes | 'take_message' |
| `authorized_by` | uuid |  |  |
| `authorized_at` | timestamp with time zone |  |  |
| `notified` | jsonb | yes | '{}' |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

## Customers and CRM

### `customers`

A person the business serves (caller, client, patient, guest). Leads are customers not yet converted.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `first_name` | text |  |  |
| `last_name` | text |  |  |
| `email` | text |  |  |
| `phone` | text |  |  |
| `company_name` | text |  |  |
| `status` | text | yes | 'active' |
| `source` | text |  |  |
| `notes` | text |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `do_not_call` | boolean | yes | false |
| `do_not_sms` | boolean | yes | false |
| `do_not_email` | boolean | yes | false |
| `preferred_contact_method` | text |  |  |
| `last_contacted_at` | timestamp with time zone |  |  |
| `do_not_contact` | boolean | yes | false |
| `tags` | text[] | yes | '{}'[] |
| `date_of_birth` | date |  |  |
| `address` | text |  |  |
| `preferred_contact` | text |  |  |
| `lead_stage` | text |  |  |
| `assigned_to` | uuid |  |  |
| `priority` | text |  |  |
| `qualification` | jsonb | yes | '{}' |
| `qualification_result` | text |  |  |
| `contact_deadline_at` | timestamp with time zone |  |  |
| `next_follow_up_at` | timestamp with time zone |  |  |
| `lost_reason` | text |  |  |
| `lost_at` | timestamp with time zone |  |  |
| `reactivate_after` | timestamp with time zone |  |  |
| `converted_at` | timestamp with time zone |  |  |
| `email_suppressed_at` | timestamp with time zone |  |  |
| `email_suppressed_reason` | text |  |  |
| `preferred_channel` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business members can create customers (insert), business members can update customers (update), business members can view customers (select), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_auto_assign_lead_trg`, `zella_customer_change`, `zella_dnc_trg`, `zella_welcome_new_customer`, `zz_tenant_links`.

### `customer_relationships`

Verified links between people (parent, guardian, partner) with what each may do.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `record_id` | uuid |  |  |
| `related_customer_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `permissions` | text[] | yes | '{}'[] |
| `valid_until` | date |  |  |
| `note` | text |  |  |
| `verified_at` | timestamp with time zone |  |  |
| `verified_by` | uuid |  |  |
| `verification_method` | text |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `revoked_at` | timestamp with time zone |  |  |
| `revoked_by` | uuid |  |  |
| `revoke_reason` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- `related_customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: customer_relationships_read (select), zella_mfa_required (all).

### `customer_requests`

Things a customer asked for that staff must handle, with owner and due time.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `call_id` | uuid |  |  |
| `kind` | text | yes |  |
| `summary` | text | yes |  |
| `source` | text | yes | 'staff' |
| `status` | text | yes | 'open' |
| `priority` | text | yes | 'normal' |
| `assigned_to` | uuid |  |  |
| `due_at` | timestamp with time zone | yes |  |
| `resolution_note` | text |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `overdue_notified_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: customer_requests_member_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `customer_consents`

Per-customer consent flags (older table; contact_consents is the history).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `record_id` | uuid |  |  |
| `kind` | text | yes |  |
| `scope` | text |  |  |
| `status` | text | yes |  |
| `given_by_customer_id` | uuid | yes |  |
| `given_at` | timestamp with time zone | yes | now() |
| `expires_at` | date |  |  |
| `evidence` | text |  |  |
| `recorded_by` | uuid |  |  |
| `revoked_at` | timestamp with time zone |  |  |
| `revoked_by` | uuid |  |  |
| `revoke_reason` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- `given_by_customer_id` → `public.customers` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: customer_consents_read (select), zella_mfa_required (all).

### `contact_consents`

Append-only consent history per phone or email, channel and purpose.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `phone_digits` | text |  |  |
| `email_lower` | text |  |  |
| `channel` | text | yes |  |
| `purpose` | text | yes | 'marketing' |
| `status` | text | yes |  |
| `source` | text | yes |  |
| `keyword` | text |  |  |
| `evidence` | jsonb | yes | '{}' |
| `recorded_by` | uuid |  |  |
| `recorded_at` | timestamp with time zone | yes | clock_timestamp() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: members read consents (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `duplicate_reviews`

Possible duplicate customers waiting for staff to merge or keep apart.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `incoming` | jsonb | yes |  |
| `status` | text | yes | 'open' |
| `resolved_by` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: duplicate_reviews_select (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `crm_tasks`

Tasks for staff on customers and records.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `kind` | text | yes | 'follow_up' |
| `title` | text | yes |  |
| `body` | text |  |  |
| `priority` | text | yes | 'normal' |
| `status` | text | yes | 'open' |
| `due_at` | timestamp with time zone |  |  |
| `assigned_to` | uuid |  |  |
| `source` | text | yes | 'automation' |
| `entity_id` | uuid |  |  |
| `escalated_at` | timestamp with time zone |  |  |
| `completed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `overdue_notified_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: crm_tasks_select (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `crm_record_types`

A business's industry record types (pet, vehicle, matter, job, ...) and their fields.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `key` | text | yes |  |
| `singular` | text | yes |  |
| `plural` | text | yes |  |
| `icon` | text | yes | 'folder' |
| `title_label` | text | yes | 'Name' |
| `link_person` | boolean | yes | true |
| `statuses` | jsonb | yes |  |
| `closed_statuses` | text[] | yes | '{}'[] |
| `fields` | jsonb | yes | '[]' |
| `columns` | text[] | yes | '{}'[] |
| `notice` | text |  |  |
| `enabled` | boolean | yes | true |
| `position` | integer | yes | 0 |
| `preset_key` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `capability` | text |  |  |
| `capacity` | jsonb |  |  |
| `fields_seen` | text[] | yes | '{}'[] |
| `appointment_link` | boolean | yes | false |
| `workflow` | jsonb | yes | '{}' |

- Primary key: `id`.
- Unique: `(business_id, key)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: crm_record_types_select (select), zella_mfa_required (all).
- Triggers: `zella_record_type_defaults`, `zella_record_workflow_defaults`.

### `crm_records`

Industry records (one pet, one vehicle, one matter) linked to customers.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `type_key` | text | yes |  |
| `title` | text | yes |  |
| `status` | text | yes |  |
| `customer_id` | uuid |  |  |
| `assigned_to` | uuid |  |  |
| `due_at` | timestamp with time zone |  |  |
| `data` | jsonb | yes | '{}' |
| `unique_key` | text |  |  |
| `source` | text | yes | 'staff' |
| `created_by` | uuid |  |  |
| `closed_at` | timestamp with time zone |  |  |
| `archived_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `business_id, type_key` → `public.crm_record_types` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: crm_records_select (select), zella_mfa_required (all), zella_record_type_enabled_read (select).
- Triggers: `zella_industry_status`, `zella_record_status_touches`, `zz_tenant_links`.

### `crm_record_events`

History of each industry record.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `detail` | text |  |  |
| `actor` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: crm_record_events_select (select), zella_mfa_required (all).

### `crm_record_files`

Files attached to records, with the upload check verdict.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `path` | text | yes |  |
| `file_name` | text | yes |  |
| `mime_type` | text | yes |  |
| `size_bytes` | bigint | yes |  |
| `kind` | text | yes |  |
| `caption` | text |  |  |
| `private` | boolean | yes | false |
| `status` | text | yes | 'pending' |
| `uploaded_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `removed_at` | timestamp with time zone |  |  |
| `removed_by` | uuid |  |  |
| `checked_at` | timestamp with time zone |  |  |
| `sha256` | text |  |  |
| `check_result` | text |  |  |
| `purged_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(path)`.
- `business_id` → `public.businesses` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: crm_record_files_read (select), zella_mfa_required (all).

### `crm_record_secrets`

Private record fields (access codes, member IDs) kept apart and shown only to allowed roles.

| Column | Type | Required | Default |
|---|---|---|---|
| `record_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `field_key` | text | yes |  |
| `value` | text | yes |  |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `record_id, field_key`.
- `business_id` → `public.businesses` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `record_workflow_presets`

Default approvals, milestones and checks per record type.

| Column | Type | Required | Default |
|---|---|---|---|
| `preset_key` | text | yes |  |
| `type_key` | text | yes |  |
| `config` | jsonb | yes |  |

- Primary key: `preset_key, type_key`.
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `record_approvals`

Approvals waiting or decided on a record.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `charge_id` | uuid |  |  |
| `kind` | text | yes |  |
| `title` | text | yes |  |
| `amount_minor` | bigint |  |  |
| `currency` | text |  |  |
| `status` | text | yes | 'requested' |
| `expires_on` | date |  |  |
| `requested_by` | uuid |  |  |
| `requested_at` | timestamp with time zone | yes | now() |
| `approver_customer_id` | uuid |  |  |
| `approver_relationship_id` | uuid |  |  |
| `method` | text |  |  |
| `file_id` | uuid |  |  |
| `decided_by` | uuid |  |  |
| `decided_at` | timestamp with time zone |  |  |
| `note` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `approver_customer_id` → `public.customers` (on delete set null).
- `approver_relationship_id` → `public.customer_relationships` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `charge_id` → `public.customer_charges` (on delete set null).
- `file_id` → `public.crm_record_files` (on delete set null).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: record_approvals_read (select), zella_mfa_required (all).

### `record_milestones`

Dates coming up on a record (renewals, due services).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `kind` | text | yes | 'milestone' |
| `title` | text | yes |  |
| `due_on` | date | yes |  |
| `staff_id` | uuid |  |  |
| `done_at` | timestamp with time zone |  |  |
| `done_by` | uuid |  |  |
| `next_of` | uuid |  |  |
| `note` | text |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `next_of` → `public.record_milestones` (on delete set null).
- `record_id` → `public.crm_records` (on delete cascade).
- `staff_id` → `public.staff_members` (on delete set null).
- Row security: on; policies: record_milestones_read (select), zella_mfa_required (all).

### `record_inspections`

Checklists done on a record during a visit.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `appointment_id` | uuid |  |  |
| `title` | text | yes |  |
| `items` | jsonb | yes | '[]' |
| `outcome` | text | yes | 'in_progress' |
| `staff_id` | uuid |  |  |
| `started_by` | uuid |  |  |
| `started_at` | timestamp with time zone | yes | now() |
| `finished_by` | uuid |  |  |
| `finished_at` | timestamp with time zone |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- `staff_id` → `public.staff_members` (on delete set null).
- Row security: on; policies: record_inspections_read (select), zella_mfa_required (all).

### `record_exceptions`

Problems holding up work on a record until resolved.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `detail` | text |  |  |
| `expected_by` | date |  |  |
| `inspection_id` | uuid |  |  |
| `opened_by` | uuid |  |  |
| `opened_at` | timestamp with time zone | yes | now() |
| `resolved_by` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `resolution` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `inspection_id` → `public.record_inspections` (on delete set null).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: record_exceptions_read (select), zella_mfa_required (all).

### `record_credits`

Units added to or used from a record (packages, class passes).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `record_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `units` | integer | yes |  |
| `appointment_id` | uuid |  |  |
| `note` | text |  |  |
| `actor` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `record_id` → `public.crm_records` (on delete cascade).
- Row security: on; policies: record_credits_read (select), zella_mfa_required (all).

### `quotes`

Quotes sent to customers and their status.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid | yes |  |
| `title` | text | yes |  |
| `status` | text | yes | 'issued' |
| `issued_at` | timestamp with time zone | yes | now() |
| `expires_at` | timestamp with time zone |  |  |
| `follow_ups_sent` | integer | yes | 0 |
| `max_follow_ups` | integer | yes | 3 |
| `follow_up_every_days` | integer | yes | 3 |
| `next_follow_up_at` | timestamp with time zone |  |  |
| `closed_at` | timestamp with time zone |  |  |
| `created_by` | uuid |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: quotes_select (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `customer_charges`

Money owed by a customer (records only; no card data).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `number` | text |  |  |
| `description` | text |  |  |
| `amount_minor` | bigint | yes |  |
| `currency` | text | yes |  |
| `status` | text | yes |  |
| `customer_id` | uuid |  |  |
| `record_id` | uuid |  |  |
| `appointment_id` | uuid |  |  |
| `due_on` | date |  |  |
| `idempotency_key` | text |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- `record_id` → `public.crm_records` (on delete set null).
- Row security: on; policies: customer_charges_read (select), zella_mfa_required (all).

### `customer_charge_payments`

Payments recorded against a customer charge.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `charge_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `amount_minor` | bigint | yes |  |
| `method` | text | yes |  |
| `source` | text | yes |  |
| `provider_ref` | text |  |  |
| `note` | text |  |  |
| `idempotency_key` | text |  |  |
| `recorded_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `charge_id` → `public.customer_charges` (on delete cascade).
- Row security: on; policies: customer_charge_payments_read (select), zella_mfa_required (all).

### `data_rights_requests`

Customer data access, export and erasure requests.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `kind` | text | yes |  |
| `requester_name` | text |  |  |
| `requester_contact` | text |  |  |
| `note` | text |  |  |
| `status` | text | yes | 'open' |
| `due_at` | timestamp with time zone | yes | (now() + '30 days'::interval) |
| `reminded_at` | timestamp with time zone |  |  |
| `created_by` | uuid |  |  |
| `handled_by` | uuid |  |  |
| `handled_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: data_rights_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

## Leads

### `lead_rules`

Per-business rules for new leads (sources, qualification, call-back timing).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `sort_order` | integer | yes | 0 |
| `match` | jsonb | yes | '{}' |
| `assign_to` | uuid |  |  |
| `set_priority` | text |  |  |
| `is_active` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: lead_rules_all (all), zella_leads_managers_delete (delete), zella_leads_managers_insert (insert), zella_leads_managers_update (update), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_lead_rule_check_trg`.

### `lead_questions`

Questions the receptionist asks a lead, and when an answer qualifies them.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `key` | text | yes |  |
| `question` | text | yes |  |
| `required` | boolean | yes | false |
| `qualifies_when` | jsonb |  |  |
| `sort_order` | integer | yes | 0 |
| `is_active` | boolean | yes | true |

- Primary key: `id`.
- Unique: `(business_id, key)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: lead_questions_all (all), zella_leads_managers_delete (delete), zella_leads_managers_insert (insert), zella_leads_managers_update (update), zella_mfa_required (all).

### `lead_submissions`

Raw lead submissions from forms and integrations, before they become customers.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `form_id` | uuid |  |  |
| `kind` | text | yes |  |
| `channel` | text | yes | 'website' |
| `status` | text | yes |  |
| `customer_id` | uuid |  |  |
| `callback_id` | uuid |  |  |
| `source` | jsonb | yes | '{}' |
| `summary` | text |  |  |
| `urgent` | boolean | yes | false |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Row security: on; policies: lead_submissions_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `website_forms`

A business's website forms and chat widgets, with their public form key.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes | 'Website' |
| `public_key` | text | yes | replace((gen_random_uuid()), '-', '') |
| `allowed_origins` | text[] | yes | '{}'[] |
| `enabled` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(public_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: website_forms_read (select), zella_mfa_required (all).

### `website_sources`

Websites a business lets Zella Voice read for knowledge.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `root_url` | text | yes |  |
| `host` | text | yes |  |
| `status` | text | yes | 'pending_approval' |
| `approved_by` | uuid |  |  |
| `approved_at` | timestamp with time zone |  |  |
| `auto_approve_new` | boolean | yes | false |
| `frequency_hours` | integer | yes | 168 |
| `max_pages` | integer | yes | 25 |
| `sitemap_urls` | text[] | yes | '{}'[] |
| `next_discovery_at` | timestamp with time zone |  |  |
| `last_discovery_at` | timestamp with time zone |  |  |
| `last_crawl_at` | timestamp with time zone |  |  |
| `last_error` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, host)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: website_sources_read (select), zella_mfa_required (all).

### `website_pages`

Pages read from those websites.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `source_id` | uuid | yes |  |
| `url` | text | yes |  |
| `status` | text | yes | 'pending' |
| `title` | text |  |  |
| `content_hash` | text |  |  |
| `text_excerpt` | text |  |  |
| `http_status` | integer |  |  |
| `fail_count` | integer | yes | 0 |
| `last_error` | text |  |  |
| `found_via` | text | yes | 'sitemap' |
| `first_seen_at` | timestamp with time zone | yes | now() |
| `last_seen_at` | timestamp with time zone |  |  |
| `last_fetched_at` | timestamp with time zone |  |  |
| `last_ok_at` | timestamp with time zone |  |  |
| `changed_at` | timestamp with time zone |  |  |
| `next_fetch_at` | timestamp with time zone |  |  |
| `claimed_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(source_id, url)`.
- `business_id` → `public.businesses` (on delete cascade).
- `source_id` → `public.website_sources` (on delete cascade).
- Row security: on; policies: website_pages_read (select), zella_mfa_required (all).

### `google_lead_keys`

Keys for Google Ads lead form webhooks (stored hashed).

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `key_hash` | text | yes |  |
| `key_hint` | text | yes |  |
| `enabled` | boolean | yes | true |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `last_lead_at` | timestamp with time zone |  |  |
| `test_received_at` | timestamp with time zone |  |  |

- Primary key: `business_id`.
- Unique: `(key_hash)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `google_lead_events`

Google lead deliveries received, for de-duplication.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `lead_id` | text | yes |  |
| `submission_id` | uuid |  |  |
| `received_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id, lead_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `assignment_rules`

How new work is assigned to staff, and when to alert about unassigned work.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `mode` | text | yes | 'round_robin' |
| `roles` | text[] | yes | ARRAY['owner', 'admin', 'manager', 's... |
| `unassigned_alert_minutes` | integer | yes | 10 |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: assignment_rules_member_read (select), zella_mfa_required (all).

## Calls and the AI receptionist

### `calls`

Every inbound and outbound call: numbers, status, outcome, summary, transcript (role-restricted).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `conversation_id` | uuid |  |  |
| `direction` | text | yes |  |
| `status` | text | yes | 'initiated' |
| `from_number` | text |  |  |
| `to_number` | text |  |  |
| `started_at` | timestamp with time zone |  |  |
| `answered_at` | timestamp with time zone |  |  |
| `ended_at` | timestamp with time zone |  |  |
| `duration_seconds` | integer |  |  |
| `recording_url` | text |  |  |
| `transcript` | text |  |  |
| `ai_handled` | boolean | yes | false |
| `external_call_id` | text |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `needs_human` | boolean | yes | false |
| `escalation_reason` | text |  |  |
| `escalated_at` | timestamp with time zone |  |  |
| `escalation_resolved_at` | timestamp with time zone |  |  |
| `escalation_resolved_by` | uuid |  |  |
| `summary` | text |  |  |
| `transfer_status` | text |  |  |
| `failure_reason` | text |  |  |
| `failure_context` | jsonb |  |  |
| `assigned_to` | uuid |  |  |
| `outcome` | text |  |  |
| `outcome_note` | text |  |  |
| `outcome_at` | timestamp with time zone |  |  |
| `escalation_acknowledged_at` | timestamp with time zone |  |  |
| `escalation_acknowledged_by` | uuid |  |  |
| `escalation_reminded_at` | timestamp with time zone |  |  |
| `transfer_approved_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete set null).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: business members can create calls (insert), business members can update calls (update), business members can view calls (select), zella_mfa_required (all), zella_module_calls_read (select), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_billing_call_spam_trg`, `zella_call_insight_queue`, `zella_call_integrity`, `zella_calls_callbacks_trg`, `zella_calls_usage`, `zella_spam_call`, `zz_tenant_links`.

### `call_messages`

Messages the receptionist took for the business.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `call_id` | uuid |  |  |
| `customer_id` | uuid |  |  |
| `kind` | text | yes | 'message' |
| `caller_name` | text |  |  |
| `caller_phone` | text |  |  |
| `message` | text | yes |  |
| `after_hours` | boolean | yes | false |
| `status` | text | yes | 'new' |
| `handled_by` | uuid |  |  |
| `handled_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `call_id` → `public.calls` (on delete set null).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: call_messages_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `call_insights`

AI call intelligence results (topics, sentiment) when switched on.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `call_id` | uuid | yes |  |
| `status` | text | yes | 'pending' |
| `attempts` | integer | yes | 0 |
| `claimed_at` | timestamp with time zone |  |  |
| `intent` | text |  |  |
| `sentiment` | text |  |  |
| `urgency` | text |  |  |
| `summary` | text |  |  |
| `details` | jsonb | yes | '{}' |
| `unresolved` | jsonb | yes | '[]' |
| `model` | text |  |  |
| `error` | text |  |  |
| `review_status` | text | yes | 'new' |
| `reviewed_by` | uuid |  |  |
| `reviewed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `processed_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(call_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `call_id` → `public.calls` (on delete cascade).
- Row security: on; policies: call_insights_read (select), zella_mfa_required (all), zella_module_calls_read (select).

### `callbacks`

Calls the business owes a customer, with status and owner.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `call_id` | uuid |  |  |
| `appointment_id` | uuid |  |  |
| `reason` | text | yes | 'other' |
| `priority` | text | yes | 'normal' |
| `status` | text | yes | 'new' |
| `contact_number` | text |  |  |
| `summary` | text |  |  |
| `preferred_at` | timestamp with time zone |  |  |
| `due_at` | timestamp with time zone |  |  |
| `assigned_to` | uuid |  |  |
| `assigned_team` | text |  |  |
| `auto_call` | boolean | yes | false |
| `attempts` | integer | yes | 0 |
| `max_attempts` | integer | yes | 3 |
| `retry_delay_minutes` | integer | yes | 120 |
| `outcome` | text |  |  |
| `note` | text |  |  |
| `locked_at` | timestamp with time zone |  |  |
| `created_by` | text | yes | 'ai' |
| `completed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `overdue_notified_at` | timestamp with time zone |  |  |
| `overdue_escalated_at` | timestamp with time zone |  |  |
| `reminder_sent_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: callbacks_select (select), zella_mfa_required (all).
- Triggers: `zella_auto_assign_callback_trg`, `zz_tenant_links`.

### `callback_attempts`

Each attempt to make a callback.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `callback_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `attempt_no` | integer | yes |  |
| `attempted_at` | timestamp with time zone | yes | now() |
| `outcome` | text | yes |  |
| `provider_ref` | text |  |  |
| `error` | text |  |  |
| `notes` | text |  |  |
| `next_attempt_at` | timestamp with time zone |  |  |
| `initiated_by` | text | yes | 'system' |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `callback_id` → `public.callbacks` (on delete cascade).
- Row security: on; policies: callback_attempts_select (select), zella_mfa_required (all).

### `ai_agents`

Receptionist agents per business.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `agent_type` | text | yes |  |
| `description` | text |  |  |
| `status` | text | yes | 'active' |
| `channels` | text[] | yes | '{}'[] |
| `is_default` | boolean | yes | false |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business members can view ai agents (select), zella_mfa_required (all).
- Triggers: `zella_audit_privileged_trg`.

### `ai_agent_configs`

Receptionist settings per business (greeting, rules, escalation, safety lines).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `agent_id` | uuid | yes |  |
| `system_prompt` | text |  |  |
| `personality` | text |  |  |
| `tone` | text |  |  |
| `goals` | jsonb | yes | '[]' |
| `capabilities` | jsonb | yes | '[]' |
| `knowledge_base` | jsonb | yes | '{}' |
| `escalation_rules` | jsonb | yes | '{}' |
| `appointment_rules` | jsonb | yes | '{}' |
| `voice_config` | jsonb | yes | '{}' |
| `business_context` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(agent_id)`.
- `agent_id` → `public.ai_agents` (on delete cascade).
- Row security: on; policies: business members can view ai agent configs (select), zella_mfa_required (all).
- Triggers: `zella_setup_knowledge_trg`.

### `agent_config_versions`

Versions of the assistant configuration that was built and sent to Vapi.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `agent_id` | uuid | yes |  |
| `version` | integer | yes |  |
| `config` | jsonb | yes |  |
| `status` | text | yes | 'draft' |
| `validation_errors` | jsonb | yes | '[]' |
| `sync_status` | text | yes | 'none' |
| `sync_error` | text |  |  |
| `created_by` | uuid |  |  |
| `published_by` | uuid |  |  |
| `published_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(agent_id, version)`.
- `agent_id` → `public.ai_agents` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: agent_config_versions_read (select), agent_config_versions_select (select), zella_mfa_required (all).

### `assistant_deliveries`

Which configuration version each call actually received.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | bigint | yes |  |
| `business_id` | uuid |  |  |
| `version_id` | uuid |  |  |
| `provider_call_id` | text |  |  |
| `outcome` | text | yes |  |
| `problems` | jsonb | yes | '[]' |
| `created_at` | timestamp with time zone | yes | now() |
| `config_hash` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `version_id` → `public.agent_config_versions` (on delete set null).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `ai_tool_calls`

Every receptionist tool call, its arguments, answer and idempotency key.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `provider_call_id` | text |  |  |
| `tool` | text | yes |  |
| `idempotency_key` | text |  |  |
| `arg_keys` | text[] | yes | '{}'[] |
| `status` | text | yes | 'started' |
| `result_status` | text |  |  |
| `verified` | boolean |  |  |
| `error` | text |  |  |
| `result` | jsonb |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `finished_at` | timestamp with time zone |  |  |
| `lookup_ref` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: ai_tool_calls_read (select), zella_mfa_required (all).

### `ai_answer_reports`

Staff reports of a wrong receptionist answer, with the right one.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `call_id` | uuid |  |  |
| `reported_by` | uuid |  |  |
| `what_was_wrong` | text | yes |  |
| `correct_answer` | text |  |  |
| `status` | text | yes | 'open' |
| `knowledge_item_id` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `call_id` → `public.calls` (on delete set null).
- `knowledge_item_id` → `public.knowledge_items` (on delete set null).
- Row security: on; policies: ai_answer_reports_read (select), zella_mfa_required (all).

### `ai_response_samples`

Calls sampled for quality review and the reviewer's verdict.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `call_id` | uuid | yes |  |
| `verdict` | text |  |  |
| `note` | text |  |  |
| `reviewed_by` | uuid |  |  |
| `reviewed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(call_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `call_id` → `public.calls` (on delete cascade).
- Row security: on; policies: ai_response_samples_read (select), zella_mfa_required (all).

### `ai_eval_cases`

Test cases the receptionist must pass per industry.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `question` | text | yes |  |
| `expect_contains` | text[] | yes | '{}'[] |
| `expect_none` | boolean | yes | false |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: ai_eval_cases_all (all), zella_mfa_required (all).

### `vapi_request_receipts`

Vapi requests already accepted, so a replay is refused.

| Column | Type | Required | Default |
|---|---|---|---|
| `signature_hash` | text | yes |  |
| `received_at` | timestamp with time zone | yes | now() |

- Primary key: `signature_hash`.
- Row security: on; policies: zella_mfa_required (all).

### `on_call_settings`

After-hours and emergency transfer settings per business.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `enabled` | boolean | yes | false |
| `scope` | text | yes | 'after_hours' |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: on_call_settings_read (select), zella_mfa_required (all).

### `on_call_shifts`

The on-call rota: who takes transfers, when.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `staff_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `weekday` | smallint |  |  |
| `starts` | time without time zone |  |  |
| `ends` | time without time zone |  |  |
| `starts_at` | timestamp with time zone |  |  |
| `ends_at` | timestamp with time zone |  |  |
| `note` | text |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `staff_id` → `public.staff_members` (on delete cascade).
- Row security: on; policies: on_call_shifts_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `on_call_reminders_sent`

Reminders sent to on-call staff, so each is sent once.

| Column | Type | Required | Default |
|---|---|---|---|
| `shift_id` | uuid | yes |  |
| `starts_at` | timestamp with time zone | yes |  |
| `sent_at` | timestamp with time zone | yes | now() |

- Primary key: `shift_id, starts_at`.
- Row security: on; policies: zella_mfa_required (all).

### `store_lookup_guards`

Limits on order lookups by phone, per call and caller.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `provider_call_id` | text | yes |  |
| `reservation_id` | uuid |  |  |
| `caller_number` | text |  |  |
| `lookup_ref` | text |  |  |

- Primary key: `business_id, provider_call_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

## Knowledge

### `knowledge_items`

Approved answers the receptionist may use.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `kind` | text | yes | 'faq' |
| `title` | text | yes |  |
| `question` | text |  |  |
| `answer` | text | yes |  |
| `status` | text | yes | 'processing' |
| `version` | integer | yes | 1 |
| `error` | text |  |  |
| `gap_id` | uuid |  |  |
| `created_by` | uuid |  |  |
| `approved_by` | uuid |  |  |
| `approved_at` | timestamp with time zone |  |  |
| `ready_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `source_page_id` | uuid |  |  |
| `source_url` | text |  |  |
| `source_key` | text |  |  |
| `conflicts_with` | uuid |  |  |
| `source_stale` | boolean | yes | false |
| `sync_attempts` | integer | yes | 0 |
| `search` | tsvector |  | to_tsvector('english'::regconfig, (((... |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `source_page_id` → `public.website_pages` (on delete set null).
- Row security: on; policies: knowledge_items_member_insert (insert), knowledge_items_member_select (select), knowledge_items_member_update (update), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_knowledge_guard_trg`, `zella_knowledge_source_guard_trg`, `zella_knowledge_version_log_trg`, `zella_knowledge_zcheck_trg`.

### `knowledge_versions`

History of each knowledge item.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `item_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `version` | integer | yes |  |
| `title` | text |  |  |
| `question` | text |  |  |
| `answer` | text |  |  |
| `status` | text |  |  |
| `changed_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `item_id` → `public.knowledge_items` (on delete cascade).
- Row security: on; policies: knowledge_versions_read (select), zella_mfa_required (all).

### `knowledge_gaps`

Questions the receptionist could not answer, for the owner to fill in.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `call_id` | uuid |  |  |
| `customer_id` | uuid |  |  |
| `question` | text | yes |  |
| `question_key` | text | yes |  |
| `times_asked` | integer | yes | 1 |
| `status` | text | yes | 'open' |
| `knowledge_item_id` | uuid |  |  |
| `notified_at` | timestamp with time zone |  |  |
| `resolved_by` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `first_asked_at` | timestamp with time zone | yes | now() |
| `last_asked_at` | timestamp with time zone | yes | now() |
| `suggested_title` | text |  |  |
| `suggested_answer` | text |  |  |
| `suggested_kind` | text |  |  |
| `suggestion_source` | text |  |  |
| `suggestion_confidence` | text |  |  |
| `suggestion_attempts` | integer | yes | 0 |
| `suggested_at` | timestamp with time zone |  |  |
| `repeat_notified_at` | timestamp with time zone |  |  |
| `report_notified_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: knowledge_gaps_member_select (select), zella_mfa_required (all).

## Scheduling

### `appointments`

Bookings of every kind (appointments, jobs, visits, reservations, classes).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `assigned_to` | uuid |  |  |
| `title` | text | yes |  |
| `description` | text |  |  |
| `appointment_type` | text |  |  |
| `status` | text | yes | 'scheduled' |
| `start_time` | timestamp with time zone | yes |  |
| `end_time` | timestamp with time zone | yes |  |
| `timezone` | text | yes | 'America/New_York' |
| `location` | text |  |  |
| `meeting_url` | text |  |  |
| `external_event_id` | text |  |  |
| `reminder_sent` | boolean | yes | false |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `checked_in_at` | timestamp with time zone |  |  |
| `internal_notes` | text |  |  |
| `party_size` | integer |  |  |
| `staff_id` | uuid |  |  |
| `booking_state` | text | yes | 'confirmed' |
| `hold_expires_at` | timestamp with time zone |  |  |
| `original_start_time` | timestamp with time zone |  |  |
| `rescheduled_at` | timestamp with time zone |  |  |
| `reschedule_count` | integer | yes | 0 |
| `reschedule_requested_by` | text |  |  |
| `cancelled_at` | timestamp with time zone |  |  |
| `cancel_reason` | text |  |  |
| `conflict_note` | text |  |  |
| `arrived_at` | timestamp with time zone |  |  |
| `in_service_at` | timestamp with time zone |  |  |
| `attendance_source` | text |  |  |
| `attendance_by` | uuid |  |  |
| `attendance_note` | text |  |  |
| `record_id` | uuid |  |  |
| `record_suggested_id` | uuid |  |  |
| `table_ids` | uuid[] |  |  |
| `resource_ids` | uuid[] |  |  |
| `crew_staff_ids` | uuid[] |  |  |

- Primary key: `id`.
- `assigned_to` → `public.profiles` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- `record_id` → `public.crm_records` (on delete set null).
- `record_suggested_id` → `public.crm_records` (on delete set null).
- `staff_id` → `public.staff_members` (on delete set null).
- Row security: on; policies: business members can create appointments (insert), business members can update appointments (update), business members can view appointments (select), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_appointment_after_trg`, `zella_appointment_before_trg`, `zella_appointment_conflict_guard`, `zella_appointment_message`, `zella_appointment_moved`, `zella_appointment_new`, `zella_appointment_record`, `zella_appointment_record_event`, `zella_appointment_record_match`, `zella_appointment_source_trg`, `zella_appointment_staff`, `zella_appointment_touches`, `zella_booking_messages_withdrawn`, `zella_calendar_sync_trg`, `zella_capability_appointment`, `zella_cross_sell_booked`, `zella_cross_sell_completed`, `zella_no_show_followup`, `zella_resource_guard`, `zella_spam_booking_guard`, `zella_spam_booking_record`, `zella_table_clearing_trg`, `zz_tenant_links`.

### `appointment_reminders`

Reminders and confirmations due for each appointment.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `appointment_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `kind` | text | yes |  |
| `channel` | text | yes | 'sms' |
| `hours_before` | numeric |  |  |
| `reason` | text |  |  |
| `due_at` | timestamp with time zone | yes |  |
| `status` | text | yes | 'pending' |
| `attempts` | integer | yes | 0 |
| `sent_at` | timestamp with time zone |  |  |
| `error` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: appointment_reminders_select (select), zella_mfa_required (all).
- Triggers: `zella_welcome_superseded`, `zz_tenant_links`.

### `appointment_reschedule_links`

Private reschedule links sent to customers (stored hashed).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `appointment_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `token_hash` | text | yes |  |
| `created_at` | timestamp with time zone | yes | now() |
| `last_used_at` | timestamp with time zone |  |  |
| `uses` | integer | yes | 0 |
| `purpose` | text | yes | 'reschedule' |
| `expires_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(token_hash)`.
- `appointment_id` → `public.appointments` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `blocked_times`

Times a staff member or the business cannot be booked.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `title` | text | yes | 'Blocked' |
| `reason` | text |  |  |
| `start_time` | timestamp with time zone | yes |  |
| `end_time` | timestamp with time zone | yes |  |
| `all_day` | boolean | yes | false |
| `staff_id` | uuid |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `source` | text |  |  |
| `external_id` | text |  |  |
| `connection_id` | uuid |  |  |
| `resource_id` | uuid |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `resource_id` → `public.resources` (on delete cascade).
- `staff_id` → `public.staff_members` (on delete cascade).
- Row security: on; policies: blocked_times_member_delete (delete), blocked_times_member_insert (insert), blocked_times_member_select (select), blocked_times_member_update (update), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zella_block_trg`, `zella_resource_block_guard`, `zz_tenant_links`.

### `resources`

Rooms, chairs, bays and equipment bookings need.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `kind` | text | yes |  |
| `capacity` | integer | yes | 1 |
| `buffer_minutes` | integer | yes | 0 |
| `is_active` | boolean | yes | true |
| `sort_order` | integer | yes | 0 |
| `notes` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: resources_read (select), zella_mfa_required (all).

### `resource_needs`

Which resources each service needs, and how many.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `service` | text | yes |  |
| `kind` | text | yes |  |
| `quantity` | integer | yes | 1 |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: resource_needs_read (select), zella_mfa_required (all).

### `recurring_plans`

Repeat work (every two weeks, monthly) per customer.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `record_id` | uuid |  |  |
| `title` | text | yes |  |
| `service` | text |  |  |
| `duration_minutes` | integer | yes | 60 |
| `frequency` | text | yes |  |
| `interval_count` | integer | yes | 1 |
| `weekday` | smallint |  |  |
| `month_day` | smallint |  |  |
| `start_at` | time without time zone | yes |  |
| `staff_id` | uuid |  |  |
| `resource_ids` | uuid[] |  |  |
| `starts_on` | date | yes |  |
| `ends_on` | date |  |  |
| `is_active` | boolean | yes | true |
| `notes` | text |  |  |
| `generated_through` | date |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- `record_id` → `public.crm_records` (on delete set null).
- `staff_id` → `public.staff_members` (on delete set null).
- Row security: on; policies: recurring_plans_read (select), zella_mfa_required (all).

### `recurring_visits`

The visits generated from a recurring plan.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `plan_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `occurs_on` | date | yes |  |
| `appointment_id` | uuid |  |  |
| `outcome` | text | yes |  |
| `reason` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `plan_id` → `public.recurring_plans` (on delete cascade).
- Row security: on; policies: recurring_visits_read (select), zella_mfa_required (all).

### `job_dispatch`

Field job progress: en route, on site, finished, checklist.

| Column | Type | Required | Default |
|---|---|---|---|
| `appointment_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `status` | text | yes | 'assigned' |
| `en_route_at` | timestamp with time zone |  |  |
| `on_site_at` | timestamp with time zone |  |  |
| `finished_at` | timestamp with time zone |  |  |
| `checklist` | jsonb | yes | '[]' |
| `return_of` | uuid |  |  |
| `note` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |
| `updated_by` | uuid |  |  |

- Primary key: `appointment_id`.
- `appointment_id` → `public.appointments` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- `return_of` → `public.appointments` (on delete set null).
- Row security: on; policies: job_dispatch_read (select), zella_mfa_required (all).

### `waitlist_entries`

People waiting for a time to free up.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid | yes |  |
| `title` | text |  |  |
| `duration_minutes` | integer | yes | 30 |
| `earliest_at` | timestamp with time zone |  |  |
| `latest_at` | timestamp with time zone |  |  |
| `staff_id` | uuid |  |  |
| `notes` | text |  |  |
| `status` | text | yes | 'waiting' |
| `offered_start` | timestamp with time zone |  |  |
| `offered_end` | timestamp with time zone |  |  |
| `offered_staff_id` | uuid |  |  |
| `offer_expires_at` | timestamp with time zone |  |  |
| `appointment_id` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `party_size` | integer |  |  |
| `preferences` | text |  |  |
| `contact_ok` | boolean |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: waitlist_select (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `waitlist_offer_links`

Private links offering a freed time to someone on the waitlist.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `entry_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `token_hash` | text | yes |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(token_hash)`.
- `business_id` → `public.businesses` (on delete cascade).
- `entry_id` → `public.waitlist_entries` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `calendar_connections`

Connected Google or Outlook calendars (tokens in Vault, not here).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `provider` | text | yes | 'google' |
| `status` | text | yes | 'active' |
| `calendar_id` | text | yes | 'primary' |
| `account_email` | text |  |  |
| `vault_secret_name` | text |  |  |
| `connected_at` | timestamp with time zone | yes | now() |
| `last_pushed_at` | timestamp with time zone |  |  |
| `last_pulled_at` | timestamp with time zone |  |  |
| `busy_refresh_due_at` | timestamp with time zone |  |  |
| `last_error` | text |  |  |

- Primary key: `id`.
- Unique: `(business_id, provider)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: calendar_connections_member_read (select), zella_mfa_required (all).

### `calendar_sync_queue`

Calendar sync work waiting for the calendar worker.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `appointment_id` | uuid | yes |  |
| `action` | text | yes |  |
| `status` | text | yes | 'pending' |
| `attempts` | integer | yes | 0 |
| `due_at` | timestamp with time zone | yes | now() |
| `claimed_at` | timestamp with time zone |  |  |
| `event_id` | text |  |  |
| `error` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `completed_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `restaurant_tables`

A restaurant's tables and seats.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `section` | text | yes | 'Main dining room' |
| `min_party` | integer | yes | 1 |
| `max_party` | integer | yes |  |
| `attributes` | text[] | yes | '{}'[] |
| `active` | boolean | yes | true |
| `position` | integer | yes | 0 |
| `notes` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |
| `pos_x` | numeric(5,2) |  |  |
| `pos_y` | numeric(5,2) |  |  |
| `shape` | text | yes | 'square' |

- Primary key: `id`.
- Unique: `(business_id, name)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: restaurant_tables_member_select (select).

### `table_combinations`

Tables that can be joined for larger parties.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `table_ids` | uuid[] | yes |  |
| `min_party` | integer | yes | 1 |
| `max_party` | integer | yes |  |
| `active` | boolean | yes | true |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: table_combinations_member_select (select).

### `table_states`

Each table's live state (free, seated, needs cleaning).

| Column | Type | Required | Default |
|---|---|---|---|
| `table_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `state` | text | yes |  |
| `appointment_id` | uuid |  |  |
| `since` | timestamp with time zone | yes | now() |
| `by_user` | uuid |  |  |

- Primary key: `table_id`.
- `business_id` → `public.businesses` (on delete cascade).
- `table_id` → `public.restaurant_tables` (on delete cascade).
- Row security: on; policies: table_states_member_select (select).

### `table_blocks`

Times a table cannot be booked.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `table_id` | uuid | yes |  |
| `starts_at` | timestamp with time zone | yes |  |
| `ends_at` | timestamp with time zone | yes |  |
| `reason` | text |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `table_id` → `public.restaurant_tables` (on delete cascade).
- Row security: on; policies: table_blocks_member_select (select).

### `table_events`

History of table changes.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | bigint | yes |  |
| `business_id` | uuid | yes |  |
| `table_id` | uuid |  |  |
| `appointment_id` | uuid |  |  |
| `action` | text | yes |  |
| `by_user` | uuid |  |  |
| `detail` | jsonb | yes | '{}' |
| `at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: table_events_member_select (select).

## Messages and conversations

### `conversations`

A thread with a customer on one channel.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `channel` | text | yes |  |
| `status` | text | yes | 'open' |
| `subject` | text |  |  |
| `assigned_to` | uuid |  |  |
| `ai_handled` | boolean | yes | false |
| `last_message_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `priority` | text | yes | 'normal' |
| `last_read_at` | timestamp with time zone |  |  |
| `last_inbound_at` | timestamp with time zone |  |  |
| `handover_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `assigned_to` → `public.profiles` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: business members can create conversations (insert), business members can update conversations (update), business members can view conversations (select), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).
- Triggers: `zz_tenant_links`.

### `conversation_messages`

Messages in a conversation.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `conversation_id` | uuid | yes |  |
| `sender_type` | text | yes |  |
| `message_type` | text | yes | 'text' |
| `content` | text |  |  |
| `external_message_id` | text |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `conversation_id` → `public.conversations` (on delete cascade).
- Row security: on; policies: business members can create conversation messages (insert), business members can view conversation messages (select), zella_mfa_required (all).
- Triggers: `zella_conversation_touch`.

### `conversation_notes`

Staff notes on a conversation.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `conversation_id` | uuid | yes |  |
| `author_id` | uuid |  |  |
| `author_name` | text |  |  |
| `body` | text | yes |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete cascade).
- Row security: on; policies: members read conversation notes (select), zella_mfa_required (all).

### `message_templates`

Text and email templates (platform defaults and business copies).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `industry_id` | uuid |  |  |
| `key` | text | yes |  |
| `channel` | text | yes |  |
| `purpose` | text | yes | 'transactional' |
| `locale` | text | yes | 'en-US' |
| `subject` | text |  |  |
| `body` | text | yes |  |
| `version` | integer | yes | 1 |
| `status` | text | yes | 'active' |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `industry_id` → `public.industries` (on delete cascade).
- Row security: on; policies: members read templates (select), zella_mfa_required (all).

### `message_drafts`

Suggested messages waiting for staff approval.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid | yes |  |
| `body` | text | yes |  |
| `reason` | text |  |  |
| `entity_id` | uuid |  |  |
| `status` | text | yes | 'pending' |
| `decided_by` | uuid |  |  |
| `decided_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: message_drafts_read (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `sms_messages`

Every text prepared, sent, skipped or received, with status.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `conversation_id` | uuid |  |  |
| `direction` | text | yes |  |
| `status` | text | yes | 'queued' |
| `from_number` | text |  |  |
| `to_number` | text |  |  |
| `message_body` | text |  |  |
| `external_message_id` | text |  |  |
| `sent_at` | timestamp with time zone |  |  |
| `delivered_at` | timestamp with time zone |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete set null).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: business members can create sms (insert), business members can view sms (select), zella_mfa_required (all).
- Triggers: `zella_billing_sms_trg`, `zella_spam_sms`, `zz_tenant_links`.

### `email_messages`

Every email prepared, sent or skipped, with status.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `conversation_id` | uuid |  |  |
| `direction` | text | yes |  |
| `status` | text | yes | 'queued' |
| `from_email` | text |  |  |
| `to_email` | text |  |  |
| `cc` | text |  |  |
| `bcc` | text |  |  |
| `subject` | text |  |  |
| `body_text` | text |  |  |
| `body_html` | text |  |  |
| `external_message_id` | text |  |  |
| `sent_at` | timestamp with time zone |  |  |
| `delivered_at` | timestamp with time zone |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete set null).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: business members can create email (insert), business members can view email (select), zella_mfa_required (all).
- Triggers: `zella_billing_email_trg`, `zella_spam_email`, `zz_tenant_links`.

### `email_events`

Delivery, bounce and complaint events from the email provider.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `provider_event_id` | text | yes |  |
| `type` | text | yes |  |
| `email_message_id` | uuid |  |  |
| `business_id` | uuid |  |  |
| `to_email` | text |  |  |
| `detail` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(provider_event_id)`.
- Row security: on; policies: zella_mfa_required (all).

### `email_unsubscribe_tokens`

Private unsubscribe links (stored hashed).

| Column | Type | Required | Default |
|---|---|---|---|
| `token` | text | yes | encode(extensions.gen_random_bytes(16... |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid | yes |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `token`.
- Unique: `(business_id, customer_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `followup_tasks`

Follow-ups due (no-show, thank-you, quote, reactivation, callback fallback).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `customer_id` | uuid |  |  |
| `appointment_id` | uuid |  |  |
| `call_id` | uuid |  |  |
| `kind` | text | yes |  |
| `channel` | text | yes | 'call' |
| `due_at` | timestamp with time zone | yes |  |
| `status` | text | yes | 'pending' |
| `attempts` | integer | yes | 0 |
| `max_attempts` | integer | yes | 2 |
| `outcome` | text |  |  |
| `outcome_notes` | text |  |  |
| `provider_call_id` | text |  |  |
| `claimed_at` | timestamp with time zone |  |  |
| `completed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `entity_ref` | uuid |  |  |
| `vars` | jsonb | yes | '{}' |

- Primary key: `id`.
- `appointment_id` → `public.appointments` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete cascade).
- Row security: on; policies: followup_tasks_member_select (select), zella_mfa_required (all).
- Triggers: `zella_message_policy`, `zella_spam_reply_guard`, `zz_tenant_links`.

### `automation_channel_reviews`

Automations whose channel needs an owner decision before they can run.

| Column | Type | Required | Default |
|---|---|---|---|
| `automation_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `trigger_type` | text | yes |  |
| `requested_channel` | text | yes |  |
| `status` | text | yes | 'needs_review' |
| `choice` | text |  |  |
| `consent_confirmed` | boolean |  |  |
| `resolved_by` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `automation_id`.
- `automation_id` → `public.automations` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: automation_channel_reviews_read (select).

### `meta_connections`

Connected Facebook, Instagram and WhatsApp accounts (tokens in Vault).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `page_id` | text | yes |  |
| `page_name` | text |  |  |
| `instagram_id` | text |  |  |
| `whatsapp_phone_id` | text |  |  |
| `waba_id` | text |  |  |
| `status` | text | yes | 'connected' |
| `token_secret` | text |  |  |
| `granted_permissions` | text[] | yes | '{}'[] |
| `call_consent_confirmed` | boolean | yes | false |
| `auto_acknowledge` | boolean | yes | true |
| `comment_keywords` | text[] | yes | '{}'[] |
| `last_checked_at` | timestamp with time zone |  |  |
| `next_check_at` | timestamp with time zone | yes | now() |
| `last_error` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `qualify_flow` | boolean | yes | false |

- Primary key: `id`.
- Unique: `(page_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: meta_connections_read (select), zella_mfa_required (all).

### `meta_contacts`

People met on Meta channels, linked to customers.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `channel` | text | yes |  |
| `external_id` | text | yes |  |
| `display_name` | text |  |  |
| `customer_id` | uuid |  |  |
| `conversation_id` | uuid |  |  |
| `last_ack_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, channel, external_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete set null).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `meta_events`

Webhook events received from Meta.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `event_key` | text | yes |  |
| `kind` | text | yes |  |
| `page_id` | text |  |  |
| `business_id` | uuid |  |  |
| `status` | text | yes | 'pending' |
| `payload` | jsonb | yes | '{}' |
| `attempts` | integer | yes | 0 |
| `next_try_at` | timestamp with time zone | yes | now() |
| `last_error` | text |  |  |
| `claimed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(event_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `meta_outbox`

Meta messages waiting to be sent.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `page_id` | text | yes |  |
| `channel` | text | yes |  |
| `kind` | text | yes | 'message' |
| `recipient` | text | yes |  |
| `text_body` | text | yes |  |
| `template_name` | text |  |  |
| `conversation_id` | uuid |  |  |
| `status` | text | yes | 'queued' |
| `attempts` | integer | yes | 0 |
| `next_try_at` | timestamp with time zone | yes | now() |
| `claimed_at` | timestamp with time zone |  |  |
| `external_id` | text |  |  |
| `last_error` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `template_language` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete set null).
- Row security: on; policies: zella_mfa_required (all).

### `meta_templates`

Approved WhatsApp templates.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `language` | text | yes | 'en_US' |
| `category` | text |  |  |
| `body` | text |  |  |
| `status` | text | yes | 'unknown' |
| `synced_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, name, language)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: meta_templates_read (select), zella_mfa_required (all).

### `social_flows`

Where a social-media conversation is in its question flow.

| Column | Type | Required | Default |
|---|---|---|---|
| `conversation_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `step` | text | yes | 'ask_contact' |
| `answers` | jsonb | yes | '{}' |
| `offered` | jsonb | yes | '[]' |
| `tries` | integer | yes | 0 |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `conversation_id`.
- `business_id` → `public.businesses` (on delete cascade).
- `conversation_id` → `public.conversations` (on delete cascade).
- Row security: on; policies: social_flows_read (select), zella_mfa_required (all).

### `live_notices`

Short notices the receptionist reads out (closed today, running late).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `message` | text | yes |  |
| `ends_at` | timestamp with time zone | yes |  |
| `created_by` | uuid |  |  |
| `cleared_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: live_notices_read (select), zella_mfa_required (all).

## Spam and abuse

### `spam_settings`

Per-business spam protection settings.

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `enabled` | boolean | yes | true |
| `call_screening` | text | yes | 'flag' |
| `ai_spam_handling` | text | yes | 'end_politely' |
| `repeat_call_limit` | integer | yes | 5 |
| `repeat_window_minutes` | integer | yes | 60 |
| `sms_monitoring` | boolean | yes | true |
| `sms_flood_limit` | integer | yes | 10 |
| `email_monitoring` | boolean | yes | true |
| `email_flood_limit` | integer | yes | 10 |
| `booking_protection` | boolean | yes | true |
| `booking_daily_limit` | integer | yes | 3 |
| `auto_restrict` | boolean | yes | true |
| `notify_high_risk` | boolean | yes | true |
| `notify_medium` | boolean | yes | false |
| `weekly_report` | boolean | yes | true |
| `ai_review` | boolean | yes | false |
| `updated_at` | timestamp with time zone | yes | now() |
| `updated_by` | uuid |  |  |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: spam_settings_read (select), zella_mfa_required (all).

### `spam_incidents`

Detected spam calls, texts and form posts, with score and outcome.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `channel` | text | yes |  |
| `sender` | text | yes |  |
| `sender_display` | text |  |  |
| `customer_id` | uuid |  |  |
| `risk_score` | integer | yes |  |
| `risk_level` | text | yes |  |
| `reasons` | jsonb | yes | '[]' |
| `action` | text | yes |  |
| `status` | text | yes | 'new' |
| `assigned_to` | uuid |  |  |
| `occurrences` | integer | yes | 1 |
| `dedupe_key` | text | yes |  |
| `last_source_table` | text |  |  |
| `last_source_id` | uuid |  |  |
| `first_seen_at` | timestamp with time zone | yes | now() |
| `last_seen_at` | timestamp with time zone | yes | now() |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `workflow_status` | text | yes | 'not_needed' |
| `workflow_attempts` | integer | yes | 0 |
| `workflow_claim` | uuid |  |  |
| `workflow_claimed_at` | timestamp with time zone |  |  |
| `workflow_next_at` | timestamp with time zone |  |  |
| `workflow_done_at` | timestamp with time zone |  |  |
| `workflow_result` | jsonb | yes | '{}' |

- Primary key: `id`.
- Unique: `(business_id, dedupe_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- `customer_id` → `public.customers` (on delete set null).
- Row security: on; policies: spam_incidents_read (select), zella_mfa_required (all).
- Triggers: `zella_spam_kick`, `zella_spam_queue`, `zz_tenant_links`.

### `spam_incident_events`

History of each spam incident.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `incident_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `kind` | text | yes |  |
| `actor` | uuid |  |  |
| `from_status` | text |  |  |
| `to_status` | text |  |  |
| `note` | text |  |  |
| `source_table` | text |  |  |
| `source_id` | uuid |  |  |
| `detail` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `incident_id` → `public.spam_incidents` (on delete cascade).
- Row security: on; policies: spam_incident_events_read (select), zella_mfa_required (all).

### `spam_list_entries`

Numbers, addresses and words a business blocks or always allows.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `list` | text | yes |  |
| `channel` | text | yes |  |
| `value_type` | text | yes |  |
| `value` | text | yes |  |
| `reason` | text |  |  |
| `source` | text | yes | 'manual' |
| `incident_id` | uuid |  |  |
| `expires_at` | timestamp with time zone |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `removed_at` | timestamp with time zone |  |  |
| `removed_by` | uuid |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: spam_list_entries_read (select), zella_mfa_required (all).

## Automations and background work

### `automations`

A business's automations and whether each is on.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `name` | text | yes |  |
| `description` | text |  |  |
| `trigger_type` | text | yes |  |
| `status` | text | yes | 'active' |
| `trigger_config` | jsonb | yes | '{}' |
| `actions` | jsonb | yes | '[]' |
| `conditions` | jsonb | yes | '[]' |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `paused_by_suspension` | boolean | yes | false |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `created_by` → `public.profiles` (on delete set null).
- Row security: on; policies: authorized managers can create automations (insert), authorized managers can delete automations (delete), authorized managers can update automations (update), business members can view automations (select), zella_mfa_required (all), zella_module_automations_delete (delete), zella_module_automations_insert (insert), zella_module_automations_read (select), zella_module_automations_update (update).
- Triggers: `zella_audit_privileged_trg`, `zella_channel_review_trg`, `zella_reminder_settings_trg`.

### `automation_runs`

Each run of an automation.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `automation_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `status` | text | yes | 'running' |
| `trigger_data` | jsonb | yes | '{}' |
| `execution_log` | jsonb | yes | '[]' |
| `error_message` | text |  |  |
| `started_at` | timestamp with time zone | yes | now() |
| `completed_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `customer_id` | uuid |  |  |
| `current_action_index` | integer | yes | 0 |
| `next_run_at` | timestamp with time zone |  |  |
| `attempt_count` | integer | yes | 0 |
| `last_action_status` | text |  |  |

- Primary key: `id`.
- `automation_id` → `public.automations` (on delete cascade).
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: business members can view automation runs (select), zella_mfa_required (all).
- Triggers: `zz_tenant_links`.

### `automation_events`

Durable events waiting for, or handled by, the event router.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `event_type` | text | yes |  |
| `schema_version` | integer | yes | 1 |
| `source` | text | yes |  |
| `provider_event_id` | text |  |  |
| `idempotency_key` | text | yes |  |
| `correlation_id` | uuid | yes | gen_random_uuid() |
| `causation_id` | uuid |  |  |
| `payload` | jsonb | yes | '{}' |
| `status` | text | yes | 'received' |
| `attempts` | integer | yes | 0 |
| `next_attempt_at` | timestamp with time zone |  |  |
| `claimed_at` | timestamp with time zone |  |  |
| `error_category` | text |  |  |
| `error_message` | text |  |  |
| `received_at` | timestamp with time zone | yes | now() |
| `processed_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(business_id, idempotency_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: managers read events (select), zella_mfa_required (all).

### `automation_dead_letters`

Events that failed for good or have no handler yet, kept visible.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `source_table` | text | yes |  |
| `source_id` | uuid | yes |  |
| `event_id` | uuid |  |  |
| `reason` | text | yes |  |
| `error_category` | text |  |  |
| `status` | text | yes | 'open' |
| `created_at` | timestamp with time zone | yes | now() |
| `resolved_by` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `event_id` → `public.automation_events` (on delete set null).
- Row security: on; policies: managers read dead letters (select), zella_mfa_required (all).

### `workflow_executions`

Record of n8n workflow runs reported back to the database.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `workflow_key` | text | yes |  |
| `workflow_version` | text |  |  |
| `event_id` | uuid |  |  |
| `correlation_id` | uuid |  |  |
| `status` | text | yes | 'running' |
| `current_step` | text |  |  |
| `steps` | jsonb | yes | '[]' |
| `provider_refs` | jsonb | yes | '{}' |
| `retry_count` | integer | yes | 0 |
| `error_category` | text |  |  |
| `error_message` | text |  |  |
| `needs_manual` | boolean | yes | false |
| `started_at` | timestamp with time zone | yes | now() |
| `finished_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `event_id` → `public.automation_events` (on delete set null).
- Row security: on; policies: managers read executions (select), zella_mfa_required (all).

### `n8n_dispatch_state`

How often the dispatcher called each n8n worker, and the stuck-item guard.

| Column | Type | Required | Default |
|---|---|---|---|
| `workflow` | text | yes |  |
| `last_triggered_at` | timestamp with time zone |  |  |
| `last_count` | integer | yes | 0 |
| `consecutive_same` | integer | yes | 0 |
| `triggers_total` | bigint | yes | 0 |

- Primary key: `workflow`.
- Row security: on; policies: zella_mfa_required (all).

### `integrations`

A business's connected integrations and their status.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `provider` | text | yes |  |
| `integration_type` | text | yes |  |
| `status` | text | yes | 'active' |
| `account_email` | text |  |  |
| `external_account_id` | text |  |  |
| `credentials` | jsonb | yes | '{}' |
| `configuration` | jsonb | yes | '{}' |
| `last_synced_at` | timestamp with time zone |  |  |
| `error_message` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `last_error` | text |  |  |
| `last_checked_at` | timestamp with time zone |  |  |
| `error_count` | integer | yes | 0 |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: authorized managers can create integrations (insert), authorized managers can update integrations (update), business members can view integrations (select), zella_mfa_required (all).

### `integration_secrets`

References to secrets for integrations (values in Vault).

| Column | Type | Required | Default |
|---|---|---|---|
| `integration_id` | uuid | yes |  |
| `credentials` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `integration_id`.
- `integration_id` → `public.integrations` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `provider_health`

Latest health check per provider.

| Column | Type | Required | Default |
|---|---|---|---|
| `provider` | text | yes |  |
| `ok` | boolean |  |  |
| `detail` | text |  |  |
| `checked_at` | timestamp with time zone |  |  |
| `claimed_at` | timestamp with time zone |  |  |
| `consecutive_failures` | integer | yes | 0 |
| `last_ok_at` | timestamp with time zone |  |  |

- Primary key: `provider`.
- Row security: on; policies: zella_mfa_required (all).

## Offers, reviews and growth

### `offers`

Platform offers and promotions.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `name` | text | yes |  |
| `description` | text |  |  |
| `internal_note` | text |  |  |
| `offer_type` | text | yes | 'percent_discount' |
| `status` | text | yes | 'draft' |
| `discount_kind` | text | yes | 'percent' |
| `percent_off_bp` | integer |  |  |
| `amount_off_cents` | bigint |  |  |
| `currency` | text | yes | 'usd' |
| `duration` | text | yes | 'once' |
| `duration_months` | integer |  |  |
| `timezone` | text | yes | 'America/New_York' |
| `starts_at` | timestamp with time zone |  |  |
| `ends_at` | timestamp with time zone |  |  |
| `eligibility` | jsonb | yes | '{"match": "all", "rules": []}' |
| `max_redemptions` | integer |  |  |
| `max_per_business` | integer | yes | 1 |
| `code` | text |  |  |
| `code_case_sensitive` | boolean | yes | false |
| `stackable` | boolean | yes | false |
| `channels` | text[] | yes | ARRAY['dashboard'] |
| `needs_approval` | boolean | yes | false |
| `created_by` | uuid |  |  |
| `submitted_by` | uuid |  |  |
| `submitted_at` | timestamp with time zone |  |  |
| `approved_by` | uuid |  |  |
| `approved_at` | timestamp with time zone |  |  |
| `activated_at` | timestamp with time zone |  |  |
| `paused_at` | timestamp with time zone |  |  |
| `expired_at` | timestamp with time zone |  |  |
| `archived_at` | timestamp with time zone |  |  |
| `version` | integer | yes | 1 |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Row security: on; policies: zella_mfa_required (all).

### `offer_rules`

Who an offer applies to and when.

| Column | Type | Required | Default |
|---|---|---|---|
| `key` | text | yes |  |
| `enabled` | boolean | yes | false |
| `config` | jsonb | yes | '{}' |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `key`.
- Row security: on; policies: zella_mfa_required (all).

### `offer_redemptions`

Offers a business redeemed.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `offer_id` | uuid | yes |  |
| `business_id` | uuid | yes |  |
| `status` | text | yes | 'pending' |
| `source` | text | yes |  |
| `idempotency_key` | text | yes |  |
| `terms` | jsonb | yes | '{}' |
| `discount_cents` | bigint |  |  |
| `payment_id` | uuid |  |  |
| `hold_until` | timestamp with time zone |  |  |
| `claimed_by` | uuid |  |  |
| `note` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `confirmed_at` | timestamp with time zone |  |  |
| `ended_at` | timestamp with time zone |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(idempotency_key)`.
- `business_id` → `public.businesses` (on delete restrict).
- `offer_id` → `public.offers` (on delete restrict).
- `payment_id` → `public.payments` (on delete set null).
- Row security: on; policies: zella_mfa_required (all).

### `offer_events`

History of offer changes.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `offer_id` | uuid |  |  |
| `business_id` | uuid |  |  |
| `kind` | text | yes |  |
| `from_status` | text |  |  |
| `to_status` | text |  |  |
| `actor` | uuid |  |  |
| `detail` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete set null).
- `offer_id` → `public.offers` (on delete restrict).
- Row security: on; policies: zella_mfa_required (all).

### `offer_job_runs`

Runs of the offer background jobs.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `job` | text | yes |  |
| `trigger` | text | yes | 'schedule' |
| `status` | text | yes | 'running' |
| `processed` | integer | yes | 0 |
| `failures` | integer | yes | 0 |
| `error` | text |  |  |
| `detail` | jsonb | yes | '{}' |
| `started_by` | uuid |  |  |
| `started_at` | timestamp with time zone | yes | now() |
| `finished_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Row security: on; policies: zella_mfa_required (all).

### `cross_sell_rules`

'You might also need' follow-up suggestions per service.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `after_service` | text | yes |  |
| `suggestion` | text | yes |  |
| `delay_days` | integer | yes | 14 |
| `active` | boolean | yes | true |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: cross_sell_rules_read (select), zella_mfa_required (all).

### `review_sources`

Where a business's reviews come from (Google).

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `provider` | text | yes | 'google' |
| `account_id` | text | yes |  |
| `location_id` | text | yes |  |
| `status` | text | yes | 'active' |
| `last_error` | text |  |  |
| `consecutive_failures` | integer | yes | 0 |
| `last_fetched_at` | timestamp with time zone |  |  |
| `next_fetch_at` | timestamp with time zone | yes | now() |
| `claimed_at` | timestamp with time zone |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: review_sources_read (select), zella_mfa_required (all).

### `reviews`

Reviews received and the reply drafts waiting for owner approval.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `provider` | text | yes |  |
| `external_id` | text | yes |  |
| `site` | text |  |  |
| `author_name` | text |  |  |
| `rating` | smallint |  |  |
| `body` | text |  |  |
| `reviewed_at` | timestamp with time zone | yes | now() |
| `status` | text | yes | 'drafted' |
| `draft` | text |  |  |
| `draft_source` | text |  |  |
| `ai_status` | text | yes | 'none' |
| `ai_attempts` | integer | yes | 0 |
| `ai_claimed_at` | timestamp with time zone |  |  |
| `reply` | text |  |  |
| `existing_reply` | text |  |  |
| `decided_by` | uuid |  |  |
| `decided_at` | timestamp with time zone |  |  |
| `post_attempts` | integer | yes | 0 |
| `post_claimed_at` | timestamp with time zone |  |  |
| `post_error` | text |  |  |
| `posted_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, provider, external_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: reviews_read (select), zella_mfa_required (all).
- Triggers: `zella_review_after_insert`, `zella_review_before_insert`.

## Billing and usage

### `plans`

Shared (standard) plans, for later. Readable only by billing admins and members of a business on that plan.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `name` | text | yes |  |
| `slug` | text | yes |  |
| `description` | text |  |  |
| `price_monthly` | numeric(10,2) | yes | 0 |
| `price_yearly` | numeric(10,2) | yes | 0 |
| `currency` | text | yes | 'USD' |
| `features` | jsonb | yes | '{}' |
| `limits` | jsonb | yes | '{}' |
| `is_active` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(name)`.
- Unique: `(slug)`.
- Row security: on; policies: zella_mfa_required (all), zella_plans_read (select).

### `business_plans`

Each business's own plan, versioned: tier label, price, setup fee, allowances, languages, trial; a change is a new version.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `version` | integer | yes |  |
| `tier` | text | yes |  |
| `billing_interval` | text | yes |  |
| `price_cents` | bigint | yes |  |
| `setup_fee_cents` | bigint | yes | 0 |
| `currency` | text | yes | 'USD' |
| `minutes` | integer | yes |  |
| `texts` | integer | yes |  |
| `emails` | integer | yes |  |
| `team_seats` | integer | yes |  |
| `phone_numbers` | integer | yes |  |
| `locations` | integer | yes |  |
| `languages` | text[] | yes |  |
| `trial_enabled` | boolean | yes | false |
| `contact_limits` | jsonb | yes | '{}' |
| `estimate` | jsonb | yes | '{}' |
| `acknowledged_warnings` | jsonb | yes | '[]' |
| `effective_from` | timestamp with time zone | yes | now() |
| `idempotency_key` | text | yes |  |
| `values_hash` | text | yes |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, idempotency_key)`.
- Unique: `(business_id, version)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.
- Triggers: `zella_business_plans_immutable`.

### `billing_pack_catalog`

The fixed add-on pack prices (minutes, texts, emails).

| Column | Type | Required | Default |
|---|---|---|---|
| `code` | text | yes |  |
| `resource` | text | yes |  |
| `quantity` | integer | yes |  |
| `price_cents` | bigint | yes |  |
| `currency` | text | yes | 'USD' |
| `active` | boolean | yes | true |

- Primary key: `code`.
- Unique: `(resource, quantity)`.
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `billing_periods`

One row per business per monthly allowance period (yearly plans too); usage is serialised on it.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `subscription_id` | uuid |  |  |
| `business_plan_id` | uuid | yes |  |
| `period_start` | timestamp with time zone | yes |  |
| `period_end` | timestamp with time zone | yes |  |
| `is_trial` | boolean | yes | false |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, period_start)`.
- `business_id` → `public.businesses` (on delete cascade).
- `business_plan_id` → `public.business_plans` (on delete no action).
- `subscription_id` → `public.subscriptions` (on delete set null).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `allowance_buckets`

Current balances per period: rolled-over minutes, plan, packs and the 5% buffer for appointment messages.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `period_id` | uuid | yes |  |
| `resource` | text | yes |  |
| `kind` | text | yes |  |
| `pack_purchase_id` | uuid |  |  |
| `granted` | numeric(14,4) | yes |  |
| `used` | numeric(14,4) | yes | 0 |
| `expires_at` | timestamp with time zone | yes |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `pack_purchase_id` → `public.pack_purchases` (on delete no action).
- `period_id` → `public.billing_periods` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `pack_purchases`

Packs added to a business (step 2: admin grants only, with a reason; purchases come with payments).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `pack_code` | text | yes |  |
| `resource` | text | yes |  |
| `quantity` | integer | yes |  |
| `price_cents` | bigint | yes |  |
| `currency` | text | yes | 'USD' |
| `status` | text | yes |  |
| `source` | text | yes |  |
| `reason` | text | yes |  |
| `period_id` | uuid | yes |  |
| `idempotency_key` | text | yes |  |
| `created_by` | uuid |  |  |
| `purchased_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, idempotency_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- `pack_code` → `public.billing_pack_catalog` (on delete no action).
- `period_id` → `public.billing_periods` (on delete no action).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `usage_charges`

Every subtraction from (or return to) a balance, once per idempotency key.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `period_id` | uuid | yes |  |
| `resource` | text | yes |  |
| `idempotency_key` | text | yes |  |
| `quantity` | numeric(14,4) | yes |  |
| `allocations` | jsonb | yes | '[]' |
| `over_quantity` | numeric(14,4) | yes | 0 |
| `source_kind` | text | yes |  |
| `source_id` | uuid |  |  |
| `message_kind` | text |  |  |
| `occurred_at` | timestamp with time zone | yes |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(idempotency_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- `period_id` → `public.billing_periods` (on delete no action).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.
- Triggers: `zella_usage_charges_immutable`.

### `auto_reload_settings`

The business owner's auto-reload choice (stored; reloads need payments).

| Column | Type | Required | Default |
|---|---|---|---|
| `business_id` | uuid | yes |  |
| `resource` | text | yes |  |
| `enabled` | boolean | yes | false |
| `threshold` | integer | yes |  |
| `pack_code` | text | yes |  |
| `monthly_cap_cents` | bigint | yes |  |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `business_id, resource`.
- `business_id` → `public.businesses` (on delete cascade).
- `pack_code` → `public.billing_pack_catalog` (on delete no action).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `subscriptions`

A business's subscription and its state.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `plan_id` | uuid |  |  |
| `status` | text | yes | 'trial' |
| `billing_interval` | text | yes | 'monthly' |
| `provider` | text |  |  |
| `external_subscription_id` | text |  |  |
| `trial_start_at` | timestamp with time zone |  |  |
| `trial_end_at` | timestamp with time zone |  |  |
| `current_period_start` | timestamp with time zone |  |  |
| `current_period_end` | timestamp with time zone |  |  |
| `cancelled_at` | timestamp with time zone |  |  |
| `expired_at` | timestamp with time zone |  |  |
| `grace_period_end_at` | timestamp with time zone |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `status_changed_at` | timestamp with time zone | yes | now() |
| `past_due_since` | timestamp with time zone |  |  |
| `trial_notice_days` | integer[] | yes | '{}'::integer[] |
| `billing_event_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(business_id)`.
- `business_id` → `public.businesses` (on delete cascade).
- `plan_id` → `public.plans` (on delete restrict).
- Row security: on; policies: business members can view subscriptions (select), zella_mfa_required (all).
- Triggers: `zella_billing_subscription_linked`, `zella_offer_subscription_trg`, `zella_subscription_after_trg`, `zella_subscription_before_trg`.

### `payments`

Payments reported by the payment provider (no card data).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `subscription_id` | uuid |  |  |
| `amount` | numeric | yes |  |
| `currency` | text | yes | 'USD' |
| `status` | text | yes | 'pending' |
| `provider` | text |  |  |
| `external_payment_id` | text |  |  |
| `payment_method` | text |  |  |
| `failure_reason` | text |  |  |
| `paid_at` | timestamp with time zone |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |
| `amount_minor` | bigint |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `subscription_id` → `public.subscriptions` (on delete set null).
- Row security: on; policies: business members can view payments (select), zella_mfa_required (all).
- Triggers: `zella_offer_payment_trg`.

### `billing_events`

Payment provider webhook events, applied once and in order.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `provider` | text | yes |  |
| `external_event_id` | text | yes |  |
| `type` | text | yes |  |
| `business_id` | uuid |  |  |
| `subscription_id` | uuid |  |  |
| `data` | jsonb | yes | '{}' |
| `status` | text | yes | 'processed' |
| `error` | text |  |  |
| `received_at` | timestamp with time zone | yes | now() |
| `args` | jsonb |  |  |
| `event_created_at` | timestamp with time zone |  |  |
| `attempts` | integer | yes | 0 |
| `next_attempt_at` | timestamp with time zone |  |  |
| `processed_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- Unique: `(provider, external_event_id)`.
- Row security: on; policies: zella_mfa_required (all).

### `usage_records`

Append-only usage ledger (one entry per finalised call; adjustments, never edits).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `subscription_id` | uuid |  |  |
| `usage_type` | text | yes |  |
| `quantity` | numeric(12,4) | yes | 0 |
| `unit` | text |  |  |
| `period_start` | timestamp with time zone | yes |  |
| `period_end` | timestamp with time zone | yes |  |
| `source_id` | uuid |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `call_id` | uuid |  |  |
| `provider_call_id` | text |  |  |
| `provider_event_id` | text |  |  |
| `idempotency_key` | text |  |  |
| `entry_kind` | text | yes | 'usage' |
| `adjusts_record_id` | uuid |  |  |
| `usage_category` | text |  |  |
| `occurred_at` | timestamp with time zone |  |  |
| `duration_seconds` | integer |  |  |
| `billable_seconds` | integer |  |  |
| `telephony_billed_seconds` | integer |  |  |
| `included_minutes_consumed` | numeric(12,4) |  |  |
| `policy` | jsonb |  |  |
| `period_source` | text |  |  |
| `status` | text | yes | 'recorded' |
| `reconciliation_status` | text | yes | 'ok' |
| `processed_by` | text |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `adjusts_record_id` → `public.usage_records` (on delete no action).
- `business_id` → `public.businesses` (on delete cascade).
- `call_id` → `public.calls` (on delete set null).
- `subscription_id` → `public.subscriptions` (on delete set null).
- Row security: on; policies: business members can view usage records (select), zella_mfa_required (all).
- Triggers: `zella_billing_usage_trg`.

### `usage_thresholds`

Usage warning levels per business.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `measure` | text | yes |  |
| `value` | numeric(12,2) | yes |  |
| `event_type` | text | yes |  |
| `enabled` | boolean | yes | true |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `usage_threshold_events`

Warnings already raised, so each is raised once.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `threshold_key` | text | yes |  |
| `period_key` | text | yes |  |
| `event_type` | text | yes |  |
| `usage_minutes` | numeric(12,4) | yes |  |
| `limit_minutes` | numeric(12,4) |  |  |
| `notification_id` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `resource` | text | yes | 'minutes' |

- Primary key: `id`.
- Unique: `(business_id, threshold_key, period_key)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `usage_processing_issues`

Calls and messages whose usage could not be recorded yet, retried until resolved.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid |  |  |
| `call_id` | uuid |  |  |
| `kind` | text | yes |  |
| `status` | text | yes | 'open' |
| `attempts` | integer | yes | 0 |
| `next_attempt_at` | timestamp with time zone | yes | now() |
| `last_error` | text |  |  |
| `detail` | jsonb | yes | '{}' |
| `escalated_at` | timestamp with time zone |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `resolution` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `call_id` → `public.calls` (on delete cascade).
- Row security: on; policies: zella_mfa_required (all).

### `voice_pricing`

Provider unit costs used for cost estimates.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `provider` | text | yes |  |
| `component` | text | yes | 'per_minute' |
| `unit_cost` | numeric(12,6) | yes |  |
| `currency` | text | yes | 'USD' |
| `billing_increment_seconds` | integer | yes | 60 |
| `effective_from` | timestamp with time zone | yes |  |
| `note` | text |  |  |
| `created_by` | uuid |  |  |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(provider, component, effective_from)`.
- Row security: on; policies: zella_mfa_required (all).

## Notifications, reports and support

### `notifications`

In-app notifications for business members.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `user_id` | uuid |  |  |
| `type` | text | yes |  |
| `title` | text | yes |  |
| `message` | text |  |  |
| `is_read` | boolean | yes | false |
| `action_url` | text |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- `user_id` → `auth.users` (on delete cascade).
- Row security: on; policies: business members can create notifications (insert), users can delete their notifications (delete), users can update their notifications (update), users can view their notifications (select), zella_mfa_required (all).

### `notification_preferences`

What each person wants to be told about, and how.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `user_id` | uuid | yes |  |
| `notification_type` | text | yes |  |
| `email_enabled` | boolean | yes | true |
| `sms_enabled` | boolean | yes | false |
| `push_enabled` | boolean | yes | true |
| `in_app_enabled` | boolean | yes | true |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, user_id, notification_type)`.
- `business_id` → `public.businesses` (on delete cascade).
- `user_id` → `auth.users` (on delete cascade).
- Row security: on; policies: users can create notification preferences (insert), users can delete notification preferences (delete), users can update notification preferences (update), users can view notification preferences (select), zella_mfa_required (all).

### `staff_notifications`

Notifications for staff who don't sign in (by text or email).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `user_id` | uuid |  |  |
| `kind` | text | yes |  |
| `severity` | text | yes | 'info' |
| `title` | text | yes |  |
| `body` | text |  |  |
| `page_key` | text |  |  |
| `entity_id` | uuid |  |  |
| `delivery_status` | text | yes | 'pending' |
| `delivery_error` | text |  |  |
| `delivered_at` | timestamp with time zone |  |  |
| `read_at` | timestamp with time zone |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `claimed_at` | timestamp with time zone |  |  |
| `sms_status` | text |  |  |
| `sms_claimed_at` | timestamp with time zone |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: staff_notifications_select (select), zella_mfa_required (all).
- Triggers: `zella_mark_staff_sms_trg`.

### `admin_alert_prefs`

Platform admin alert preferences.

| Column | Type | Required | Default |
|---|---|---|---|
| `user_id` | uuid | yes |  |
| `email_enabled` | boolean | yes | true |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `user_id`.
- Row security: on; policies: zella_mfa_required (all).

### `platform_alerts`

Platform alerts for Zella Voice staff (grouped, with resolution).

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `kind` | text | yes |  |
| `severity` | text | yes | 'warning' |
| `business_id` | uuid |  |  |
| `title` | text | yes |  |
| `detail` | text |  |  |
| `meta` | jsonb | yes | '{}' |
| `dedupe_key` | text | yes | '' |
| `status` | text | yes | 'open' |
| `occurrences` | integer | yes | 1 |
| `first_seen_at` | timestamp with time zone | yes | now() |
| `last_seen_at` | timestamp with time zone | yes | now() |
| `notified_at` | timestamp with time zone |  |  |
| `acknowledged_by` | uuid |  |  |
| `acknowledged_at` | timestamp with time zone |  |  |
| `resolved_by` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `resolution_note` | text |  |  |

- Primary key: `id`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; policies: platform_alerts_admin_select (select), zella_mfa_required (all).

### `platform_incidents`

Incidents shown on the public status page.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `title` | text | yes |  |
| `detail` | text |  |  |
| `status` | text | yes | 'open' |
| `notified_businesses` | integer | yes | 0 |
| `created_by` | uuid |  |  |
| `resolution_note` | text |  |  |
| `created_at` | timestamp with time zone | yes | now() |
| `resolved_at` | timestamp with time zone |  |  |
| `is_public` | boolean | yes | false |
| `public_message` | text |  |  |
| `component` | text |  |  |

- Primary key: `id`.
- Row security: on; policies: platform_incidents_admin (select), zella_mfa_required (all).

### `business_report_schedules`

Which reports a business gets and when.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `kind` | text | yes | 'daily_summary' |
| `enabled` | boolean | yes | true |
| `local_hour` | integer | yes |  |
| `recipient_roles` | text[] | yes | '{owner}'[] |
| `period` | text | yes | 'yesterday' |
| `updated_by` | uuid |  |  |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- Unique: `(business_id, kind)`.
- `business_id` → `public.businesses` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `business_report_runs`

Reports produced.

| Column | Type | Required | Default |
|---|---|---|---|
| `schedule_id` | uuid | yes |  |
| `local_date` | date | yes |  |
| `status` | text | yes |  |
| `recipients` | integer | yes | 0 |
| `error` | text |  |  |
| `ran_at` | timestamp with time zone | yes | now() |

- Primary key: `schedule_id, local_date`.
- `schedule_id` → `public.business_report_schedules` (on delete cascade).
- Row security: on; no policies, so roles subject to row security (signed-in users and anon) get no rows directly. Superusers and `BYPASSRLS` roles (such as the server key) are not limited by it, nor is the table owner unless `FORCE ROW LEVEL SECURITY` is set; a security definer function runs with its function owner's rights.

### `support_tickets`

Support requests from businesses.

| Column | Type | Required | Default |
|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |
| `business_id` | uuid | yes |  |
| `created_by` | uuid |  |  |
| `subject` | text | yes |  |
| `description` | text |  |  |
| `status` | text | yes | 'open' |
| `priority` | text | yes | 'normal' |
| `category` | text |  |  |
| `assigned_to` | uuid |  |  |
| `resolved_at` | timestamp with time zone |  |  |
| `metadata` | jsonb | yes | '{}' |
| `created_at` | timestamp with time zone | yes | now() |
| `updated_at` | timestamp with time zone | yes | now() |

- Primary key: `id`.
- `assigned_to` → `public.profiles` (on delete set null).
- `business_id` → `public.businesses` (on delete cascade).
- `created_by` → `public.profiles` (on delete set null).
- Row security: on; policies: authorized managers can update support tickets (update), business members can create support tickets (insert), business members can view support tickets (select), zella_mfa_required (all), zella_viewer_no_delete (delete), zella_viewer_no_insert (insert), zella_viewer_no_update (update).

## Functions

Most rules live here. `SD` = security definer (runs with the owner's rights, so it must check the caller
itself and has a fixed `search_path`). `anon` = callable without signing in (public links and webhooks only).
`signed in` = callable by any signed-in person; the function then checks their business and role.
Functions callable by neither are for the server key, triggers and jobs only.

### `zella_accept_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_accept_legal_document(p_document_id uuid, p_business_id uuid)` | boolean | yes | signed in |
| `zella_accept_my_invitations()` | integer | yes | signed in |
| `zella_accept_staff_invitations()` | integer | yes | signed in |
| `zella_accept_staff_invitations_v2()` | jsonb | yes | signed in |
| `zella_accept_waitlist_offer(p_entry_id uuid)` | uuid | yes | server only |

### `zella_add_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_add_business_closure(p_business_id uuid, p_starts_on date, p_ends_on date, p_label text, p_opens time without time zone, p_closes time without time zone)` | uuid | yes | signed in |
| `zella_add_lead_note(p_customer_id uuid, p_note text)` | boolean | yes | signed in |
| `zella_add_record_note(p_id uuid, p_note text)` | boolean | yes | signed in |

### `zella_admin_*` (42)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_admin_acknowledge_alert(p_alert_id uuid)` | boolean | yes | signed in |
| `zella_admin_audit(p_action text, p_entity_type text, p_entity_id uuid, p_business_id uuid, p_old jsonb, p_new jsonb)` | void | yes | server only |
| `zella_admin_automation_detail(p_id uuid)` | jsonb | yes | signed in |
| `zella_admin_automation_overview(p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_admin_automation_set_status(p_id uuid, p_status text, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_automation_templates(p_q text, p_industry text)` | jsonb | yes | signed in |
| `zella_admin_automations(p_q text, p_status text, p_trigger text, p_business uuid, p_industry uuid, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_business_automations_pause(p_business_id uuid, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_business_options()` | jsonb | yes | signed in |
| `zella_admin_call_detail(p_call_id uuid, p_with_content boolean)` | jsonb | yes | signed in |
| `zella_admin_call_usage(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_calls(p_from timestamp with time zone, p_to timestamp with time zone, p_business uuid, p_direction text, p_status text, p_outcome text, p_failed_only boolean, p_q text, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_can(p_permission text)` | boolean | yes | signed in |
| `zella_admin_mask(p text)` | text |  | server only |
| `zella_admin_message_detail(p_channel text, p_id uuid, p_with_content boolean)` | jsonb | yes | signed in |
| `zella_admin_message_retry(p_channel text, p_id uuid, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_message_retry_check(p_channel text, p_id uuid)` | jsonb | yes | server only |
| `zella_admin_messages(p_channel text, p_from timestamp with time zone, p_to timestamp with time zone, p_business uuid, p_status text, p_direction text, p_kind text, p_q text, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_messaging_alerts()` | jsonb | yes | signed in |
| `zella_admin_messaging_compliance()` | jsonb | yes | signed in |
| `zella_admin_messaging_overview(p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_admin_number_release(p_id uuid, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_numbers(p_q text, p_status text, p_business uuid, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_pack_grant(p_business_id uuid, p_pack_code text, p_reason text, p_idempotency_key text)` | jsonb | yes | signed in |
| `zella_admin_plan_save(p_business_id uuid, p_values jsonb, p_acknowledgements jsonb, p_idempotency_key text)` | jsonb | yes | signed in |
| `zella_admin_reason(p_reason text)` | text |  | server only |
| `zella_admin_require(p_permission text)` | uuid | yes | server only |
| `zella_admin_retry_usage(p_issue_id uuid)` | jsonb | yes | signed in |
| `zella_admin_role()` | text | yes | signed in |
| `zella_admin_routing_get(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_admin_routing_save(p_business_id uuid, p_rules jsonb, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_run_detail(p_kind text, p_id uuid)` | jsonb | yes | signed in |
| `zella_admin_run_retry(p_kind text, p_id uuid, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_run_retry_check(p_kind text, p_id uuid)` | jsonb | yes | server only |
| `zella_admin_run_reviewed(p_kind text, p_id uuid, p_note text)` | jsonb | yes | signed in |
| `zella_admin_runs(p_status text, p_business uuid, p_q text, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_scheduler_health()` | jsonb | yes | signed in |
| `zella_admin_template_save(p_id uuid, p_subject text, p_body text, p_reason text)` | jsonb | yes | signed in |
| `zella_admin_template_variables(p_key text, p_channel text)` | text[] | yes | server only |
| `zella_admin_templates(p_q text, p_channel text, p_scope text, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_admin_voice_alerts()` | jsonb | yes | signed in |
| `zella_admin_voice_overview(p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |

### `zella_ai_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_ai_booking(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb)` | jsonb | yes | server only |
| `zella_ai_log_request(p_provider_call_id text, p_business_id uuid, p_kind text, p_summary text)` | jsonb | yes | server only |
| `zella_ai_manage_booking(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb)` | jsonb | yes | server only |
| `zella_ai_save_record(p_business_id uuid, p_type_key text, p_customer_id uuid, p_title text, p_data jsonb, p_follow_up_title text, p_follow_up_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_ai_tool(p_provider_call_id text, p_business_id uuid, p_tool text, p_args jsonb, p_idempotency_key text)` | jsonb | yes | server only |
| `zella_ai_tool_log(p_business_id uuid, p_limit integer)` | jsonb | yes | signed in |
| `zella_ai_voice(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb)` | jsonb | yes | server only |

### `zella_apply_*` (8)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_apply_billing_event(p_event_id uuid)` | text | yes | server only |
| `zella_apply_crm_preset(p_business_id uuid)` | integer | yes | server only |
| `zella_apply_industry_automations(p_business_id uuid)` | integer | yes | server only |
| `zella_apply_industry_defaults(p_business_id uuid)` | integer | yes | signed in |
| `zella_apply_lead_rules(p_customer_id uuid)` | void | yes | server only |
| `zella_apply_payment_policy()` | integer | yes | server only |
| `zella_apply_scheduled_cancellations()` | integer | yes | server only |
| `zella_apply_waiting_billing_events(p_provider text, p_external_subscription_id text, p_external_payment_id text)` | integer | yes | server only |

### `zella_appointment_*` (13)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_appointment_after()` | trigger | yes | server only |
| `zella_appointment_before()` | trigger |  | server only |
| `zella_appointment_conflict_guard()` | trigger | yes | server only |
| `zella_appointment_holds_time(p_status text, p_state text, p_hold_expires timestamp with time zone)` | boolean |  | anon, signed in |
| `zella_appointment_message_trg()` | trigger | yes | server only |
| `zella_appointment_moved_trg()` | trigger | yes | server only |
| `zella_appointment_new_trg()` | trigger | yes | server only |
| `zella_appointment_record_event_trg()` | trigger | yes | server only |
| `zella_appointment_record_match_trg()` | trigger | yes | server only |
| `zella_appointment_record_trg()` | trigger | yes | server only |
| `zella_appointment_source()` | trigger |  | server only |
| `zella_appointment_staff_trg()` | trigger | yes | server only |
| `zella_appointment_touches_trg()` | trigger | yes | server only |

### `zella_approval_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_approval_approver(r crm_records, p_customer_id uuid)` | uuid | yes | server only |
| `zella_approval_approvers(p_record_id uuid)` | TABLE(customer_id uuid, name text, via text) | yes | signed in |
| `zella_approval_decide(p_id uuid, p_decision text, p_method text, p_approver_customer_id uuid, p_note text, p_file_id uuid)` | jsonb | yes | signed in |
| `zella_approval_decided_trigger()` | trigger | yes | server only |
| `zella_approval_ok(p_business_id uuid, p_action text, p_entity_id uuid)` | boolean | yes | server only |
| `zella_approval_request(p_record_id uuid, p_kind text, p_title text, p_amount_minor bigint, p_currency text, p_expires_on date, p_charge_id uuid, p_note text)` | uuid | yes | signed in |
| `zella_approval_withdraw(p_id uuid, p_note text)` | boolean | yes | signed in |

### `zella_assistant_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_assistant_config(p_business_id uuid)` | jsonb | yes | server only |
| `zella_assistant_delivery_status(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_assistant_for_call(p_called_number text, p_vapi_phone_number_id text, p_provider_call_id text)` | jsonb | yes | server only |

### `zella_auto_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_auto_assign_callback()` | trigger | yes | server only |
| `zella_auto_assign_lead()` | trigger | yes | server only |
| `zella_auto_reload_save(p_business_id uuid, p_resource text, p_enabled boolean, p_threshold integer, p_pack_code text, p_monthly_cap_cents bigint)` | jsonb | yes | signed in |

### `zella_b3_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_b3_cursor(p_after jsonb, OUT t timestamp with time zone, OUT id uuid, OUT k integer)` | record |  | signed in |
| `zella_b3_like(p_query text)` | text |  | anon, signed in |
| `zella_b3_member(p_business_id uuid)` | void |  | signed in |

### `zella_billing_*` (16)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_billing_balance(p_business_id uuid, p_resource text, p_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_billing_bucket_rank(p_kind text, p_has_pack boolean)` | integer |  | signed in |
| `zella_billing_call_trg()` | trigger | yes | server only |
| `zella_billing_charge_call(p_call_id uuid)` | jsonb | yes | server only |
| `zella_billing_evaluate_alerts(p_business_id uuid, p_resource text)` | integer | yes | server only |
| `zella_billing_immutable_trg()` | trigger |  | server only |
| `zella_billing_message_kind(p_meta jsonb)` | text |  | signed in |
| `zella_billing_message_trg()` | trigger | yes | server only |
| `zella_billing_open_period(p_business_id uuid, p_at timestamp with time zone)` | billing_periods | yes | server only |
| `zella_billing_overview(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_billing_period_bounds(p_business_id uuid, p_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_billing_plan_at(p_business_id uuid, p_at timestamp with time zone)` | business_plans | yes | server only |
| `zella_billing_plan_current(p_business_id uuid)` | business_plans | yes | server only |
| `zella_billing_retry_charges(p_limit integer)` | integer | yes | server only |
| `zella_billing_settings()` | jsonb | yes | server only |
| `zella_billing_subscription_linked()` | trigger | yes | server only |

### `zella_booking_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_booking_buffer(p_business_id uuid)` | integer | yes | server only |
| `zella_booking_choices(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_duration integer, p_window integer, p_limit integer)` | TABLE(slot_start timestamp with time zone) | yes | server only |
| `zella_booking_lock(p_business_id uuid)` | void | yes | server only |
| `zella_booking_messages_withdrawn_trg()` | trigger | yes | server only |
| `zella_booking_rules(p_business_id uuid)` | jsonb | yes | server only |

### `zella_brain_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_brain_context(p_business_id uuid)` | jsonb | yes | server only |
| `zella_brain_prompt(p_business_id uuid)` | text | yes | server only |
| `zella_brain_prompt_base(p_business_id uuid)` | text | yes | server only |
| `zella_brain_run_evals(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_brain_search(p_business_id uuid, p_query text, p_limit integer)` | jsonb | yes | server only |
| `zella_brain_tool_defs()` | jsonb |  | anon, signed in |

### `zella_business_*` (20)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_business_before_trigger()` | trigger |  | server only |
| `zella_business_currency(p_business_id uuid)` | text | yes | signed in |
| `zella_business_entitlements(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_business_entitlements_internal(p_business_id uuid)` | jsonb | yes | server only |
| `zella_business_for_number(p_called_number text, p_vapi_phone_number_id text, p_fallback uuid)` | uuid | yes | server only |
| `zella_business_language_get(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_business_language_plan(p_business_id uuid)` | jsonb | yes | server only |
| `zella_business_language_save(p_business_id uuid, p_primary text, p_extras text[], p_greeting text)` | boolean | yes | signed in |
| `zella_business_lifecycle_trigger()` | trigger | yes | server only |
| `zella_business_metrics(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_assigned_to uuid)` | jsonb | yes | signed in |
| `zella_business_open(p_business_id uuid, p_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_business_readiness(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_business_request(p_business_id uuid, p_kind text, p_subject text, p_description text, p_details jsonb)` | uuid | yes | signed in |
| `zella_business_services_get(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_business_services_save(p_business_id uuid, p_services jsonb)` | jsonb | yes | signed in |
| `zella_business_settings(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_business_status_trigger()` | trigger | yes | server only |
| `zella_business_voice_get(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_business_voice_save(p_business_id uuid, p_voice_id text)` | jsonb | yes | signed in |
| `zella_business_welcome()` | trigger | yes | server only |

### `zella_calendar_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_calendar_can_manage(p_business_id uuid)` | boolean | yes | signed in |
| `zella_calendar_changed(p_connection_id uuid)` | boolean | yes | server only |
| `zella_calendar_connect_provider(p_business_id uuid, p_provider text, p_actor uuid, p_account_email text, p_refresh_token text, p_calendar_id text)` | uuid | yes | server only |
| `zella_calendar_disconnect(p_business_id uuid)` | integer | yes | signed in |
| `zella_calendar_live()` | boolean | yes | server only |
| `zella_calendar_mark_error(p_connection_id uuid, p_error text, p_fatal boolean)` | boolean | yes | server only |

### `zella_call_*` (18)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_call_allowance(p_business_id uuid)` | jsonb | yes | server only |
| `zella_call_config()` | jsonb | yes | server only |
| `zella_call_create_lead(p_call_id uuid, p_first_name text, p_last_name text)` | jsonb | yes | signed in |
| `zella_call_entitlement_check(p_business_id uuid)` | jsonb | yes | server only |
| `zella_call_insight_queue_trg()` | trigger | yes | server only |
| `zella_call_insights_list(p_business_id uuid, p_limit integer)` | jsonb | yes | signed in |
| `zella_call_integrity_trg()` | trigger | yes | server only |
| `zella_call_mark_followed_up(p_call_id uuid)` | boolean | yes | signed in |
| `zella_call_reconcile_waiting()` | integer | yes | server only |
| `zella_call_row(c calls_view)` | jsonb |  | signed in |
| `zella_call_schedule_callback(p_call_id uuid, p_preferred_at timestamp with time zone, p_summary text, p_priority text)` | uuid | yes | signed in |
| `zella_call_set_escalation(p_call_id uuid, p_flag boolean, p_reason text)` | boolean | yes | signed in |
| `zella_call_update(p_call_id uuid, p_outcome text, p_note text, p_assign_to uuid, p_unassign boolean, p_clear_outcome boolean)` | boolean | yes | signed in |
| `zella_call_usage_category(p_call calls)` | jsonb | yes | server only |
| `zella_call_usage_records(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer)` | jsonb | yes | signed in |
| `zella_call_usage_status()` | jsonb | yes | server only |
| `zella_call_usage_summary(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_call_usage_totals(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | server only |

### `zella_calls_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_calls_page(p_business_id uuid, p_filter text, p_transcripts_only boolean, p_limit integer, p_after jsonb)` | jsonb |  | signed in |
| `zella_calls_to_callbacks()` | trigger | yes | server only |
| `zella_calls_to_reconcile(p_limit integer)` | jsonb | yes | server only |
| `zella_calls_usage_trg()` | trigger | yes | server only |

### `zella_can_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_can_contact(p_business_id uuid, p_customer_id uuid, p_channel text, p_purpose text)` | boolean | yes | server only |
| `zella_can_edit(p_business_id uuid)` | boolean | yes | signed in |
| `zella_can_manage(p_business_id uuid)` | boolean | yes | signed in |
| `zella_can_read_call_content(p_business_id uuid)` | boolean | yes | signed in |
| `zella_can_read_record_secrets(p_record_id uuid)` | boolean | yes | signed in |
| `zella_can_see_record_file(p_file crm_record_files)` | boolean | yes | signed in |
| `zella_can_write_brand_asset(p_name text)` | boolean | yes | signed in |

### `zella_cancel_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_cancel_callback(p_callback_id uuid, p_reason text)` | text | yes | signed in |
| `zella_cancel_followup_task(p_task_id uuid)` | boolean | yes | signed in |
| `zella_cancel_invitation(p_invitation_id uuid)` | void | yes | signed in |

### `zella_capability_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_capability_appointment_trg()` | trigger | yes | server only |
| `zella_capability_catalog()` | jsonb |  | anon, signed in |
| `zella_capability_on(p_business_id uuid, p_key text)` | boolean | yes | server only |

### `zella_capture_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_capture_google_lead(p_payload jsonb)` | jsonb | yes | server only |
| `zella_capture_lead(p_business_id uuid, p_first_name text, p_last_name text, p_phone text, p_email text, p_source text, p_notes text, p_answers jsonb)` | jsonb | yes | server only |
| `zella_capture_web_lead(p_public_key text, p_kind text, p_name text, p_phone text, p_email text, p_message text, p_source jsonb, p_marketing_consent boolean, p_origin text, p_ip text, p_honeypot text, p_channel text)` | jsonb | yes | server only |

### `zella_channel_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_channel_on_hold(p_business_id uuid, p_type text)` | boolean | yes | server only |
| `zella_channel_review_trg()` | trigger | yes | server only |
| `zella_channel_reviews(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_channel_supported(p_type text, p_channel text)` | boolean |  | anon, signed in |

### `zella_charge_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_charge_balance(p_charge_id uuid)` | jsonb | yes | signed in |
| `zella_charge_payment_write(p_actor uuid, p_source text, p_charge_id uuid, p_kind text, p_amount_minor bigint, p_method text, p_note text, p_idempotency_key text, p_provider_ref text)` | jsonb | yes | server only |
| `zella_charge_refresh_status(p_charge_id uuid)` | text | yes | server only |

### `zella_check_*` (16)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_check_connections()` | integer | yes | server only |
| `zella_check_customer_requests()` | integer | yes | server only |
| `zella_check_data_rights_due()` | integer | yes | server only |
| `zella_check_engine_health()` | jsonb | yes | server only |
| `zella_check_escalation_acks()` | integer | yes | server only |
| `zella_check_invitations()` | jsonb | yes | server only |
| `zella_check_kpis()` | integer | yes | server only |
| `zella_check_milestones()` | integer | yes | server only |
| `zella_check_overdue_tasks(p_limit integer)` | integer | yes | server only |
| `zella_check_renewals()` | integer | yes | server only |
| `zella_check_response_times()` | integer | yes | server only |
| `zella_check_setup_incomplete()` | integer | yes | server only |
| `zella_check_trials()` | integer | yes | server only |
| `zella_check_unassigned_work()` | integer | yes | server only |
| `zella_check_uptime()` | jsonb | yes | server only |
| `zella_check_usage_thresholds()` | integer | yes | server only |

### `zella_claim_*` (23)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_claim_admin_alert_email(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_agent_syncs(p_limit integer)` | SETOF agent_config_versions | yes | server only |
| `zella_claim_calendar_pulls(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_calendar_sync(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_call_insights(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_callback_calls(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_callbacks(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_events(p_limit integer)` | SETOF automation_events | yes | server only |
| `zella_claim_followup_calls(p_limit integer, p_kinds text[])` | jsonb | yes | server only |
| `zella_claim_followup_emails(p_limit integer, p_kinds text[])` | jsonb | yes | server only |
| `zella_claim_followup_emails_base(p_limit integer, p_kinds text[])` | jsonb | yes | server only |
| `zella_claim_followup_tasks(p_limit integer, p_kinds text[])` | jsonb | yes | server only |
| `zella_claim_followup_texts(p_limit integer, p_kinds text[])` | jsonb | yes | server only |
| `zella_claim_followup_texts_base(p_limit integer, p_kinds text[])` | jsonb | yes | server only |
| `zella_claim_gap_drafts(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_gaps_for_suggestion(p_limit integer)` | TABLE(id uuid, business_id uuid, question text, times_asked integer) | yes | server only |
| `zella_claim_knowledge_updates(p_limit integer)` | SETOF knowledge_items | yes | server only |
| `zella_claim_notifications(p_limit integer)` | SETOF staff_notifications | yes | server only |
| `zella_claim_owner_emails(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_platform_alerts(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_provider_checks(p_limit integer)` | jsonb | yes | server only |
| `zella_claim_reminders(p_limit integer, p_channel text)` | jsonb | yes | server only |
| `zella_claim_staff_sms(p_limit integer)` | jsonb | yes | server only |

### `zella_complete_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_complete_agent_sync(p_version_id uuid, p_ok boolean, p_error text)` | void | yes | server only |
| `zella_complete_event(p_event_id uuid, p_ok boolean, p_error_category text, p_error text)` | text | yes | server only |
| `zella_complete_followup_task(p_task_id uuid, p_outcome text, p_notes text, p_provider_call_id text, p_call_id uuid, p_retry_in_minutes integer)` | text | yes | server only |
| `zella_complete_knowledge_update(p_item_id uuid, p_version integer, p_ok boolean, p_error text)` | text | yes | server only |
| `zella_complete_reminder(p_reminder_id uuid, p_ok boolean, p_error text)` | text | yes | server only |
| `zella_complete_task(p_task_id uuid, p_cancel boolean)` | boolean | yes | signed in |

### `zella_config_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_config_migration_apply(p_business_id uuid)` | jsonb | yes | server only |
| `zella_config_migration_preview(p_business_id uuid)` | jsonb | yes | server only |
| `zella_config_migration_restore(p_snapshot_id uuid)` | jsonb | yes | server only |

### `zella_confirm_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_confirm_appointment_record(p_appointment_id uuid)` | jsonb | yes | signed in |
| `zella_confirm_hold(p_appointment_id uuid)` | uuid | yes | signed in |
| `zella_confirm_requested_appointment(p_appointment_id uuid, p_start timestamp with time zone, p_duration_minutes integer, p_staff_id uuid)` | uuid | yes | signed in |

### `zella_create_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_create_business_draft(p_fields jsonb)` | jsonb | yes | server only |
| `zella_create_callback(p_business_id uuid, p_contact_number text, p_reason text, p_priority text, p_summary text, p_preferred_at timestamp with time zone, p_customer_id uuid, p_call_id uuid, p_appointment_id uuid, p_created_by text, p_automation text)` | uuid | yes | server only |
| `zella_create_charge(p_business_id uuid, p_kind text, p_amount_minor bigint, p_description text, p_customer_id uuid, p_record_id uuid, p_appointment_id uuid, p_due_on date, p_currency text, p_idempotency_key text)` | jsonb | yes | signed in |
| `zella_create_handover(p_business_id uuid, p_to_user uuid, p_note text, p_from_user uuid)` | jsonb | yes | signed in |
| `zella_create_task(p_business_id uuid, p_customer_id uuid, p_kind text, p_title text, p_body text, p_priority text, p_due_at timestamp with time zone, p_assigned_to uuid, p_source text, p_entity_id uuid)` | uuid | yes | server only |
| `zella_create_website_form(p_business_id uuid, p_name text, p_allowed_origins text[])` | text | yes | signed in |

### `zella_crm_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_crm_clean_data(p_fields jsonb, p_data jsonb, OUT cleaned jsonb, OUT unique_key text)` | record |  | server only |
| `zella_crm_on_industry()` | trigger | yes | server only |
| `zella_crm_write_record(p_actor uuid, p_source text, p_business_id uuid, p_type_key text, p_id uuid, p_title text, p_status text, p_customer_id uuid, p_assigned_to uuid, p_due_at timestamp with time zone, p_data jsonb)` | jsonb | yes | server only |

### `zella_cross_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_cross_sell_booked()` | trigger | yes | server only |
| `zella_cross_sell_completed()` | trigger | yes | server only |
| `zella_cross_sell_delete(p_business_id uuid, p_rule_id uuid)` | boolean | yes | signed in |
| `zella_cross_sell_ideas(p_industry_slug text)` | jsonb |  | signed in |
| `zella_cross_sell_list(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_cross_sell_save(p_business_id uuid, p_rule jsonb)` | uuid | yes | signed in |
| `zella_cross_sell_status()` | jsonb | yes | server only |

### `zella_decide_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_decide_approval(p_approval_id uuid, p_approve boolean)` | text | yes | signed in |
| `zella_decide_draft(p_draft_id uuid, p_send boolean, p_body text)` | text | yes | signed in |
| `zella_decide_time_off(p_request_id uuid, p_approve boolean)` | text | yes | signed in |

### `zella_detect_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_detect_knowledge_conflicts()` | integer | yes | server only |
| `zella_detect_repeated_questions()` | integer | yes | server only |
| `zella_detect_transfer_failures()` | integer | yes | server only |

### `zella_dispatch_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_dispatch_assign(p_appointment_id uuid, p_staff_id uuid, p_crew uuid[])` | void | yes | signed in |
| `zella_dispatch_board(p_business_id uuid, p_day date)` | jsonb | yes | signed in |
| `zella_dispatch_checklist(p_appointment_id uuid, p_items jsonb)` | void | yes | signed in |
| `zella_dispatch_n8n()` | jsonb | yes | server only |
| `zella_dispatch_return_visit(p_appointment_id uuid, p_start timestamp with time zone, p_duration_minutes integer, p_staff_id uuid, p_reason text)` | uuid | yes | signed in |
| `zella_dispatch_status(p_appointment_id uuid, p_from text, p_to text, p_note text)` | void | yes | signed in |

### `zella_finish_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_finish_admin_alert_email(p_ids uuid[], p_ok boolean, p_error text)` | jsonb | yes | server only |
| `zella_finish_calendar_sync(p_queue_id uuid, p_ok boolean, p_event_id text, p_error text)` | text | yes | server only |
| `zella_finish_execution(p_execution_id uuid, p_ok boolean, p_step text, p_steps jsonb, p_provider_refs jsonb, p_error_category text, p_error text, p_needs_manual boolean)` | boolean | yes | server only |
| `zella_finish_owner_email(p_id uuid, p_result text, p_note text)` | text | yes | server only |
| `zella_finish_record_file(p_file_id uuid)` | jsonb | yes | signed in |

### `zella_flag_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_flag_overdue_callbacks()` | integer | yes | server only |
| `zella_flag_overdue_leads()` | integer | yes | server only |
| `zella_flag_unrecorded_appointments()` | integer | yes | server only |

### `zella_google_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_google_lead_key_create(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_google_lead_key_revoke(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_google_lead_status(p_business_id uuid)` | jsonb | yes | signed in |

### `zella_inbox_*` (8)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_inbox_add_note(p_conversation_id uuid, p_body text)` | boolean | yes | signed in |
| `zella_inbox_conv(p_id uuid)` | conversations | yes | server only |
| `zella_inbox_handover(p_conversation_id uuid, p_to_ai boolean, p_assign_to uuid)` | boolean | yes | signed in |
| `zella_inbox_mark_read(p_conversation_id uuid, p_read boolean)` | boolean | yes | signed in |
| `zella_inbox_page(p_business_id uuid, p_filter text, p_limit integer, p_after jsonb)` | jsonb |  | signed in |
| `zella_inbox_previews(p_business_id uuid, p_conversation_ids uuid[])` | TABLE(conversation_id uuid, preview text) |  | signed in |
| `zella_inbox_reply(p_conversation_id uuid, p_body text, p_subject text)` | text | yes | signed in |
| `zella_inbox_update(p_conversation_id uuid, p_assign_to uuid, p_priority text, p_status text, p_unassign boolean)` | boolean | yes | signed in |

### `zella_industry_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_industry_act(p_biz uuid, p_rule jsonb, p_cust uuid, p_entity uuid, p_title text, p_status text, p_assigned uuid)` | void | yes | server only |
| `zella_industry_apply_trg()` | trigger | yes | server only |
| `zella_industry_key_for(p_business_id uuid)` | text | yes | server only |
| `zella_industry_rule_list(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_industry_rules_for(p_industry_id uuid)` | jsonb | yes | signed in |
| `zella_industry_status_trg()` | trigger | yes | server only |

### `zella_is_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_is_authorized(p_business_id uuid, p_customer_id uuid, p_record_id uuid, p_actor_customer_id uuid, p_permission text)` | boolean | yes | signed in |
| `zella_is_member(p_business_id uuid)` | boolean | yes | signed in |
| `zella_is_zella_owner()` | boolean | yes | server only |

### `zella_knowledge_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_knowledge_check_trg()` | trigger | yes | server only |
| `zella_knowledge_gap_editor(p_business_id uuid)` | boolean | yes | signed in |
| `zella_knowledge_gap_report(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_knowledge_guard()` | trigger | yes | server only |
| `zella_knowledge_rollback(p_item_id uuid, p_version integer)` | boolean | yes | signed in |
| `zella_knowledge_source_guard()` | trigger | yes | server only |
| `zella_knowledge_version_log()` | trigger | yes | server only |

### `zella_log_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_log_customer_request(p_business_id uuid, p_customer_id uuid, p_kind text, p_summary text, p_source text, p_call_id uuid, p_priority text)` | uuid | yes | server only |
| `zella_log_data_rights_request(p_business_id uuid, p_kind text, p_customer_id uuid, p_name text, p_contact text, p_note text)` | uuid | yes | signed in |
| `zella_log_knowledge_gap(p_business_id uuid, p_question text, p_call_id uuid, p_customer_id uuid)` | uuid | yes | server only |
| `zella_log_outbound_email(p_business_id uuid, p_customer_id uuid, p_to text, p_from text, p_subject text, p_body_text text, p_body_html text, p_dedupe_key text, p_status text, p_meta jsonb)` | jsonb | yes | server only |
| `zella_log_outbound_sms(p_business_id uuid, p_customer_id uuid, p_to text, p_from text, p_body text, p_dedupe_key text, p_status text, p_meta jsonb)` | jsonb | yes | server only |

### `zella_mark_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_mark_assigned(p_business_id uuid, p_user_id uuid)` | void | yes | server only |
| `zella_mark_call_placed(p_source text, p_id uuid, p_provider_call_id text)` | text | yes | server only |
| `zella_mark_invitation_reminded(p_invitation_id uuid)` | void | yes | server only |
| `zella_mark_notifications_read(p_ids uuid[])` | integer | yes | signed in |
| `zella_mark_staff_sms()` | trigger | yes | server only |

### `zella_message_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_message_allowance(p_business_id uuid, p_channel text, p_kind text)` | jsonb | yes | server only |
| `zella_message_policy(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_message_policy_for(p_business_id uuid)` | jsonb | yes | server only |
| `zella_message_policy_trg()` | trigger | yes | server only |
| `zella_message_summary(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |

### `zella_meta_*` (18)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_meta_capture_lead(p_event_id uuid, p_fields jsonb, p_campaign text)` | jsonb | yes | server only |
| `zella_meta_claim_checks(p_limit integer)` | jsonb | yes | server only |
| `zella_meta_claim_leads(p_limit integer)` | jsonb | yes | server only |
| `zella_meta_claim_outbox(p_limit integer)` | jsonb | yes | server only |
| `zella_meta_fail_event(p_event_id uuid, p_error text, p_permanent boolean)` | void | yes | server only |
| `zella_meta_process_event(p_event_id uuid)` | text | yes | server only |
| `zella_meta_receive(p_raw text, p_signature text)` | jsonb | yes | server only |
| `zella_meta_record_check(p_page_id text, p_ok boolean, p_permissions text[], p_auth_failed boolean, p_error text)` | void | yes | server only |
| `zella_meta_record_send(p_id uuid, p_ok boolean, p_external_id text, p_error text, p_auth_failed boolean, p_retry boolean)` | void | yes | server only |
| `zella_meta_record_templates(p_page_id text, p_templates jsonb)` | integer | yes | server only |
| `zella_meta_set_flow(p_business_id uuid, p_page_id text, p_enabled boolean)` | void | yes | signed in |
| `zella_meta_settings(p_business_id uuid, p_page_id text, p_call_consent boolean, p_auto_ack boolean, p_keywords text[])` | void | yes | signed in |
| `zella_meta_staff_reply(p_conversation_id uuid, p_text text)` | uuid | yes | signed in |
| `zella_meta_staff_template(p_conversation_id uuid, p_template_name text)` | uuid | yes | signed in |
| `zella_meta_status(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_meta_store_connection(p_business_id uuid, p_page_id text, p_page_name text, p_token text, p_instagram_id text, p_whatsapp_phone_id text, p_waba_id text)` | uuid | yes | server only |
| `zella_meta_token(p_page_id text)` | text | yes | server only |
| `zella_meta_verify_token(p_token text)` | boolean | yes | server only |

### `zella_milestone_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_milestone_done(p_id uuid, p_done boolean, p_next_due_on date)` | uuid | yes | signed in |
| `zella_milestone_once(p_business_id uuid, p_key text)` | boolean | yes | server only |
| `zella_milestone_save(p_record_id uuid, p_id uuid, p_title text, p_due_on date, p_kind text, p_staff_id uuid, p_note text)` | uuid | yes | signed in |

### `zella_my_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_my_admin_alert_email(p_enabled boolean)` | boolean | yes | signed in |
| `zella_my_notification_prefs(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_my_profile()` | jsonb | yes | signed in |
| `zella_my_sessions()` | jsonb | yes | signed in |
| `zella_my_workspaces()` | jsonb | yes | signed in |

### `zella_offer_*` (37)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_offer_apply_admin(p_offer_id uuid, p_business_id uuid, p_note text, p_idempotency_key text)` | jsonb | yes | signed in |
| `zella_offer_audience(p_id uuid)` | jsonb | yes | signed in |
| `zella_offer_cancel_claim(p_redemption_id uuid)` | void | yes | signed in |
| `zella_offer_capabilities()` | jsonb | yes | server only |
| `zella_offer_channel_requires(p_channel text)` | text[] |  | anon, signed in |
| `zella_offer_check_code(p_business_id uuid, p_code text)` | jsonb | yes | signed in |
| `zella_offer_claim(p_business_id uuid, p_offer_id uuid, p_code text, p_idempotency_key text)` | jsonb | yes | signed in |
| `zella_offer_detail(p_id uuid)` | jsonb | yes | signed in |
| `zella_offer_explain(p_id uuid, p_business_id uuid)` | jsonb | yes | signed in |
| `zella_offer_facts(p_business uuid)` | jsonb | yes | server only |
| `zella_offer_find_code(p_code text)` | offers | yes | server only |
| `zella_offer_is_eligible(p_offer offers, p_business uuid)` | boolean | yes | server only |
| `zella_offer_log(p_offer uuid, p_kind text, p_from text, p_to text, p_detail jsonb, p_business uuid)` | void | yes | server only |
| `zella_offer_missing(p_requires text[])` | text[] | yes | server only |
| `zella_offer_monitor(p_filter text, p_limit integer)` | jsonb | yes | signed in |
| `zella_offer_needs_approval(o offers)` | boolean | yes | server only |
| `zella_offer_on_payment()` | trigger | yes | server only |
| `zella_offer_on_subscription()` | trigger | yes | server only |
| `zella_offer_problems(o offers)` | text[] | yes | server only |
| `zella_offer_reason_text(p_reason text)` | text |  | anon, signed in |
| `zella_offer_redeem_core(p_offer uuid, p_business uuid, p_source text, p_key text, p_note text)` | jsonb | yes | server only |
| `zella_offer_report(p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_offer_retry()` | jsonb | yes | signed in |
| `zella_offer_rule_config(p_key text)` | jsonb | yes | server only |
| `zella_offer_rule_requires(p_key text)` | text[] |  | anon, signed in |
| `zella_offer_rule_results(p_eligibility jsonb, p_facts jsonb)` | jsonb |  | anon, signed in |
| `zella_offer_rule_save(p_key text, p_enabled boolean, p_config jsonb)` | void | yes | signed in |
| `zella_offer_rules_list()` | jsonb | yes | signed in |
| `zella_offer_save(p_id uuid, p_data jsonb)` | uuid | yes | signed in |
| `zella_offer_scheduler_on()` | boolean | yes | server only |
| `zella_offer_set_redemption(p_id uuid, p_status text, p_note text)` | void | yes | signed in |
| `zella_offer_slot(p_business_id uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_staff_id uuid, p_exclude_customer uuid)` | integer | yes | server only |
| `zella_offer_summary(o offers)` | text |  | anon, signed in |
| `zella_offer_terms(o offers)` | jsonb |  | anon, signed in |
| `zella_offer_times(p_tables boolean, p_party integer, p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_duration integer, p_window integer, p_pref text)` | TABLE(slot_start timestamp with time zone) | yes | server only |
| `zella_offer_transition(p_id uuid, p_action text, p_note text)` | jsonb | yes | signed in |
| `zella_offer_type_requires(p_type text)` | text[] |  | anon, signed in |

### `zella_offers_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_offers_for_business(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_offers_list()` | jsonb | yes | signed in |
| `zella_offers_tick(p_trigger text)` | jsonb | yes | server only |

### `zella_on_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_on_call_delete(p_business_id uuid, p_shift_id uuid)` | boolean | yes | signed in |
| `zella_on_call_list(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_on_call_now(p_business_id uuid, p_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_on_call_reminders()` | integer | yes | server only |
| `zella_on_call_save(p_business_id uuid, p_shift jsonb)` | uuid | yes | signed in |
| `zella_on_call_settings_save(p_business_id uuid, p_enabled boolean, p_scope text)` | boolean | yes | signed in |
| `zella_on_call_status()` | jsonb | yes | server only |

### `zella_other_*` (13)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `check_availability(p_business_id uuid, p_start_time timestamp with time zone, p_end_time timestamp with time zone, p_assigned_to uuid)` | jsonb | yes | signed in |
| `create_appointment(p_business_id uuid, p_customer_id uuid, p_title text, p_start_time timestamp with time zone, p_end_time timestamp with time zone, p_appointment_type text, p_description text, p_assigned_to uuid, p_timezone text, p_location text, p_meeting_url text)` | uuid | yes | signed in |
| `create_business(p_name text, p_industry_id uuid, p_business_type text, p_email text, p_phone text, p_website text, p_timezone text, p_portal_id text)` | uuid | yes | signed in |
| `create_customer(p_business_id uuid, p_first_name text, p_last_name text, p_email text, p_phone text, p_company_name text, p_source text, p_notes text, p_metadata jsonb)` | uuid | yes | signed in |
| `create_zella_ai_agent(p_business_id uuid)` | uuid | yes | server only |
| `get_business_context(p_business_id uuid)` | jsonb | yes | signed in |
| `get_customer(p_business_id uuid, p_phone text, p_email text, p_customer_id uuid)` | jsonb | yes | signed in |
| `handle_new_user()` | trigger | yes | server only |
| `is_business_member(target_business_id uuid)` | boolean | yes | signed in |
| `is_platform_admin()` | boolean | yes | signed in |
| `rls_auto_enable()` | event_trigger | yes | server only |
| `update_customer(p_business_id uuid, p_customer_id uuid, p_first_name text, p_last_name text, p_email text, p_phone text, p_company_name text, p_status text, p_notes text, p_metadata jsonb)` | uuid | yes | signed in |
| `update_updated_at()` | trigger |  | server only |

### `zella_people_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_people_audit(p_business_id uuid, p_action text, p_entity text, p_id uuid, p_old jsonb, p_new jsonb)` | void | yes | server only |
| `zella_people_can_edit(p_business_id uuid)` | boolean | yes | signed in |
| `zella_people_can_verify(p_business_id uuid)` | boolean | yes | signed in |
| `zella_people_merge(p_business_id uuid, p_keep uuid, p_drop uuid)` | integer | yes | server only |
| `zella_people_merge_install()` | void |  | server only |
| `zella_people_panel(p_business_id uuid, p_customer_id uuid, p_record_id uuid)` | jsonb | yes | signed in |
| `zella_people_subject_ok(p_business_id uuid, p_customer_id uuid, p_record_id uuid)` | boolean | yes | server only |

### `zella_platform_*` (7)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_platform_admin_audit()` | trigger | yes | server only |
| `zella_platform_admin_email_check()` | trigger | yes | server only |
| `zella_platform_admin_trigger()` | trigger | yes | server only |
| `zella_platform_alert(p_kind text, p_title text, p_detail text, p_severity text, p_business_id uuid, p_dedupe_key text, p_meta jsonb)` | uuid | yes | server only |
| `zella_platform_health_summary()` | jsonb | yes | signed in |
| `zella_platform_metrics(p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | server only |
| `zella_platform_public_info()` | jsonb | yes | anon, signed in |

### `zella_post_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_post_callback_digests()` | integer | yes | server only |
| `zella_post_daily_summaries()` | integer | yes | server only |
| `zella_post_team_summaries()` | integer | yes | server only |
| `zella_post_weekly_reviews()` | integer | yes | server only |

### `zella_process_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_process_billing_event(p_provider text, p_event_id text, p_type text, p_external_subscription_id text, p_business_id uuid, p_amount_minor bigint, p_currency text, p_external_payment_id text, p_period_start timestamp with time zone, p_period_end timestamp with time zone, p_plan_slug text, p_reason text, p_event_created timestamp with time zone, p_refund_minor bigint)` | text | yes | server only |
| `zella_process_call_usage(p_call_id uuid, p_source text, p_event_id text)` | jsonb | yes | server only |
| `zella_process_cancellations()` | integer | yes | server only |

### `zella_queue_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_queue_calendar_sync()` | trigger | yes | server only |
| `zella_queue_customer_message(p_business_id uuid, p_customer_id uuid, p_kind text, p_vars jsonb, p_delay interval, p_appointment_id uuid, p_dedupe interval)` | uuid | yes | server only |
| `zella_queue_customer_touches(p_limit integer)` | integer | yes | server only |
| `zella_queue_lead_reactivation(p_limit integer)` | integer | yes | server only |
| `zella_queue_no_show_followup()` | trigger | yes | server only |
| `zella_queue_quote_followups()` | integer | yes | server only |

### `zella_reconcile_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_reconcile_billing_events(p_limit integer)` | jsonb | yes | server only |
| `zella_reconcile_call(p_provider_call_id text, p_status_code integer, p_call jsonb)` | text | yes | server only |
| `zella_reconcile_call_usage(p_limit integer)` | jsonb | yes | server only |

### `zella_record_*` (23)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_record_activation_test(p_business_id uuid, p_ok boolean, p_detail text)` | void | yes | server only |
| `zella_record_call_result(p_source text, p_id uuid, p_outcome text, p_provider_call_id text, p_notes text)` | text | yes | server only |
| `zella_record_call_status(p_provider_call_id text, p_status text, p_called_number text, p_vapi_phone_number_id text, p_from_number text, p_direction text, p_event_at timestamp with time zone, p_ended_reason text)` | text | yes | server only |
| `zella_record_callback_attempt(p_callback_id uuid, p_outcome text, p_provider_ref text, p_error text, p_notes text)` | text | yes | signed in |
| `zella_record_charge_payment(p_charge_id uuid, p_kind text, p_amount_minor bigint, p_method text, p_note text, p_idempotency_key text)` | jsonb | yes | signed in |
| `zella_record_consent(p_business_id uuid, p_channel text, p_status text, p_source text, p_customer_id uuid, p_phone text, p_email text, p_purpose text, p_keyword text, p_evidence jsonb)` | uuid | yes | signed in |
| `zella_record_due(p_due timestamp with time zone, p_data jsonb, p_cfg jsonb, p_tz text)` | timestamp with time zone |  | anon, signed in |
| `zella_record_email_event(p_key text, p_event jsonb, p_event_id text)` | text | yes | server only |
| `zella_record_email_event_signed(p_key text, p_event jsonb, p_event_id text, p_sig jsonb)` | text | yes | server only |
| `zella_record_file_checked(p_file_id uuid, p_ok boolean, p_reason text, p_sha256 text, p_size bigint)` | jsonb | yes | server only |
| `zella_record_file_cleanup(p_limit integer)` | jsonb | yes | server only |
| `zella_record_file_storage_ok(p_name text, p_action text)` | boolean | yes | signed in |
| `zella_record_files_purged(p_paths text[])` | integer | yes | server only |
| `zella_record_inbound_call(p_provider_call_id text, p_called_number text, p_vapi_phone_number_id text, p_from_number text, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_seconds integer, p_reason text, p_summary text, p_recording_url text, p_transcript text, p_wants_callback boolean)` | text | yes | server only |
| `zella_record_payment_result(p_business_id uuid, p_ok boolean, p_provider_ref text, p_error text)` | text | yes | server only |
| `zella_record_provider_check(p_provider text, p_ok boolean, p_detail text)` | text | yes | server only |
| `zella_record_related(p_record_id uuid)` | jsonb | yes | signed in |
| `zella_record_secrets(p_record_id uuid)` | jsonb | yes | signed in |
| `zella_record_sms_receipt(p_business_id uuid, p_external_id text, p_status text, p_error text)` | jsonb | yes | server only |
| `zella_record_status_touches_trg()` | trigger | yes | server only |
| `zella_record_type_defaults_trg()` | trigger | yes | server only |
| `zella_record_workflow_defaults_trg()` | trigger | yes | server only |
| `zella_record_workflow_save(p_business_id uuid, p_type_key text, p_workflow jsonb)` | jsonb | yes | signed in |

### `zella_recover_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_recover_failed_texts(p_limit integer)` | integer | yes | server only |
| `zella_recover_knowledge()` | integer | yes | server only |
| `zella_recover_orphaned_work()` | integer | yes | server only |
| `zella_recover_provisioning()` | integer | yes | server only |

### `zella_recurring_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_recurring_dates(p_plan recurring_plans, p_from date, p_to date)` | SETOF date |  | server only |
| `zella_recurring_generate(p_business_id uuid, p_plan_id uuid, p_through date)` | jsonb | yes | signed in |
| `zella_recurring_save(p_business_id uuid, p_id uuid, p_plan jsonb)` | uuid | yes | signed in |

### `zella_relationship_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_relationship_in_force(r customer_relationships)` | boolean |  | server only |
| `zella_relationship_revoke(p_id uuid, p_reason text)` | void | yes | signed in |
| `zella_relationship_save(p_business_id uuid, p_id uuid, p_customer_id uuid, p_record_id uuid, p_related_customer_id uuid, p_kind text, p_permissions text[], p_valid_until date, p_note text, p_expected_updated_at timestamp with time zone)` | uuid | yes | signed in |
| `zella_relationship_verify(p_id uuid, p_method text, p_related_customer_id uuid, p_kind text, p_permissions text[], p_valid_until date, p_expected_updated_at timestamp with time zone)` | void | yes | signed in |

### `zella_remind_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_remind_integrations()` | integer | yes | server only |
| `zella_remind_reconnects()` | integer | yes | server only |
| `zella_remind_upcoming_callbacks()` | integer | yes | server only |

### `zella_replace_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_replace_business_hours(p_business_id uuid, p_hours jsonb)` | void |  | server only |
| `zella_replace_calendar_busy(p_connection_id uuid, p_events jsonb)` | integer | yes | server only |
| `zella_replace_reminders(p_appointment_id uuid, p_send_confirmation boolean, p_reason text)` | void | yes | server only |

### `zella_report_*` (8)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_report_build(p_business_id uuid, p_period text, p_now timestamp with time zone)` | jsonb | yes | server only |
| `zella_report_call_failure(p_business_id uuid, p_call_id uuid, p_error text, p_context jsonb, p_phone text)` | uuid | yes | server only |
| `zella_report_incorrect_answer(p_business_id uuid, p_call_id uuid, p_what_was_wrong text, p_correct_answer text)` | uuid | yes | signed in |
| `zella_report_next_run(p_schedule_id uuid, p_now timestamp with time zone)` | timestamp with time zone | yes | server only |
| `zella_report_schedules(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_report_service_health(p_service text, p_ok boolean, p_detail text, p_verified boolean)` | uuid | yes | server only |
| `zella_report_telephony_event(p_business_id uuid, p_provider text, p_state text, p_error text, p_retryable boolean)` | jsonb | yes | server only |
| `zella_report_unanswered(p_provider_call_id text, p_business_id uuid, p_question text)` | uuid | yes | server only |

### `zella_request_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_request_activation(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_request_appointment(p_business_id uuid, p_customer_id uuid, p_phone text, p_title text, p_preferred_start timestamp with time zone, p_notes text)` | uuid | yes | server only |
| `zella_request_approval(p_business_id uuid, p_action text, p_entity_id uuid, p_details jsonb)` | uuid | yes | signed in |
| `zella_request_time_off(p_business_id uuid, p_staff_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text)` | uuid | yes | signed in |

### `zella_reschedule_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_reschedule_appointment(p_appointment_id uuid, p_start timestamp with time zone, p_staff_id uuid, p_requested_by text)` | jsonb | yes | signed in |
| `zella_reschedule_callback(p_callback_id uuid, p_new_time timestamp with time zone)` | timestamp with time zone | yes | signed in |
| `zella_reschedule_confirm(p_token text, p_start timestamp with time zone)` | jsonb | yes | server only |
| `zella_reschedule_line(p_appointment_id uuid)` | text | yes | server only |
| `zella_reschedule_lookup(p_token text)` | jsonb | yes | server only |
| `zella_reschedule_slots(p_token text, p_days integer)` | jsonb | yes | server only |

### `zella_resolve_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_resolve_answer_report(p_report_id uuid, p_fixed boolean)` | boolean | yes | signed in |
| `zella_resolve_channel_review(p_automation_id uuid, p_choice text, p_consent_confirmed boolean)` | jsonb | yes | signed in |
| `zella_resolve_duplicate(p_review_id uuid, p_action text)` | uuid | yes | signed in |
| `zella_resolve_incident(p_incident_id uuid, p_note text)` | void | yes | signed in |
| `zella_resolve_platform_alerts(p_kind text, p_business_id uuid, p_dedupe_key text, p_note text)` | integer | yes | server only |
| `zella_resolve_template(p_business_id uuid, p_key text, p_channel text, p_locale text)` | message_templates | yes | server only |

### `zella_resource_*` (9)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_resource_block_guard()` | trigger | yes | server only |
| `zella_resource_day(p_business_id uuid, p_day date)` | jsonb | yes | signed in |
| `zella_resource_free(p_resource uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_party integer, p_ignore uuid)` | boolean | yes | server only |
| `zella_resource_guard()` | trigger | yes | server only |
| `zella_resource_needs_save(p_business_id uuid, p_needs jsonb)` | integer | yes | signed in |
| `zella_resource_pick(p_business_id uuid, p_service text, p_start timestamp with time zone, p_end timestamp with time zone, p_party integer, p_ignore uuid)` | uuid[] | yes | server only |
| `zella_resource_save(p_business_id uuid, p_id uuid, p_name text, p_kind text, p_capacity integer, p_buffer_minutes integer, p_notes text, p_sort_order integer, p_active boolean)` | uuid | yes | signed in |
| `zella_resource_usage(p_capacity integer, p_party integer)` | integer |  | signed in |
| `zella_resource_used(p_resource uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_ignore uuid)` | integer | yes | server only |

### `zella_retention_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_retention_due()` | jsonb | yes | server only |
| `zella_retention_scan(p_limit integer)` | integer | yes | server only |
| `zella_retention_summary(p_business_id uuid)` | jsonb | yes | signed in |

### `zella_retry_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_retry_automation_run(p_run_id uuid)` | text | yes | signed in |
| `zella_retry_dead_letter(p_id uuid)` | boolean | yes | signed in |
| `zella_retry_event(p_event_id uuid)` | text | yes | signed in |
| `zella_retry_failed(p_business_id uuid, p_kind text, p_id uuid)` | text | yes | signed in |

### `zella_review_*` (15)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_review_add(p_business_id uuid, p_site text, p_author text, p_rating integer, p_body text)` | uuid | yes | signed in |
| `zella_review_after_insert()` | trigger | yes | server only |
| `zella_review_before_insert()` | trigger | yes | server only |
| `zella_review_call_insight(p_insight_id uuid, p_action text)` | jsonb | yes | signed in |
| `zella_review_claim_ai(p_limit integer)` | jsonb | yes | server only |
| `zella_review_claim_fetch(p_limit integer)` | jsonb | yes | server only |
| `zella_review_claim_posts(p_limit integer)` | jsonb | yes | server only |
| `zella_review_decide(p_review_id uuid, p_action text, p_reply text)` | text | yes | signed in |
| `zella_review_ingest(p_business_id uuid, p_status_code integer, p_items jsonb)` | jsonb | yes | server only |
| `zella_review_post_result(p_review_id uuid, p_status_code integer)` | text | yes | server only |
| `zella_review_sample(p_sample_id uuid, p_verdict text, p_note text)` | boolean | yes | signed in |
| `zella_review_save_ai_draft(p_review_id uuid, p_draft text)` | text | yes | server only |
| `zella_review_source_save(p_business_id uuid, p_account_id text, p_location_id text, p_active boolean)` | boolean | yes | signed in |
| `zella_review_template(p_rating integer, p_author text, p_business_id uuid)` | text | yes | server only |
| `zella_review_work_waiting()` | integer | yes | server only |

### `zella_run_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_run_daily_reports(p_now timestamp with time zone)` | integer | yes | server only |
| `zella_run_industry_timers()` | integer | yes | server only |
| `zella_run_permission_check()` | integer | yes | server only |
| `zella_run_schedule_group(p_group text)` | jsonb | yes | server only |
| `zella_run_scheduled_job(p_job text)` | text | yes | server only |
| `zella_run_tenant_check()` | integer | yes | server only |

### `zella_save_*` (15)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_save_agent_config_draft(p_agent_id uuid, p_config jsonb)` | uuid | yes | signed in |
| `zella_save_assignment_rules(p_business_id uuid, p_mode text, p_roles text[], p_alert_minutes integer)` | jsonb | yes | signed in |
| `zella_save_business_hours(p_business_id uuid, p_hours jsonb)` | integer | yes | signed in |
| `zella_save_business_profile(p_business_id uuid, p_fields jsonb)` | jsonb | yes | signed in |
| `zella_save_call_insight(p_call_id uuid, p_result jsonb)` | jsonb | yes | server only |
| `zella_save_combinations(p_business_id uuid, p_combinations jsonb)` | jsonb | yes | signed in |
| `zella_save_industry_rule(p_business_id uuid, p_name text, p_trigger_type text, p_config jsonb, p_enabled boolean)` | uuid | yes | signed in |
| `zella_save_my_profile(p_first_name text, p_last_name text, p_phone text)` | jsonb | yes | signed in |
| `zella_save_qualification(p_customer_id uuid, p_answers jsonb)` | text | yes | signed in |
| `zella_save_record(p_business_id uuid, p_type_key text, p_id uuid, p_title text, p_status text, p_customer_id uuid, p_assigned_to uuid, p_due_at timestamp with time zone, p_data jsonb)` | jsonb | yes | signed in |
| `zella_save_record_type(p_business_id uuid, p_key text, p_patch jsonb)` | jsonb | yes | signed in |
| `zella_save_tables(p_business_id uuid, p_tables jsonb)` | jsonb | yes | signed in |
| `zella_save_template(p_business_id uuid, p_key text, p_channel text, p_body text, p_subject text, p_locale text)` | uuid | yes | signed in |
| `zella_save_terminology(p_business_id uuid, p_words jsonb)` | jsonb | yes | signed in |
| `zella_save_usage_preferences(p_business_id uuid, p_thresholds integer[], p_mode text, p_spend_limit_cents bigint, p_fallback text)` | jsonb | yes | signed in |

### `zella_schedule_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_schedule_audit(p_business_id uuid, p_action text, p_entity text, p_id uuid, p_new jsonb)` | void | yes | server only |
| `zella_schedule_calendar_pulls()` | integer | yes | server only |
| `zella_schedule_can_manage(p_business_id uuid)` | boolean | yes | signed in |
| `zella_schedule_can_work(p_business_id uuid)` | boolean | yes | signed in |

### `zella_set_*` (28)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_set_alert_status(p_id uuid, p_status text, p_user uuid, p_note text)` | boolean | yes | server only |
| `zella_set_appointment_record(p_appointment_id uuid, p_record_id uuid)` | jsonb | yes | signed in |
| `zella_set_attendance(p_appointment_id uuid, p_action text, p_reason text, p_staff_id uuid)` | text | yes | signed in |
| `zella_set_automation(p_business_id uuid, p_automation_id uuid, p_enabled boolean, p_config jsonb)` | jsonb | yes | signed in |
| `zella_set_business_logo(p_business_id uuid, p_url text)` | text | yes | signed in |
| `zella_set_business_modules(p_business_id uuid, p_enabled uuid[])` | integer | yes | server only |
| `zella_set_business_size(p_business_id uuid, p_size text)` | void | yes | signed in |
| `zella_set_call_content_access(p_business_id uuid, p_staff boolean)` | boolean | yes | signed in |
| `zella_set_capability(p_business_id uuid, p_key text, p_enabled boolean)` | jsonb | yes | signed in |
| `zella_set_charge_status(p_charge_id uuid, p_status text, p_reason text)` | jsonb | yes | signed in |
| `zella_set_contact_preferences(p_business_id uuid, p_customer_id uuid, p_preferred text, p_do_not_sms boolean, p_do_not_email boolean, p_do_not_call boolean)` | jsonb | yes | signed in |
| `zella_set_customer_channel(p_business_id uuid, p_customer_id uuid, p_channel text)` | void | yes | signed in |
| `zella_set_gap_suggestion(p_gap_id uuid, p_answer text, p_title text, p_kind text, p_source text, p_confidence text)` | boolean | yes | server only |
| `zella_set_incident_public(p_incident_id uuid, p_public boolean, p_message text, p_component text)` | boolean | yes | signed in |
| `zella_set_industry_rules(p_business_id uuid, p_rules jsonb)` | integer | yes | signed in |
| `zella_set_integration(p_business_id uuid, p_integration_id uuid, p_action text)` | text | yes | signed in |
| `zella_set_lead_plan(p_customer_id uuid, p_priority text, p_next_follow_up_at timestamp with time zone, p_clear_follow_up boolean)` | boolean | yes | signed in |
| `zella_set_lead_stage(p_customer_id uuid, p_stage text, p_reason text, p_reengage_days integer)` | text | yes | signed in |
| `zella_set_live_notice(p_business_id uuid, p_kind text, p_message text, p_hours integer)` | uuid | yes | signed in |
| `zella_set_member_away(p_business_id uuid, p_user_id uuid, p_until timestamp with time zone)` | boolean | yes | signed in |
| `zella_set_message_policy(p_business_id uuid, p_patch jsonb)` | jsonb | yes | signed in |
| `zella_set_my_avatar(p_url text)` | text | yes | signed in |
| `zella_set_my_notification_pref(p_business_id uuid, p_kind text, p_email boolean)` | boolean | yes | signed in |
| `zella_set_my_sms_alerts(p_business_id uuid, p_enabled boolean)` | boolean | yes | signed in |
| `zella_set_quote_status(p_quote_id uuid, p_status text)` | text | yes | signed in |
| `zella_set_record_status(p_id uuid, p_status text, p_note text)` | boolean | yes | signed in |
| `zella_set_report_schedule(p_business_id uuid, p_kind text, p_patch jsonb)` | jsonb | yes | signed in |
| `zella_set_review_link(p_business_id uuid, p_url text)` | void | yes | signed in |

### `zella_setup_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_setup_disabled_tools(p_business_id uuid)` | jsonb | yes | server only |
| `zella_setup_knowledge_sync(p_business_id uuid)` | integer | yes | server only |
| `zella_setup_knowledge_trg()` | trigger | yes | server only |
| `zella_setup_language_apply(p_business_id uuid, p_language text, p_greeting text)` | jsonb | yes | server only |
| `zella_setup_language_check(p_language text, p_greeting text)` | jsonb |  | server only |

### `zella_spam_*` (30)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_spam_ai_eligible(p_incident_id uuid)` | boolean | yes | server only |
| `zella_spam_assess(p_business_id uuid, p_channel text, p_phone text, p_email text, p_text text, p_extra jsonb)` | jsonb | yes | server only |
| `zella_spam_assign(p_incident_id uuid, p_user_id uuid)` | void | yes | signed in |
| `zella_spam_booking_guard()` | trigger | yes | server only |
| `zella_spam_booking_record()` | trigger | yes | server only |
| `zella_spam_call_trg()` | trigger | yes | server only |
| `zella_spam_claim_work(p_limit integer)` | jsonb | yes | server only |
| `zella_spam_config(p_business_id uuid)` | jsonb | yes | server only |
| `zella_spam_email_trg()` | trigger | yes | server only |
| `zella_spam_finish_work(p_incident_id uuid, p_claim uuid, p_result jsonb)` | jsonb | yes | server only |
| `zella_spam_hourly()` | jsonb | yes | server only |
| `zella_spam_kick_trg()` | trigger | yes | server only |
| `zella_spam_list_add(p_business_id uuid, p_list text, p_channel text, p_value text, p_reason text, p_hours integer, p_incident_id uuid)` | uuid | yes | signed in |
| `zella_spam_list_remove(p_entry_id uuid)` | void | yes | signed in |
| `zella_spam_listed(p_business_id uuid, p_channel text, p_phone text, p_email text)` | jsonb | yes | server only |
| `zella_spam_mask(p_sender text)` | text |  | server only |
| `zella_spam_note(p_incident_id uuid, p_note text)` | uuid | yes | signed in |
| `zella_spam_overview(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_spam_queue_trg()` | trigger | yes | server only |
| `zella_spam_record(p_business_id uuid, p_channel text, p_phone text, p_email text, p_display text, p_customer_id uuid, p_source_table text, p_source_id uuid, p_assessment jsonb)` | uuid | yes | server only |
| `zella_spam_reply_guard()` | trigger | yes | server only |
| `zella_spam_reports_due(p_limit integer)` | TABLE(business_id uuid, business_name text, week_start date) | yes | server only |
| `zella_spam_review(p_incident_id uuid, p_status text, p_note text, p_block boolean)` | jsonb | yes | signed in |
| `zella_spam_save_report(p_business_id uuid, p_week_start date, p_title text, p_body text)` | jsonb | yes | server only |
| `zella_spam_sender_facts(p_incident_id uuid)` | jsonb | yes | server only |
| `zella_spam_settings_get(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_spam_settings_save(p_business_id uuid, p_settings jsonb)` | jsonb | yes | signed in |
| `zella_spam_sms_trg()` | trigger | yes | server only |
| `zella_spam_work_waiting()` | integer | yes | server only |
| `zella_spam_workflow_live()` | boolean | yes | server only |

### `zella_staff_*` (8)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_staff_add_customer(p_business_id uuid, p_first_name text, p_last_name text, p_phone text, p_email text, p_notes text)` | jsonb | yes | signed in |
| `zella_staff_add_lead(p_business_id uuid, p_first_name text, p_last_name text, p_phone text, p_email text, p_source text, p_notes text)` | jsonb | yes | signed in |
| `zella_staff_create_callback(p_business_id uuid, p_contact_number text, p_summary text, p_preferred_at timestamp with time zone, p_customer_id uuid, p_priority text)` | uuid | yes | signed in |
| `zella_staff_create_task(p_business_id uuid, p_customer_id uuid, p_title text, p_due_at timestamp with time zone, p_assigned_to uuid, p_priority text)` | uuid | yes | signed in |
| `zella_staff_deactivated()` | trigger | yes | server only |
| `zella_staff_invite_fail(p_invitation_id uuid, p_error text)` | text | yes | server only |
| `zella_staff_invite_finalize(p_invitation_id uuid, p_actor uuid, p_auth_user_id uuid, p_existing_account boolean)` | text | yes | server only |
| `zella_staff_scorecards(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |

### `zella_store_*` (9)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_store_can_manage(p_business_id uuid)` | boolean | yes | signed in |
| `zella_store_connect(p_business_id uuid, p_actor uuid, p_shop_domain text, p_access_token text, p_shop_name text)` | uuid | yes | server only |
| `zella_store_disconnect(p_business_id uuid)` | integer | yes | signed in |
| `zella_store_lookup_begin(p_provider_call_id text, p_business_id uuid, p_order_ref text, p_caller_number text)` | jsonb | yes | server only |
| `zella_store_lookup_context(p_provider_call_id text, p_business_id uuid)` | jsonb | yes | server only |
| `zella_store_lookup_context(p_provider_call_id text, p_business_id uuid, p_order_ref text)` | jsonb | yes | server only |
| `zella_store_lookup_finish(p_business_id uuid, p_provider_call_id text, p_integration_id uuid, p_result text, p_verified boolean, p_order_ref text, p_reservation_id uuid)` | void | yes | server only |
| `zella_store_lookup_log(p_business_id uuid, p_provider_call_id text, p_integration_id uuid, p_result text, p_verified boolean)` | void | yes | server only |
| `zella_store_lookup_log(p_business_id uuid, p_provider_call_id text, p_integration_id uuid, p_result text, p_verified boolean, p_order_ref text)` | void | yes | server only |

### `zella_sweep_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_sweep_approvals()` | integer | yes | server only |
| `zella_sweep_open_calls()` | integer | yes | server only |
| `zella_sweep_stuck_calls()` | integer | yes | server only |

### `zella_table_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_table_action(p_business_id uuid, p_action text, p_args jsonb)` | jsonb | yes | signed in |
| `zella_table_board(p_business_id uuid, p_at timestamp with time zone)` | jsonb | yes | signed in |
| `zella_table_clearing_trg()` | trigger | yes | server only |
| `zella_table_event(p_business_id uuid, p_table_id uuid, p_appointment_id uuid, p_action text, p_detail jsonb)` | void | yes | server only |
| `zella_table_mode(p_business_id uuid)` | boolean | yes | server only |
| `zella_table_times(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_party integer, p_duration integer, p_limit integer, p_section text, p_needs text[])` | TABLE(slot_start timestamp with time zone) | yes | server only |

### `zella_tables_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_tables_affected(p_business_id uuid)` | jsonb | yes | server only |
| `zella_tables_check_bookings(p_business_id uuid)` | void | yes | server only |
| `zella_tables_fit(p_business_id uuid, p_table_ids uuid[], p_party integer, p_section text, p_needs text[])` | boolean | yes | server only |
| `zella_tables_free(p_table_ids uuid[], p_start timestamp with time zone, p_end timestamp with time zone, p_ignore uuid)` | boolean | yes | server only |

### `zella_team_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_team_capacity_trg()` | trigger | yes | server only |
| `zella_team_roster(p_business_id uuid)` | TABLE(user_id uuid, name text, role text) | yes | signed in |
| `zella_team_scorecard_nudge(p_now timestamp with time zone)` | integer | yes | server only |

### `zella_unsubscribe_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_unsubscribe_email(p_token text)` | jsonb | yes | anon, signed in |
| `zella_unsubscribe_lookup(p_token text)` | jsonb | yes | anon, signed in |
| `zella_unsubscribe_token(p_business_id uuid, p_customer_id uuid)` | text | yes | server only |

### `zella_update_*` (5)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_update_call_message(p_message_id uuid, p_status text)` | void | yes | signed in |
| `zella_update_callback(p_callback_id uuid, p_status text, p_note text, p_preferred_at timestamp with time zone, p_assign_to uuid)` | text | yes | signed in |
| `zella_update_customer_request(p_id uuid, p_status text, p_note text)` | boolean | yes | signed in |
| `zella_update_outbound_email(p_id uuid, p_status text, p_external_id text, p_error text)` | text | yes | server only |
| `zella_update_outbound_sms(p_id uuid, p_status text, p_external_id text, p_error text)` | text | yes | server only |

### `zella_usage_*` (8)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_usage_billable_seconds(p_seconds integer, p_policy jsonb)` | integer |  | server only |
| `zella_usage_consume(p_business_id uuid, p_resource text, p_quantity numeric, p_key text, p_source_kind text, p_source_id uuid, p_message_kind text, p_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_usage_counts(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | server only |
| `zella_usage_open_issue(p_business_id uuid, p_call_id uuid, p_kind text, p_error text, p_detail jsonb)` | void | yes | server only |
| `zella_usage_period_for(p_business_id uuid, p_at timestamp with time zone)` | jsonb | yes | server only |
| `zella_usage_policy()` | jsonb | yes | server only |
| `zella_usage_preferences(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_usage_release(p_business_id uuid, p_resource text, p_quantity numeric, p_key text, p_source_kind text, p_source_id uuid)` | jsonb | yes | server only |

### `zella_voice_*` (4)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_voice_assistant_status()` | jsonb | yes | server only |
| `zella_voice_choices()` | jsonb | yes | server only |
| `zella_voice_reliability_status()` | jsonb | yes | server only |
| `zella_voice_usage_summary(p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | server only |

### `zella_waitlist_*` (3)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_waitlist_offer_answer(p_token text, p_accept boolean)` | jsonb | yes | server only |
| `zella_waitlist_offer_line(p_entry_id uuid)` | text | yes | server only |
| `zella_waitlist_offer_lookup(p_token text)` | jsonb | yes | server only |

### `zella_website_*` (15)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_website_add_source(p_business_id uuid, p_url text)` | uuid | yes | signed in |
| `zella_website_approve_source(p_source_id uuid, p_auto_approve_new boolean, p_frequency_hours integer)` | boolean | yes | signed in |
| `zella_website_claim(p_limit integer)` | jsonb | yes | server only |
| `zella_website_crawl_live()` | boolean |  | server only |
| `zella_website_form_save(p_form_id uuid, p_name text, p_allowed_origins text[], p_enabled boolean)` | jsonb | yes | signed in |
| `zella_website_forms(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_website_mark_stale()` | integer | yes | server only |
| `zella_website_record_discovery(p_source_id uuid, p_sitemap_url text, p_urls text[], p_child_sitemaps text[], p_status integer, p_error text)` | integer | yes | server only |
| `zella_website_record_page(p_page_id uuid, p_http_status integer, p_final_url text, p_title text, p_text text, p_hash text, p_links text[], p_items jsonb, p_error text)` | jsonb | yes | server only |
| `zella_website_remove_source(p_source_id uuid)` | boolean | yes | signed in |
| `zella_website_same_site(p_host text, p_url text)` | boolean |  | server only |
| `zella_website_set_page(p_page_id uuid, p_approve boolean)` | boolean | yes | signed in |
| `zella_website_set_source(p_source_id uuid, p_paused boolean, p_auto_approve_new boolean, p_frequency_hours integer)` | boolean | yes | signed in |
| `zella_website_status(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_website_url_ok(p_url text)` | boolean |  | server only |

### `zella_workflow_*` (6)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_workflow_clean(p jsonb)` | jsonb |  | server only |
| `zella_workflow_due(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_workflow_effectiveness(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_workflow_log(p_business_id uuid, p_record_id uuid, p_kind text, p_detail text, p_entity text, p_entity_id uuid, p_data jsonb)` | void | yes | server only |
| `zella_workflow_move(r crm_records, p_status text, p_why text)` | boolean | yes | server only |
| `zella_workflow_record(p_record_id uuid, p_manager boolean)` | crm_records | yes | server only |

### `zella_<word>` (one-word names) (8)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_capabilities(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_digits(p text)` | text |  | anon, signed in |
| `zella_entitlements(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_notify(p_business_id uuid, p_kind text, p_title text, p_body text, p_severity text, p_page_key text, p_entity_id uuid, p_user_id uuid)` | uuid | yes | server only |
| `zella_reconcile()` | integer | yes | server only |
| `zella_redact(p text)` | text |  | signed in |
| `zella_setting(p_key text, p_default jsonb)` | jsonb | yes | server only |
| `zella_tables(p_business_id uuid)` | jsonb | yes | signed in |

### Smaller groups and older helpers (180)

| Function | Returns | SD | Who may call |
|---|---|---|---|
| `zella_acknowledge_escalation(p_call_id uuid)` | text | yes | signed in |
| `zella_activation_report(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_active_notices(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_advance_onboarding(p_business_id uuid, p_status text)` | void | yes | server only |
| `zella_agent_config_changes(p_version_id uuid)` | jsonb | yes | signed in |
| `zella_agent_config_current(p_agent_id uuid)` | jsonb | yes | signed in |
| `zella_answer_knowledge_gap(p_gap_id uuid, p_answer text, p_kind text, p_title text)` | uuid | yes | signed in |
| `zella_appointments_needing_record(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_archive_record(p_id uuid)` | boolean | yes | signed in |
| `zella_arrival_window(p_business_id uuid)` | integer | yes | server only |
| `zella_asset_type_keys()` | text[] |  | server only |
| `zella_assign_lead(p_customer_id uuid, p_user_id uuid)` | boolean | yes | signed in |
| `zella_audit_privileged()` | trigger | yes | server only |
| `zella_automation_readiness()` | jsonb | yes | signed in |
| `zella_available_slots(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_duration_minutes integer, p_staff_id uuid, p_step_minutes integer, p_limit integer, p_ignore_appointment uuid)` | TABLE(slot_start timestamp with time zone, slot_end timestamp with time zone, staff_id uuid, staff_name text) | yes | signed in |
| `zella_begin_record_file(p_record_id uuid, p_file_name text, p_mime_type text, p_size_bytes bigint, p_caption text, p_private boolean)` | jsonb | yes | signed in |
| `zella_block_trigger()` | trigger | yes | server only |
| `zella_book_appointment(p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamp with time zone, p_duration_minutes integer, p_staff_id uuid, p_party_size integer, p_notes text)` | uuid | yes | signed in |
| `zella_book_appointment(p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamp with time zone, p_duration_minutes integer, p_staff_id uuid, p_party_size integer, p_notes text, p_metadata jsonb)` | uuid | yes | server only |
| `zella_brand_name_pairs()` | TABLE(fn text, md5_before text, old_text text, new_text text) |  | server only |
| `zella_caller_context(p_business_id uuid, p_phone text)` | jsonb | yes | server only |
| `zella_caller_context_base(p_business_id uuid, p_phone text)` | jsonb | yes | server only |
| `zella_campaign_report(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_change_business_industry(p_business_id uuid, p_industry_id uuid)` | void | yes | server only |
| `zella_classify_email(p_subject text, p_body text, p_auto boolean)` | text |  | server only |
| `zella_clean_automation_config(p_type text, p_cfg jsonb)` | jsonb |  | server only |
| `zella_clean_origins(p_origins text[])` | text[] |  | signed in |
| `zella_clear_live_notice(p_business_id uuid, p_notice_id uuid)` | void | yes | signed in |
| `zella_connections_to_reconnect(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_consent_record(p_business_id uuid, p_customer_id uuid, p_record_id uuid, p_kind text, p_status text, p_given_by_customer_id uuid, p_scope text, p_expires_at date, p_evidence text)` | uuid | yes | signed in |
| `zella_consent_revoke(p_id uuid, p_reason text)` | void | yes | signed in |
| `zella_conversation_touch()` | trigger | yes | server only |
| `zella_credit_add(p_record_id uuid, p_kind text, p_units integer, p_appointment_id uuid, p_note text, p_expected_balance integer)` | jsonb | yes | signed in |
| `zella_credit_balance(p_record_id uuid)` | integer | yes | server only |
| `zella_currency_exponent(p_currency text)` | integer |  | anon, signed in |
| `zella_current_subscription(p_business_id uuid)` | subscriptions | yes | server only |
| `zella_customer_change_trg()` | trigger | yes | server only |
| `zella_customer_timeline(p_business_id uuid, p_customer_id uuid, p_limit integer)` | jsonb | yes | signed in |
| `zella_decline_waitlist_offer(p_entry_id uuid)` | void | yes | server only |
| `zella_delete_business_closure(p_closure_id uuid)` | boolean | yes | signed in |
| `zella_dismiss_dead_letter(p_id uuid, p_note text)` | boolean | yes | signed in |
| `zella_dismiss_knowledge_gap(p_gap_id uuid)` | boolean | yes | signed in |
| `zella_dnc_stops_callbacks()` | trigger | yes | server only |
| `zella_ensure_crm_types(p_business_id uuid)` | integer | yes | signed in |
| `zella_entitlement_allows(p_business_id uuid, p_key text, p_add numeric)` | boolean | yes | server only |
| `zella_erase_customer(p_business_id uuid, p_customer_id uuid)` | text | yes | signed in |
| `zella_escalation_trigger_keys()` | text[] |  | anon, signed in |
| `zella_escalation_triggers(p_business_id uuid)` | text[] | yes | server only |
| `zella_evaluate_call_usage_thresholds(p_business_id uuid)` | integer | yes | server only |
| `zella_exception_open(p_record_id uuid, p_kind text, p_detail text, p_expected_by date)` | uuid | yes | signed in |
| `zella_exception_resolve(p_id uuid, p_resolution text)` | boolean | yes | signed in |
| `zella_expire_holds()` | integer | yes | server only |
| `zella_expire_waitlist_offers()` | integer | yes | server only |
| `zella_export_customer_data(p_business_id uuid, p_customer_id uuid)` | jsonb | yes | signed in |
| `zella_fail_call_insight(p_call_id uuid, p_error text)` | void | yes | server only |
| `zella_fail_notification(p_id uuid, p_error text)` | void | yes | server only |
| `zella_failed_work(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_fulfil_data_rights_request(p_request_id uuid, p_note text)` | jsonb | yes | signed in |
| `zella_get_call_recording(p_call_id uuid)` | jsonb | yes | signed in |
| `zella_get_review_link(p_business_id uuid)` | text | yes | signed in |
| `zella_handle_inbound_sms_keyword(p_business_id uuid, p_from text, p_body text)` | jsonb | yes | server only |
| `zella_handle_staff_unavailable(p_business_id uuid, p_staff_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text)` | integer | yes | server only |
| `zella_has_role(p_business_id uuid, p_roles text[])` | boolean | yes | signed in |
| `zella_hold_slot(p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamp with time zone, p_duration_minutes integer, p_staff_id uuid, p_hold_minutes integer)` | uuid | yes | server only |
| `zella_inbound_email_address(p_business_id uuid)` | text | yes | server only |
| `zella_ingest_event(p_business_id uuid, p_event_type text, p_source text, p_idempotency_key text, p_payload jsonb, p_provider_event_id text, p_correlation_id uuid, p_causation_id uuid)` | jsonb | yes | server only |
| `zella_inspection_clean(p_items jsonb)` | jsonb |  | server only |
| `zella_inspection_save(p_record_id uuid, p_id uuid, p_title text, p_items jsonb, p_finish boolean, p_staff_id uuid, p_appointment_id uuid, p_expected_updated_at timestamp with time zone)` | jsonb | yes | signed in |
| `zella_integration_summary(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_invite_staff(p_business_id uuid, p_email text, p_name text, p_role text)` | uuid | yes | signed in |
| `zella_issue_quote(p_customer_id uuid, p_title text, p_expires_in_days integer)` | uuid | yes | signed in |
| `zella_join_waitlist(p_business_id uuid, p_customer_id uuid, p_title text, p_duration_minutes integer, p_earliest timestamp with time zone, p_latest timestamp with time zone, p_staff_id uuid, p_notes text)` | uuid | yes | signed in |
| `zella_language_allowance(p_business_id uuid)` | integer | yes | signed in |
| `zella_language_catalog()` | jsonb |  | anon, signed in |
| `zella_languages_status()` | jsonb | yes | server only |
| `zella_lead_rule_check()` | trigger | yes | server only |
| `zella_lead_source_report(p_business_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)` | jsonb | yes | signed in |
| `zella_leads_page(p_business_id uuid, p_filter text, p_source text, p_assignee text, p_query text, p_view text, p_limit integer, p_after jsonb)` | jsonb |  | signed in |
| `zella_list_drafts(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_list_invitations(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_lock_call_columns()` | text | yes | server only |
| `zella_mask_phone(p text)` | text |  | server only |
| `zella_match_customer(p_business_id uuid, p_phone text, p_email text)` | TABLE(customer_id uuid, certainty text) | yes | server only |
| `zella_max_party_ai(p_business_id uuid)` | integer | yes | server only |
| `zella_merge_customers(p_business_id uuid, p_keep uuid, p_drop uuid)` | jsonb | yes | signed in |
| `zella_messaging_status(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_mfa_satisfied()` | boolean | yes | anon, signed in |
| `zella_minor_to_amount(p_minor bigint, p_currency text)` | numeric |  | anon, signed in |
| `zella_module_on(p_business_id uuid, p_slug text)` | boolean | yes | signed in |
| `zella_move_open_work(p_business_id uuid, p_from uuid, p_to uuid)` | jsonb | yes | server only |
| `zella_move_sensitive_values(p_business_id uuid)` | integer | yes | server only |
| `zella_n8n_resend_auth(p_key text, p_endpoint text, p_id text, p_timestamp text, p_signature text, p_raw text)` | text | yes | server only |
| `zella_next_call_time(p_at timestamp with time zone, p_timezone text, p_start time without time zone, p_end time without time zone)` | timestamp with time zone |  | signed in |
| `zella_normalize_e164(p_number text)` | text |  | server only |
| `zella_notify_message_failures()` | integer | yes | server only |
| `zella_notify_owners(p_business_id uuid, p_kind text, p_title text, p_body text, p_severity text, p_page_key text)` | void | yes | server only |
| `zella_offboard_member(p_business_id uuid, p_user_id uuid, p_reassign_to uuid)` | jsonb | yes | signed in |
| `zella_open_incident(p_title text, p_detail text)` | uuid | yes | signed in |
| `zella_open_workload(p_business_id uuid, p_user_id uuid)` | integer | yes | server only |
| `zella_order_lookup_report(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_owner_continue_plan(p_business_id uuid)` | boolean | yes | signed in |
| `zella_owner_rules_prompt(p_business_id uuid, p_part text)` | text | yes | server only |
| `zella_patch_function(p_signature text, p_marker text, p_anchor text, p_replacement text)` | text |  | server only |
| `zella_pending_approvals(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_performance_review(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_permission_check()` | jsonb | yes | server only |
| `zella_phone_capacity_trg()` | trigger | yes | server only |
| `zella_pick_assignee(p_business_id uuid, p_exclude uuid)` | uuid | yes | server only |
| `zella_pick_tables(p_business_id uuid, p_party integer, p_start timestamp with time zone, p_end timestamp with time zone, p_ignore uuid, p_section text, p_needs text[])` | uuid[] | yes | server only |
| `zella_plan_evaluate(p_values jsonb)` | jsonb | yes | signed in |
| `zella_plan_limits(p_business_id uuid)` | jsonb | yes | server only |
| `zella_pre_request()` | void | yes | anon, signed in |
| `zella_prepare_email(p_business_id uuid, p_customer_id uuid, p_template_key text, p_vars jsonb, p_purpose text)` | jsonb | yes | server only |
| `zella_prepare_sms(p_business_id uuid, p_customer_id uuid, p_template_key text, p_vars jsonb, p_purpose text)` | jsonb | yes | server only |
| `zella_preset_v2_merge(p_patch jsonb)` | integer | yes | server only |
| `zella_preview_template(p_business_id uuid, p_key text, p_channel text, p_vars jsonb)` | jsonb | yes | signed in |
| `zella_provider_charge_payment(p_charge_id uuid, p_kind text, p_amount_minor bigint, p_provider_ref text)` | jsonb | yes | server only |
| `zella_provider_checks_live()` | boolean | yes | server only |
| `zella_public_status()` | jsonb | yes | anon, signed in |
| `zella_publish_agent_config(p_version_id uuid)` | integer | yes | signed in |
| `zella_rate_limit(p_key text, p_max integer, p_window_seconds integer)` | boolean | yes | server only |
| `zella_reactivate_business(p_business_id uuid)` | void | yes | server only |
| `zella_ready_knowledge(p_business_id uuid)` | TABLE(id uuid, kind text, title text, question text, answer text, version integer) | yes | signed in |
| `zella_reassign_callback(p_callback_id uuid, p_to_user uuid)` | text | yes | signed in |
| `zella_rebalance_assignments()` | integer | yes | server only |
| `zella_rebook_line(p_appointment_id uuid)` | text | yes | server only |
| `zella_receive_inbound_email(p_key text, p_message jsonb)` | jsonb | yes | server only |
| `zella_receive_inbound_email_signed(p_key text, p_message jsonb, p_sig jsonb)` | jsonb | yes | server only |
| `zella_records_page(p_business_id uuid, p_type_key text, p_filter text, p_query text, p_limit integer, p_after jsonb)` | jsonb |  | signed in |
| `zella_register_phone_number(p_business_id uuid, p_number text, p_vapi_phone_number_id text, p_label text)` | uuid | yes | server only |
| `zella_reject_data_rights_request(p_request_id uuid, p_reason text)` | void | yes | signed in |
| `zella_release_call(p_source text, p_id uuid, p_reason text, p_defer_minutes integer)` | text | yes | server only |
| `zella_reminder_response(p_appointment_id uuid, p_response text, p_note text)` | text | yes | server only |
| `zella_reminder_settings_trg()` | trigger | yes | server only |
| `zella_remove_record_file(p_file_id uuid)` | jsonb | yes | signed in |
| `zella_remove_waitlist_entry(p_id uuid)` | boolean | yes | signed in |
| `zella_require_capability(p_business_id uuid, p_key text)` | void | yes | server only |
| `zella_resend_invitation(p_invitation_id uuid)` | void | yes | signed in |
| `zella_resend_signature_ok(p_id text, p_timestamp text, p_signature text, p_raw text)` | text | yes | server only |
| `zella_response_time_report(p_business_id uuid, p_days integer)` | jsonb | yes | signed in |
| `zella_resync_reminders(p_business_id uuid)` | integer | yes | server only |
| `zella_reviews_list(p_business_id uuid, p_status text)` | jsonb | yes | signed in |
| `zella_reviews_status()` | jsonb | yes | server only |
| `zella_revoke_my_session(p_session_id uuid)` | boolean | yes | signed in |
| `zella_rls_coverage()` | jsonb | yes | server only |
| `zella_rollback_agent_config(p_version_id uuid)` | integer | yes | signed in |
| `zella_sample_ai_responses()` | integer | yes | server only |
| `zella_scan_duplicates()` | integer | yes | server only |
| `zella_seating_pref(p_business_id uuid, p_pref text)` | jsonb | yes | server only |
| `zella_security_log(p_business_id uuid, p_limit integer, p_before timestamp with time zone)` | jsonb | yes | signed in |
| `zella_seed_capability_defaults()` | integer | yes | server only |
| `zella_send_gap_reports()` | integer | yes | server only |
| `zella_sensitive_industry(p_business_id uuid)` | boolean | yes | signed in |
| `zella_session_proved_email()` | boolean | yes | signed in |
| `zella_skip_followup_task(p_task_id uuid, p_reason text)` | text | yes | server only |
| `zella_skip_reminder(p_reminder_id uuid, p_reason text)` | text | yes | server only |
| `zella_slot_say(p_start timestamp with time zone, p_tz text, p_window integer)` | text |  | anon, signed in |
| `zella_sms_parts(p_body text)` | integer |  | signed in |
| `zella_social_flow(p_conversation_id uuid, p_text text, p_intent text)` | text | yes | server only |
| `zella_start_execution(p_workflow_key text, p_business_id uuid, p_event_id uuid, p_workflow_version text, p_correlation_id uuid)` | uuid | yes | server only |
| `zella_stop_callbacks_for(p_business_id uuid, p_customer_id uuid, p_phone text, p_reason text)` | integer | yes | server only |
| `zella_stuck_executions(p_minutes integer)` | SETOF workflow_executions | yes | server only |
| `zella_subscription_after()` | trigger | yes | server only |
| `zella_subscription_trigger()` | trigger | yes | server only |
| `zella_suspend_business(p_business_id uuid, p_reason text)` | void | yes | server only |
| `zella_tenant_leak_check()` | jsonb | yes | server only |
| `zella_tenant_link_guard()` | trigger | yes | server only |
| `zella_today_operations(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_track_provisioning(p_business_id uuid, p_step text, p_status text, p_error text)` | void | yes | server only |
| `zella_transfer_destination(p_provider_call_id text, p_called_number text, p_vapi_phone_number_id text, p_from_number text)` | jsonb | yes | server only |
| `zella_valid_email(p_email text)` | boolean |  | anon, signed in |
| `zella_validate_agent_config(p_version_id uuid)` | jsonb | yes | signed in |
| `zella_validate_business_config(p_business_id uuid)` | jsonb | yes | signed in |
| `zella_vapi_authenticate(p_raw text, p_headers jsonb)` | text | yes | server only |
| `zella_verify_calls()` | integer | yes | server only |
| `zella_verify_provisioning(p_business_id uuid)` | jsonb | yes | server only |
| `zella_welcome_new_customer_trg()` | trigger | yes | server only |
| `zella_welcome_superseded_trg()` | trigger | yes | server only |
| `zella_within_plan_limit(p_business_id uuid, p_key text, p_current numeric)` | boolean | yes | server only |
| `zella_workspace_navigation(p_business_id uuid)` | jsonb | yes | signed in |

