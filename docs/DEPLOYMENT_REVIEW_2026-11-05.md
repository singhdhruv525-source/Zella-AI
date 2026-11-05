# Deployment review (5 Nov 2026)

**Commit reviewed:** the commit that adds this file on `main` (see the end of this file). It replaces the earlier
review point `bd17aec`; everything from `bd17aec` is included.

**Nothing has been deployed, applied or switched on.**
- No production migration has been run and no function deployed.
- No n8n workflow imported, no Vapi assistant changed.
- Texting, email, calls, calendar sync and schedulers are as they were.

Production reads for this review were read-only: the function list and the deployed voice-rules source.

Production today (read 5 Nov):
- Postgres 17; 4 businesses (salon in testing, two restaurants, dental).
- None of the 17 migrations below.
- Edge functions deployed: owner-provision-business v13, continue-plan v5, website-lead v4, billing-webhook v5, reschedule-appointment v3, staff-invite v3, voice-rules v4.
- Two legacy admin-check functions (`smart-action`, `zella-admin-check-v2`) that are not in the repository. They are untouched; your decision whether to keep them.

## 1. What would be deployed

### 1.1 Database migrations, in order

Classes:
- **A**: backward-compatible infrastructure. New tables, functions and checks; nothing anyone sees changes until it's used.
- **P**: permissions or what the app shows change for existing users.
- **V**: live call behaviour changes (the AI receptionist).
- **M**: customer messaging changes. Only matters once texting or email is live, and both are off.

