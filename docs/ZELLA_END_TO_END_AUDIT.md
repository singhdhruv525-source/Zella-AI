# Zella AI: end-to-end audit (frontend, backend, admin dashboard, security)

Date: 29 October 2026. Branch `voice-reliability`. Environment audited: the production Supabase project
(`pffqxlumqhjdbzvvoszm`), read-only except for the fixes listed under F. Every test that touched production ran inside
a transaction that was rolled back, with throwaway users and businesses that never persisted.

Evidence labels used below: **Verified** (a test ran and its result is quoted), **Inspected** (read in code or the
database, not executed), **Blocked** (needs something that isn't available), **Not run**.

## A. Executive summary

| | |
|---|---|
| Overall | Security and tenant isolation are sound after this audit's fixes. The app is fully wired to the database. Real customer traffic is still blocked by setup items (hosting, providers, live switches). |
| Pages discovered | 221 screens: 8 public, 30 business pages + industry record pages, 90 business-settings pages, 18 admin sidebar pages, 75 admin-settings pages (17 categories). Plus detail drawers and the business wizard. |
| Pages audited | All 221: each page's data calls were checked against the live database (see B). Browser-tested this round: the 3 new admin pages, every tab and drawer, and the business Today page. |
| Data connections checked | 194 database functions, 50 tables, 328 selected columns, 82 admin server actions, 4 edge functions called from the app. All 194 functions and 82 actions exist and are callable by the right role. One table read was broken (M-1, fixed). |
| Disconnected / partly connected features | 1 broken (M-1, fixed). 1 misleading save message across the business app (M-2, fixed). Features that depend on unconfigured providers are labelled as not set up, not as working (G). |
| Security findings | Critical 0. High 2 (both fixed and verified). Medium 5 (2 fixed, 3 open). Low 6 (1 fixed, 5 open). |
| Tests | 141 tests against production (attack, fix and edge-function probes, all rolled back), 252 staging SQL tests, and browser tests of both apps. **All pass after the fixes**. Before them, 8 attack cases got through (H-1) and the billing test showed calls could be edited (H-2). 1 test blocked (Stripe webhook not configured). Details in E. |
| Production readiness | **Conditionally ready** (H): no known open critical or high issue, but the app is not hosted and no provider (calls, texts, email, payments) is live yet. |

## B. Frontend connection matrix

How this was checked (**Verified**). A script listed every `supabase.rpc`, `supabase.from(...).select(...)`, direct
write, owner-function action and edge-function call in `web/src` (194 functions, 50 tables, 328 columns, 82 actions).
Each was checked against the live database: the function exists and signed-in users may call it, or the table/column
exists and signed-in users may read it. Each admin action was checked against the permission map in
`owner-provision-business`. Every read and write still goes through row-level security or a function that checks the
caller (D). The tables below list what each page's file uses. Shared components (person drawer, booking panel,
forms) are listed under the page that opens them.

Authentication and authorisation for all business pages: a signed-in member of the selected business. The sidebar
hides items by module and role. The database enforces the same rules: row-level security on tables, and a
membership or role check inside every function.

### Public pages

| Route | Page | Data | Protection | Result |
|---|---|---|---|---|
| `/` (signed out) | Admin sign-in | Supabase Auth, `zella_platform_public_info` | sign-in; admin role checked on the server (`zella_admin_role`) | Inspected; admin gate Verified (non-admins get NOT_ALLOWED from every admin function) |
| `/app` (signed out), `/welcome` | Business sign-in, invitation / password setup | Supabase Auth, `zella_accept_my_invitations` | email link token | Inspected |
| `/status` | Public status page | `zella_public_status` (anon) | public by design, no customer data | Verified (callable signed out, returns states only) |
| `/continue-plan` | Owner keeps their plan | edge `continue-plan` (signed link) | HMAC-signed token | Verified (bad token → "invalid") |
| `/r/<64 hex>` | Customer reschedule link | edge `reschedule-appointment` | 256-bit token, rate limited | Verified (bad token → "invalid") |
| `/w/<64 hex>` | Waitlist offer link | edge `reschedule-appointment` | 256-bit token | Inspected |
| `/u/<32 hex>` | Email unsubscribe | `zella_unsubscribe_lookup` / `_email` (anon) | 128-bit token; only adds an opt-out | Inspected |

### Business CRM (`/app/...`)

