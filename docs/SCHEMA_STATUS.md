# Database: what the repo can and can't rebuild

**Update 2026-11-04:** a schema-only baseline of the live project is now in `sql/baseline/`, captured read-only and
checked for secrets: 131 tables, 663 functions, 170 policies, 91 triggers, plus grants and storage policies.
`sql/baseline/restore.sh <db>` restores it into an isolated Postgres in a known order; a clean restore was verified.
`tests/security/run.sh` uses it. The sections below describe the state before the baseline.

Checked on 2026-10-26 against the 99 files in `sql/`, and against the live project (read-only) once the Supabase connector was available. The live Supabase project was not connected
during this check, so anything below marked "live only" could not be verified.

## The database can't be rebuilt from this repo yet

The `sql/` files add to a base schema that was created directly in Supabase and never saved here.
These 27 tables are used by the SQL files, the edge functions or the web app, but nothing in the
repo creates them:

`ai_agent_configs`, `ai_agents`, `appointments`, `audit_logs`, `automation_runs`, `automations`,
`business_invitations`, `business_members`, `business_modules`, `businesses`, `calls`,
`conversation_messages`, `conversations`, `customers`, `email_messages`, `industries`,
`industry_configurations`, `industry_modules`, `integrations`, `notification_preferences`,
`payments`, `plans`, `platform_admins`, `profiles`, `sms_messages`, `subscriptions`, `support_tickets`

Missing functions: `is_platform_admin()` and `is_business_member()`. `zella_brain_prompt_base`,
`zella_claim_followup_emails_base` and `zella_claim_followup_texts_base` are made by renaming
inside later files. They aren't missing, but they only exist once those files have run in order.

The row security policies on these tables are also live only. That includes `customers`,
`appointments`, `calls`, `conversations` and `business_members`, which the business app reads and
writes directly. Nothing in the repo shows whether those policies are correct.

### How to recover it (schema only, no customer data)

Run this on a computer with the Supabase CLI. It writes table, view, function and policy
definitions only, never rows:

```
npx supabase login
npx supabase db dump --project-ref pffqxlumqhjdbzvvoszm --schema public -f sql/000_base_schema.sql
```

Read the file before committing it. It should hold no data and no secrets. Then open a new
Supabase project, run `000_base_schema.sql` and the rest in order, and run the checks below before
calling the database reproducible.

### Checks to run on the live project (read-only)

```sql
-- 1. Tables with business data and no row security, open policies, anonymous access. All three should be [].
select public.zella_tenant_leak_check();

-- 2. Policies on the tables the browser writes to directly.
select tablename, policyname, cmd, roles, qual, with_check from pg_policies
 where schemaname = 'public' and tablename in ('customers', 'appointments', 'calls', 'conversations', 'business_members',
   'knowledge_items', 'blocked_times', 'staff_members') order by 1, 3;

-- 3. What signed-in users may do to calls (after the lock step, only SELECT on unprotected columns).
select privilege_type, count(*) from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'calls' and grantee = 'authenticated' group by 1;
```

Every insert from the browser into `customers`, `appointments`, `knowledge_items`, `blocked_times`
and `staff_members` sends a `business_id`. The policies must check it with a `with check` that
matches the person's active membership. Query 2 shows whether they do.

## `zella_run_all.sql`

`zella_run_all.sql` is an older bundle. Its 96 functions and 19 tables match copies in the
separate files (mostly `zella_workflows.sql` and `zella_industry_crm.sql`). Later files have since
replaced or patched four of those functions:

| Function | Changed later by |
| --- | --- |
| `zella_claim_reminders` | `zella_email_sender.sql`, `zella_followup_emails.sql`, `zella_reschedule.sql` |
| `zella_replace_reminders` | `zella_reminder_rules.sql`, `zella_reschedule.sql` |
| `zella_queue_lead_reactivation` | `zella_messaging_extras.sql` (patched in place) |
| `zella_resolve_duplicate` | `zella_customer_records.sql` (patched in place) |

**Don't re-run `zella_run_all.sql` on the live database.** It would put the old versions of these
four functions back. On a fresh database, run it first and then the later files, in the order in
the "Needs" line at the top of `sql/zella_dispatcher.sql`.

Branch note: `zella_reminder_minutes.sql` and `zella_reminder_rules.sql` are on `main` but not on
`n8n-engine`.

