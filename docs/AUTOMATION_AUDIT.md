# Zella automation engine: Phase 1 audit and gap analysis

Audited against the live project (`pffqxlumqhjdbzvvoszm`) and the repo on `main`. Nothing here has been run against real providers. No workflow below is marked "tested".

## 1. What actually exists

**Stack:** React/Vite front end (`web/`), Supabase (Postgres 17, RLS, 4 edge functions), n8n (not yet built), Telnyx and Vapi (not yet connected). Edge functions: `owner-provision-business`, `continue-plan`, `zella-admin-check`, `zella-admin-check-v2`. There is no `supabase/migrations` folder; SQL lives in `sql/` and is pasted by hand.

**Database:** 141 `zella_*` functions. 19 industries, each with 10 modules, terminology and a CRM preset. 0 businesses, 0 automations, 0 runs, 0 integrations, so nothing has run end to end.

**The queue-and-claim engine is already built in Postgres** (see `docs/N8N_Workflows.md`):

| Area | Already in the database |
|---|---|
| Queue workers (service role only) | `zella_claim_callbacks`, `_reminders`, `_followup_tasks`, `_notifications`, `_knowledge_updates`, `_agent_syncs`, `_platform_alerts`, `_gaps_for_suggestion`, each with a matching complete/fail function |
| Schedulers | `zella_calls_to_callbacks`, `_flag_overdue_leads`, `_queue_quote_followups`, `_queue_lead_reactivation`, `_queue_no_show_followup`, `_expire_holds`, `_expire_waitlist_offers`, `_detect_transfer_failures`, `_check_invitations`, `_check_trials`, `_apply_payment_policy`, `_retention_due`, `_post_weekly_reviews` |
| AI tools | `zella_available_slots`, `_book_appointment`, `_request_appointment`, `_hold_slot`, `_reschedule_appointment`, `_capture_lead`, `_create_callback`, `_log_knowledge_gap`, `_match_customer`, `_ai_save_record` |
| Safety | calling hours 9am to 7pm local, attempt caps, stop on do-not-contact, reminders replaced on reschedule, automations paused until live |
| Health and alerts | `zella_report_service_health`, `zella_platform_alert` (deduped), `zella_activation_report` |

All claim and scheduler functions are executable by `service_role` only. Verified.

The scheduler is **not** `pg_cron` (extension not installed). The design is n8n polling every 1 to 5 minutes. That is fine, but it means n8n downtime pauses all automation, so a "last heartbeat" check is needed.

## 2. The "preview" UUID error: root cause

`BusinessApp.jsx` defines a dev-only preview workspace with `id: "preview"`. Every query that filters `business_id = id` then fails with `invalid input syntax for type uuid: "preview"`. It only happens under `npm run dev` at `/app/preview`, not in production builds. **Fixed** in this change: the preview id is now an all-zero UUID that matches no business, so queries return empty results and RLS stays untouched. `ContinuePlan.jsx` also sends the word "preview" but as an action name, which is correct.

## 3. Gaps (versus the master prompt)

| Gap | Why it matters | Needs |
|---|---|---|
| **No event gateway or event inbox** | Webhooks (Telnyx, Vapi, Meta, website) have nowhere durable to land. No dedupe by provider event ID, no replay protection, no correlation IDs | `automation_events` table, signature check per provider, idempotency key |
| **No consent ledger or inbound STOP handling** | Only `do_not_contact/call/sms/email` flags exist. No record of when, how or why consent was given or revoked. Nothing processes inbound STOP or HELP | `contact_consents` table, inbound SMS handler |
| **No message templates** | Wording is not versioned or editable per business or industry | `message_templates` (business, industry, key, channel, version) |
| **Delivery tracking is thin** | `sms_messages` and `email_messages` have status and `delivered_at`, but no provider error codes, bounces or complaints | extra columns or a `message_delivery_events` table |
| **No dead-letter or unified job view** | Failed claims are retried by timeout. There is no manual recovery queue across reminders, callbacks and follow-ups | `automation_dead_letters` plus a view |
| **No execution log for n8n workflows** | `automation_runs` only covers business automations. Platform workflows (gateway, schedulers) leave no trace | `workflow_executions` table |
| **No industry automation defaults** | New businesses start with no automations. "Start here" is hardcoded for clinics | `industry_automation_defaults` |
| **No website intake, Meta, WhatsApp or crawler** | Modules 8 to 10 do not exist at all | adapters, SSRF-safe fetcher, approval queue (knowledge approval already exists) |
| **No n8n workflow exports** | Only documentation exists in `docs/` | importable workflows built against the installed n8n version |
| **No automated tests** | Nothing is verified | pgTAP for RLS and functions, plus mock-provider end-to-end tests |
| **Browser writes bypass audit** | Today-page check-in buttons, profile saves and call follow-up flags write directly | route through logged functions |

## 4. Catalogue map (status of each module today)

Status key: **DB** = rules already in Postgres, **n8n** = workflow not built, **New** = nothing exists.

| Module | Status |
|---|---|
| 1 Inbound call automation | Tools (DB) exist. Vapi/Telnyx wiring, event gateway and emergency rules per industry: New |
| 2 Missed call and callback engine | DB complete (claim, attempts, caps, DNC stop, hours). n8n worker not built |
| 3 Appointment lifecycle | Booking, hold, reschedule, cancel, attendance, reminders: DB. Email/SMS senders, calendar sync, post-visit flows: n8n not built |
| 4 Email automation | Table exists. Provider adapter, bounces, unsubscribe, templates: New |
| 5 SMS and messaging | Table exists. Telnyx adapter, STOP/HELP, delivery receipts, consent ledger: New |
| 6 Lead and sales | Stages, assignment, overdue, quote and reactivation follow-ups: DB. Round-robin, sequences: partial |
| 7 Customer lifecycle | Matching and duplicate review: DB. Inactivity, data-rights routing: New |
| 8 Website lead intake | New |
| 9 Meta (Lead Ads, IG, Messenger, WhatsApp) | New, and blocked on Meta app review |
| 10 Website knowledge sync | Approval and publish flow exists (`knowledge_items`). Crawler, change detection: New |
| 11 Knowledge gap and AI quality | Gap logging and draft suggestion: DB. Quality sampling, rollback: partial |
| 12 Staff operations | Invites, roster, deactivation: DB. Workload-aware assignment: New |
| 13 Industry packs | Terminology, modules, CRM presets done for all 19. Automation defaults and templates: New |

## 5. Proposed next unit of work (Phase 2 foundation)

One migration, `sql/zella_automation_foundation.sql`, adding only what is missing: `automation_events`, `workflow_executions`, `automation_dead_letters`, `contact_consents`, `message_templates`, `industry_automation_defaults`, plus RLS (members read their own business, writes by service role or logged functions) and the functions n8n will call (`zella_ingest_event`, `zella_record_execution`, `zella_dead_letter`, `zella_record_consent`, `zella_apply_industry_defaults`). It reuses every existing queue instead of replacing it.

External decisions that block go-live (not the build): Telnyx number and 10DLC registration, Vapi account, an email sender and domain, Meta app review, n8n hosting and version.
