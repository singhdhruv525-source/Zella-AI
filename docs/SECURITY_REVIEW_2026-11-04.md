# Security review, 2026-11-04

What was checked, what was fixed, what was tested, and what is still open. Nothing here is deployed: every
database and function change is in the repo only and needs the owner's approval to go live (order at the end).

Live checks were **read-only** SQL against the Supabase project. Tests ran on an **isolated Postgres 16** restored
from the schema baseline (no customer data) and with **mocked** providers. No email, text or call was sent.

## Findings

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | High | **Invitation cancel race.** `staff-invite` wrote `sent`/`failed` with an unconditional update, so a cancel during sending was overwritten and the invitation reopened. Reproduced on the isolated DB. | Fixed |
| 2 | High | **Email ownership trusted from `last_sign_in_at`.** Staff invites were tied to whatever account had that email, and acceptance worked from any session (password, OAuth). With email confirmation off, someone who registers an address first gets the seat. | Fixed |
| 2b | High | **Owner seats: same flaw.** `zella_accept_my_invitations` activated every `invited` owner membership for any session, with no expiry or email check. 0 waiting owner seats live today. | Fixed |
| 2c | Medium | **Platform-admin invites** granted admin straight to an existing account that had signed in, without a confirmed email (`owner-provision-business`, `adminInvite`). | Fixed |
| 3 | High | **Billing events dropped.** An event for a subscription not linked yet was marked handled and never applied. Nothing ordered events by time, and a failure left nothing to retry. | Fixed |
| 4 | High | **Currency.** Amounts were divided by 100 for every currency (JPY ×100 off, KWD wrong). `payments.amount` was `numeric(10,2)`, which also truncates 3-decimal currencies. | Fixed |
| 5 | Medium | **Navigation crash.** `segments()` threw on malformed encoding (`/app/%`), blanking the app. There was no error boundary. | Fixed |
| 6 | High (latent) | **MFA bypass through the API.** An aal1 session of a user with a verified factor could call tables and RPCs directly. `is_platform_admin()` and the membership checks ignore `aal`. 0 verified factors live, so not exploitable today. | Fixed |
| 7 | Medium | **Invitation errors hidden after sign-in.** Failures only reached the console. | Fixed |
| 8a | Info | **Schema not reproducible.** | Baseline captured, clean restore verified |
| 8b | Low | `businesses.inbound_email_token` is readable by every member, staff and viewer included. It is the local part of the business's own inbound address. Delivering mail into a business also needs the webhook key in Vault, and the address functions are service-role only. | Reported |
| 8c | Medium (product decision) | Call transcripts and `recording_url` are readable by every member role, staff and viewer included (already open as M-4). Signed-in users have no INSERT or UPDATE grant on `calls`. | Needs owner decision |
| 8d | Info | Every SECURITY DEFINER function in `public` has a fixed `search_path`. No definer function is executable by PUBLIC. 4 are executable by anon, all intended: public info, status, and two unsubscribe functions. All 131 tables have RLS. The private documents bucket has no policies, so it is service-role only. | OK |
| L-2 | Low | `staff-invite` checked configuration before the caller's sign-in. | Fixed |

## Fixes

### Invitations (1, 2, 2b, 2c, 7)

**`sql/zella_invitation_hardening.sql`**
- `zella_staff_invite_finalize` locks the invitation row. It moves the invitation to `sent` only from an open state, and only if all of these hold:
  - the inviter is still an owner or admin, and an admin is not inviting an admin;
  - the invitation hasn't expired;
  - the business is open;
  - the account's email matches the invitation;
  - the person isn't already a member.
- `zella_staff_invite_fail` cannot reopen a closed invitation.
- Acceptance (`zella_accept_staff_invitations_v2`) needs a session signed in through an email link (JWT `amr`: otp, magiclink, invite, recovery, signup, email_change). It returns accepted, waiting, expired and per-invitation errors. Removed members come back with the invited role.
- `zella_accept_my_invitations` (owner seats) needs the same proof and an open, unexpired owner invitation at the account's current address.

**`staff-invite` edge function**
- The decisions moved to `logic.ts`. It pre-checks before sending, then sends an invite for a new account or a sign-in link for an existing one, then finalizes atomically.
- Finalize codes map to 403/404/409. Send errors are recorded through `fail()`.

**`owner-provision-business`**
- `adminInvite` refuses an existing account whose email was never confirmed.

**Web app**
- `acceptInvitations()` returns a status.
- A banner on the workspace and on the "no workspace" screen offers "Email me a sign-in link" or "Try again". Existing workspaces keep working.
- If the database is older and has no `_v2`, the app falls back to the old function.

### Billing (3, 4)

**`sql/zella_billing_hardening.sql`**
- **Durable events.**
  - An event that can't be matched yet is kept as `pending`.
  - It is applied when the subscription is linked (trigger) or on redelivery.
  - Failures are kept as `failed` with backoff.
  - `zella_reconcile_billing_events` retries due events and closes ones unmatched after 7 days, with an alert.
- **Ordering.** `subscriptions.billing_event_at`: an older event never overrides a newer one. Payments only move forward.
- **Idempotency.**
  - The event id is unique. A redelivery re-applies only a pending or failed event.
  - Payments are unique per (provider, external payment id).
  - A concurrency test confirmed this.
