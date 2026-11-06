# Batch 1: security, permissions, lead integrity, tenant isolation (6 Nov 2026)

Branch `claude/bold-pasteur-efhksy`. **Nothing here is deployed.** The live database, edge functions and web app are as
they were. Production was only read (schema, definitions, grants, advisors), and no production data was changed.

## 1. Findings

| # | Issue | Root cause (confirmed) | Files / functions | Severity | Security impact | Fix |
|---|---|---|---|---|---|---|
| 1 | Admin dashboard treated a failed permission lookup as full access | `allowed()` and `can()` returned true when `me_admin` failed (`meFailed`) and, for `can()`, while it was loading (`!me`) | `web/src/OwnerDashboard.jsx` | High (UI) | A restricted admin whose lookup failed saw every page and action. The server still refused each action, so no data was exposed or changed. The real exposure was misleading UI and requests that were bound to fail. | Explicit states (loading, authorized, unauthorized, failed). Nothing protected renders and no protected data loads until the state is authorized. A failure shows an error with Retry. A 401/403 shows "No admin access" with Sign out. Direct links to pages the role lacks show "This page isn't available". Permissions reload when the signed-in user changes (sign-in in another tab) and on returning to the tab. Search, alerts bell and the status link appear only with `businesses.view`. |
| 1b | Restricted roles without `businesses.view` couldn't learn their own permissions | the admin function required `businesses.view` for `me_admin` itself, so such a role got 403. The old UI turned that into full access; failing closed would have left the role locked out. | `owner-provision-business/index.ts`, permission gate | Medium | none beyond #1 | `me_admin` is allowed for any active platform admin. It returns only the caller's own role and permissions. Every other action keeps its permission check. |
| 2 | Security & Abuse treated missing permissions as granted | `can = (p) => !permissions \|\| permissions.includes(p)` | `web/src/SecurityAbuse.jsx` | High (UI) | Same as #1 for policy defaults, block rules and automation. | `can()` is true only for a listed permission. The dashboard always passes the loaded list, so the page fails closed. Server checks were reviewed and are unchanged: `spam_admin_overview/incidents/incident/rules` need `security.view`, `rule_add/remove` need `security.manage`, `policy_save/automation_save` need `platform.configure`. All four writes are audit-logged. Incident detail masks the sender and never returns message text or note content. |
| 3 | Lead creation fell back to a direct `customers` insert | when the RPC error looked like "function missing", the modal inserted into `customers`, skipping duplicate matching, lead stage, contact deadline, follow-up task and callback | `web/src/BusinessForms.jsx` (`AddLeadModal`) | High | Bypassed the lead pipeline. It did not cross tenants: row security still held. | Fallback removed (`web/src/leadCreate.js`). Only `zella_staff_add_lead` is called. If it is missing or fails, a plain message says the lead wasn't added. Database wording is never shown. A ref guard stops double submission (click, click, Enter) while saving. Success refreshes the lists, as before. |
| 3a | `zella_staff_add_lead` in production | checked, and correct as deployed | live definition | — | Owner/admin/manager/staff of *that* business only (`zella_has_role`, active membership). Name required. `zella_capture_lead` refuses suspended or cancelled businesses and requires a phone or valid email. Duplicates: an exact match updates notes; an uncertain match creates a duplicate review, a task and a notification. New leads get stage `new`, a contact deadline from the new-lead automation, and lead rules. Neither function is executable by `anon`; `zella_capture_lead` isn't executable by `authenticated` either. | no change |
| 4A | `calls_view` (advisory: security definer view) | intentional. `authenticated` has column-level SELECT on `calls` **without** `transcript` and `recording_url`. The view runs as its owner to return those two only where `zella_can_read_call_content` allows (owner/admin/manager; staff only outside sensitive industries with the business's opt-in). It filters by `is_business_member`, the `calls` module and the MFA gate. `anon` has no grant. | `public.calls_view` | Low (advisory) | A `security_invoker` view could not read the withheld columns. Switching would break call content for owners, or would need the column grant, which exposes transcripts to everyone with direct table access. The safer equivalent is what exists. | No change; justified. Tests cover owner/staff/anon/cross-business access and direct reads of the withheld columns. |
| 4B | Six SECURITY DEFINER functions executable by `anon` | each is a deliberate public endpoint | `zella_mfa_satisfied`, `zella_pre_request` (PostgREST `db_pre_request` hook: it runs for anonymous requests too and must stay executable, or every anonymous request fails), `zella_platform_public_info` (sign-in page: display name, support contact, logo, headline, maintenance), `zella_public_status` (status page: component states and public incidents), `zella_unsubscribe_lookup` / `zella_unsubscribe_email` (email footer link; 32-hex token required; returns only the business name) | Low | None found. No business, customer or credential data is reachable without a valid unsubscribe token. The token is 128-bit and only opts that recipient out. | No change. A test pins the exact list, so a seventh function fails the suite. |
| 4C | `zella_appointment_holds_time` mutable search path | SECURITY INVOKER; reads no tables, only built-ins. It was also mislabelled IMMUTABLE although it calls `now()`. | `sql/zella_booking_buffers.sql` | Low (hygiene) | No real risk: a caller's search path could only affect that caller. | `STABLE` and `search_path = ''` (`sql/zella_batch1_security.sql`). Nothing indexes it or uses it in a policy, default, view or constraint (checked live). Side effect: the planner no longer inlines it, negligible at these sizes. |
| 4D | Tenant isolation | rechecked, holds | customers, leads, appointments, CRM records, record files, calls and transcripts, business settings/profile, platform tables | — | Tested for direct table access and through functions (section 3). Rereading production: 152/152 public tables have RLS, 316 policies, 751 SECURITY DEFINER functions, all with a fixed search path. 322 are executable by `authenticated`. A pattern scan found 40 with no direct caller check. Those are gated by `zella_admin_require` or a membership helper, or return per-business config facts only: currency, module or capability on, plan language count, sensitive-industry flag, arrival window. Row security policies call `zella_module_on` and `zella_mfa_satisfied`, so they must stay executable. | No change (see residual risks) |
| 5 | Record file stuck when the check failed | after a successful upload, a failed or timed-out content check left the file in `checking`. The UI said "it will appear once it has been", but nothing re-ran the check, so people re-uploaded. Reservations whose upload failed were left pending. | `web/src/BusinessRecords.jsx` (`RecordFiles`), `record-files` function (reviewed, unchanged) | Medium | No access problem: unchecked files are visible only to their uploader (row security and storage policy). The issue was reliability and orphaned files. | The uploader sees their waiting files ("Waiting for the file check · only you can see it") with **Check again**, which re-runs the check on the stored copy without re-uploading, and **Discard**. A failed upload releases its reservation at once. A file the check refuses outright is discarded with the reason. The server's daily cleanup of abandoned uploads already exists (`zella_record_file_cleanup`, `record-files` action `cleanup`). Its schedule still awaits approval (see section 4). |

### Residual risks (found, not changed in Batch 1)
- **Direct `customers` inserts are still allowed by row security** for owners, admins, managers and staff (the viewer cannot). The lead modal no longer uses this path, but the walk-in check-in (`BusinessMore.jsx`, `WalkInModal`) still creates customers directly, without duplicate matching. Restricting direct inserts would need that flow and any other writer moved to an RPC first. That belongs in a later batch.
- **Per-business config helpers** (`zella_business_currency`, `zella_language_allowance`, `zella_capability_on`, `zella_module_on`, `zella_sensitive_industry`, `zella_arrival_window`) answer for any business id to any signed-in user. They reveal small configuration facts only, no people or messages. Membership checks inside them would need care, because policies depend on two of them.
- **`tickets_list`** returns every business's id and name to an admin with `support.manage` even without `businesses.view`. This is admin-only, but broader than that role's description.
- **Leaked-password protection** (Supabase Auth advisory) is off. It is a dashboard setting, not code.
- The admin UI refreshes permissions on sign-in changes and when the tab becomes visible, not on a timer. A role changed by an owner shows on the next focus. The server enforces the new role immediately either way.

## 2. Change summary

| File | Change |
|---|---|
| `web/src/adminPermissions.js` (new) | access states, `hasPermission`, `useAdminAccess` hook (fail closed, retry, reload on user change) |
| `web/src/OwnerDashboard.jsx` | uses the hook; loading, failed, unauthorized and denied screens; data loads gated on permission; search, alerts and status link gated |
| `web/src/CreateBusinessWizard.jsx` | `callOwnerFunction` errors carry the HTTP status and server code (message unchanged) |
| `web/src/SecurityAbuse.jsx` | `can()` fails closed |
| `web/supabase/functions/owner-provision-business/index.ts` | `me_admin` allowed for any active platform admin |
| `web/src/leadCreate.js` (new) | lead pipeline call and plain-language errors; no fallback |
| `web/src/BusinessForms.jsx` | `AddLeadModal` uses it, with a double-submit guard; direct insert removed |
| `web/src/recordFileCheck.js` (new) | interprets the check result: ready, rejected, waiting or failed |
| `web/src/BusinessRecords.jsx`, `web/src/BusinessApp.css` | waiting uploads with Check again and Discard; reservation released after a failed upload |
| `sql/zella_batch1_security.sql` (new migration) | `zella_appointment_holds_time` STABLE with `search_path = ''` |
| `sql/rollback/zella_batch1_security_rollback.sql` (new) | its undo |
| `sql/zella_booking_buffers.sql` | same definition in the source file, so a re-run doesn't undo it |
| `tests/security/batch1/run.sh`, `tests/security/batch1/test.sql` (new) | database checks on an isolated copy of production |
| `web/tests/batch1_unit.test.mjs` (new) | unit tests |
| `tests/browser/admin-permissions.cjs`, `tests/browser/crm-batch1.cjs` (new) | browser tests against a stubbed backend |

## 3. Test evidence

| Command | What it covers | Result |
|---|---|---|
| `tests/security/batch1/run.sh` | isolated Postgres 16 copy of production state (`build_full.sh` plus every file applied since), the migration applied twice: lead pipeline (owner and staff create; repeat submission matches instead of duplicating; no contact, bad email and no name refused; other business's member, viewer by RPC and by direct insert, suspended member, paused business and anon refused); cross-tenant reads and writes on customers, appointments, CRM records, calls, businesses, by table and by function (settings, profile, file start); platform tables closed to business users; call content (owner yes, staff no, direct column read refused, anon none); public endpoints (exactly six anon definer functions, token checks, public info and status keys only); record files (uploader-only visibility of unchecked files, re-check repeatable, teammates and other businesses refused, discard, missing upload, abandoned cleanup); holds_time (stable, fixed path, same answers, hostile search path); rollback restores the old definition | **10 checks + migration + rollback: all passed** |
| `cd web && node --test tests/batch1_unit.test.mjs` | permission states (owner, restricted, loading, failures, malformed answers, 401/403/MFA), lead call and messages (no fallback, no database wording), file-check outcomes | **11 / 11 passed** |
| `node tests/browser/admin-permissions.cjs` (Chromium, stubbed backend, 1366 px and 390 px) | owner pages; restricted admin's menu; direct URLs `/audit-logs`, `/plans`, `/support`, `/verification`, `/businesses/new` denied with no data requested; read-only Security & Abuse defaults and no rule add; loading shows nothing protected and requests nothing; failure shows Retry and no actions; Retry recovers; 403 shows only Sign out; account switch in another tab replaces the permissions; sign-out leaves no navigation | **49 / 49 passed** |
| `node tests/browser/crm-batch1.cjs` (stubbed backend) | double submission sends one request; no direct customers write; missing RPC and refusal explained plainly; waiting file shown; Check again makes it ready without re-uploading; a still-failing check keeps it waiting; Discard removes the row and the stored copy; a refused file is discarded with its reason | **13 / 13 passed** |
| `me_admin` through the real `owner-provision-business` in the Supabase edge runtime v1.78.0, isolated database (test-only role change, put back) | a restricted role without `businesses.view`: `me_admin` 200 with its own permissions, `dashboard_data` 403; owner 200; business owner 403; no token 401 | as expected |
| `tests/security/run.sh` (existing suite) | every existing security test | all passed (the new test lives in its own folder so this older runner doesn't pick it up) |
| `tests/deploy/run_all.sh` (existing full sequence) | all suites, 28-industry call matrix (current and deployed-era voice-rules), rollback and re-apply, including the edited `zella_booking_buffers.sql` | **25 / 25 passed** (first run: 7 failed only because `deno` wasn't on PATH; re-run with it) |
| `web/supabase/functions/check.sh`; `deno test` in owner-provision-business | type checks for all 11 functions; 13 unit tests | all ok; 13 / 13 |
| `npm run build`; `npx oxlint src` | build; lint | build ok; lint 0 errors, 185 warnings before and after (no new categories) |

**Not verified:** anything in production. No test ran against the live project, the live edge functions or the
published web app. Browser tests use canned backend answers, so they show the UI fails closed but not the live
server's answers. The edge-runtime check covers those against the isolated database. Not covered: real Google or
Supabase sign-in flows for the account switch (simulated with the sign-in library's cross-tab message), Safari and
Firefox, and the record-files content check on real storage (covered earlier by `tests/browser/record-files-e2e.mjs`;
unchanged here).

## 4. Deployment requirements (each needs your approval)

1. **Database migration:** `sql/zella_batch1_security.sql` (two `alter function` statements; safe to run twice).
   Undo: `sql/rollback/zella_batch1_security_rollback.sql`.
2. **Edge function:** `owner-provision-business`, new version (the `me_admin` gate). Undo: redeploy the current live
   version (v14 / main at `7a8e399`).
3. **Web app:** publish the branch's `web/` (Cloudflare Pages builds from `main` once merged). Undo: redeploy the
   previous Pages build.
4. **Order:** function first, then the web app. The new dashboard on the old function works for every role that has
   `businesses.view`. A role without it would see "No admin access" until the function is deployed.
5. **Configuration:** none required. Optional, separate approval: schedule the `record-files` `cleanup` action
   (server key, daily), and turn on leaked-password protection in Supabase Auth.

## 5. Status

BATCH 1 STATUS: **Completed** for tasks 1–6. Residual risks are listed above for a later batch.
READY FOR ARCHITECT REVIEW: **Yes**
READY FOR DEPLOYMENT: **No**, pending your approval of section 4. Nothing has been deployed.

## 6. Deployment (6 Nov 2026, approved: "apply and deploy at the same time")

| Step | State |
|---|---|
| Migration `zella_batch1_security` | **applied to production**. Checked live: `zella_appointment_holds_time` is STABLE with `search_path=""`, and gives the same answers (scheduled holds; expired hold and request free the time). Undo: `sql/rollback/zella_batch1_security_rollback.sql`. |
| Web app | **published**: `main` fast-forwarded to this commit; Cloudflare Pages builds `main`. The live site can't be reached from this container, so the build is unconfirmed. |
| `owner-provision-business` (`me_admin` gate) | **not deployed.** The container can't reach the Supabase API, so the MCP upload would need all nine files (about 240 KB) copied by hand, which is too risky for the admin backend. It isn't needed today: production's only active admins are the two Zella owners, who have every permission, so the new dashboard works with the live v14. It matters only once a restricted role without `businesses.view` is created. Live v14 also lacks `main`'s `onboarding.ts` arrival-window setting (from the arrival-windows work), which is a separate pending item. Deploy both with `supabase functions deploy owner-provision-business --project-ref pffqxlumqhjdbzvvoszm` from `web/`. |
