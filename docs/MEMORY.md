# Zella Voice: project memory

The running memory of the project: where things stand, what was decided, what is open, and what was learnt the hard
way. Read it at the start of every session; update it in the same pull request as the change that makes it out of
date. No secrets, passwords, keys or customer data ever go here (`NN-2`).

Last updated: 12 November 2026. It replaces `docs/PROJECT_STATE.md` (last updated 30 October), which is kept only for
history.

---

## 1. How we work (standing instructions from the owner)

- **No production change without the owner's explicit approval for that specific change:** migrations, deployments,
  publishing, real calls/texts/emails, live switches, billing changes, destructive actions (`NN-3`, `NN-4`).
- **Never print credentials** or ask for them in chat, and never copy customer data into fixtures or docs. Never ask
  the owner to paste a database password into the chat.
- **Preserve TLS and package integrity checks.** Never disable tests or weaken authorization to make something pass.
- **Database tests run only in an isolated test environment** (`tests/lib/isolated_guard.sh`), never against
  production.
- **Don't modify live customer assistants, switch production numbers or enable sending** without approval. No live
  notifications while developing or testing.
- **Say which kind of test proved something:** automated local, staging, or real provider. Never say "everything is
  fixed" or "production-ready" unless the evidence supports it (`NN-11`).
- **Every change goes through a pull request** that CodeRabbit reviews. The owner has allowed Claude to merge once the
  review is clean and the tests pass ("if it needs to be merged you can merge"; `NN-5`). CodeRabbit fixes its own findings when
  the owner ticks "Fix comments".
