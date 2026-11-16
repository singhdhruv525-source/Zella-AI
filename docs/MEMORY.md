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

**Not launched yet (owner, 15 Nov 2026):** Zella Voice is still being built. The live project holds 4 demo businesses and
no real customers; tests on it use those demo businesses. Every apply, deploy and live switch still needs the owner's approval.

**Database:** all migrations on `main` are applied **except `sql/zella_workflow_alert_email.sql`** (PR #57; keeps n8n
workflow failures out of admin emails; waiting on the owner's decision and approval). The last seven applied were applied on 12 Nov 2026:

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

**Edge functions deployed** (read from Supabase on 16 Nov 2026: version and last deploy date; setting a secret raises every function's version by one without changing its files):

| Function | Version, last deploy |
|---|---|
| `voice-rules` | v8, 15 Nov 2026 (forward on the usage limit; files match `main`) |
| `record-files`, `google-lead`, `calendar-connect`, `website-lead` | v2, v2, v2, v5, 14 Nov 2026 |
| `platform-emails` | v2, 15 Nov 2026 (new; files match `main`; answers 401 without the Vault secret) |
| `staff-invite` | v6, 15 Nov 2026 (files match `main`: two step sign in required, request size limit, plain wording, and the strict `cors.ts`: browsers are allowed only from `ZELLA_APP_URL`'s origin, `ZELLA_ALLOWED_ORIGINS` and localhost) |
| `continue-plan` | v7, 9 Nov 2026 (behind `main`) |
| `owner-provision-business` | v18, 16 Nov 2026 (deployed by the owner with the CLI from `main`, built on Supabase's servers with `--use-api`; answers 401 to an unsigned request and gives no `Access-Control-Allow-Origin` to an unlisted website) |
| `store-connect` | v1, 6 Nov 2026 |
| `billing-webhook` | v5, 4 Nov 2026 (behind `main`; kept off until step 4) |
| `reschedule-appointment` | v3, 29 Oct 2026 |
| `smart-action` (named "zella-admin-check") and `zella-admin-check-v2` | v5, 18 Oct 2026: old one-off checks with no source in the repo; candidates for removal, with approval |

Not deployed yet from `main`: `billing-webhook`, `continue-plan`, `reschedule-appointment`, `store-connect`.

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:9e7f82a2344a79e99bb8059dd7bea910ddfc525e6c55c22836f01fc57314405d -->

**App address secrets:** current owner invitation code rejects an unusable `ZELLA_APP_URL` with 503 before Resend resets status or sends, and before the setup-finish send plan claims, sends or activates (BIZ-01). Production deployment and the live `ZELLA_APP_URL` value remain unresolved verification items. The earlier Codespace configuration note does not establish their current state. A new Codespace has a new address, so its `ZELLA_ALLOWED_ORIGINS` entry must be updated when used.

<!-- /coderabbit-ai-generated:v1 -->

n8n workflows are not re-imported since PR #57. Deploying needs the owner's approval.

**n8n:** the 30 workflows were renamed "Zella Voice - …" in n8n on 13 Nov 2026 (owner's approval; name only, all still unpublished), matching `n8n/workflows/`.

**Live switches (all off; read 15 Nov 2026):** `usage_enforcement` = calls off, messages off; `calls_live`, `sms_live`, `email_live`, `calendar_sync_live`, `reviews_live`,
`review_ai_live`, `knowledge_ai_live`, `call_intel_live`, `call_reconcile_live`, `spam_workflow_live`, `spam_ai_live`,
`website_crawl_live`. `n8n_dispatch_enabled` is true, but the `zella_dispatch` job and the other timed jobs are
inactive, except `zella_usage_thresholds` and `zella_billing_reconcile` (checked 15 Nov 2026). So the hourly group, and with it the business moments, does not run until `zella_jobs_hourly` is switched on, with approval. `vapi_auth_mode` is `bearer`.

## 4. Open problems

| Problem | State | Next step |
|---|---|---|
| **Vapi call authentication.** Vapi sends some messages (call status, end-of-call reports) without the Authorization header, so `voice-rules` answers 401. The test assistant was reloaded with the token in every server's headers on 30 Oct. | Open | Owner test-calls the test assistant, then checks `voice-rules` logs. Real assistants need the headers sent from the server side, with approval. |
| **Edge functions and n8n behind `main`** | Open | Deploy from `main` with approval. |
| <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:9123bd8d8797eb6c820594101faae82df3c1e7e1894bae6c11114bfbf409fc5f --> **Owner invitations without the app address** (`docs/ADMIN_AUDIT_2026-11-16.md` BIZ-01). Current invitationResend and the setup-finish send plan reject an unusable ZELLA_APP_URL with 503 before changing state or sending an invitation. <!-- /coderabbit-ai-generated:v1 --> | Open | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:7c407862abe286bb2872c7e7bf19ce759aff5483cd9bb2bd5a75d6dd5933192c --> Verify production deployment and live ZELLA_APP_URL configuration, then confirm the deployed revision refuses before changing state or sending. These remain unresolved. <!-- /coderabbit-ai-generated:v1 --> |
| **Admin panel audit** (16 Nov 2026): 210 items across every admin page, 16 of them P1, with a page by page section and a build checklist, in `docs/ADMIN_AUDIT_2026-11-16.md`. Evidence: code review, a local browser crawl and visual pass on the isolated database, and read only production checks. | Open | Owner picks the order; the audit suggests one (permissions first, then sign in, invitations and lifecycle). |
| **Scheduled cancellations** (BIZ-03, 16 Nov 2026): the daily job only marked a business cancelled and left its AI receptionist on and its subscription active; the full cancellation ran only when an admin opened Overview or Businesses. `sql/zella_cancellations_scheduled.sql` makes the scheduled path do the full cancellation, hourly. | Built, not applied | Apply with the owner's approval; it acts only once `zella_jobs_hourly` or `zella_jobs_daily` is switched on. Then remove the page open fallback from owner-provision-business. |
| **Owner onboarding journey** (owner, 16 Nov 2026): after the admin dashboard work, an owner opens the invitation link, sets a password and two step sign in, checks the details the admin entered step by step, verifies their identity (provider to decide; Persona recommended), sees their plan, pays (Stripe), then goes live. Screens and checklist in `docs/ADMIN_AUDIT_2026-11-16.md`, add on task. | Server side built, not applied (16 Nov 2026): `sql/zella_owner_onboarding.sql`, the `owner-onboarding` and `identity-webhook` edge functions, contract `docs/OWNER_ONBOARDING_CONTRACT.md`; tested on the isolated database and the local stand in only. Screens built separately (`claude/owner-onboarding-screens`). | Owner approves the four defaults below (or changes one, a one line change in `zella_onboarding_rules()`), then applies the migration and deploys both functions with the screens. Stripe Checkout and the payment webhook, and the Persona connection, are still to build. Note: once applied, a business that isn't live can't go live until identity is verified and a provider confirmed payment exists. |
| **Repo build vs production drift.** The isolated build from the repo differs from production in a few places: production is stricter on execute grants for `zella_arrival_window`, `zella_booking_choices` and `zella_capability_on` (server only) and `zella_cross_sell_ideas` (signed in, not anon); `zella_session_proved_email` is security definer in production; production has `zella_audit_privileged_trg` on `platform_admins`; and the repo build keeps an old `zella_calendar_connect(uuid,text,text,text)` that production dropped. | Open | Bring the repo build in line with production (a test-only change to the builder, or a new migration if the repo is right). |
| Database test scripts outside the isolated test server: most are guarded through `build_full.sh` or `sql/baseline/restore.sh` (checked 13 Nov 2026); `tests/features/run.sh` and the three in `tests/voice-reliability/` now use `tests/lib/zpsql.sh` and the guard (G-10) | Fixed in PR #60 | — |
| `tests/voice-reliability/run_all.sh` (and `tests/features/run.sh`, which needs its database) is out of date: it checks its build against production's function bodies of 28 Oct, and five have changed since, so it fails on `main` before any test runs | Open | Refresh the snapshot from production (read-only) and the build scripts, or retire the suite in favour of `tests/deploy/run_all.sh` and `tests/calls/run.sh`. |
| **Conformance check, 13 Nov 2026:** 14 rules pass across the whole system; 5 gaps fixed in PR #59; G-2, G-4, G-5, G-7, G-8 and G-10 in PRs #60–#65; the database parts of G-2, G-4, G-7 and G-8 applied to production on 14 Nov 2026 with the owner's approval; G-1, G-3, G-6 and G-9 still open | Open | Follow the order in `docs/CONFORMANCE_2026-11-13.md`. |
| `tests/deploy/run_all.sh` didn't apply the newer migrations | Fixed in PR #57 (a `LATER` list applies, rolls back and re-applies them; all checks pass locally) | — |
| **Inbound call routing:** a call whose number and Vapi phone ID match two different businesses' rows is routed by the ID (CodeRabbit, PR #57). Each column is already unique. | Open, owner's decision | Proposed: `zella_business_for_number` returns a business only when both agree; a guarded migration with rollback. |
| **Billing step 2 (plans, balances, usage, alerts):** `sql/zella_billing_allowances.sql`, tested on the isolated database (tests/billing, and the full rehearsal in tests/deploy/run_all.sh). Applied to production on 14 Nov 2026 with the owner's approval and checked by read-only fingerprints; the one difference is `zella_language_allowance`, where production keeps its earlier, stricter role check | Applied; next steps open | Next: switch on calls to the fallback number at 100% and stopping routine texts and emails at 100% (live changes); set `voice_max_call_seconds` to 1200 for the 20-minute cap; fill in the unit costs (`billing_rules.unit_costs`); then deploy the step 3 pages (`owner-provision-business`, which refuses to finish setup without a saved plan, was deployed on 16 Nov 2026 as v18). `tests/browser/wizard-journey.cjs` needs the billing migration in its database now. |
| **Payments provider is Stripe** (D-34 changed 13 Nov 2026: Zella Voice is a Wyoming LLC). Integration reference from Stripe's docs in `docs/PAYMENTS_ARCHITECTURE.md` §16; auto-reload and pay as you go charge automatically (D-54 closed) | Open, owner | The owner completes the Stripe account checklist (§16.7: EIN, identity, US bank account, Billing on, sandbox keys saved as staging secrets by the owner), and decides when a trial business pays the setup fee. |
| **Stripe payments, built switched off (lane F, 16 Nov 2026):** the owner's instruction "complete everything; once Stripe is made we just add the webhook". Built so far: the Stripe client `_shared/stripe.ts` and the local fake `tests/stripe_fake/fake_stripe.ts` (no test reaches Stripe); the rebuilt `billing-webhook` and the new `billing-worker` with `sql/zella_stripe_pipeline.sql` (gaps C-1 to C-8 closed; the live `zella_reconcile_billing_events` job unchanged); Checkout and the saved card trial for onboarding step 6 (`sql/zella_stripe_checkout.sql`, `billing-api`; the go live gate counts only a bound Stripe payment; rule `first_payment` stays `pay_before_live`); renewals, failed payments and the 5 day pause (`sql/zella_stripe_renewals.sql`; Stripe retries, Zella Voice never charges a renewal; 30 days unpaid only alerts a person); packs bought by the owner and auto reload (`sql/zella_stripe_packs.sql`; a PaymentIntent on the saved card; one pending reload at a time; the monthly spend limit; never blocks a usage entry); refund requests with server side eligibility, approved only by the Zella Voice owner (`sql/zella_stripe_refunds.sql`; a Dashboard refund is recorded and alerted); cancel and continue synced to Stripe from `businesses.cancel_at`, latest choice wins (`sql/zella_stripe_cancel.sql`); invoices recorded from Stripe invoice events and the admin Payments panel on Plans & subscriptions (`sql/zella_stripe_invoices.sql`, `web/src/admin/BillingRecords.jsx`); disputes recorded, the account suspended while one is open, shown to admins (`sql/zella_stripe_disputes.sql`); billing emails decided in the database and rendered into the platform outbox, held while `email_live` is off (`sql/zella_stripe_emails.sql`); **open owner decision:** most billing templates show the card's last 4 digits, which §9 says Zella Voice never stores, so those emails are held (MISSING_FIELD card) until the owner decides | Built, not applied or deployed | Going live is three owner steps, in `docs/PAYMENTS_ARCHITECTURE.md` §16.7: (1) secrets `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` (no price IDs needed: the worker creates a Price per plan version); (2) the webhook endpoint `.../functions/v1/billing-webhook` in Stripe with the §16.5 events; (3) `select public.zella_payments_switch(true, '<worker url>')` |
| **The deployed `billing-webhook` doesn't follow the Stripe design yet** (`docs/PAYMENTS_ARCHITECTURE.md` §17, gaps C-1 to C-8): it grants from the payload, treats an active status as a renewal and has no binding check. It is off (no `STRIPE_WEBHOOK_SECRET`). | Open, step 4 | Keep the secret unset until step 4 rebuilds the webhook as in §6.0b and its tests pass. |
| **Workflow-failure emails:** `sql/zella_workflow_alert_email.sql` (merged, not applied) keeps n8n failures in the dashboard only | Open, owner's decision | Apply with approval, or drop it if admins should be emailed. |
| **Unsubscribe functions have no rate limit** (SEC-6 gap, architecture §30) | Fixed, applied 14 Nov 2026 | `sql/zella_unsubscribe_limit.sql`: lookup 30 and save 10 per link per 10 minutes, unknown links answered before counting, and an opt-out is never refused (NN-8: it is skipped only when the person's latest choice is already opted out). The web page's busy state keeps the Unsubscribe button and must ship with it. Already applied; do not apply again. |
| Other rulebook gaps from the 12 Nov review: industry branches in database functions (BIZ-10) | Open | Plan it as its own PR. The `business_id` columns on six business-owned tables (TEN-1) were added by G-8, applied 14 Nov 2026. |
| **Call-minute margins:** pack prices are below a 60% margin at an estimated $0.15/min cost, and the 250-minute pack costs more per minute than the 100-minute pack | Open, owner | Measure the real cost per minute from Vapi call logs, then revisit. |
| PR #42 outside-diff finding: the webhook metadata business-ID fallback | Open | Review and fix. |
| The last commit of PR #49 (`a5bcb54`, a merge commit) was never reviewed by CodeRabbit | Open | Low risk; re-review if touched. |
| Audit follow-ups M-3, M-4, L-2, L-4, L-5 | Open | `docs/ZELLA_REMEDIATION_CHECKLIST.md` |
| "Something is missing in the app" (owner, no details yet) | Waiting on the owner | |
| **Emails from Zella Voice to businesses:** catalogue and admin preview built; outbox `sql/zella_platform_emails.sql` applied 15 Nov 2026 (empty) | Open | Delivery applied and deployed 15 Nov 2026 (`sql/zella_email_delivery.sql`; `platform-emails` v1, which refuses a call without the Vault secret). Event based: a new email wakes the sender at once; the minute job is only a safety net. Still off, each with approval: set `platform_emails_url` and the sender address (`email_from_address`), add `RESEND_API_KEY` to the function, switch on the two event triggers and the safety net job, then turn on `email_live`. Billing emails per Stripe event in step 4. |
| **Usage limits that act:** `sql/zella_usage_enforcement.sql` applied 15 Nov 2026 (fingerprints match the tested copy; switches off); voice-rules v8 deployed 15 Nov 2026 (files match `main`; unsigned requests refused) | Open, owner's approval | 1. Give one demo business a test fallback number the owner controls. 2. Staging call with the calls switch on for it, to prove Vapi transfers on the `destination` reply. 3. Turn on `usage_enforcement.calls`, then `.messages`, each with approval. The monthly spending limit for pay as you go needs payments (step 4). |
| **Fallback number for every business** (owner, 15 Nov 2026: decided at Create Business, REQ-BIL-34). New businesses can't finish setup without one (owner-provision-business, merged; deployed 16 Nov 2026 as v18). | Open | The 4 businesses in production are demo businesses (owner, 15 Nov 2026), so none needs a real fallback number; one gets a test number for the staging call. |
| **Safe retry on Platform operations (OPS-05):** `sql/zella_retry_event_safe.sql` (built, not applied). `zella_retry_event` gains a reason argument and refuses an event that already acted; `zella_start_execution` refuses a run of an event that isn't claimed (EVENT_NOT_CLAIMED) or that names another business (EVENT_BUSINESS_MISMATCH), and the Event Router stops for that event instead of running its handler | Open, owner's approval | Goes live as one step, in this order: the n8n Event Router (re-import `n8n/workflows/zella-event-router.json`, so a refused start runs nothing), then the SQL, then the web app (it sends the reason; the old app's retry would fail until it is published). Rollback in reverse. Not covered: two workers that both hold a claim (the 10 minute reclaim); claims carry no owner token yet |
| **Status page honesty (OPS-01, OPS-02):** production's `/status` says "Everything is working" although every check and job is off (read 16 Nov 2026). `sql/zella_status_honest.sql` built, not applied | Open, owner's approval | Apply with the web app (either order). Once applied, `/status` will read "Not every part is checked right now" until the provider checks and the `zella_dispatch` job are switched on (PLT-07). |
| **Business moments** (record day, call surge, weekend on call gaps): `sql/zella_business_moments.sql` applied 15 Nov 2026 and added to the hourly group; in app notifications only | Open, owner's approval | They run only once the timed job `zella_jobs_hourly` is switched on (it is off in production, like most timed jobs; only `zella_usage_thresholds` and `zella_billing_reconcile` are active). Later moments need data the app doesn't keep yet (recall due dates, seasonal demand such as tax season). |

## 5. Decisions

The owner's decisions of 9 Nov 2026 are in `docs/ARCHITECTURE.md` §23.1, and the open ones are in §23.2. The ones
most often needed:

- **Writing and notifications (owner, 14 Nov 2026):** no dashes or hyphens anywhere people read text (screens,
  emails, texts, notifications, the AI receptionist); notifications are creative but professional and use each
  business's own words. Rules in `docs/DESIGN_SYSTEM.md` (Writing; Notifications); checked by `npm run lint`.
  Part 2 (15 Nov 2026): the database (`sql/zella_writing_cleanup.sql`, applied 15 Nov 2026) and the edge function
  labels (`staff-invite` deployed 15 Nov 2026; `owner-provision-business` deployed 16 Nov 2026). Left on purpose: n8n
  workflow and node names and internal reason codes (only admins see them in n8n; renaming means a re-import).
  The industry "E-commerce" is shown as "Ecommerce".

- **Owner onboarding defaults (16 Nov 2026, taken at the recommended answers until the owner decides; one server
  constant, `zella_onboarding_rules()` in `sql/zella_owner_onboarding.sql`):** identity by manual upload, checked by
  Zella Voice in Verification, with a provider neutral receiver ready for Persona and off (`identity_provider` = `none`);
  the owner accepts the plan Zella Voice set, no switching (`accept_only`); a confirmed payment before going live
  (`pay_before_live`); after a failed check the owner tries again, and after 2 failed checks Zella Voice reviews it by
  hand (`retry_then_review`, `identity_attempts` = 2). Only Zella Voice admins with `businesses.view` and the
  business's owner can read the progress; other team members can't. The owner's calls are database functions (the
  rules live in the database, NN-6); only the document upload is an edge function, because it needs the server key.

- **Unsubscribe link limits (G-7, 14 Nov 2026):** limits are per link only, never platform-wide or per address (a burst
  of genuine opt-outs after a big email must never be refused), and the limit never stops an opt-out.

- **Billing policy decided on 12 Nov 2026** (D-34 payment provider, now Stripe since 13 Nov 2026 because Zella Voice is a Wyoming LLC; D-41 policy, D-25 no pause): full text in
  `docs/ARCHITECTURE.md` §17. Every plan is customised per business, with **no preset prices or values**: on the plan
  page of Create Business the team picks the label (**Base** or **Pro**) and sets price, setup fee, caps and trial.
  This is for the start; **standard published plans come later**, based on what businesses actually buy; 5-day trial (20 min, 5 texts, 5 emails, card at start); fixed pack
  prices. Allowances refresh each billing month: on monthly plans once that month's charge succeeds, on yearly plans (charged once a year, D-46) every month of the paid year with no monthly charge; unused minutes roll over for one month, capped at 20% of the plan's minutes (and 20% of each minutes pack's size); pack texts and emails don't roll over (D-42, 13 Nov 2026). At 100% of texts or emails only appointment confirmations and reminders continue, within an unbilled 5% buffer (D-43). At 100% of minutes the owner picks stop, auto-reload or pay as you go at the business's own per-minute rate (D-44). Open billing decisions: D-45 to D-51. Plans, balances, usage counting and the billing pages are built and tested on the isolated database but **not applied or deployed** (PR #59); payment collection (Stripe) is **not built**, and nothing is charged; real charges need the owner's
  approval. Never invent a price that isn't in §17.
- United States only at launch (D-14). Lower-risk industries first; regulated industries after legal review (D-20).
- Businesses are created by the Zella Voice team (D-06). No demo data in production.
- Call recording is off until legal review. Retention: recordings 30 days, transcripts 90 days, message bodies 2
  years, audit logs 7 years (D-13, D-27).
- Lead and missed-call AI calls: 2 attempts, 2–3 hours apart, one message after each (D-01, D-02, D-12).
- Call transcripts: managers and above; staff only if the owner allows; never in sensitive industries (M-4).

- **No public API or outgoing webhooks (owner, 16 Nov 2026):** businesses get the Zella Voice CRM and the connections
  Zella Voice builds, nothing more. Don't build API keys, `/api/v1` endpoints or outgoing webhooks (architecture §36,
  REQ-API-01 to 04, Settings API management and Webhooks). A read only log of incoming provider events for admins is
  still fine.

Waiting on the owner:

- whether suspended businesses keep read-only access (L-5);
- whether to remove the never-used super-admin account that looks like a typo;
- the trademark check for "Zella Voice";
- an Anthropic key for knowledge drafting, when the budget allows.

## 6. Lessons learnt (don't repeat these)

- **Check a migration against production, not only the test copy (15 Nov 2026):** before each apply, compare the
  fingerprint (md5 of `pg_get_functiondef`) of every function the file changes, in production and in the test copy.
  On 15 Nov four differed because `sql/zella_review_sql_fixes.sql` is live but missing from the test template, and
  production's `vault.create_secret` has an extra optional argument the test stub lacked; the version guard refused
  `zella_email_delivery.sql` and nothing changed. Copy the production definitions into the test copy, prove all
  fingerprints match, then test. Production also refuses direct edits of `cron.job` (the test copy allows them):
  switch a job off with `cron.alter_job`, and check the permissions a migration needs (read only) before applying.

- **Payments rules (13 Nov 2026, Stripe design):** a webhook payload is only a notice, so fetch the invoice or
  PaymentIntent from Stripe before granting; every Stripe POST has a deterministic Idempotency-Key stored with the
  exact body before the first send, and a key is reused only for that identical request (Stripe keeps keys about
  24 hours, then search by `metadata` first); grants are keyed on the Stripe object, money on ledger operation keys;
  every refund, even for a duplicate charge, waits for the owner's approval (`REQ-BIL-45`). Full map:
  `docs/PAYMENTS_ARCHITECTURE.md` §8.1.
- **Check the provider's documentation before designing on it (13 Nov 2026).** The payments draft assumed our own renewal
  retries and charging a saved card later in USD; Razorpay's docs show it retries renewals itself, deprecated
  subscription add-ons, and takes INR only for card-token charges. Read the provider's current pages (the session
  needs the host allowed) and record what was read and when. The same day the provider changed to Stripe (Wyoming
  LLC), which removed those limits; the design was rewritten from Stripe's docs.
- **Billing review, 13 Nov 2026 (CodeRabbit, 21 findings on PR #59, all fixed in `aa873f8`).** Rules to keep:
  - *Usage belongs to the period it happened in.* Find the period from the event's time, including past periods, and
    when late usage lands in a closed month, lower the next month's rollover with it. Open periods hourly so a quiet
    month still rolls over; lock periods earlier-to-later so they never deadlock.
  - *Lock the row you charge.* Lock the call before reading what it was already charged, or two updates charge twice.
  - *Our failures are never billable:* a failed call counts nothing, and is given back if it is marked failed later.
  - *Count like the provider:* texts by GSM-7 / UCS-2 parts, not characters.
  - *A plan change applies from the period it starts in;* limits come from the plan in effect, not the latest version.
  - *A retry is done only when its result says so;* re-evaluate alerts after it.
  - *Rollbacks keep history:* archive rows (never delete), keep append-only triggers on archives, rename archived
    indexes so a re-apply gets its own keys, and test re-apply without dropping the archive.
  - *Pages say only what is true:* no "paused", "card taken" or "next charge" before those exist; show loading, error
    and Retry; never save values from a check of earlier input; keep dialog focus stable.
  - *Permission tests must assert the denial message,* not pass on an empty page.

- **A null check passes silently in PL/pgSQL.** `jsonb_typeof(x) <> 'string'` is null (not true) when the key is missing, so an `if` skips it. The billing tests caught a missing warning reason being accepted that way. Wrap these checks in `coalesce`.

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
- **CodeRabbit's "Fix comments" can push commits to the PR branch.** In PR #57 it applied changes that had been held
  for the owner (a new migration and a live call-handling change). Read every bot commit and run the tests before
  merging.
- **Production's text sort order differs from the test database.** Use `collate "C"` when comparing ordered lists or
  hashes between them.

## 7. Where to look

| Need | Document |
|---|---|
| What the product does | `docs/PRODUCT.md` |
| Rules for every change | `ZELLA_VOICE_RULES.md` |
| How it is designed | `docs/ARCHITECTURE.md` |
| Payments, idempotency and scale (draft for the owner's review) | `docs/PAYMENTS_ARCHITECTURE.md`, `docs/ARCHITECTURE.md` §17 and §21.1 |
| Billing emails (every invoice, receipt, renewal notice; auto-debit on/off; SMS for urgent ones) | `docs/BILLING_EMAILS.md`, `docs/PAYMENTS_ARCHITECTURE.md` §6.11 |
| Look and feel | `docs/DESIGN_SYSTEM.md`, `docs/ZELLA_PRODUCT_VOICE.md`, `docs/ZELLA_STATUS_LANGUAGE_GUIDE.md` |
| Database reference | `docs/BACKEND_SCHEMA.md` (generated) and `docs/SCHEMA_STATUS.md` (what is applied) |
| Going live | `docs/GO_LIVE.md`, `n8n/GO-LIVE.md` |
| Undoing a migration | `sql/rollback/README.md` |
| Running tests | each `tests/*/README.md` |