- **Refunds and disputes.**
  - Full and partial refunds are recorded separately. A dispute opened is not counted as a refund; a lost dispute reverses the payment, a won one clears it.
  - A refund that arrives before its payment waits.
- **Money.**
  - Amounts are integer minor units with the currency's exponent: 0 for zero-decimal currencies, 3 for BHD/JOD/KWD/OMR/TND, 2 otherwise.
  - `payments.amount` becomes unconstrained `numeric`, and `amount_minor` is added.
  - Unsupported or negative amounts are refused, with an alert.

**`billing-webhook` edge function**
- The logic moved to `logic.ts`: signature check (300 s window, constant-time compare, rotation), event mapping in minor units, HTTP status.
- Invalid events return 422. A failed processing run returns 500, so the provider retries.

### MFA (6): `sql/zella_mfa_enforcement.sql`
- `zella_pre_request()` runs as PostgREST `db_pre_request` on every API request. It refuses an aal1 session of a user with a verified factor (`MFA_REQUIRED`).
- A RESTRICTIVE policy `zella_mfa_required` on every RLS table and on `storage.objects` covers Realtime and Storage.
- Service role, anonymous visitors and users without a factor are unaffected.

### Navigation (5)
- `segments()` decodes safely.
- Error boundaries:
  - at the root;
  - around each business page (reset on page or business change);
  - around the admin content.
- Unknown addresses show "Page not found". Pages the role can't open show "This page isn't available".

## Tests run (results from this session)

| Suite | Kind | Result |
|---|---|---|
| `tests/security/run.sh`: invitations (10 + 3 concurrency), billing (9 + 1 concurrency), isolation (3 + control), MFA (4). Each migration is also run twice. | Isolated Postgres 16, baseline schema, test data | **ALL PASSED** |
| Isolation: 408 table/view checks across owner, admin, manager, staff, viewer and an outsider. Writes into another business refused. 272 calls to functions that take a business id, made with another business's id: none returned its data or changed it. Positive control: as that business's own owner the same probe sees its data in 3 functions. | Isolated DB | PASS |
| `staff-invite/logic_test.ts` (9), `billing-webhook/logic_test.ts` (8), `voice-rules/logic_test.ts` (19) | Deno, fakes, no network | PASS |
| `tests/browser/security-journeys.cjs` (23): `/app/%` and other malformed addresses, unknown page, `/%`, role-restricted page, business switching, settings direct links + Back/Forward/refresh, in-app Back, unsaved-changes guard (link and Back), crashing page contained and recovered, invitation banner (waiting, problem named, send link, failure + retry, old database fallback) | Playwright, **stubbed backend** | 23/23 PASS |
| `web/src/router.test.mjs` | node:test | PASS |
| n8n suite (`n8n/test.mjs`) | Local | 391 passed. It regenerated two workflow JSONs (`zella-brain-tools`, `zella-appointment-booking`), which were out of date relative to already-committed shared source. I reverted them to keep this change scoped; they still need regenerating. |
| `npm run build` | | Pass |
| `oxlint` | | 0 errors, 182 warnings (176 before; the 6 new ones are fast-refresh/effect warnings) |
| Baseline restore | Isolated DB | 131 tables, 663 functions, 170 policies, 91 triggers, clean |

## Not verified or blocked

- **Not run against live Supabase:** auth settings (whether email confirmation is required, and OTP expiry). These can't be read through SQL and need the dashboard or the Management API. The fixes don't depend on them.
- **Real email links:** the `amr` value Supabase puts on an invite or magic-link session was not seen on a live token; it is taken from Supabase's documented values. Check it on staging before applying the migration. If the value differs, acceptance is refused and the banner offers a link, so it fails closed.
- **Edge functions:** `deno check` fails in this container because of the edge-runtime type file. The old files fail the same way.
- **`owner-provision-business` change:** checked with `deno lint` only. It has no unit test, because the function isn't split into testable logic.
- **Real browser against a real backend:** not done. The browser tests use a stub.
- **Journey review not re-done in this session**, beyond invitations, billing, MFA and navigation:
  - booking, rescheduling, cancellation, waitlist;
  - inbox, callbacks, voice tools, call records;
  - settings and integrations beyond navigation.

  The earlier audits cover them (`ZELLA_END_TO_END_AUDIT.md`), but they were not re-verified here.
- **Hosting:** no host or SPA rewrite config exists in the repo yet. The rewrite must send every path, malformed ones included, to `index.html`. Vite's dev server answers `/app/%` with a 404 itself.
- **Vapi:** call status and end-of-call messages still arrive without auth headers (401). Still open.

## To apply (needs approval, in this order)

1. **Invitations.**
   1. Apply `sql/zella_invitation_hardening.sql`.
   2. Deploy `staff-invite` and `owner-provision-business`.
   3. Deploy the web app.
2. **Billing.**
   1. Apply `sql/zella_billing_hardening.sql`. It alters `payments.amount`; there are 0 live rows.
   2. Deploy `billing-webhook`.
   3. Optionally schedule `zella_reconcile_billing_events` with cron.
3. **MFA.** Apply `sql/zella_mfa_enforcement.sql`. It changes the `authenticator` role config and adds a policy to every table.

   Rollback: `alter role authenticator reset pgrst.db_pre_request;`, then drop the `zella_mfa_required` policies.

Release readiness: **not ready.** The fixes are written and tested in isolation but not deployed. Vapi call events are still refused. Hosting isn't set up. Providers (SMS, billing, email sending) are still off.