## New in this change (2026-10-26)

This table is a record of each file, **not an apply list**. Only some rows say whether they are applied; a row
without **applied** may still be live (for example `zella_call_usage.sql`, applied on 28 Oct 2026, see
`docs/MINUTE_USAGE_OPERATIONS.md`). Before applying any file: check production read only (the migration history and
the objects the file creates), apply only with the owner's approval, and follow the prerequisites named in each row
(for example `zella_voice_reliability.sql`, then `zella_vapi_auth.sql`, then `zella_voice_assistant.sql`, then
`zella_call_usage.sql`), not the order of the table. Never apply a row marked **applied** again.

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:c3642ed14f40289057c7eb23ec1070d7c374361069518d50e6ee860fdfd7d205 -->

| File | What it does | Changes tables? |
| --- | --- | --- |
| `zella_role_check_hardening.sql` | Anonymous requests no longer pass `zella_has_role` | No |
| `zella_call_writes.sql` | `zella_call_mark_followed_up`, `zella_call_set_escalation`. Section 2 (the lock) stays commented out | No |
| `zella_staff_invite_binding.sql` | A team invitation can only be accepted by the account it was sent to | No |
| `zella_business_settings.sql` | Business Settings: profile, hours, holidays, my profile | No |
| `zella_receptionist_editor.sql` | Managers can read the receptionist's live settings to edit them | No |
| `zella_settings_system.sql` | Settings foundations: 7 platform roles and a permission matrix, public platform info, sessions, plan entitlements (team seats and phone numbers enforced), voice pricing, usage protection and notices, legal documents, logo bucket, notification preferences, viewer role read-only, terminology, requests to Zella, fixed search_path; website forms (list, edit, allowed websites, switch off), lead rules and qualifying questions limited to owners/admins/managers, work assignment settings | Adds tables and policies; the role check on platform_admins allows 5 more roles |
| `zella_navigation.sql` | CRM navigation: `zella_workspace_navigation`, `zella_module_on`, and read rules that hide calls, transcripts, automations and switched-off record types when the module is off | Restrictive policies only; no tables or rows change |
| `zella_industry_hotels.sql` | Adds a Hotels industry built from Hospitality (words, modules, record types) if none exists | Adds rows only |
| `zella_calendar.sql` | Records who made each new booking (`appointments.metadata.source`: staff or Zella) so the calendar can mark AI bookings | One insert trigger; no existing rows or functions change |
| `zella_db_fixes.sql` | Missing foreign-key indexes, a faster `legal_acceptances_read` rule, and removes one exact duplicate read rule | Indexes and policies only; no data changes |
| `zella_messaging_status.sql` | `zella_messaging_status` (booking panel's Messages: on/off flags, members only) and `zella_automation_readiness` (Admin Settings > n8n go-live checklist, platform admins only) | Two read-only functions |
| `zella_no_show_rebook.sql` | No-show follow-up texts and emails carry a private 14-day link to pick a new time; the reschedule page accepts it for a missed visit | Two columns on `appointment_reschedule_links`, one new function, three replaced (`zella_reschedule_lookup`, `zella_claim_followup_texts`, `zella_claim_followup_emails`, built from the live bodies), two starter templates updated |
| `zella_onboarding.sql` | Verification documents (`business_verification_documents`, private bucket `business-documents`); bookings follow the business's opening hours when no team hours exist; whole-hour slot steps no longer fail | One table, one bucket, one function replaced (built from its live body) |
| `zella_spam_protection.sql` | Spam protection: per-business settings, block/allow lists and platform block rules, incidents with history, risk scoring, call screening at call start (plus no transfer/callback for screened callers in `zella_ai_voice`, patched from its live body), booking holds, SMS/email checks, review RPCs for the CRM, the Spam Response workflow queue (claim / finish / weekly report, fallback alerts), hourly reminders and retention (cron job created switched off) | Four new tables (read-only to owners/admins/managers, no browser writes); triggers on `calls`, `sms_messages`, `email_messages`, `appointments`, `followups`; `zella_caller_context` replaced (live body kept as `zella_caller_context_base`); one `platform_settings` row. Every hook falls back to allowing the record if detection fails |
| `zella_call_usage.sql` | AI calling usage ledger on `usage_records` (one usage row per call, auditable adjustments, configurable rounding), processing issues, threshold events, reconciliation every 15 minutes, plan-agnostic entitlement interface (not enforced), admin view and retry. Run after `zella_voice_assistant.sql`, then re-run `zella_dispatcher.sql`; `zella_call_usage_status()` | Adds columns and indexes to `usage_records`; 3 new tables; one trigger on `calls`; `zella_usage_counts` patched, `zella_check_usage_thresholds` replaced (same job). No data changes; no plans or allowances |
| `zella_voice_assistant.sql` | Voice receptionist phase 4: missed calls decided only after the end-of-call report, transfer callbacks closed or replaced, unanswered questions counted once per call with an owner notice, prompt rules, a Vapi-ready `zella_assistant_config` (`{ assistant, ready_to_send, problems }`), consent on automatic callbacks. Run after `zella_vapi_auth.sql`; `zella_voice_assistant_status()` shows what is in place | 5 live functions patched at exact anchors, `zella_assistant_config` replaced, one status function, two platform settings. No data changes |
| `zella_vapi_auth.sql` | Vapi request authentication: `zella_vapi_authenticate` checks the HMAC signature (or bearer token) against a Vault secret, a 5-minute window and a replay cache, for the `voice-rules` edge function and the n8n Vapi webhooks. Run after `zella_voice_reliability.sql` | One new table (`vapi_request_receipts`, service role only), one function. Refuses every Vapi request until `zella_vapi_hmac_secret` is in Vault. No data changes |
| `zella_voice_reliability.sql` | Booking concurrency (per-business lock before every availability check; in-flight duplicate tool requests wait), one call row per provider call id, provider status updates, reconciliation of calls whose report was lost, server-side transfer destinations. Run AFTER the source files it patches (see the file header); `zella_voice_reliability_status()` shows what is in place | One unique index on `calls` (refuses to run if duplicates exist); 6 live functions patched at exact anchors (fails if an anchor changed); new functions; one platform setting. No data changes |
| `zella_admin_ops.sql` | Admin Voice & numbers, Messaging and Automations pages: permission-checked `zella_admin_*` functions (overviews, paged lists, details, number release, call routing, message retry, template versions, automation pause/resume, run retry/review, scheduler health), each change audited | Functions only (no new tables); applied as migrations `zella_admin_ops_1_voice` to `_4_options` |
| `zella_tenant_links.sql` | Audit finding H-1: a guard trigger (`zz_tenant_links`) on 28 tables refuses a row whose `customer_id`, `staff_id` or assignee (`assigned_to`, `to_user`, `from_user`) belongs to another business | Triggers only; existing rows were checked first (none broke the rule); applied as `zella_tenant_links` |
| `zella_write_lockdown.sql` | Audit findings H-2 and M-1: signed-in users can no longer write `calls`, `sms_messages`, `email_messages`, `conversations`, `conversation_messages`, `notifications`, `support_tickets`, `integrations`, `automations` directly (the app uses checked functions; providers and n8n use the server key); `ai_eval_cases` readable again (owners/admins by policy); `zella_usage_billable_seconds` search path pinned | Grants only; applied as `zella_write_lockdown` and `zella_ai_eval_cases_read` |
| `zella_vapi_voices.sql` | Receptionist voice options: Vapi's own voices (provider `vapi`, Version 2) as well as ElevenLabs, and an optional ElevenLabs voice model (`voice_tts_model`) | Patches `zella_assistant_config`; applied as `zella_vapi_voices` and `zella_voice_tts_model` (voice `burt`, model `eleven_v4_turbo`) |
| `zella_business_voice.sql` | A voice per business: approved list (`voice_tts_choices`, Vapi's built-in ElevenLabs voices), `business_voice` table, `zella_business_voice_get` / `_save` (owners, admins, managers, or a Zella admin with `ai.configure`; audited); the assistant uses the business's voice, else the default | New table (no browser access) and functions; patches `zella_assistant_config`; applied as `zella_business_voice` |
| `zella_platform_emails.sql` | The platform outbox for every email Zella Voice sends to a business (`docs/BUSINESS_EMAILS.md`): `platform_emails` (one row per business and dedupe key; each claim gets a token that must match to finish), `zella_queue_platform_email`, `zella_claim_platform_emails` (test mode while `email_live` is off; held after 5 tries with an admin alert), `zella_finish_platform_email` (server only) and `zella_admin_platform_emails` (`businesses.view`). Owners and admins read their own business's rows | One new table with row security, four functions; no existing table or data changes; **applied to production on 15 Nov 2026** (owner's approval; checked after applying: function fingerprints match the tested copy); the rollback refuses while the outbox holds any row (nothing is deleted); rollback `sql/rollback/zella_platform_emails_rollback.sql`; tests `tests/platform_emails/run.sh` |
| `zella_usage_enforcement.sql` | Usage limits that act (REQ-BIL-22, D-43), behind `platform_settings.usage_enforcement` = {calls: false, messages: false}: `zella_call_gate` (forward a new call to the business's fallback number, `escalation_rules.fallback_number` from Create Business, never `businesses.phone`, at 100% or when the business is inactive; pay as you go with a rate keeps answering; no valid number keeps answering) and `zella_message_gate` (routine messages stop at 100%, appointment messages use the 5% reserve), wired into `zella_assistant_for_call`, `zella_prepare_sms` and `zella_prepare_email` by guarded patches; `assistant_deliveries` gains the outcome `forwarded_usage`. Needs `zella_billing_allowances.sql` | Three function patches, three new functions (server only), one setting, one widened check; **applied to production on 15 Nov 2026** (owner's approval; checked after applying: function fingerprints match the tested copy); turning each switch on is a separate live change; `platform_settings.usage_enforcement` read after applying: calls false, messages false; rollback `sql/rollback/zella_usage_enforcement_rollback.sql` restores the functions exactly; tests `tests/usage_enforcement/run.sh` |
| `zella_business_moments.sql` | Three business moments for the notification bell, run hourly after `zella_check_milestones`: a record day (`best_day`: yesterday's AI bookings, at least 10, beat every day of the 90 before), a call surge (`call_surge`: after 11:00, at least 20 inbound calls and 2.5 times the 28 day average) and an on call gap (`on_call_gap`: on Thursday or Friday from 9:00, on call is switched on but nobody covers part or all of the coming weekend). Each at most once per business per day or weekend (`zella_milestone_once`), live businesses only, one business never stops the others | One function (server only) and one entry in `zella_run_schedule_group('hourly')` (guarded patch); no tables or data change; **applied to production on 15 Nov 2026** (owner's approval; checked after applying: function fingerprints match the tested copy; it runs only when the timed job `zella_jobs_hourly` is switched on, which it is not yet); rollback `sql/rollback/zella_business_moments_rollback.sql`; tests `tests/business_moments/run.sh` |
| `zella_writing_cleanup.sql` | No dashes, part 2 (the owner's writing rule, `docs/DESIGN_SYSTEM.md` Writing): plain wording in 33 phrases across 22 functions people read (follow up, no show, opt out, after hours and so on), each replaced only when the exact phrase is there; stored names, descriptions and message text in industries, modules, automations and presets cleaned by `zella_plain_words` / `zella_plain_json` (E-commerce becomes Ecommerce); values that code matches on (services, options, statuses) are left alone | One new table `zella_text_archive` (every changed value, for the exact rollback); text in existing rows changes, no structure; **applied 15 Nov 2026** (the 24 changed functions match the tested copy by fingerprint; 289 values archived; no automation or industry name keeps a hyphen); rollback `sql/rollback/zella_writing_cleanup_rollback.sql`; tests `tests/writing_cleanup/run.sh` |
| `zella_email_delivery.sql` | Notification emails through the platform outbox: `zella_claim_notification_emails` (the old owner email rules), `zella_dispatch_platform_emails` (woken at once by `zella_kick_platform_emails` on new notifications and outbox emails, with a minute job as safety net; both created switched off; only when set up and there is work), `zella_platform_emails_check` (the Vault secret); retires the n8n Owner Emails path (`zella_claim_owner_emails` returns nothing, archived for the rollback; the n8n dispatcher stops counting it); adds `platform_emails_url` (empty) and the Vault secret `zella_platform_emails_secret` (the rollback removes them only if this file made them); `zella_claim_platform_emails` now cancels an email for someone no longer an active member (known version only, archived) | Three functions, one function body replaced, one dispatcher line patched, one cron job, one setting, one Vault secret, two event triggers; **applied 15 Nov 2026** (the 7 functions match the rehearsal on a copy matched to production; the job and both triggers off, `platform_emails_url` empty, `email_live` false, so nothing is called or sent); rollback `sql/rollback/zella_email_delivery_rollback.sql` restores all three functions exactly and refuses while notification emails are waiting; tests `tests/email_delivery/run.sh` |
| `zella_support_notes.sql` | Internal support notes stay with Zella Voice (`docs/ADMIN_AUDIT_2026-11-16.md` OPS-06, OPS-26): admins' notes moved from `support_tickets.metadata` (readable by the business's members) to the server only table `support_ticket_notes`; a guard moves any notes written into metadata later (an older admin function, a new ticket) | One new table (row security on, no policies, server only), two helpers, two triggers; **built, not applied** (needs the owner's approval; production had no tickets on 16 Nov 2026); malformed or missing legacy note timestamps fall back to now(), and the admin reader pages all notes ordered by created_at and id; either deploy order is safe; rollback `sql/rollback/zella_support_notes_rollback.sql` puts every note back into metadata, oldest first; tests `tests/support_notes/run.sh` |
| `zella_rebrand_voice.sql` | Brand renamed from "Zella AI" to "Zella Voice" in the default receptionist created for new businesses (`create_zella_ai_agent`, `create_business`) | Function bodies only; applied as `zella_rebrand_voice` |
| `zella_brand_name.sql` | The brand is named in full ("Zella Voice") in 17 strings across 16 functions: owner and admin email sender name, welcome, setup, trial and payment messages, daily and weekly email subjects, staff text prefix, calendar event note, public status, spam notes, security log. Version-guarded; adds `zella_brand_name_pairs()` (server only) used by the rollback | Function bodies only; applied 9 Nov 2026 as `zella_brand_name`; rollback `sql/rollback/zella_brand_name_rollback.sql` |
| `zella_billing_allowances.sql` | Billing step 2: each business's own versioned plan (`business_plans`), monthly balances (`allowance_buckets`), usage counted once per key, thresholds and alerts, packs granted by admins only, auto reload stored and inactive (`docs/PAYMENTS_ARCHITECTURE.md`) | New tables, functions and policies; **applied to production on 14 Nov 2026** (owner's approval; checked after applying by read only fingerprints; production keeps its earlier, stricter role check in `zella_language_allowance`); tests `tests/billing/` |
| `zella_tenant_business_id.sql` | `business_id` on the six business-owned tables that reached their business only through a parent (TEN-1, gap G-8): `ai_agent_configs`, `conversation_messages`, `business_report_runs`, `integration_secrets`, `on_call_reminders_sent`, `industry_automation_runs`. Filled from the parent, required, foreign key and index; a trigger keeps it equal to the parent's and refuses another business; a parent trigger carries a move. Expand step only: policies unchanged | Columns, constraints, indexes, triggers; **applied to production on 14 Nov 2026** (owner's approval; checked after applying); stops on orphan rows instead of deleting them; locks the six parent tables (SHARE) while it runs, and each new child row locks its parent row so a concurrent move cannot leave a stale copy; the rollback stops if a row has lost its parent; rollback `sql/rollback/zella_tenant_business_id_rollback.sql`; tests `tests/tenant_business_id/run.sh` |
| `zella_unsubscribe_limit.sql` | A rate limit on the public unsubscribe link (SEC-6, gap G-7): `zella_unsubscribe_lookup` 30 and `zella_unsubscribe_email` 10 calls per link per 10 minutes. An unknown link is answered before counting. Opt-out always wins (NN-8): an opt-out is recorded whatever the count unless the person's latest choice is already opted out | Function bodies, and `zella_unsubscribe_lookup` becomes `volatile` (it now writes a rate-limit count): callers must use POST, as `supabase.rpc` in `Unsubscribe.jsx` does; a GET runs read-only and fails; **applied to production on 14 Nov 2026** (owner's approval; checked after applying); rollback `sql/rollback/zella_unsubscribe_limit_rollback.sql`; tests `tests/unsubscribe_limit/run.sh` |
| `zella_fk_indexes.sql` | An index for each of the 38 foreign keys that had none (DB-15, gap G-2), created only where no usable index (valid; not partial, or partial only on `<key> IS NOT NULL`) already starts with the key's columns, and marked by a comment so the rollback drops only what it created; 12 other foreign keys whose only index is limited to a status (e.g. `crm_records(business_id)` `WHERE archived_at IS NULL`) are a recorded follow-up, listed in `tests/fk_indexes/run.sh`; adds `zella_fk_index_list()` (server only) used by the rollback | Indexes only, no data or permission change; **applied to production on 14 Nov 2026** (owner's approval; checked after applying); plain `create index`, fine while the tables are this small); rollback `sql/rollback/zella_fk_indexes_rollback.sql`; tests `tests/fk_indexes/run.sh` |
| `zella_model_defaults.sql` | No AI model name as a fallback in database functions (REL-11, gap G-4): `zella_assistant_config`, `zella_claim_call_insights`, `zella_claim_gap_drafts`, `zella_review_claim_ai`, `zella_spam_claim_work` read the model only from `platform_settings`; a missing setting stops the assistant with a problem or claims no AI work. Version-guarded; adds `zella_function_archive` (server only) holding the original definitions for the rollback | Function bodies plus one server-only table; **applied to production on 14 Nov 2026** (owner's approval; checked after applying); rollback `sql/rollback/zella_model_defaults_rollback.sql`; tests `tests/model_defaults/run.sh` |


<!-- /coderabbit-ai-generated:v1 -->

Each file lists its dependencies, what it means for access, how to undo it, and a rolled-back
check. All six were run against a local PostgreSQL 16 with stand-ins for the Supabase roles and
`auth.uid()`. The checks there: the right member is allowed; another business's owner, staff below
the required role, and anonymous callers are refused; bad input is rejected; a second run changes
nothing.


## Live project findings (2026-10-26, read-only)

- On 26 Oct 2026 none of the six files listed then were applied yet (only the older `zella_accept_staff_invitations` was live). Several are live now; see the table above and check production before relying on this line.
- `zella_tenant_leak_check()` is clean: no business table without row security, no open policies, no anonymous reads.
- Every insert and update policy on customers, appointments, calls, conversations, support tickets, knowledge items,
  blocked times and staff members checks the person's own business. Gap fixed in `zella_settings_system.sql`:
  members with the **viewer** role could still write (the policies only checked membership).
- Security advisor: 7 functions without a fixed search_path (fixed in `zella_settings_system.sql`); leaked-password
  protection is off (Supabase dashboard > Authentication); 174 "definer function callable by signed-in users" notices
  are the app's role-checked functions and expected.
- Edge functions: `reschedule-appointment` is **not deployed**, so reschedule and waitlist links in texts don't work yet.
  Two leftover functions, `smart-action` ("zella-admin-check") and `zella-admin-check-v2`, only report whether the
  caller is an admin, are not in the repo and nothing calls them; delete them in the Supabase dashboard.
- `platform_admins` allowed only `zella_owner` and `super_admin`; `is_platform_admin()` still means those two only.
  Restricted roles get no direct database access; they act only through the admin function, one permission at a time.
- No plans, subscriptions, payments, usage records or calls exist yet, so billing and usage pages correctly show zero.
- No storage bucket existed; `brand-assets` is created by the migration.

## Settings system checks (run after applying, read-only)

```sql
select public.zella_rls_coverage();                    -- tables with and without row security
select role, count(*) from public.platform_role_permissions group by 1;
select id, public, file_size_limit from storage.buckets where id = 'brand-assets';
select jobname, schedule from cron.job where jobname = 'zella_usage_thresholds';
select tablename, policyname from pg_policies where policyname like 'zella_viewer_no_%' order by 1;
select tablename, policyname from pg_policies where policyname like 'zella_leads_managers_%' order by 1;  -- 6 rows
select tgname from pg_trigger where tgname = 'zella_lead_rule_check_trg';
-- Lead rules per business (to see who uses them before staff lose write access).
select business_id, count(*) from public.lead_rules group by 1;
```

Before applying section 17, check that no staff member's work depends on editing lead rules or qualifying
questions: from then on only owners, admins and managers can change them (everyone can still read them). The
website-crawler pages in Settings (AI receptionist > Website knowledge sources) need `zella_website_crawler.sql`
applied, and pages are only read once `website_crawl_live` is switched on.
