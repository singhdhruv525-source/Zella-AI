Owner onboarding: flow and backend (progress, owner calls, identity, go live gate)
base: main

Already open as PR #92 (https://github.com/singhdhruv525-source/Zella-AI/pull/92), head e9857eeaf3cb2db40e03a064c9d22d7e6386f492. CodeRabbit was rate limited (neutral), so it hasn't reviewed it yet.

## What this builds

The flow and backend of the Zella Voice owner onboarding journey (`docs/ADMIN_AUDIT_2026-11-16.md`, add on task): welcome, password and two step sign in, check your details, verify your identity, your plan, pay or start a trial, you're all set, with Finish later and resume. The screens are built separately on `claude/owner-onboarding-screens` against `docs/OWNER_ONBOARDING_CONTRACT.md`, now at version 2. Version 2 only adds clarifications: no call or field was removed or renamed, and the changes are listed at the top of the file.

**`sql/zella_owner_onboarding.sql`** (version guarded, exact rollback in `sql/rollback/`)
- **Progress per business:** `owner_onboarding`, `owner_onboarding_steps` and `owner_onboarding_sections`.
  - Row security: only the business's active owner and Zella Voice admins with `businesses.view` can read them. Other team members, including business admins, can't.
  - Nobody writes them directly.
- **Identity events:** `identity_verification_events` (server only, unique per provider and event id; unknown references are kept as unmapped and alerted, TEN-12).
- **Owner callable functions:** `zella_owner_onboarding_list`, `_get`, `_complete_step`, `_section`, `_plan_accept`, `_identity_status`, `_payment_status`, `_finish_later` and `_resume`. Each one:
  - checks in the database that the caller is the active owner of **that** business;
  - needs `aal2` from step 3 on;
  - is idempotent (`changed: false` on a repeat);
  - is audited with before and after (DB-13).
- **Step 2:** checked from `auth.users` and `auth.mfa_factors` plus the session's `aal`, never from the client.
- **Step 3:**
  - Looks right, or Change with a note. The note reaches the admin as a platform alert and in the overview.
  - A section that changes after Looks right asks again (a fingerprint of what the owner confirmed).
- **Step 4 (manual upload):** reuses `business_verification_documents` and the admin Verification queue.
  - Statuses: Documents needed, Checking, Verified, Try again, In review.
  - A trigger counts a rejected required document as a failed check on step 4.
  - After 2 failed checks it goes to manual review, with an admin alert that resolves when identity passes.
  - The owner can't pass until it is verified.
- **Step 5:** the plan comes from `business_plans` (no estimate or margins are shown). The owner can accept only the current version.
- **Step 6:** waits. Payment is `locked` until identity is verified, then `waiting`, and `confirmed` only with a provider confirmed payment record.
- **Admin calls:** `zella_admin_onboarding_overview()` and `_progress(id)` (`businesses.view`) and `_change_done` (`businesses.manage`, audited). The fields BIZ-12 can show on the business page are in contract section 6. `BusinessDetails.jsx` is not edited.
- **Go live gate (REQ-LC-14):**
  - `zella_activation_report` adds two checks: "Owner identity verified" and "First payment confirmed".
  - `zella_request_activation` checks both again itself and locks the business row while it does.
  - Both functions are archived first and changed only if they match production's fingerprint, the one read from `zprod3`. Every earlier check stays.

**Why database functions rather than an edge function for the owner steps:** the rules belong in the database (NN-6). The owner's own session reaches them directly with the real row security and grants, and `owner-provision-business` refuses anyone who is not a Zella Voice admin. Only the document upload needs the server key, so it is the one edge function.

**Edge functions**
- **`owner-onboarding`:** the identity document upload for step 4.
  - It first asks `zella_owner_identity_upload_check` with the owner's own token.
  - It signs an upload path it chooses in the private `business-documents` bucket.
  - On confirm, it checks the stored file and records it with the owner id the database returned, never one from the request.
- **`identity-webhook`:** a provider neutral receiver, with Persona described and nothing called.
  - HMAC SHA256 over the raw bytes plus the timestamp, checked before anything is parsed, within 5 minutes.
  - Each event is processed once.
  - Off by default: it needs `IDENTITY_WEBHOOK_ENABLED=true`, `IDENTITY_WEBHOOK_SECRET`, and the database rule naming the provider. Today the rule is `none`.

