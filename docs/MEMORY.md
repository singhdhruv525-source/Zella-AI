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
| **Call recording is decided by Vapi's default** (16 Nov 2026): Zella Voice's assistant config never sets Vapi's recording option, so whether calls are recorded is left to Vapi's default, although recording must stay off until legal review (D-13, D-27, REQ-VOX-09). | Open, owner | Owner checks the Vapi dashboard now (recording setting on the account and each assistant). A fix on the live call path (setting recording off explicitly in the assistant config) needs its own approval. |
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
| **Stripe payments, built switched off (lane F, 16 Nov 2026):** the owner's instruction "complete everything; once Stripe is made we just add the webhook". Built so far: the Stripe client `_shared/stripe.ts` and the local fake `tests/stripe_fake/fake_stripe.ts` (no test reaches Stripe); the rebuilt `billing-webhook` and the new `billing-worker` with `sql/zella_stripe_pipeline.sql` (gaps C-1 to C-8 closed; the live `zella_reconcile_billing_events` job unchanged); Checkout and the saved card trial for onboarding step 6 (`sql/zella_stripe_checkout.sql`, `billing-api`; the go live gate counts only a bound Stripe payment; the rule `first_payment` is set by the payment gate below); renewals, failed payments and the 5 day pause (`sql/zella_stripe_renewals.sql`; Stripe retries, Zella Voice never charges a renewal; 30 days unpaid only alerts a person); packs bought by the owner and auto reload (`sql/zella_stripe_packs.sql`; a PaymentIntent on the saved card; one pending reload at a time; the monthly spend limit; never blocks a usage entry); refund requests with server side eligibility, approved only by the Zella Voice owner (`sql/zella_stripe_refunds.sql`; a Dashboard refund is recorded and alerted); cancel and continue synced to Stripe from `businesses.cancel_at`, latest choice wins (`sql/zella_stripe_cancel.sql`); invoices recorded from Stripe invoice events and the admin Payments panel on Plans & subscriptions (`sql/zella_stripe_invoices.sql`, `web/src/admin/BillingRecords.jsx`); disputes recorded, the account suspended while one is open, shown to admins (`sql/zella_stripe_disputes.sql`); billing emails decided in the database and rendered into the platform outbox, held while `email_live` is off (`sql/zella_stripe_emails.sql`); **open owner decision:** most billing templates show the card's last 4 digits, which §9 says Zella Voice never stores, so those emails are held (MISSING_FIELD card) until the owner decides; reconciliation that never corrects money, the Events API catch up for a webhook that was down, and one end to end journey test through the fake Stripe (`sql/zella_stripe_reconcile.sql`, `tests/stripe_e2e/journey_test.ts`); not built: pay as you go charging (§6.9). **Plan changes for a business paying through Stripe must go through `zella_admin_plan_change_start`:** a renewal Stripe bills on another plan version than the period's is held for a person (quarantined), never granted; upgrade and downgrade (`sql/zella_stripe_plan_change.sql`: Stripe's preview, the owner confirms, applied only when paid at the preview; downgrades by schedule from the period end; switching monthly and yearly is not built); **owner decision 16 Nov 2026:** the pay before going live check is off until payments are live (`sql/zella_stripe_payment_gate.sql`): while `payments_live` is false, go live doesn't wait for a payment and onboarding step 6 says Payment opens here soon and can be passed; once switched on, pay before going live applies (`first_payment`: `not_until_payments_live` while `payments_live` is false, `pay_before_live` while it is true); usage alert emails at 80% and 100% of minutes (`sql/zella_stripe_usage_emails.sql`), held until payments and email are live. **Defaults chosen pending owner decision (20 Nov 2026, review of PR #108):** the most conservative choice that matches production today (money never moves twice, nothing charged or refunded automatically that wasn't before, refuse rather than guess): (1) a downgrade already scheduled at Stripe stays, and no other plan change starts until it takes effect or a person cancels it (`DOWNGRADE_SCHEDULED`); (2) missed events are read from a stored watermark that moves only after a complete scan; a longer backfill is a separate, manual, approved step; (3) a pack can't be used while its refund is pending (its units are held at approval and freed if the refund fails); (4) a Checkout session that expires is not paid: the owner starts again, nothing is charged automatically, and a session for a changed plan is expired at Stripe before a new one opens; (5) an owner who finished step 6 while payments were off is not blocked afterwards: switching payments on flags each such business (alert `onboarding_unpaid_before_live`) and changes no access | Built, not applied or deployed | Going live is three owner steps, in `docs/PAYMENTS_ARCHITECTURE.md` §16.7: (1) secrets `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` (no price IDs needed: the worker creates a Price per plan version); (2) the webhook endpoint `.../functions/v1/billing-webhook` in Stripe with the §16.5 events; (3) `select public.zella_payments_switch(true, '<worker url>')` |
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
| **Businesses list (UI-03, UI-04, BIZ-15, BIZ-16, BIZ-23, BIZ-24, BIZ-27, BIZ-29):** the paged list action `businesses_list` and the slimmer `dashboard_data` (no members) in `owner-provision-business` are built on branch `claude/admin-businesses-list`, not deployed. The web app works against the deployed function: it gets 400 "Unknown action", falls back to `dashboard_data` and says so on the page | Open, owner's approval | Deploy in either order. `dashboard_data` keeps every field the Offers page, the setup wizard and an older web app read. Overview's totals (`overview_data`) still stop at 1,000 rows (BIZ-15, Overview part). Owner decision: `businesses_list` shows every `businesses.view` role (read only admins too) each business's saved plan tier, version and billing interval, no prices. That is new for `businesses.view` (`tenants_search` only shows the subscription's plan name); if plan detail should stay with billing roles, gate it on `billing.view`. |
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