| Route | Page | Component (file) | Database functions | Tables read | Direct writes |
|---|---|---|---|---|---|
| `/app` | Today | `BusinessToday` (BusinessToday.jsx) | `zella_complete_task`, `zella_spam_overview` | `appointments`, `calls_view`, `conversations`, `crm_records`, `crm_tasks`, `customers`, `staff_members` | appointments |
| `/app/leads` | Leads | `LeadsPage` (BusinessLeads.jsx) | `zella_add_lead_note`, `zella_assign_lead`, `zella_set_lead_plan`, `zella_set_lead_stage`, `zella_staff_create_callback`, `zella_team_roster` | `callbacks`, `calls_view`, `crm_tasks`, `customers` | — |
| `/app/calendar` | Calendar | `CalendarPage` (BusinessPages.jsx) | — | `ai_agents`, `appointments`, `blocked_times`, `calls_view`, `conversations`, `customers`, `staff_members` | appointments, blocked_times |
| `/app/calls` | Calls | `CallsPage` (BusinessCalls.jsx) | `zella_call_create_lead`, `zella_call_insights_list`, `zella_call_mark_followed_up`, `zella_call_schedule_callback`, `zella_call_update`, `zella_review_call_insight` | `callbacks`, `calls_view`, `followup_tasks` | — |
| `/app/transcripts` | Transcripts | `CallsPage` (BusinessCalls.jsx) | `zella_call_create_lead`, `zella_call_insights_list`, `zella_call_mark_followed_up`, `zella_call_schedule_callback`, `zella_call_update`, `zella_review_call_insight` | `callbacks`, `calls_view`, `followup_tasks` | — |
| `/app/messages` | Messages | `MessagesPage` (BusinessPages.jsx) | — | `ai_agents`, `appointments`, `blocked_times`, `calls_view`, `conversations`, `customers`, `staff_members` | appointments, blocked_times |
| `/app/receptionist` | Receptionist | `ReceptionistPage` (BusinessPages.jsx) | — | `ai_agents`, `appointments`, `blocked_times`, `calls_view`, `conversations`, `customers`, `staff_members` | appointments, blocked_times |
| `/app/automations` | Automations | `AutomationsPage` (BusinessControls.jsx) | `zella_set_automation` | `audit_logs`, `automation_runs`, `automations`, `followup_tasks` | — |
| `/app/callbacks` | Callbacks | `CallbacksPage` (BusinessCallbacks.jsx) | `zella_record_callback_attempt`, `zella_staff_create_task`, `zella_update_callback` | `callback_attempts`, `callbacks`, `customers` | — |
| `/app/tasks` | Tasks | `TasksPage` (BusinessWork.jsx) | `zella_activation_report`, `zella_complete_task`, `zella_issue_quote`, `zella_join_waitlist`, `zella_mark_notifications_read`, `zella_remove_waitlist_entry`, `zella_request_activation`, `zella_resolve_duplicate`, `zella_set_lead_stage`, `zella_set_quote_status`, `zella_staff_create_callback`, `zella_staff_create_task` | `callbacks`, `crm_tasks`, `customers`, `duplicate_reviews`, `quotes`, `staff_notifications`, `waitlist_entries` | — |
| `/app/waitlist` | Waitlist | `WaitlistPage` (BusinessWork.jsx) | `zella_activation_report`, `zella_complete_task`, `zella_issue_quote`, `zella_join_waitlist`, `zella_mark_notifications_read`, `zella_remove_waitlist_entry`, `zella_request_activation`, `zella_resolve_duplicate`, `zella_set_lead_stage`, `zella_set_quote_status`, `zella_staff_create_callback`, `zella_staff_create_task` | `callbacks`, `crm_tasks`, `customers`, `duplicate_reviews`, `quotes`, `staff_notifications`, `waitlist_entries` | — |
| `/app/spam` | Spam | `SpamPage` (SpamPage.jsx) | `zella_spam_assign`, `zella_spam_list_add`, `zella_spam_list_remove`, `zella_spam_note`, `zella_spam_overview`, `zella_spam_review`, `zella_spam_settings_get`, `zella_spam_settings_save` | `appointments`, `calls_view`, `email_messages`, `sms_messages`, `spam_incident_events`, `spam_incidents`, `spam_list_entries` | — |
| `/app/reviews` | Reviews | `ReviewsPage` (ReviewsPage.jsx) | `zella_review_add`, `zella_review_decide`, `zella_review_source_save`, `zella_reviews_list` | — | — |
| `/app/scorecards` | Scorecards | `ScorecardsPage` (ScorecardsPage.jsx) | `zella_staff_scorecards` | — | — |
| `/app/knowledge` | Knowledge | `KnowledgePage` (BusinessKnowledge.jsx) | `zella_answer_knowledge_gap`, `zella_dismiss_knowledge_gap` | `knowledge_gaps`, `knowledge_items` | knowledge_items |
| `/app/team` | Team | `TeamPage` (BusinessTeam.jsx) | — | `blocked_times`, `business_members`, `staff_members` | blocked_times, staff_members |
| `/app/drafts` | Drafts | `DraftsPage` (BusinessDrafts.jsx) | `zella_active_notices`, `zella_clear_live_notice`, `zella_decide_draft`, `zella_get_review_link`, `zella_list_drafts`, `zella_set_live_notice`, `zella_set_review_link` | — | — |
| `/app/access` | Access | `AccessPage` (BusinessAccess.jsx) | `zella_create_handover`, `zella_decide_approval`, `zella_failed_work`, `zella_invite_staff`, `zella_list_invitations`, `zella_offboard_member`, `zella_pending_approvals`, `zella_resend_invitation`, `zella_retry_failed`, `zella_security_log`, `zella_team_roster` | — | — |
| `/app/approvals` | Approvals | `ApprovalsPage` (BusinessAccess.jsx) | `zella_create_handover`, `zella_decide_approval`, `zella_failed_work`, `zella_invite_staff`, `zella_list_invitations`, `zella_offboard_member`, `zella_pending_approvals`, `zella_resend_invitation`, `zella_retry_failed`, `zella_security_log`, `zella_team_roster` | — | — |
| `/app/failed` | Failed | `FailedWorkPage` (BusinessAccess.jsx) | `zella_create_handover`, `zella_decide_approval`, `zella_failed_work`, `zella_invite_staff`, `zella_list_invitations`, `zella_offboard_member`, `zella_pending_approvals`, `zella_resend_invitation`, `zella_retry_failed`, `zella_security_log`, `zella_team_roster` | — | — |
| `/app/security` | Security | `SecurityLogPage` (BusinessAccess.jsx) | `zella_create_handover`, `zella_decide_approval`, `zella_failed_work`, `zella_invite_staff`, `zella_list_invitations`, `zella_offboard_member`, `zella_pending_approvals`, `zella_resend_invitation`, `zella_retry_failed`, `zella_security_log`, `zella_team_roster` | — | — |
| `/app/checkins` | Checkins | `CheckInsPage` (BusinessCheckIns.jsx) | `zella_set_attendance` | `appointments`, `staff_members` | — |
| `/app/attention` | Attention | `AttentionPage` (BusinessMore.jsx) | `zella_performance_review`, `zella_set_integration` | `appointments`, `calls_view`, `customers`, `integrations` | appointments, customers |
| `/app/inbox` | Inbox | `InboxPage` (BusinessInbox.jsx) | `zella_inbox_add_note`, `zella_inbox_handover`, `zella_inbox_mark_read`, `zella_inbox_reply`, `zella_inbox_update`, `zella_staff_create_callback` | `calls_view`, `conversation_messages`, `conversation_notes`, `conversations`, `customers`, `email_messages`, `integrations`, `sms_messages` | — |
| `/app/lead-sources` | Lead sources | `LeadSourcesPage` (BusinessMore.jsx) | `zella_performance_review`, `zella_set_integration` | `appointments`, `calls_view`, `customers`, `integrations` | appointments, customers |
| `/app/reports` | Reports | `ReportsPage` (BusinessMore.jsx) | `zella_performance_review`, `zella_set_integration` | `appointments`, `calls_view`, `customers`, `integrations` | appointments, customers |
| `/app/integrations` | Integrations | `IntegrationsPage` (IntegrationsPage.jsx) | — | — | — |
| `/app/settings` | Settings | `BusinessSettingsPage` (BusinessSettings.jsx) | `zella_accept_legal_document`, `zella_agent_config_current`, `zella_business_entitlements`, `zella_business_request`, `zella_business_settings`, `zella_integration_summary`, `zella_owner_continue_plan`, `zella_save_business_profile`, `zella_save_terminology`, `zella_save_usage_preferences`, `zella_set_business_logo`, `zella_usage_preferences` | `agent_config_versions`, `ai_agents`, `ai_eval_cases`, `business_phone_numbers`, `calendar_connections`, `contact_consents`, `legal_acceptances`, `legal_documents`, `message_templates`, `plans`, `staff_notifications`, `support_tickets` | — |
| `/app/customers` | Customers | `CustomersPage` → `PeoplePage` (BusinessPages.jsx) | — | `customers`, `appointments`, `calls_view`, `conversations` | customers (via add/edit forms) |
| `/app/records/<type>` | Industry records (Tables, Jobs, Recalls…) | `RecordsPage` (BusinessRecords.jsx) | `zella_save_record`, `zella_archive_record`, `zella_add_record_note`, `zella_ensure_crm_types` | `crm_records`, `crm_record_types`, `crm_record_events` | — |
| `/app/record-settings` | Customise records | `RecordSettingsPage` (BusinessRecords.jsx) | `zella_save_record_type` | `crm_record_types` | — |