| # | File | Depends on | Class | What changes, the moment it's applied | Data written by the migration itself |
|---|---|---|---|---|---|
| 1 | `zella_viewer_read_only.sql` | — | P | View-only members can no longer change anything (35 functions now need staff or above) | none |
| 2 | `zella_staff_add_lead.sql` | 1 | A | Staff can add leads through the lead pipeline | none |
| 3 | `zella_call_content_privacy.sql` | — | P | Transcripts and recordings are no longer readable by every member; `calls_view` shows them to owners, admins and managers, and to staff only if the owner allows (never in health, legal, financial, insurance, vet or childcare) | none |
| 4 | `zella_capabilities.sql` | 1 | P | The menu, Today and booking follow each business's capabilities. New bookings, check-ins and waitlist are refused where switched off (e-commerce: earlier bookings kept) | capability defaults on 28 industry configurations |
| 5 | `zella_record_links_secrets.sql` | 4 | P | Private fields (access codes, member IDs) move to `crm_record_secrets`, shown only to managers and assigned staff; record links; class capacity | **moves existing private values out of record data** (production: none today) |
| 6 | `zella_money.sql` | 1, 4 | A | Charges and payments tables and functions; nothing charged | none |
| 7 | `zella_presets_v2.sql` | 4, 5 | P | Industry presets for 28 industries; existing businesses get new record types switched off; 11 title labels renamed | **presets rewritten; record types added to every business** (backups required first, §3) |
| 8 | `zella_automation_presets_v2.sql` | 7 | A | 15 starter automations (team tasks only) available to install | preset rows |
| 9 | `zella_receptionist_industry_rules.sql` | 4, 7 | **V** | **Every AI receptionist's instructions change from its next call** (industry safety lines; "no appointments" where scheduling is off) | none |
| 10 | `zella_readiness.sql` | 4 | A | One read-only function | none |
| 11 | `zella_appointment_records.sql` | 1 | A/P | Bookings can be linked to the pet, vehicle or property they're for. Zella only suggests, never chooses. "Which pet?" on Today | `appointment_link` set on matching record types and presets |
| 12 | `zella_record_files.sql` | 1, 3, 5 | A | Private `record-files` bucket and policies. Uploads stay "checking" until the `record-files` function passes them | bucket row |
| 13 | `zella_ai_caller_fixes.sql` | 4 | **V** | **From the next call, the AI:**<br>• saves text / call / email preferences;<br>• links the live call to the caller;<br>• links callbacks to new leads;<br>• **no longer offers or books times where bookings are off** (e-commerce). | none |
| 14 | `zella_message_courtesy.sql` | 1 | **M** | Per-industry message policy (`docs/MESSAGING_POLICY_2026-11-05.md`). Messages held back are stored as skipped with the reason. Cancelled or moved bookings withdraw their own pending follow-ups | `industry_message_policy` defaults (28 rows) |
| 15 | `zella_google_leads.sql` | 1 | A | Google Ads lead intake (needs the `google-lead` function) | none |
| 16 | `zella_calendar_providers.sql` | calendar sync | A | Owners and admins can connect Google or Outlook (needs `calendar-connect`). Claims name the provider | none |
| 17 | `zella_store_orders.sql` | 4, brain | A/**V** | Shopify connection (needs `store-connect`). **The AI gets a `lookup_order` tool, offered only where Orders is on and answered by voice-rules** | none |

All 17 are safe to run twice. Each patch of an existing function checks the function is still the version it was written
against, and stops with "has changed; review this patch" otherwise.

### 1.2 Edge functions

| Function | State | Needs | Notes |
|---|---|---|---|
| `google-lead` | new | migration 15 | public (`verify_jwt = false`); the Google key in the lead is the proof |
| `record-files` | new | migration 12 | `verify_jwt = false`; checks the member's sign-in through the database; cleanup is server-key only and **not scheduled** |
| `calendar-connect` | new | migration 16; secrets `GOOGLE_CALENDAR_CLIENT_ID/SECRET`, `MICROSOFT_CALENDAR_CLIENT_ID/SECRET`, `ZELLA_LINK_SECRET` (already set), `ZELLA_APP_URL`; redirect URI `https://pffqxlumqhjdbzvvoszm.supabase.co/functions/v1/calendar-connect` registered with Google and Microsoft | `verify_jwt = false` (the provider redirect has no Supabase sign-in); signed 10-minute state |
| `store-connect` | new | migration 17 | `verify_jwt = false`; only `*.myshopify.com` hosts |
| `voice-rules` | **changed** (v4 → new) | migration 17 | adds `lookup_order`; everything else is identical to the deployed v4 (compared with the production source) |
| `_shared/vapi-brain-tools.js` | changed | — | `lookup_order` added to the known tools (used by voice-rules and n8n Brain Tools) |
| other 6 | unchanged code | — | `deno.json` gained `"nodeModulesDir": "none"` (type checking only). Redeploying them isn't needed |

Deploy with a **current Supabase CLI**: five functions carry `deno.lock` version 5, which the older edge runtime v1.69.6
can't read (verified, §4).

### 1.3 n8n workflows (files only; not imported)

| Workflow | Change |
|---|---|
| Calendar Sync | Outlook through Microsoft Graph, alongside Google. New placeholder boxes `PASTE_MICROSOFT_CLIENT_ID/SECRET` |
| Receptionist Brain Tools, Appointment Booking | rebuilt because the shared tool file they inline changed (`lookup_order` known; answered "take a message" by the database on this path) |

### 1.4 Web app

| Area | Change |
|---|---|
| Records | "For" picker and suggestion; photos and files |
| Today | "Which pet?" |
| Settings > Calendar connections | Connect Google / Outlook, Disconnect |
| Integrations | Shopify store and Google Ads lead cards |

The new screens only work once their migrations and functions exist. Before that, they hide themselves or show "can't be
connected yet". **Deploy the web app after the database and functions.**

## 2. What changes immediately on deployment

**Infrastructure only (no visible change until used):** migrations 2, 6, 8, 10, 12, 15, 16, the infrastructure part of
17, and the four new functions.

**Visible to the team at once:**
- View-only members can't write (1).
- Transcripts are hidden from staff (3).
- Menus and Today follow capabilities (4).
- Private fields hidden from unassigned staff (5).
- New preset record types appear switched off in Customize records (7).
- Booking "For" suggestions (11).

**Live calls, from the next call:**
- New receptionist instructions (9).
- Preference saving, the live-call link, and no booking offers where bookings are off (13).
- `lookup_order` offered to e-commerce businesses with Orders on (17). Production has no e-commerce business today.

**Customer messages:** none, while `sms_live` and `email_live` are off. Policy decisions are recorded on queued tasks as
"skipped" with the reason, so the team can see them.

**Not switched on by deployment** (each needs your separate approval):
- `sms_live`, `email_live`, `calendar_sync_live`;
- the `record-files` cleanup schedule;
- importing the n8n workflows;
- updating Vapi assistants;
- Google, Microsoft and Shopify credentials.

## 3. Order of deployment and checks

1. **Backups** (required; the rollback refuses to run without them):
   ```sql
   create table public.backup_20261104_presets as select * from public.industry_crm_presets;
   create table public.backup_20261104_types as select * from public.crm_record_types;
   create table public.backup_20261104_records as select id, business_id, type_key, data from public.crm_records;
   ```
2. Migrations 1–17 in the order above. After each:
   - check it reported no error;
   - run the advisors (security and performance) at the end.
3. Functions:
   - deploy `google-lead`, `record-files`, `calendar-connect`, `store-connect` and `voice-rules`;
   - set the secrets in §1.2 when you have the Google and Microsoft apps. Until then `calendar-connect` answers "provider not configured".
4. Web app.
5. n8n imports only after the matching approvals (sending, calendar sync).

**Verification (read-only, no customer content):**
- `select count(*) from industry_message_policy` = 28.
- `select zella_capabilities(id) -> 'orders' ->> 'state' from businesses` returns "unsupported" for non-e-commerce businesses.
- `select (zella_brain_context(id) -> 'tools') ? 'lookup_order' from businesses` is false for all 4 current businesses.
- `calls` column grants: `transcript` and `recording_url` are not selectable by `authenticated`.
- `select count(*) from crm_records where data ?| array[<private field keys>]` = 0.
- Edge function list shows the 4 new functions ACTIVE with `verify_jwt` false.
- One synthetic call to each public function's refusal path (`google-lead` with a wrong key → 401; `record-files` without sign-in → 401).
- A test call to the salon's assistant from the owner's phone (Vapi dashboard "Talk") to hear the new instructions. Only with your go-ahead.

**Monitoring for the first week:**
- Edge function logs: 4xx/5xx rates for the five functions.
- voice-rules `server-timing` (tool latency).
- `ai_tool_calls` by `result_status`: watch for new `not_available`, `unverified` and `store_unauthorized`.
- `followup_tasks` with `outcome = 'policy'`: what the policy held back.
- `calendar_connections.last_error` and `integrations.last_error`.
- Platform alerts.
- Supabase advisors.

## 4. Staging coverage, precisely

**Environment**
- Isolated local PostgreSQL **16.15**. Production is PostgreSQL **17**; no 17-only feature is used.
- Extensions present: pgcrypto 1.3, plpgsql, uuid-ossp 1.1.
- Supabase-specific schemas are **stubs**:
  - `auth.users` and `auth.uid()` from the request's JWT claims;
  - `storage.objects` / `storage.buckets` tables with the real policies;
  - `vault.secrets` as a plain table, with `create_secret` / `update_secret` and a `decrypted_secrets` view;
  - `net` and `cron` stubs that do nothing.
- Not reproduced: pg_cron scheduling, pg_net HTTP calls, realtime triggers, Supabase Vault encryption, PostgREST itself.
  A local stand-in maps REST/RPC calls to SQL run as the caller's role with their claims.
- Schema is the production schema dumped read-only (`sql/baseline`), checked against production on 5 Nov: tables, columns, policies, the patched functions' checksums, reference-data hashes.
- Data is synthetic only:
  - 28 industry businesses with every role and every preset record type filled;
  - 4 businesses shaped like production (counts and statuses only).
- Runtimes: Node 22.23.4, Deno 2.5.6, Playwright 1.63.0 with Chromium, Supabase edge runtime images v1.78.0 (current) and v1.69.6.

**Exercised for real:**
- Row-level security and grants: as `authenticated` with each role's claims, and as `service_role`.
- SECURITY DEFINER functions, triggers, deferred constraint triggers.
- The storage policies on `storage.objects`.
- The exact Code-node JavaScript n8n runs (sending pipeline, calendar, brain tools).
- Every edge function inside **Supabase's edge runtime v1.78.0**: per-function isolates with memory and CPU limits, real `jsr:` / `npm:` imports.
- The app in Chromium against the stand-in.

**Simulated:**
- **Auth:** HS256 JWTs signed with a local secret, and a minimal auth API (user, invite, sign-in).
- **Storage HTTP:** upload, download, signed links. Policy decisions run as the caller in Postgres, and signed-link expiry is implemented in the stand-in, not by Supabase Storage.
- **Providers:** Telnyx (SMS), Vapi (voice), Google, Microsoft, Shopify, Stripe. Their answers are stand-ins in tests. Requests to them are only checked for shape; **no request went to any provider**.
- **Cron:** the scheduled functions are called directly by the tests.
- **The Supabase gateway:** `verify_jwt`, request size limits and routing are not reproduced.

**Commands and results (5 Nov, on the commit reviewed):**

| Command | Result |
|---|---|
| `REF=<fixtures> tests/staging/run.sh` | 31 checks passed: build, backups, 17 migrations, second run unchanged, nothing lost, roles, rollback exact, rollback after use, rollback refused without backups, re-deploy |
| `tests/security/run.sh` | all files passed, each after the migrations ran twice |
| `node tests/workflows/industry_matrix.mjs` | 1,383 checks, all passed (28 industries × intake, scheduling, records, private values, Today, money, messages, recovery) |
| `node tests/workflows/salon_launch.mjs` | all passed |
| `node n8n/test.mjs` | 396 passed |
| `web/supabase/functions/check.sh` | 11 functions type-check (0 errors) |
| Deno unit tests | record-files 21, calendar-connect 18, store-connect 8, voice-rules 29, google-lead 13 |
| `tests/runtime/start.sh` + `node tests/runtime/edge_functions.mjs` | runtime checks for google-lead, website-lead, reschedule, staff-invite, continue-plan, billing-webhook, voice-rules (incl. `lookup_order`), calendar-connect, store-connect: all passed |
| `node tests/browser/record-files-e2e.mjs` (runtime) | 23 passed |
| `node tests/browser/wizard-journey.cjs` (runtime) | 23 passed |

**Skipped or not possible here:**
- Real provider calls, including the OAuth code exchange with Google and Microsoft and the Shopify API. These are unit-tested with recorded shapes only.
- pg_cron-driven runs.
- Load and concurrency beyond the class-capacity test.
- Postgres 17 itself.
- Browser checks of every industry's screens. Industry screens were swept earlier; new screens were checked for salon, cleaning and e-commerce.

**Rollback tests: which writes survive**
- **Exact rollback** (no use after deploy): schema and every row return to the pre-deploy snapshot. Functions, grants, policies, triggers, views, tables, columns and data were all compared.
- **Rollback after use** (the old schema comes back, new data is retained):
  - an access code saved after deploy goes back into the record's data;
  - an invoice and a capability choice stay in `*_rolled_back_20261104` tables;
  - an Outlook calendar connection, with its Vault key, stays in `calendar_connections_outlook_rolled_back_20261104`.
- **Files:**
  - the bucket and every stored object are kept;
  - the file list table is renamed, not dropped, when it has rows;
  - the storage policies are removed, so nobody can open files until re-deploy.
- **Relationships:**
  - links between records are stored as ids in record data and survive;
  - booking-to-record links (`appointments.record_id`) are dropped with the column. Re-deploying doesn't restore them; they are re-chosen.
- **Also retained:** Google Ads lead keys and lead events (renamed tables), Shopify store connections and their tokens
  (`integrations` and `integration_secrets` existed before), owners' message-policy choices (`businesses.setup_data`),
  and queued messages the policy held back (still "skipped", with the reason).
- **Not retained by rollback:** the industry message-policy defaults table (reference data, re-created by re-deploying).

## 5. Rollback and recovery

**Database:**
- Run `sql/rollback/industry_2026_11_04_rollback.sql`. It is generated from the before and after schemas plus the hand-written data part.
- It needs the §3 backups, runs in one transaction, and refuses without the backups.
- Afterwards, the migrations can be re-applied (tested).

**Functions:**
- Redeploy the previous voice-rules (production v4 source, identical to the repository before this work).
- Delete or ignore the four new functions; nothing calls them once the web app is rolled back.

**Web app:** redeploy the previous build.

**n8n:** nothing to roll back unless imported; keep the exported previous versions before importing.

**Partial failure:** each migration is self-contained and re-runnable. Stop at the first error, fix, and re-run from that file.

## 6. Decisions and credentials still needed

1. Approval to apply migrations 1–17 and deploy the five functions (and in which window).
2. The messaging policy (D1–D5 in `docs/MESSAGING_POLICY_2026-11-05.md`) before sending is switched on.
3. Google Cloud OAuth client (calendar.events scope verification) and Microsoft Entra app registration for calendars.
4. Each e-commerce customer creates a read-only Shopify custom app.
5. The record-files cleanup schedule.
6. BAAs before healthcare or dental go live with real patients.
7. Keep or remove the two legacy admin-check functions in production.