- **One list of audit actions, alert kinds and permissions (PLT-08, 16 Nov 2026):** they live in
  `web/supabase/functions/_shared/catalog.json`. `tests/catalog/drift_test.mjs` runs in `npm run lint` and fails when SQL,
  an edge function module, n8n or the web app uses a name that isn't listed, or a listed name is no longer used. No CI
  yet: adding GitHub Actions is the owner's choice. The Audit logs page already reads its labels from the list first
  (`catalog.audit_actions`, falling back to `actionLabel`); pages that still call `web/src/ownerFormat.js`'s
  `ACTION_LABELS` directly move to the list next (PLT-08 part 2).

- **Incident updates never notify businesses by default (OPS-12, 16 Nov 2026, recommended default taken):** an update
  is internal unless the admin ticks Tell all active businesses (`p_notify`, false by default, in
  `zella_incident_post_update`). Incidents don't record which businesses they affect, so a notice goes to every active
  business. Editing an open incident notifies nobody. Showing updates on the public status page is not built yet
  (`zella_public_status` is unchanged).

- **Fresh code for admin access changes (ACC-19, 16 Nov 2026, recommended default taken):** adding an admin and changing
  an admin's role or access need an authenticator code entered in the last 5 minutes (`FRESH_CODE_MAX_AGE_SECONDS` in
  `owner-provision-business/mfa_gate.ts`, read from the token's amr). No second owner approval while there are only
  two owners. `roles_save` gets the check after the open admin polish changes to Settings > Platform roles merge.
  It only means something once two step sign in for admins (ACC-01) is live.

- **Admins' own security changes go through the server (ACC-30, 16 Nov 2026):** `me_mfa_added`, `me_mfa_remove` and
  `me_password_change` in `owner-provision-business/access.ts`, audited. The password change uses the server key, which
  skips Supabase Auth's "reauthenticate first" step; a code entered in the last 5 minutes (ACC-19) is the
  reauthentication instead. Removing the last authenticator is refused on the server too (ACC-01). The first
  authenticator set up at sign in is recorded from `web/src/mfa.js`, best effort (the factor is already on).

- **Refused admin calls are security events (ACC-15, 16 Nov 2026, defaults taken):** `security.admin_refused` with ip
  and user agent at the three refusal points (not an admin, two step sign in, permission), capped by
  `REFUSAL_LIMIT` (5 per person and reason in 10 minutes, `owner-provision-business/access.ts`). Not recorded: calls with
  no signed in person (401; Supabase Auth logs those) and FRESH_CODE_REQUIRED (an ordinary step, not a refusal).
  Shown on Users & access; the Settings Security overview card gets the count after the open admin polish merges
  (`security_overview` already returns `refusals24h`).

