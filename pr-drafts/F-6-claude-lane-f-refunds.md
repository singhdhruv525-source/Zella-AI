Payments: refund requests with server side eligibility, approved only by the Zella Voice owner
base: claude/lane-f-packs

## What and why
Lane F, step 6: `docs/PAYMENTS_ARCHITECTURE.md` §6.7, REQ-BIL-38 to REQ-BIL-45, and the rest of gap C-8.

- `sql/zella_stripe_refunds.sql`
  - `billing_refunds` (server only): requested, sending, processed, failed, rejected; kinds guarantee, setup_fee, pack, annual, error, outside.
  - `zella_refund_options(business)`: eligibility decided by the database only: the 30 day guarantee on the **plan fee** of the first payment, once per business ever (REQ-BIL-38, 41); the setup fee within 48 hours (REQ-BIL-39); an unused pack within 14 days (REQ-BIL-40); a yearly renewal within 7 days (REQ-BIL-42). Each with a reason code.
  - `zella_owner_refund_request`: active owner, code verified session; the payment row is locked and eligibility re-checked in the same transaction; the amount is reserved (requested, approved, sending, uncertain and processed together never exceed the capture). Audited, alert for the owner of Zella Voice.
  - `zella_admin_refund_decide`: **only the Zella Voice owner** (`zella_admin_role() = 'zella_owner'` and `billing.manage`; a billing admin can read but not approve), a reason, re-checked at approval, one Stripe refund `refund:<id>` through the outbox. `zella_admin_refund_raise` for duplicate or wrong charges (REQ-BIL-43). `zella_admin_refunds` lists them (`billing.view`).
  - `refund.created`, `refund.updated`, `refund.failed` (fetched): ours must match the approved amount and payment (else quarantined); processed once with ledger `refund:<stripe id>`, the payment marked refunded when fully refunded, a refunded pack's balance closed. A refund made in the Stripe Dashboard is recorded against its payment as `outside`, audited and alerted urgently (C-8).
- `billing-api`: `refund_options`, `refund_request`.

Not in this branch: the owner's Refund button on the CRM Billing page and the admin approval screen (functions and API exist).

## Defaults taken (owner can change)
- "Onboarding work started" for the setup fee (REQ-BIL-39) is read as 48 hours after the first payment.
- Approval is the Zella Voice owner's role only, not super admin.
- Prolonged service failure prorated refunds (REQ-BIL-42, owner's discretion) go through `zella_admin_refund_raise`.

## Deploy order
After step 5: the SQL, then `billing-api`. **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_refunds/run.sh`: 31 passed. Before: no refund request. Apply, apply again, rollback twice, apply again, drift refused both ways; options within 48 hours (plan fee 29900, setup fee 59900); after 48 hours setup fee not refundable; another owner, aal1, anonymous refused; an ineligible option refused; **two concurrent requests reserve once**; one guarantee per business; a billing admin can't approve but can see; reason required; approval after 30 days refused; owner approves, twice changes nothing; one refund queued with key and amount; audited; wrong amount quarantined; processed and posted once, balanced; Dashboard refund recorded, audited, alerted; an error refund can't exceed what is left; rollback refuses with data.
- `deno check` billing-api.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