Settings (`/app/settings/<section>/<page>`, 16 categories, 90 pages, `BusinessSettings.jsx`): the data paths were
checked the same way (all functions and columns exist and are readable). Before this audit, one panel was broken:
AI receptionist > "Test it yourself" (M-1).

## C. Super Admin dashboard

Security boundary (**Verified**):
- The admin app only renders after `zella_admin_role()` returns a role. This is read from the `platform_admins` table
  on the server; local storage and user metadata are never used for authorisation.
- Every admin action goes through `owner-provision-business` (server checks the token, reads the role from the
  database, maps each action to a permission, rejects unknown actions, and requires two-step sign-in for admins who set
  it up) or through `zella_admin_*` database functions, which call `zella_admin_require(permission)` first.
- Tested: a business owner calling `zella_admin_calls` / `zella_admin_numbers` / `zella_admin_business_options` gets
  NOT_ALLOWED; a signed-out caller gets "permission denied"; `owner-provision-business` without a token or with a fake
  token returns 401.
- In the browser, a read-only admin role sees no change buttons on Voice, Messaging or Automations. When the server
  refuses an action, the page shows "Your admin role doesn't allow this."
- Privileged changes write `audit_logs`: number release, routing, message retry, template save, automation status,
  run retry/review, call and message content views, and the owner-function actions.

