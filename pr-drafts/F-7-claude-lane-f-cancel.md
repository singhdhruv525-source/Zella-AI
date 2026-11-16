Payments: cancel and continue synced to Stripe from cancel_at; the latest choice always wins
base: claude/lane-f-refunds

## What and why
Lane F, step 8: `docs/PAYMENTS_ARCHITECTURE.md` §6.10 and the cancel row of §8.1, REQ-BIL-44. Kept in line with the merged scheduled cancellations (PR #84): `businesses.cancel_at` stays the single record of the owner's choice, and the daily job still does the full business cancellation at that time.

- `sql/zella_stripe_cancel.sql`
  - `subscriptions.desired_cancel_at_period_end` and `cancel_version`; an after update trigger on `businesses.cancel_at` (whoever changes it: Settings, the admin, the Continue my plan email link, `zella_owner_continue_plan`) raises the version under the subscription row lock and queues `POST /v1/subscriptions/:id {cancel_at_period_end}` with key `cancel:<sub>:<version>:<attempt>`; any older version still waiting is cancelled, so it is never sent.
  - After each send, and on every `customer.subscription.updated` (fetched), Stripe's value is compared with the latest desired one; if they differ and nothing is waiting, the latest is resent with the next attempt number.
  - A trial is cancelled at once: `DELETE /v1/subscriptions/:id`, key `cancelnow:<sub>` (nothing was paid, §6.2).
  - `zella_stripe_on_customer_subscription_updated` now calls the check (archived first; guard accepts only the packs step's version).
  - `customer.subscription.deleted` (step 2) records the end of the period.

Not built: the final pay as you go invoices after a cancellation (§6.9, part of pay as you go, not built).

## Defaults taken (owner can change)
- A trial cancel ends the Stripe subscription immediately; access ends at `cancel_at` as the scheduled cancellations decide.

## Deploy order
After step 6. **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_cancel/run.sh`: 18 passed. Before: a scheduled cancellation told Stripe nothing. Apply, apply again, rollback twice, apply again, drift refused both ways; cancel (version 1), continue through `zella_owner_continue_plan` (version 2, version 1 never sent), cancel again (only version 3 waits); a click while a send is in flight still queues the newer version after it; an older send that landed last is resent with attempt 2; a disagreeing subscription event resends; agreement sends nothing; period end records the cancellation; a trial is deleted at once; a business without Stripe queues nothing.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
