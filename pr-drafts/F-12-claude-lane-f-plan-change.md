Payments: upgrade at Stripe's previewed amount once paid, downgrade at the period end
base: claude/lane-f-reconcile

## What and why
Lane F, step 5: `docs/PAYMENTS_ARCHITECTURE.md` §6.6, REQ-BIL-30. Plans stay set by Zella Voice (rule `plan_choice` "accept_only"): an admin saves the new `business_plans` version as today, then starts the change; the owner confirms an upgrade after seeing Stripe's amount.

- `sql/zella_stripe_plan_change.sql`
  - `billing_plan_changes` (server only, one open per subscription).
  - `zella_admin_plan_change_start(business, version, reason)`: `billing.manage`, a reason, audited; refuses a monthly/yearly switch (`INTERVAL_CHANGE_NOT_BUILT`).
  - Upgrade: the version's Price (`price:<version>`), then `POST /v1/invoices/create_preview` for our subscription item and the new Price with one stored `proration_date` T (valid 15 minutes); `zella_owner_plan_change` shows the owner Stripe's amount; `zella_owner_plan_change_confirm` (active owner, code verified session) queues `POST /v1/subscriptions/:id` with the new Price, `always_invoice`, the **same** T and `pending_if_incomplete` (key `upgrade:<change id>`). `invoice.paid` with `subscription_update`: the paid total must equal the preview and every line must be this business's old or new Price, else quarantined; then the change is applied and the prorated extra allowance for the rest of the period is added (rounded down).
  - Downgrade: `POST /v1/subscription_schedules {from_subscription}` then the phases (this period at the current Price, then the lower Price), keys `downgrade:<id>` and `downgrade:<id>:phases`; nothing is credited or refunded now.
  - The subscription handler also records Stripe's item id and Price (archived first; guard accepts only step 8's version).

Not built: the owner's confirm screen in the CRM (functions exist), a failed or abandoned upgrade marked failed from Stripe's expired pending update (it stays confirmed until a person looks; the plan is unchanged because Stripe applies nothing unpaid), switching between monthly and yearly.

## Defaults taken (owner can change)
- The admin starts every change; the owner confirms upgrades only. **Confirm in the Stripe sandbox:** that `create_preview` returns an invoice with an id, that `proration_date` is accepted with `pending_if_incomplete`, the proration lines' shape (one or two lines, both with our Prices), and the schedule phase parameters.

## Deploy order
After step 12. **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_plan_change/run.sh`: 21 passed (before: an upgrade invoice quarantined; apply, apply again, rollback twice, apply again, drift refused both ways; read only admin and business owner can't start; reason required; the Price first; one open change; the preview body (our item, the new Price, always_invoice); the owner sees Stripe's amount; an expired preview refused; paid at another amount and a foreign price quarantined with nothing applied; paid at the preview applied; rollback refuses with data).
- End to end through the fake Stripe, `tests/stripe_pipeline/flow.sh tests/stripe_plan_change/flow_test.ts <all lane F migrations>`: 2 passed (Checkout, admin starts (a read only admin refused), preview, another owner refused, owner confirms, the update carries the preview's proration time and `pending_if_incomplete`, invoice paid at the preview, change applied, minutes increased; downgrade scheduled with two phases; nothing quarantined; the ledger balances).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