| Route | Page | Component (file) | Server actions (owner function) | Database functions | Tables read |
|---|---|---|---|---|---|
| `/` | Overview | `OwnerOverview` (OwnerOverview.jsx) | `overview_data` | — | — |
| `/businesses`, `/businesses/<id>`, `/businesses/new` | Businesses, business details, create-business wizard | inline list in `OwnerDashboard`, `BusinessDetails` (BusinessDetails.jsx), `CreateBusinessWizard` | `tenants_search`, `business_detail`, `dashboard_data`, `setup_load`, `setup_save_*` (11 steps), `setup_finish`, `setup_document_*` | — | — |
| `/verification` | Verification | `VerificationQueue` (VerificationQueue.jsx) | `document_review`, `document_view`, `documents_queue` | — | — |
| `/security-abuse` | Security & Abuse | `SecurityAbuse` (SecurityAbuse.jsx) | `spam_admin_automation_save`, `spam_admin_incident`, `spam_admin_incidents`, `spam_admin_overview`, `spam_admin_policy_save`, `spam_admin_rule_add`, `spam_admin_rule_remove`, `spam_admin_rules` | — | — |
| `/audit-logs` | Audit Logs | `AuditLogs` (AuditLogs.jsx) | `audit_logs` | — | — |
| `/industries` | Industry Configuration | `IndustryConfiguration` (IndustryConfiguration.jsx) | `industries_list`, `industry_create`, `industry_save` | — | — |
| `/agents` | AI Agents | `AIAgents` (AIAgents.jsx) | `agents_list` | — | — |
| `/modules` | Modules & Features | `ModulesPage` (ModulesPage.jsx) | `modules_overview` | — | — |
| `/users` | Users & Access | `UsersAccess` (UsersAccess.jsx) | `admins_list` | — | — |
| `/integrations` | Integrations | `IntegrationsPage` (IntegrationsPage.jsx) | `integrations_overview` | — | — |
| `/support` | Support | `SupportTickets` (SupportTickets.jsx) | `ticket_create`, `ticket_update`, `tickets_list` | — | — |
| `/plans` | Plans & Subscriptions | `PlansPage` (PlansPage.jsx) | `plan_save`, `plans_list` | — | — |
| `/offers` | Offers & Promotions | `OffersPage` (OffersPage.jsx) | `dashboard_data` | `zella_offer_apply_admin`, `zella_offer_audience`, `zella_offer_detail`, `zella_offer_monitor`, `zella_offer_report`, `zella_offer_retry`, `zella_offer_rule_save`, `zella_offer_rules_list`, `zella_offer_save`, `zella_offer_set_redemption`, `zella_offer_transition`, `zella_offers_list` | — |
| `/operations` | Platform Operations | `PlatformOperations` (PlatformOperations.jsx) | `platform_status` | — | — |
| `/voice` | Voice & numbers | `VoiceNumbersPage` (VoiceNumbersPage.jsx) | `number_assign`, `number_set_status` | `zella_admin_call_detail`, `zella_admin_calls`, `zella_admin_number_release`, `zella_admin_numbers`, `zella_admin_routing_get`, `zella_admin_routing_save`, `zella_admin_voice_alerts`, `zella_admin_voice_overview` | — |
| `/messaging` | Messaging | `MessagingPage` (MessagingPage.jsx) | — | `zella_admin_message_detail`, `zella_admin_message_retry`, `zella_admin_messages`, `zella_admin_messaging_alerts`, `zella_admin_messaging_compliance`, `zella_admin_messaging_overview`, `zella_admin_template_save`, `zella_admin_templates` | — |
| `/automations` | Automations | `AutomationsPage` (AutomationsPage.jsx) | — | `zella_admin_automation_detail`, `zella_admin_automation_overview`, `zella_admin_automation_set_status`, `zella_admin_automation_templates`, `zella_admin_automations`, `zella_admin_business_automations_pause`, `zella_admin_run_detail`, `zella_admin_run_retry`, `zella_admin_run_reviewed`, `zella_admin_runs`, `zella_admin_scheduler_health` | — |
| `/settings` | Settings | `SettingsPage` (SettingsPage.jsx) | `me_admin` | — | — |

What each page controls, and what's incomplete:
- **Overview, Businesses, Verification, Industry Configuration, Modules, Plans, Offers, AI Agents, Integrations,
  Support, Security & Abuse, Users & Access, Audit Logs, Platform Operations, Settings**: wired to the owner function or
  database functions listed above. All 82 actions exist on the server with a permission.
- **Voice & numbers / Messaging / Automations** (built this week): live KPIs, server-side filters and paging, detail
  drawers, actions that require a reason, and audit logging. Browser-tested end to end with every tab, drawer and write
  (10 writes), a read-only role, and server refusal.
- **Not built, shown as "not available" rather than faked:**
  - buying numbers and reading carrier details from Telnyx;
  - a "test connection" button for providers (it would need keys in the browser);
  - switching the live sending flags from the UI (intentional);
  - creating automations from the admin;
  - restricted admin roles (M-3).

## D. RLS and security report

### Method
- Read-only inventory of the live database:
  - every table and view in `public`, with row-level security on or off;
  - every policy;
  - grants to `anon` and `authenticated`, including column grants;
  - all 265 `SECURITY DEFINER` functions callable by signed-in users, and the 4 callable by visitors;
  - storage buckets and their policies;
  - triggers on `calls` and `sms_messages`;
  - Supabase's security advisor.
- The access helpers were read and confirmed sound:
  - `is_business_member`, `zella_is_member`, `zella_has_role` and `zella_can_manage` require an **active** membership
    of the signed-in user (`auth.uid()`);
  - `is_platform_admin` and `zella_admin_can` read `platform_admins`;
  - all have a fixed `search_path`.
- A scan of all 265 functions flagged 117 that take an id without passing it to a helper. The 13 with no helper call
  were read one by one: each checks membership inline. The rest load the row and then check its business. Then
  everything was attacked for real (E).
- Visitors (`anon`) can read only active `industries` and `plans`, and can call 4 functions: public info, status page,
  unsubscribe lookup/confirm.