- **Audit log export (ACC-12, 16 Nov 2026, recommended default taken):** `audit.view` and the Zella Voice owner or super
  admin role (`AUDIT_EXPORT_ROLES` in `owner-provision-business/access.ts`), because the file holds addresses and browsers;
  at most 10,000 entries per file (`AUDIT_EXPORT_MAX_ROWS`); every export is audited as `audit.exported` with its filters
  and row count. The audit page's filter uses the key `auditAction`, since `action` names the function's own action.

- **Support business hours (OPS-25, 16 Nov 2026, recommended default taken):** Monday to Friday 9:00 to 17:00
  America/New_York, first reply goal 4 business hours, stored as `platform_settings.support_business_hours`
  (`SUPPORT_HOURS_DEFAULT` in `owner-provision-business/access.ts` until it is set). It has no editor yet: the
  platform settings allowlist belongs to another lane. Replies notify the business in the app only (never email or
  text, `delivery_status` skipped).

- **Owner onboarding defaults (16 Nov 2026, taken at the recommended answers until the owner decides; one server
  constant, `zella_onboarding_rules()` in `sql/zella_owner_onboarding.sql`):** identity by manual upload, checked by
  Zella Voice in Verification, with a provider neutral receiver ready for Persona and off (`identity_provider` = `none`);
  the owner accepts the plan Zella Voice set, no switching (`accept_only`); a confirmed payment before going live
  (`pay_before_live`); after a failed check the owner tries again, and after 2 failed checks Zella Voice reviews it by
  hand (`retry_then_review`, `identity_attempts` = 2). Only Zella Voice admins with `businesses.view` and the
  business's owner can read the progress; other team members can't. The owner's calls are database functions (the
  rules live in the database, NN-6); only the document upload is an edge function, because it needs the server key.

- **Reference fixture (UI-35, owner, 16 Nov 2026):** local test databases may hold production CONFIGURATION, never
  customer data: `tests/fixtures/reference_config.sql` (industries, modules, configurations, automation defaults,
  platform templates, platform settings), copied read only by `tests/fixtures/export_reference.mjs`, which refuses
  anything off its allowlist. Left out: business rows, template authors (`created_by`), settings ending in `_url`,
  sender address and number, `vapi_` settings and model settings. Every `_live` switch and `n8n_dispatch_enabled` is
  off in it. Loaded only by `tests/fixtures/load_reference.sh` (isolated server only); checked by `tests/fixtures/run.sh`.

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
- **AI testing (AI-TESTING, recommended default taken 16 Nov 2026, owner can change):** a failing evaluation is a warning
  only and never blocks going live. A business passes with at least 3 test questions (`ZELLA_EVAL_MIN_CASES`), all
  passing. Showing the warning on the go live checklist belongs to the Business detail job (BIZ-12).
- **Sensitive industries (CFG-05, recommended default taken 16 Nov 2026, owner can change):** stored as
  `industries.sensitive`. Only a Zella Voice owner may change it (`SENSITIVE_ROLE` in config.ts), with a reason, audited;
  turning it off needs a typed confirmation because staff may then read transcripts. A new industry starts sensitive.
  The seed equals today's list (7 slugs); check it against the reference configuration once UI-35 is decided.
- **Plans page permissions (CFG-19, default taken 16 Nov 2026, owner can change):** each kind of plan keeps the one
  permission its server path already checks: the shared fallback plans need `plans.manage` (plan_save and
  plan_entitlements_save), each business's own plan needs `billing.manage` (zella_admin_plan_save, REQ-BIL-10), and
  reading needs `billing.view`. The page hides each editor without its permission.
- **Connected, answering and live (COM-01, defaults taken 16 Nov 2026, owner can change):** one definition in SQL
  (`sql/zella_connection_state.sql`, `docs/PRODUCT.md` §9.1). Answering is a served call in the last 7 days and is shown
  on its own, never folded into live; live needs an active business, the receptionist switched on and an active number
  linked to Vapi. Email is "not tracked". Real values still need an owner approved read only count in production.
