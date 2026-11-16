Payments: invoices from Stripe invoice events, and the admin Payments panel on Plans & subscriptions
base: claude/lane-f-cancel

## What and why
Lane F, step 9: an invoices record filled from Stripe invoice events, and an admin view (`docs/PAYMENTS_ARCHITECTURE.md` §4, §6.11, §16.5).

- `sql/zella_stripe_invoices.sql` (functions only; `billing_invoices` was made in step 2):
  - `invoice.created`, `invoice.finalized`: the fetched invoice is recorded (number, status, totals in cents, lines, hosted page and PDF links), status forward only; an unlinked subscription's invoice waits; another customer's is quarantined.
  - `invoice.voided`: recorded as void; a void fetched as paid changes nothing.
  - `invoice.deleted`: acts only when our row is a draft and the event says draft; otherwise held for a person (§16.5).
  - `zella_admin_invoices` (`billing.view`) and `zella_owner_invoices` (the business's active owner only).
- `web/src/admin/BillingRecords.jsx` + `billingRecords.js`: a Payments panel with three tabs: Invoices (status filter, link to Stripe's hosted page), Refunds (status filter; the Zella Voice owner's Approve / Decline with a reason, checked again in the database) and Disputes (from step 10; says "appear once set up" while the function is missing). **Lane C owns `PlansPage.jsx`: this adds only one import line and one `<BillingRecords />` line.**

## Defaults taken (owner can change)
- Draft and deleted invoices are hidden from owners; deleted ones from admins.

## Deploy order
After step 8: the SQL, then the web app. **Production md5s to be confirmed by the supervisor before apply.**

## Tests
Automated, local:
- `tests/stripe_invoices/run.sh`: 22 passed (before: nothing recorded; apply, apply again, rollback twice, apply again, drift refused both ways; created draft; finalized open with number, link, cents; no going back; void of a paid invoice ignored; void recorded; our deleted draft; deleted paid held; foreign invoice quarantined; billing.view admin reads, support admin refused; owner reads own issued invoices; other owner and anonymous refused; table closed).
- `node --test web/tests/billingRecords.test.mjs`: 2 passed. `npm run lint` 0 errors, 0 dashes; `npx vite build` clean.

Local browser (`tests/browser/stripe-admin-payments.cjs`, local stand in on a seeded isolated database, deviceScaleFactor 1): 12 passed at 1440x900 and 390 wide (invoices with $898.00 from cents, no page horizontal scroll, the refund waiting for approval, disputes not set up yet without an error, no page errors, nothing left the machine). Screenshots:
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f8-payments-invoices-1440.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f8-payments-invoices-390.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f8-payments-refunds-1440.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f8-payments-refunds-390.png

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