- Storage: `brand-assets` is public-read (logos) with writes limited by `zella_can_write_brand_asset`.
  `business-documents` is private and has no browser policies; it is only reached through the owner function's signed
  URLs.
- No service-role or secret key in `web/src` or the built bundle: a scan of `dist/assets` found no `sb_secret_` key
  and no JWT of any role. The browser uses only `VITE_SUPABASE_URL` and the publishable key; edge functions read the
  secret key from their own environment.

### Findings

| ID | Severity | Finding | Evidence | Status |
|---|---|---|---|---|
| H-1 | High | **Cross-tenant links.** Row-level security checked a row's own `business_id` but not the ids it points to. A member of business A could save an appointment or conversation pointing at business B's customer or staff member, or assign work to a user of business B. They could do this directly, or through `zella_staff_create_callback`, `zella_staff_create_task` and `zella_update_callback`. Functions that later read the linked customer by id, such as the inbox reply (which looks up the phone number), could then act on B's customer. | Attack tests: round 1 found 2 cases, round 2 found 6 more (E). | **Fixed** (`sql/zella_tenant_links.sql`): guard trigger on 28 tables. All 8 attacks now fail with TENANT_MISMATCH; 7 legitimate same-business cases still work; existing data had 0 violations. |
| H-2 | High | **Members could edit call and message records directly.** Any non-viewer member could update `calls.duration_seconds`, `ended_at` or `ai_handled`, and the usage trigger recalculates billable minutes from those. They could also insert fake calls, or record texts and emails as "delivered". | Code: `zella_calls_usage_trg`. Test: an owner shortened a 600-second call before the fix. | **Fixed** (`sql/zella_write_lockdown.sql`): no direct writes by signed-in users to calls, texts, emails, conversations, notifications, support tickets, integrations or automations. The app already uses checked functions for all of these. Re-tested: the attacks are refused, `zella_call_update` and `zella_inbox_mark_read` still work, and the call duration was unchanged. |
| M-1 | Medium | Business Settings > AI receptionist > "Test it yourself" read `ai_eval_cases`, which had no SELECT grant, so the panel always failed. | Column check: the only unreadable columns in the whole app. | **Fixed**: `grant select` (the policy already limits it to owners and admins). Re-tested as owner. |
| M-2 | Medium | When row-level security refuses an update (for example a view-only member marking an appointment), Supabase returns no error and 0 rows, and the app said it was saved. This affected about 20 update/delete calls in the business app. | Browser test: the success message appeared while nothing changed. | **Fixed**: `changed()` in `BusinessShared.jsx` asks for the changed rows and reports "Nothing was changed. Your role may not allow this…". Today shows action errors separately from load errors. Browser-verified: allowed → normal message; refused → error, no success message. |
| M-3 | Medium | `platform_admins` accepts only `zella_owner` and `super_admin` (trigger `zella_platform_admin_trigger`). The restricted roles (support, billing, read-only…) offered in Settings can't be given to anyone. | Insert of `read_only_admin` → INVALID_ADMIN_ROLE (earlier test). | Open. Needs a decision on whether restricted admins should exist. The fix is to widen the trigger to the role list in `platform_role_permissions`. |
| M-4 | Medium | Staff and view-only members can read call transcripts and recording links directly from `calls` / `calls_view`, while `zella_get_call_recording` limits recordings to owners and admins. The two rules disagree. | Inspected (column grants + policy). | Open: a product decision. Restricting it would hide transcripts from staff on the Calls page. |
| M-5 | Medium | `app_base_url` / `ZELLA_APP_URL` is not set and the app isn't hosted, so invitation, reschedule and waitlist links can't be sent. `staff-invite` correctly refuses (503). | Probe of `staff-invite`. | Open: manual (hosting + domain). |
| L-1 | Low | Leftover edge functions `smart-action` ("zella-admin-check") and `zella-admin-check-v2` are deployed but not in the repo. They only answer whether the caller is an admin. | Code read. | Open: delete in the Supabase dashboard. |
| L-2 | Low | `staff-invite` checks its configuration before the caller's sign-in, so a signed-out caller learns that `ZELLA_APP_URL` is unset. | Probe. | Open: harmless once the URL is set. |
| L-3 | Low | Leaked-password protection is off. | Security advisor. | Open: needs the Supabase Pro plan. |
| L-4 | Low | `businesses.inbound_email_token` (the inbound email address token) is readable by every member of that business, including view-only. | Column grants. | Open: low impact (own business only). |
| L-5 | Low | Members of a suspended business keep normal access to its data. Only automations pause. | Helpers check membership, not business status. | Open: confirm this is intended. |
| L-6 | Low | `zella_usage_billable_seconds` had no fixed `search_path`. | Security advisor. | **Fixed** (pinned). |

Advisor notices not counted as findings:
- 35 tables with RLS on and no policies: intentional, server-only tables.
- 265 signed-in-callable definer functions: the app's checked API, reviewed and attacked above.
- 4 visitor-callable functions: reviewed above.

### Table-by-table inventory (live database, after fixes)

"Signed-in user grants" are table privileges. Row-level policies then limit rows to the user's own business, or own
rows. "Super Admin access: server functions" means admins reach the table only through permission-checked functions
or the owner function (service key on the server), never with direct browser access. "Link guard" = the H-1 trigger.