- **Industry modules (CFG-01, recommended default taken 16 Nov 2026, owner can change):** switching an industry's module
  off stays a kill switch: it removes the module at once from every business in that industry that has it on
  (`zella_module_on` needs the module offered). The admin sees "N businesses lose X" and gives a reason first; the server
  refuses an unconfirmed switch off (`industry_save` `confirmOff`). While `LEGACY_SWITCH_OFF_ALLOWED` (config.ts) is true
  an older web app that sends no confirmation still works and the audit row says so; set it false once the new web app
  is live. Deactivating an industry (CFG-08) only stops it being offered for new businesses.

- **Scheduled job intent (PLT-07, 16 Nov 2026, default the owner can change):** every go live job (zella_dispatch,
  the every 5, every 15, hourly, daily and weekly jobs, zella_cron_cleanup, zella_platform_emails, zella_spam_hourly)
  is recorded as "Deliberately off until go live" by `sql/zella_job_intent.sql`. Intents live in their own table;
  recording one needs `platform.configure` and a reason and is audited. An intent is a record, never a switch: no
  lane or page switches a job, which stays the owner's live switch. zella_usage_thresholds and zella_billing_reconcile
  (on in production) have no intent recorded, so the page shows them as plain On.

- **n8n answers (OPS-17, 16 Nov 2026, default the owner can change):** a 401 or 403 from n8n (wrong secret) is one
  urgent `n8n_dispatch_refused` alert for every workflow; a 404 (workflow not published) is a warning per workflow; a
  later 2xx resolves them. The dispatcher reads pg_net's answer on its next run and never waits for it.

- **Go live checklist (UI-23, 16 Nov 2026):** one list on Platform operations. The server secret list lives in
  `owner-provision-business/ops.ts` (`SERVER_SECRETS`), shared by Operations' Services and the checklist; add a new
  secret there. The jobs and email triggers are read by the signed in admin (database functions), the secrets by the
  function; a part that doesn't load reads "Not checked", never "Ready".

- **n8n's own status (AUTO-N8N-STATUS, 16 Nov 2026):** read on the server (`owner-provision-business` `n8n_status`,
  `n8n.ts`) with `N8N_API_KEY` and `N8N_API_URL` (https only) as Supabase secrets; read only, the key never leaves the
  server. Built and tested against a stub; it shows "Not connected yet" until the owner creates the key in n8n and
  sets both secrets.

- **Voice alerts (UI-14, COM-09, 16 Nov 2026, defaults the owner can change):** missed call alert at 5 or more
  inbound calls in 24 hours with 25% or more missed, warning (named constants in `zella_admin_voice_alerts`); a
  refused Vapi request in the last hour is a warning. voice-rules counts refusals (type, reason, header names only)
  without waiting; its deploy is the live call path and needs its own approval, after the "Fix Vapi call auth" work.

- **Alert rules (SET-ALERT-RULES, 16 Nov 2026, the owner decision's safety default):** urgent alerts can't be switched
  off or lowered, only rerouted, and a quiet window or repeat interval never holds them back. Protected kinds:
  service_incident, scheduler_failed, provider_down, integration_disconnected, tenant_leak, plus anything raised as
  urgent. `sql/zella_run_all.sql` re-creates the old `zella_platform_alert` (line 1519): never re-run it after
  `sql/zella_alert_rules.sql`, or apply that file again.
- **Owner decisions of 16 Nov 2026** (architecture §23.1a, and where each requirement lives):
  1. **Growth page (REQ-ADM-18, ACC-36): later**, not before launch. `growth.manage` doesn't exist yet and is not
     listed as an existing permission (`docs/PRODUCT.md`).
  2. **One platform wide default receptionist script (AI-GLOBAL-PROMPT): later.** Each business keeps its own script.
  3. **Weekly platform summary report for admins: yes**, being built in `claude/weekly-admin-report`.
  4. **Billing emails: build now**, held (nothing queued or sent) until Stripe and email are both live (architecture
     §14.4, `docs/BILLING_EMAILS.md`).
  5. **Audit history is never deleted with a business (ACC-10):** `audit_logs` keeps its rows with `business_id` set to
     null, and the row recording the deletion keeps the business id and name (architecture §7, §20, §29). Needs a
     migration (today the foreign key cascades); not built yet.
  6. **Production configuration, never customer data, may be copied read only into test fixtures**, through an
     allowlist of tables and columns (UI-35, architecture §21).
  7. **Pay before go live applies only once Stripe is live**; until then the go live gate doesn't wait for payment
     (REQ-LC-14, REQ-BIL-29).
  8. **No public API, API keys or outgoing webhooks:** already recorded in PR #91 (the bullet below, architecture §36).

- **No public API or outgoing webhooks (owner, 16 Nov 2026):** businesses get the Zella Voice CRM and the connections
  Zella Voice builds, nothing more. Don't build API keys, `/api/v1` endpoints or outgoing webhooks (architecture §36,
  REQ-API-01 to 04, Settings API management and Webhooks). A read only log of incoming provider events for admins is
  still fine.

