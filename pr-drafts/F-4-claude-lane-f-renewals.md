Payments: renewals, failed payments and the 5 day pause, from verified Stripe invoices
base: claude/lane-f-checkout

## What and why
Lane F, step 4a: `docs/PAYMENTS_ARCHITECTURE.md` §6.3, REQ-BIL-33. Stripe retries a failed renewal itself (Smart Retries, days 2, 3 and 4 set in the Dashboard); Zella Voice never charges a renewal and only reacts to verified, fetched invoices.

- `sql/zella_stripe_renewals.sql` (functions only, no table change):
  - `zella_stripe_bind_lines`: every line of an invoice is our plan Price for this business at its stored amount (x quantity) or an invoice item we created at its stored amount; the lines add up to the total; the list is complete.
  - `zella_stripe_grant_subscription_cycle`: then the subscription is active for Stripe's new period and the period opens with fresh balances and the 20% rollover (`zella_billing_open_period`, unchanged). An older period's invoice is recorded only. The first charge after a trial is the same reason (plan price + the setup fee item from step 3). During a dispute the saved state moves on and service stays suspended (§7).
  - `invoice.payment_failed`, `invoice.payment_action_required`: past due once (from active or a trial), urgent in app notice; a failure fetched after the invoice was paid changes nothing.
  - `zella_billing_nonpayment_sweep` (the worker runs it every minute): 5 days past due (`billing_rules.pause_after_days`) is `paused_nonpayment`, audited and alerted. The call gate already treats that as inactive, so new calls go to the fallback number **once the owner's separate `usage_enforcement.calls` switch is on**. Paying restores it. 30 days unpaid: an alert for a person; nothing is cancelled or deleted.
  - `customer.subscription.trial_will_end`: the owner's in app reminder. `zella_stripe_after_invoice_item` links our invoice items with their amount.
- `_shared/billingWorker.ts`: the sweep at the end of each run.

## Defaults taken (owner can change)
- Pause after 5 days past due (REQ-BIL-33), as the setting `billing_rules.pause_after_days`.
- 30 days unpaid: alert only; no automatic cancellation (a person decides).
- **Confirm in the Stripe sandbox:** the Dashboard retry schedule (days 2, 3, 4) and "leave past due" after the last retry; that the first invoice after a trial has `billing_reason` `subscription_cycle`.

## Deploy order
After step 3: `sql/zella_stripe_renewals.sql`, then `billing-worker` (the sweep call is skipped if the function is missing). **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_renewals/run.sh`: 29 passed. Before: a renewal was quarantined (no grant). Apply, apply again, rollback twice, apply again, drift refused both ways; a foreign line, our price at another amount and a partly paid renewal quarantined; a bound renewal moves the period and grants 500 minutes plus a 100 minute rollover (20%, 150 unused); an older invoice never moves it back; failed renewal past due with the notice; failure after paid changes nothing; the sweep waits while payments are off, pauses at 5 days once, the call gate reads inactive, paying restores; 30 days alerts without cancelling; payment action needed notice; our setup fee item linked; the trial end invoice (plan + fee) activates; trial reminder; signed in users can't run the sweep.
- `tests/stripe_pipeline/flow.sh tests/stripe_checkout/flow_test.ts ... zella_stripe_renewals`: 2 passed. `check.sh` all functions ok.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