**Local stand in:** `tests/browser/local-backend.mjs` now signs uploads and lists files for private, server only buckets (`business-documents`). This is additive.

## Defaults taken (the owner's four open decisions)

They are one server constant, `zella_onboarding_rules()`, so changing one is a one line migration:

| Decision | Default | Setting |
|---|---|---|
| Identity | Manual upload, checked by Zella Voice in Verification; the receiver is ready for Persona and off | `identity_provider: "none"` |
| Plan | Accept only | `plan_choice: "accept_only"` |
| First payment | Pay before going live | `first_payment: "pay_before_live"` |
| Failed check | Retry, then manual review after 2 failed checks | `failed_check: "retry_then_review"`, `identity_attempts: 2` |

## Not built

- Persona live: no inquiry is created and there are no keys. The receiver is tested with fake secrets only.
- Stripe Checkout and the payment webhook: step 6 always shows waiting, and `checkout_available` is false.
- The saved card trial: if the rule is switched to it, nothing counts as confirmed.
- The owner screens (another job) and the business page field (BIZ-12, another job).

## Deploy order (each step needs the owner's approval; nothing here was applied or deployed)

1. Apply `sql/zella_owner_onboarding.sql`. It refuses with `VERSION_MISMATCH` if either activation function differs from production's.
   - Effect: a business that isn't live yet can't go live until its owner's identity is verified and a provider confirmed payment exists. Stripe isn't built yet.
   - Live businesses stay live.
2. Deploy `owner-onboarding` and `identity-webhook`. Their `config.toml` entries keep `verify_jwt = false`, because each checks its own proof. Set no webhook variables, so the webhook stays off.
3. Deploy the onboarding screens.

Rollback: `sql/rollback/zella_owner_onboarding_rollback.sql`.
- It restores both functions exactly, and refuses with `ROLLBACK_DRIFT` if they changed.
- It keeps every onboarding row in `zella_owner_onboarding_archive` (server only).
- It doesn't touch documents, plans or payments.

## Tests

All of these ran locally on the isolated database or the local stand in. None ran on staging or with a real provider.

| Kind | Command | Result |
|---|---|---|
| Database, isolated copy of production (`zprod3`) | `tests/owner_onboarding/run.sh` | 141 checks, all passed |
| Database, after the merged migrations that are built but not applied (writing cleanup, admin permissions, admin MFA, support notes, status honest, scheduled cancellations) | `DB=zonb_test_stack TEMPLATE=zonb_stack tests/owner_onboarding/run.sh` | all passed |
| Deno, `owner-onboarding`: authorization (another business's owner, staff, a session without the code, anonymous, the server key or publishable key as a token), input, paths, CORS, failures | `cd web/supabase/functions/owner-onboarding && deno test --no-lock -A .` | 22 passed |
| Deno, `identity-webhook`: signatures with fake secrets (wrong secret, changed body, stale, replay, rotation, malformed), off by default, once per event | `cd web/supabase/functions/identity-webhook && deno test --no-lock -A .` | 10 passed |
| End to end on the local stand in with the real function code. The admin rejects and approves documents in Verification through `owner-provision-business`, and saves the plan with `zella_admin_plan_save` | `node tests/owner_onboarding/e2e.mjs` | 52 checks, all passed |
| Type check of every edge function | `web/supabase/functions/check.sh` | all ok |
| No dashes in text people read | `node web/scripts/check-dashes.mjs --root web/supabase/functions/owner-onboarding` (and `identity-webhook`) | 0 found |
| Harness safety | `node --test tests/browser/harness-safety.test.cjs tests/browser/glitch-proxy.test.cjs` | 8 passed |

The database suite covers:
- who may call: another business's owner, staff, a business admin, a Zella Voice admin on owner calls, an admin without the permission, and anonymous are all refused;
- grants and row security;
- step order and idempotency;
- an audit record with before and after for every write;
- step 2 read from the auth records;
- stale section answers;
- the identity path (needed, checking, try again, in review, then verified by an admin), with its alerts;
- the plan version;
- the payment rules (pending payments and payments without a provider don't count);
- the go live gate in both functions;
- a suspended business;
- the provider event (off, applied, duplicate, unmapped, ignored);
- the version guard, apply twice, rollback twice, the archive, reapply after rollback, and rollback drift.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