- **Weekly platform report (owner, 16 Nov 2026):** one weekly summary of the whole platform for Zella Voice admins,
  readable with `reports.view` (owner and super admins by default). The bell alert and the email digest only say it is
  ready, never the figures, because every admin sees the bell and gets the digest. Built, not applied
  (`sql/zella_weekly_platform_report.sql`); runs once `zella_jobs_weekly` is on. Found while building it:
  `zella_check_business_moments` is in the hourly list but not in `zella_run_scheduled_job`'s allowed list, so the
  hourly job would return not_allowed for it. Fixed by `sql/zella_business_moments_job.sql` (built, not applied;
  apply it after the weekly report file).
- **Member support from the Business page (lane E review, 19 Nov 2026, defaults the owner can change):** a two step
  reset is refused for someone who also belongs to another business, because an authenticator protects the person's
  sign in everywhere, not one membership. Deactivate, Reactivate and Cancel invitation run in one database step each
  (`sql/zella_business_member_admin.sql`, built, not applied) and only from what the page showed; until that file is
  applied they answer that the database update is needed. Pack grants by RPC rely on `sql/zella_admin_mfa.sql` (lane A)
  for two step sign in in the database: apply it before the pack grant page is used.
- **Admin Business page reads (lane E defaults, 16 Nov 2026, owner can change):** the Activity list and who did each
  action go only to admins with `audit.view` (BIZ-04); caller numbers and connection account details are masked by
  default with the `zella_admin_mask` rule (`mask.ts`), the Spam page keeps its older rule for now (BIZ-22). The
  permission set comes from `adminPermissions` in `owner-provision-business/detail.ts`, the same answer `me_admin` gives.

- **Business size goes through the admin function (BIZ-08, 16 Nov 2026):** `business_size_save` (businesses.manage).
  Until EXECUTE on `zella_set_business_size` is revoked from signed in users (deferred: after
  `sql/zella_admin_permissions.sql` is applied or dropped, whose version guard covers that function), an owner or
  super admin can still call the old RPC by hand from a browser, skipping the two step check.

- **Admin audit rows record before and after (BIZ-17, lane E default, 16 Nov 2026):** a failed audit write alerts
  (`audit_write_failed`, urgent) and warns the admin; it does not fail the action. Failing closed for suspend and
  cancel would need the audit row written first inside the handler (the dispatcher writes it after the action has
  committed); not built, the database trigger already records those changes. COM-04 confirmed from the function
  definitions: a receptionist edit reaches the next call (`zella_assistant_for_call` reads the live configuration);
  the audit row records `config_hash` before and after.

- **Automations' live rule is behind a switch (BIZ-07, 16 Nov 2026):** `ZELLA_AUTOMATIONS_START_ON_SAVE=on` (an
  edge function secret) makes an automation turned on for a live business start at once (real messages), because
  every deploy is cut from main and production's four businesses are all `onboarding_status` active. Off by default:
  saves behave as before. No backfill of automations already left paused on live businesses (owner decision).
- **Deleting a draft business (Lane B, BIZ-13a, 16 Nov 2026):** only a Zella Voice owner or super admin, with the
  name typed and a reason, and only a business that never finished setup and has no calls, numbers, billing or
  accepted owner. Audit history is never deleted with a business (ACC-10, owner decision, 16 Nov 2026):
  audit_logs.business_id is SET NULL, and the deletion entry keeps the business id and name.