| Table | RLS | Policies (r = restrictive) | Visitor (anon) | Signed-in user grants | Tenant key | Super Admin access | Link guard |
|---|---|---|---|---|---|---|---|
| `activation_tests` | on | select | — | read | business_id | server functions |  |
| `admin_alert_prefs` | on | none | — |  | platform | server functions |  |
| `agent_config_versions` | on | select | — | read | business_id | server functions |  |
| `ai_agent_configs` | on | select | — | read | via agent | server functions |  |
| `ai_agents` | on | select | — | read | business_id | server functions |  |
| `ai_answer_reports` | on | select | — | read | business_id | server functions |  |
| `ai_eval_cases` | on | all | — | read | business_id | policy |  |
| `ai_response_samples` | on | select | — | read | business_id | server functions |  |
| `ai_tool_calls` | on | select | — |  | business_id | policy |  |
| `appointment_reminders` | on | select | — | read | business_id | server functions | yes |
| `appointment_reschedule_links` | on | none | — |  | business_id | server functions |  |
| `appointments` | on | delete(r), insert, insert(r), select, update, update(r) | — | read/insert/update | business_id | server functions | yes |
| `assignment_rules` | on | select | — | read | business_id | server functions |  |
| `audit_logs` | on | select | — | read | business_id | server functions |  |
| `automation_dead_letters` | on | select | — | read | business_id | server functions |  |
| `automation_events` | on | select | — | read | business_id | server functions |  |
| `automation_runs` | on | select | — | read | business_id | server functions | yes |
| `automations` | on | delete, delete(r), insert, insert(r), select, select(r), update, update(r) | — | read | business_id | server functions |  |
| `billing_events` | on | none | — |  | business_id | server functions |  |
| `blocked_times` | on | delete, delete(r), insert, insert(r), select, update, update(r) | — | read/insert/update/delete | business_id | server functions | yes |
| `business_closures` | on | select | — |  | business_id | server functions |  |
| `business_hours` | on | select | — |  | business_id | server functions |  |
| `business_invitations` | on | none | — |  | business_id | server functions |  |
| `business_languages` | on | select | — |  | business_id | server functions |  |
| `business_members` | on | select | — | read | business_id | server functions |  |
| `business_modules` | on | select | — | read | business_id | server functions |  |
| `business_phone_numbers` | on | select | — | read (columns) | business_id | server functions |  |
| `business_usage_preferences` | on | none | — |  | business_id | server functions |  |
| `business_verification_documents` | on | select | — | read (columns) | business_id | server functions |  |
| `businesses` | on | select | — | read | id (membership) | server functions |  |
| `calendar_connections` | on | select | — | read (columns) | business_id | server functions |  |
| `calendar_sync_queue` | on | none | — |  | business_id | server functions |  |
| `call_insights` | on | select, select(r) | — |  | business_id | server functions |  |
| `call_messages` | on | select | — |  | business_id | server functions | yes |
| `callback_attempts` | on | select | — | read | business_id | server functions |  |
| `callbacks` | on | select | — | read | business_id | server functions | yes |
| `calls` | on | delete(r), insert, insert(r), select, select(r), update, update(r) | — | read | business_id | server functions | yes |
| `calls_view` (view, security_invoker) | n/a (uses `calls` policies) | — | — | read | business_id | server functions |  |
| `contact_consents` | on | select | — | read | business_id | server functions | yes |
| `conversation_messages` | on | insert, select | — | read | via conversation | server functions |  |
| `conversation_notes` | on | select | — | read | business_id | server functions |  |
| `conversations` | on | delete(r), insert, insert(r), select, update, update(r) | — | read | business_id | server functions | yes |
| `crm_record_events` | on | select | — | read | business_id | server functions |  |
| `crm_record_types` | on | select | — | read | business_id | server functions |  |
| `crm_records` | on | select, select(r) | — | read | business_id | server functions | yes |
| `crm_tasks` | on | select | — | read | business_id | server functions | yes |
| `cross_sell_rules` | on | select | — |  | business_id | server functions |  |
| `customer_requests` | on | select | — | read | business_id | server functions | yes |
| `customers` | on | delete(r), insert, insert(r), select, update, update(r) | — | read/insert/update | business_id | server functions | yes |
| `data_rights_requests` | on | select | — | read | business_id | server functions | yes |
| `duplicate_reviews` | on | select | — | read | business_id | server functions | yes |
| `email_events` | on | none | — |  | business_id | server functions |  |
| `email_messages` | on | insert, select | — | read | business_id | server functions | yes |
| `email_unsubscribe_tokens` | on | none | — |  | business_id | server functions | yes |
| `followup_tasks` | on | select | — | read | business_id | server functions | yes |
| `industries` | on | select | read (active only) | read | platform | server functions |  |
| `industry_automation_defaults` | on | select | — | read | platform | server functions |  |
| `industry_automation_presets` | on | none | — |  | platform | server functions |  |
| `industry_automation_runs` | on | none | — |  | platform | server functions |  |
| `industry_configurations` | on | select | — | read | platform (own industry) | server functions |  |
| `industry_crm_presets` | on | none | — |  | platform | server functions |  |
| `industry_modules` | on | select | — | read | platform | server functions |  |
| `integration_secrets` | on | none | — |  | platform | server functions |  |
| `integrations` | on | insert, select, update | — | read (columns, no credentials) | business_id | server functions |  |
| `knowledge_gaps` | on | select | — | read | business_id | server functions |  |
| `knowledge_items` | on | delete(r), insert, insert(r), select, update, update(r) | — | read/insert/update | business_id | server functions |  |
| `knowledge_versions` | on | select | — | read | business_id | server functions |  |
| `lead_questions` | on | all, delete(r), insert(r), update(r) | — | read/insert/update/delete | business_id | server functions |  |
| `lead_rules` | on | all, delete(r), insert(r), update(r) | — | read/insert/update/delete | business_id | server functions |  |
| `lead_submissions` | on | select | — |  | business_id | server functions | yes |
| `legal_acceptances` | on | select | — | read | own user / owners | server functions |  |
| `legal_documents` | on | select | — | read (published) | platform | server functions |  |
| `live_notices` | on | select | — | read | business_id | server functions |  |
| `message_drafts` | on | select | — | read | business_id | server functions | yes |
| `message_templates` | on | select | — | read | business_id (or platform) | server functions |  |
| `meta_connections` | on | select | — |  | business_id | server functions |  |
| `meta_contacts` | on | none | — |  | business_id | server functions | yes |
| `meta_events` | on | none | — |  | business_id | server functions |  |
| `meta_outbox` | on | none | — |  | business_id | server functions |  |
| `meta_templates` | on | select | — |  | business_id | server functions |  |
| `n8n_dispatch_state` | on | none | — |  | platform | server functions |  |
| `notification_preferences` | on | delete, insert, select, update | — | read/insert/update/delete (own rows) | business_id + user | server functions |  |
| `notifications` | on | delete, insert, select, update | — | read | business_id + user | server functions |  |
| `offer_events` | on | none | — |  | business_id | server functions |  |
| `offer_job_runs` | on | none | — |  | platform | server functions |  |
| `offer_redemptions` | on | none | — |  | business_id | server functions |  |
| `offer_rules` | on | none | — |  | platform | server functions |  |
| `offers` | on | none | — |  | platform | server functions |  |
| `on_call_reminders_sent` | on | none | — |  | platform | server functions |  |
| `on_call_settings` | on | select | — |  | business_id | server functions |  |
| `on_call_shifts` | on | select | — |  | business_id | server functions | yes |
| `payments` | on | select | — | read | business_id | server functions |  |
| `plans` | on | select | read (active only) | read | platform | server functions |  |
| `platform_admins` | on | none | — |  | platform | server functions |  |
| `platform_alerts` | on | select | — | read | business_id | policy (admins only) |  |
| `platform_incidents` | on | select | — | read | platform | policy (admins only) |  |
| `platform_role_permissions` | on | none | — |  | platform | server functions |  |
| `platform_settings` | on | none | — |  | platform | server functions |  |
| `profiles` | on | select, update (own row) | — | read/update own row (insert/delete have no policy) | own user | server functions |  |
| `provider_health` | on | none | — |  | platform | server functions |  |
| `provisioning_steps` | on | none | — |  | business_id | server functions |  |
| `quotes` | on | select | — | read | business_id | server functions | yes |
| `rate_limits` | on | none | — |  | platform | server functions |  |
| `review_sources` | on | select | — |  | business_id | server functions |  |
| `reviews` | on | select | — |  | business_id | server functions |  |
| `sensitive_approvals` | on | select | — |  | business_id | server functions |  |
| `sms_messages` | on | insert, select | — | read | business_id | server functions | yes |
| `social_flows` | on | select | — | read | business_id | server functions |  |
| `spam_incident_events` | on | select | — | read | business_id | server functions |  |
| `spam_incidents` | on | select | — | read | business_id | server functions | yes |
| `spam_list_entries` | on | select | — | read | business_id | server functions |  |
| `spam_settings` | on | select | — | read | business_id | server functions |  |
| `staff_handovers` | on | select | — |  | business_id | server functions | yes |
| `staff_members` | on | delete, delete(r), insert, insert(r), select, update, update(r) | — | read/insert/update/delete | business_id | server functions |  |
| `staff_notifications` | on | select | — | read | business_id + user | server functions |  |
| `subscriptions` | on | select | — | read | business_id | server functions |  |
| `support_tickets` | on | delete(r), insert, insert(r), select, update, update(r) | — | read | business_id | server functions |  |
| `time_off_requests` | on | select | — | read | business_id | server functions | yes |
| `usage_processing_issues` | on | none | — |  | business_id | server functions |  |
| `usage_records` | on | select | — | read | business_id | server functions |  |
| `usage_threshold_events` | on | none | — |  | business_id | server functions |  |
| `usage_thresholds` | on | none | — |  | business_id | server functions |  |
| `vapi_request_receipts` | on | none | — |  | platform | server functions |  |
| `voice_pricing` | on | none | — |  | platform | server functions |  |
| `waitlist_entries` | on | select | — | read | business_id | server functions | yes |
| `waitlist_offer_links` | on | none | — |  | business_id | server functions |  |
| `website_forms` | on | select | — |  | business_id | server functions |  |
| `website_pages` | on | select | — | read | business_id | server functions |  |
| `website_sources` | on | select | — | read | business_id | server functions |  |
| `workflow_executions` | on | select | — | read | business_id | server functions |  |
| `zella_milestones` | on | none | — |  | business_id | server functions |  |