- **Never edit an applied migration.** Write a new one. Every migration is version-guarded (it refuses to run on a
  function body it wasn't written for) and has an exact rollback in `sql/rollback/` that deletes no data.
- **No model IDs** in commits, PR text, code comments or docs.
- **Brand:** always "Zella Voice", in full (`NN-12`).

## 2. Accounts and environment

| Thing | Value |
|---|---|
| Repository | `singhdhruv525-source/Zella-AI`, default branch `main` |
| Supabase project | `pffqxlumqhjdbzvvoszm` (Postgres 17) |
| Web app | `web/` (React and Vite): admin at `/`, business CRM at `/app` |
| Edge functions | `web/supabase/functions/` |
| n8n workflows | `n8n/workflows/` (n8n Cloud, Starter plan: 2,500 runs a month, so nothing in n8n runs on a timer) |
| Domains | `zellavoice.com` (main) and `zellaai.in` (spare), DNS at GoDaddy |
| Planned hosting | Cloudflare Pages: `app.zellavoice.com` (CRM) and `admin.zellavoice.com` |
| Email | People's inboxes at GoDaddy; automatic email through Resend (domain verified 30 Oct); Supabase sign-in email through Resend SMTP |
| Isolated test database | Postgres 16 on socket `/var/lib/postgresql/zella-sec`, port 55433. It stops when the worker restarts; start it again with `pg_ctl` (see `tests/lib`). |

## 3. What is live in production (12 Nov 2026)

**Database:** all migrations on `main` are applied. The last seven were applied on 12 Nov 2026:

| # | File | How |
|---|---|---|
| 1 | `sql/zella_rollback_security.sql` | MCP |
| 2 | `sql/zella_n8n_webhook_auth.sql` | MCP (no live effect: the Resend vault secrets aren't set) |
| 3 | `sql/zella_record_files_purge_retry.sql` | MCP |
| 4 | `sql/zella_replace_business_hours.sql` | owner, SQL editor |
| 5 | `sql/zella_order_lookup_reservations.sql` | owner, SQL editor |
| 6 | `sql/zella_review_sql_fixes.sql` | owner, SQL editor (the version fixed in PR #55 that keeps the Zella Voice wording) |
| 7 | `sql/zella_seating_handoff.sql` | owner, SQL editor; must run after #6 |

Checked after the apply: the guarded function hashes match `main`, seating is in `zella_ai_booking`,
`zella_audit_privileged_trg` exists, and 19 functions carry "Zella Voice".

Shape: 163 tables (plus three `backup_20261104_*` tables from the 4 Nov industry work), row security on every one,
340 policies, 861 functions, 111 triggers. Full reference: `docs/BACKEND_SCHEMA.md`. Data: 4 businesses, 3 record
types, no plans.

**Edge functions deployed** (last deploy date):

| Function | Last deploy |
|---|---|
| `billing-webhook` | 4 Nov |
| `voice-rules`, `record-files`, `google-lead`, `store-connect`, `calendar-connect` | 6 Nov |
| `owner-provision-business` | 7 Nov |
| `staff-invite`, `continue-plan` | 9 Nov |
| `website-lead`, `reschedule-appointment` | earlier |
| `smart-action` (named "zella-admin-check") and `zella-admin-check-v2` | old one-off checks with no source in the repo; candidates for removal, with approval |

Changes merged after those dates (PRs #42, #49, #51, #53, #55) **have not been deployed to the edge functions or n8n**.
Deploying needs the owner's approval.

**Live switches (all off):** `calls_live`, `sms_live`, `email_live`, `calendar_sync_live`, `reviews_live`,
`review_ai_live`, `knowledge_ai_live`, `call_intel_live`, `call_reconcile_live`, `spam_workflow_live`, `spam_ai_live`,
`website_crawl_live`. `n8n_dispatch_enabled` is true, but the `zella_dispatch` job and the other timed jobs are
inactive, except `zella_usage_thresholds` and `zella_billing_reconcile`. `vapi_auth_mode` is `bearer`.

## 4. Open problems

| Problem | State | Next step |
|---|---|---|
| **Vapi call authentication.** Vapi sends some messages (call status, end-of-call reports) without the Authorization header, so `voice-rules` answers 401. The test assistant was reloaded with the token in every server's headers on 30 Oct. | Open | Owner test-calls the test assistant, then checks `voice-rules` logs. Real assistants need the headers sent from the server side, with approval. |
| **Edge functions and n8n behind `main`** | Open | Deploy from `main` with approval. |
| **Repo build vs production drift.** The isolated build from the repo differs from production in a few places: production is stricter on execute grants for `zella_arrival_window`, `zella_booking_choices` and `zella_capability_on` (server only) and `zella_cross_sell_ideas` (signed in, not anon); `zella_session_proved_email` is security definer in production; production has `zella_audit_privileged_trg` on `platform_admins`; and the repo build keeps an old `zella_calendar_connect(uuid,text,text,text)` that production dropped. | Open | Bring the repo build in line with production (a test-only change to the builder, or a new migration if the repo is right). |
| About 20 database test scripts lack the isolation guard | Open | Add `tests/lib/isolated_guard.sh` to each. |
| `tests/deploy/run_all.sh` doesn't apply `zella_seating_handoff.sql`; 2 checks fail on unmodified `main` too (the tables test expects seating, and `vite` is missing in that runner) | Open | Fix the runner. |
| PR #42 outside-diff finding: the webhook metadata business-ID fallback | Open | Review and fix. |
| The last commit of PR #49 (`a5bcb54`, a merge commit) was never reviewed by CodeRabbit | Open | Low risk; re-review if touched. |
| Audit follow-ups M-3, M-4, L-2, L-4, L-5 | Open | `docs/ZELLA_REMEDIATION_CHECKLIST.md` |
| "Something is missing in the app" (owner, no details yet) | Waiting on the owner | |

## 5. Decisions

The owner's decisions of 9 Nov 2026 are in `docs/ARCHITECTURE.md` §23.1, and the open ones are in §23.2. The ones
most often needed:

- No plans, prices or minute allowances until the owner adds them (D-09, D-34). Never invent any.
- United States only at launch (D-14). Lower-risk industries first; regulated industries after legal review (D-20).
- Businesses are created by the Zella Voice team (D-06). No demo data in production.
- Call recording is off until legal review. Retention: recordings 30 days, transcripts 90 days, message bodies 2
  years, audit logs 7 years (D-13, D-27).
- Lead and missed-call AI calls: 2 attempts, 2–3 hours apart, one message after each (D-01, D-02, D-12).
- Call transcripts: managers and above; staff only if the owner allows; never in sensitive industries (M-4).

Waiting on the owner:

- whether suspended businesses keep read-only access (L-5);
- whether to remove the never-used super-admin account that looks like a typo;
- the trademark check for "Zella Voice";
- an Anthropic key for knowledge drafting, when the budget allows.

## 6. Lessons learnt (don't repeat these)

- **Check what production has before writing a guarded migration.** The review fixes stopped at `VERSION_MISMATCH`
  because production already had the unmerged brand-name change. The fix was to add production's hash to the guard
  and keep the "Zella Voice" wording, never to bypass the guard.
- **Order matters.** `zella_seating_handoff.sql` must run after `zella_review_sql_fixes.sql`. A combined file can be
  run only once: on the second run the guard rightly rejects the newer function.
- **The MCP `apply_migration` tool can hang** waiting for a confirmation on statements it thinks are destructive, and
  can't take files of about 200 KB. For large files, give the owner a single SQL file to run in the SQL editor.
- **GitHub GraphQL is blocked here.** Use the REST API through `gh api` (create PRs with `gh api repos/.../pulls`,
  merge with `gh api -X PUT .../pulls/N/merge`).
- **CodeRabbit is limited to roughly 4–8 reviews an hour.** Batch changes rather than pushing many small commits.
- **The isolated test database stops when the worker restarts.** Start it again before running tests.
- **Production's text sort order differs from the test database.** Use `collate "C"` when comparing ordered lists or
  hashes between them.

## 7. Where to look

| Need | Document |
|---|---|
| What the product does | `docs/PRODUCT.md` |
| Rules for every change | `ZELLA_VOICE_RULES.md` |
| How it is designed | `docs/ARCHITECTURE.md` |
| Look and feel | `docs/DESIGN_SYSTEM.md`, `docs/ZELLA_PRODUCT_VOICE.md`, `docs/ZELLA_STATUS_LANGUAGE_GUIDE.md` |
| Database reference | `docs/BACKEND_SCHEMA.md` (generated) and `docs/SCHEMA_STATUS.md` (what is applied) |
| Going live | `docs/GO_LIVE.md`, `n8n/GO-LIVE.md` |
| Undoing a migration | `sql/rollback/README.md` |
| Running tests | each `tests/*/README.md` |