- **Abandoned drafts (Lane B, BIZ-13b, D-30 recommended default, 16 Nov 2026):** a draft with no change for 30 days
  (`draft_abandon_days`, 7 to 365) is marked Abandoned and alerted once ever; nothing is deleted automatically. The
  alert is raised when Business onboarding is opened (no scheduled job for it yet).

- **Missing documents (Lane B, UI-11, 16 Nov 2026):** live businesses without documents are listed too (Live without
  documents); Request documents is allowed once per business per 24 hours, read from the last audit entry. Defaults,
  owner can change.

- **Provisioning steps (Lane B, SET-ONB-RETRY part 1, 16 Nov 2026):** every setup save is recorded through
  zella_track_provisioning. A deliberate refusal (bad input, or setup can't finish yet) is not a failed step and
  raises no alert; only an unexpected error or a failed invitation email is.

- **Setup step retry (Lane B, SET-ONB-RETRY part 2, 16 Nov 2026):** only modules, the receptionist and automations
  are retried, by Retry step or by the timed job zella_provisioning_retry (off until the owner switches it on, at most 3
  tries each). The invitation email and provider steps are never retried on their own. Default, owner can change.

- **Whole business export (Lane B, SET-DL-EXPORT, 16 Nov 2026):** an admin requests, a Zella Voice owner other than the
  requester approves, downloadable for 7 days through signed links that end with it, by the requester or an owner.
  Never in an export: secret tables and columns, recording links, and transcripts in sensitive industries. Default,
  owner can change.

- **Export worker limit (Lane B, 16 Nov 2026; changed in review 19 Nov 2026):** each worker run has about 2 minutes. A run
  that runs out pauses the job (zella_export_pause): it saves where it stopped, page by page, and isn't counted as a try,
  so a large business takes as many runs as it needs; only failures and runs that stop answering count toward the 3.
  Each export also has its own file list, taken once, so files removed or added later never shift it.

- **Spanish template versions aren't sent yet (Lane B review, 19 Nov 2026):** every sender asks zella_resolve_template
  for en-US, so a Spanish version made on Messaging, Templates is kept but not used. How a send picks its language (the
  business's language setting, or Spanish creation held back until then) is waiting on the owner; the page says so.

- **Held emails to businesses (Lane B, 16 Nov 2026):** an email held after 5 tries is released (back to queued, tries
  reset) or discarded by an admin with comms.manage and a reason. A discard ends as `failed`, which only a discard
  writes, shown as Discarded; the sender never marks an email failed (it holds it). Default, owner can change.

- **Template versions (Lane B, UI-20, 16 Nov 2026):** Create only makes an industry or Spanish version of a key that
  already has a platform version (no sender uses a brand new key); Retire only archives such overrides. Default,
  owner can change.

- **Contact lookup privacy (Lane B, COM-29, 16 Nov 2026):** comms.manage only, one business, at least 4 digits or a
  full email, a reason, masked results (last 4 digits), every lookup audited. Default, owner can change.

- **CodeRabbit review routine (owner, 17 Nov 2026):** CodeRabbit reviews a PR in full once, when it opens. Later
  pushes (merges of main, fixes) are reviewed only when someone comments `@coderabbitai review`, and the author must
  request that review on the final head before merging: no PR merges without a CodeRabbit success on its final changes.
  `docs/BACKEND_SCHEMA.md` is not reviewed, because it is generated; every schema change must still regenerate it with
  `docs/generators/backend_schema.py` from an isolated copy. Reason: the review allowance per hour is shared by every PR
  from the one account. Draft PRs get no review when they open (`drafts: false`): when a draft is marked ready for review, comment
  `@coderabbitai review` to start the first review.
- **Number orders (VOICE-PROVIDERS, built 16 Nov 2026, not deployed):** every Telnyx or Vapi purchase or release is an
  order an admin with `telephony.manage` asks for and a Zella Voice owner **who didn't ask** approves (an owner's own
  request needs another owner); the approver's click places it once (claim), and a lost answer is "Check at Telnyx",
  never retried. Bought numbers are added to Vapi but not assigned to a business: that stays the audited Assign step.
  Off until the owner adds `TELNYX_API_KEY`, `VAPI_API_KEY` (and optionally `VAPI_TELNYX_CREDENTIAL_ID`,
  `TELNYX_CONNECTION_ID`, `TELNYX_MESSAGING_PROFILE_ID`) and sets `number_orders_enabled` to true. The Telnyx and Vapi
  request shapes follow their public API docs and are proven only against local fakes; confirm them with a sandbox key.

- **Recording policy (SET-RECORDING-POLICY, built 16 Nov 2026, not deployed):** off for every business. A business can
  be switched on only after a Zella Voice owner records `recording_legal_approved` with the caller disclosure line
  (`recording_disclosure_text`, empty until legal provides it); those two settings can't be changed any other way.
  Not connected to the live call path: today Zella Voice's assistant config doesn't set Vapi's recording option at
  all, so Vapi's own default and dashboard settings decide whether calls are recorded. Making voice-rules send
  recording off (or the policy) is a call path change that needs its own approval.

- **Retention (SET-RETENTION, BIZ-18b, built 16 Nov 2026, not deployed):** each kind of data has its own period, set to
  the architecture's proposal and marked pending legal review (recordings 30 days, transcripts 90, message words 2
  years, audit logs 7 years, replaced verification copies 30 days, owner identity files 90 days after verification,
  a cancelled business's documents and the business itself 30 days after cancellation, never before its
  `retention_until`, which still uses `retention_days`, 90 today). The dry run lists what is past its period and
  deletes nothing. Legal holds keep a business out of every list and make it undeletable. Defaults taken: placing a
  hold needs security.manage, releasing one needs a Zella Voice owner; message bodies are redacted, not deleted.