## E. Test evidence

| Test | How | Result |
|---|---|---|
| Cross-tenant attack, round 1 | 54 cases as owner A, staff, viewer, an outsider and a visitor against business B: direct reads, row-by-id, inserts with B's id, moving rows to B, self-promotion to owner, joining B, admin functions, 30 business functions with B's ids | 52 blocked; **2 got through** (H-1) |
| Assignee / link attack, round 2 | 17 cases: every "assign to" function and direct inserts with B's customer/staff/user | **6 got through** (H-1); the others blocked |
| H-1 fix (rolled back first, then applied) | 8 attacks + 7 legitimate cases | 8/8 blocked, 7/7 allowed |
| H-2 fix | 4 forgery attempts + 5 normal paths, as an owner | 4/4 refused, call duration unchanged; normal paths work |
| **Final regression** (after all fixes) | 38 cases: 27 attacks (tenant, role, removed/suspended member, viewer, visitor, admin functions, billing, links) + 11 normal actions | **38/38 passed**; business B's data intact |
| Edge functions, live | 8 requests without sign-in, with fake tokens or with missing signatures | owner function 401/401, voice-rules 401, website-lead "unknown form", continue-plan "invalid", reschedule "invalid", staff-invite 503 (not configured), billing-webhook 503 (**Blocked**: no Stripe secret) |
| Data-connection check | Script + live database | 194/194 functions, 82/82 actions, 327/328 columns (1 table broken → M-1, fixed) |
| Dead buttons / fake data | Scan of every `<button>` and for mock/demo/random data | 0 buttons without a handler; no mock data (only random idempotency keys and greeting wording); no seed inserts in `sql/` |
| Feature SQL tests | `tests/features/run.sh` (staging copy) | 68 PASS, ALL PASSED |
| Voice reliability tests | `tests/voice-reliability/run_all.sh` (staging copy, includes the voice-rules edge function end to end) | 184 PASS, ALL PASSED |
| Admin pages in a browser | Playwright: navigation, every tab and drawer, 10 writes with reasons, validation, read-only role, server refusal, 390 px phone width | all passed, 0 page errors |
| Business app in a browser | Playwright: Today page action allowed vs refused by the database | passed (M-2 fix) |
| Lint / build | `npx oxlint src` (0 errors; existing warnings only), `npx vite build` | passed |
| Not run | Real calls, texts, emails, payments, calendar sync; n8n executions | **Blocked**: providers not configured and live switches off by design |