- **Purge runs (built 16 Nov 2026, not deployed):** a run removes only the rows listed when it was asked for, after
  two different people approve (one a Zella Voice owner) and one of them types "PURGE <rows>", with
  `retention_purge_enabled` on and the period legally approved. Lesson: emptying a call's transcript makes
  `zella_call_integrity` re-mark a short old call as missed and start a missed call callback, so a purged transcript
  is replaced by "Removed under the retention policy." instead. Defaults taken: at most 1000 rows per run; the second
  person needs security.manage (or is another owner). Recordings at Vapi are not deleted (provider copy, needs Vapi).

- **Business purge (BIZ-13d, built 16 Nov 2026, not deployed):** a cancelled business is deleted only by an approved
  purge run (two people, one a Zella Voice owner), after a recorded final export offer at least 14 days old (default
  taken), with its name typed and purges switched on. It waits for: legal approval of the cancelled business period,
  lane B's `zella_draft_delete.sql` and the owner's ACC-10 decision (`audit_logs.business_id` to ON DELETE SET NULL, so
  its audit history survives; lane B keeps it CASCADE until then), and the whole business export (B8, B9)
  for the offer. Refused while it has payment or billing records: how long those are kept after deletion is an owner
  and legal decision not taken. Provider copies: numbers must be released first; deleting Vapi assistants or call
  recordings at Vapi isn't built.

Waiting on the owner:

- whether suspended businesses keep read-only access (L-5);
- the identity check written for a member's two step reset (REQ-LC-19) and whether a fresh admin code is required
  once ACC-19 exists (UI-06);
- the owner invitation defaults (BIZ-21): resend cooldown 5 minutes, a reason to cancel, `businesses.manage`, and a
  never used account kept after a cancel;
- the support access defaults on the Business page (BIZ-22): every open audited with a 30 minute dedupe, a reason
  to reveal contacts, `businesses.manage` to reveal, member and invitee emails masked;
- when to turn on `ZELLA_AUTOMATIONS_START_ON_SAVE`, and whether to start automations already left paused on live
  businesses (BIZ-07);
- whether to remove the never-used super-admin account that looks like a typo;
- the trademark check for "Zella Voice";
- an Anthropic key for knowledge drafting, when the budget allows;
- for pay before go live, once Stripe is live: whether a business on a trial goes live on its confirmed saved card
  trial setup (REQ-BIL-12) instead of a first payment.

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

- **A business could not be deleted at all before zella_draft_delete.sql.** The privileged audit trigger wrote a row
  pointing at the business being deleted, which failed the audit foreign key. Test any delete path on a business
  made the real way (with its receptionist), not a bare row.

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
| Audit action, alert kind and permission names | `web/supabase/functions/_shared/catalog.json`, `tests/catalog/README.md` |