Production data (read-only):
- 4 businesses, all created by hand during testing: "test saloon", "hawkye cafe", "ftyuyguygiug" and "Roohani Cafe".
  The last three are unfinished setups with no members.
- 1 customer, 4 appointments, 1 test-mode text.
- 0 calls, numbers, runs, integrations or calendar connections.
- No demo data is seeded by code.

## F. Changes made

| File / migration | Why | Verified by |
|---|---|---|
| `sql/zella_tenant_links.sql` → migration `zella_tenant_links` | H-1 | rolled-back attack test, final regression |
| `sql/zella_write_lockdown.sql` → migrations `zella_write_lockdown`, `zella_ai_eval_cases_read` | H-2, M-1, L-6 | forgery test, final regression, column check |
| `web/src/BusinessShared.jsx` (`changed()`, NOT_CHANGED message) | M-2 | browser test |
| `BookingPanel.jsx`, `BusinessToday.jsx`, `BusinessKnowledge.jsx`, `BusinessProfile.jsx`, `BusinessPages.jsx`, `BusinessTeam.jsx`, `BusinessForms.jsx` | M-2: each update/delete uses `changed()`; Today shows action errors on their own | lint, build, browser |
| `docs/SCHEMA_STATUS.md` | new SQL files listed | n/a |
| Earlier in this branch (same week): `sql/zella_admin_ops.sql` and `web/src/admin/*` | Voice / Messaging / Automations admin pages | tests listed in C |

All database changes are additive (new trigger, revoked write grants, one read grant). No table was dropped or
recreated, no data was changed, and row-level security was not disabled anywhere.

## G. Remaining work and manual actions

See `docs/ZELLA_REMEDIATION_CHECKLIST.md`. Integration status, kept separate on purpose:

| Integration | Configured | Authenticated | Reachable | Tested | Live in production |
|---|---|---|---|---|---|
| Vapi (AI calls) | key presence reported by the server | not checked (provider checks off) | not checked | staging tests only | no: `calls_live` off, 0 numbers |
| Telnyx (texts) | sender number **not set** | no | no | no | no: `sms_live` off |
| Resend (email) | sender address **not set** | no | no | no | no: `email_live` off |
| n8n | address set; secret **not stored** in vault | no | no | workflows inactive | no: dispatcher job off |
| Stripe (billing) | webhook secret **not set** | no | endpoint answers "not configured" | no | no |
| Google Calendar | 0 connections | — | — | — | no |
| Scheduled jobs | 9 jobs; only `zella_usage_thresholds` on | — | — | — | partly |

## H. Production readiness

**Conditionally ready.** No critical or high issue is open: both highs were fixed in production and re-tested with
real user roles. Tenant isolation, admin separation and the app's data connections are verified.

It is not ready for real customers yet because:
- the app has no hosting or `app_base_url`, so links in messages can't open;
- no provider is connected or switched on;
- payments aren't configured;
- three medium items need a decision (M-3, M-4, M-5).

A passing build is not the reason for this rating; the tests in E are.
