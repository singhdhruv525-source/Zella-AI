Payments: reconciliation with Stripe that never corrects money, and the whole journey tested end to end
base: claude/lane-f-billing-emails

## What and why
Lane F, step 12: `docs/PAYMENTS_ARCHITECTURE.md` §10 and §12, plus the end to end test the lane asked for.

- `sql/zella_stripe_reconcile.sql`
  - `zella_billing_events_cursor`: the worker reads Stripe's Events API from an hour before the newest stored event and stores each event exactly as the webhook does (`zella_stripe_event_store`, repeats ignored), so a webhook that was down for hours loses nothing (§12).
  - `zella_billing_reconcile_objects` (daily, `zella_billing_reconcile_due`): Stripe's invoices, refunds and disputes of the last 7 days against our rows by Stripe id and amount; objects that aren't ours are ignored. `zella_billing_ledger_check`: every operation's lines sum to zero. Each run is logged in `billing_reconcile_runs`; each difference is one urgent alert. **Nothing is ever corrected automatically.**
  - **`zella_reconcile_billing_events`, the live 15 minute job, is not replaced**: the guard refuses to apply unless its body is still production's exact one (md5 `9f59ce3f06d391759dce9a17ff5fef77`), and the tests check it is unchanged after every lane F migration.
- `_shared/billingWorker.ts`: `reconcile()` at the end of each run. The fake Stripe lists disputes and gives subscriptions a default payment method.
- `tests/stripe_e2e/journey_test.ts`: the whole journey through the fake Stripe.

## Defaults taken (owner can change)
- Events catch up window: from an hour before the newest stored event (or 3 days back when there is none). Object check: once a day, last 7 days.

## Deploy order
After step 11. **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_reconcile/run.sh`: 17 passed (before: nothing compares; apply, apply again, rollback twice, apply again, drift refused both ways; the live job's body unchanged; the file refuses if that body ever differs; balanced ledger passes; an unbalanced operation found and alerted; a paid invoice we don't have, a refund never approved and a dispute never recorded found, others' objects ignored; a different paid amount found; one alert, no row corrected; once a day; the events cursor).
- End to end, `tests/stripe_pipeline/flow.sh tests/stripe_e2e/journey_test.ts zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes zella_stripe_emails zella_stripe_reconcile`: passed. Plan saved, Checkout through `billing-api` with the owner's token, signed webhook, payment confirmed, go live gate's payment check passes; a renewal (draft recorded, then paid, period moved); a declined renewal (past due), 5 days later paused (call gate inactive), paid again (active); a pack on the saved card (100 minutes granted); a refund asked by the owner, approved by the Zella Voice owner, sent to the fake and processed; invoice rows; the welcome receipt queued and card notices held (no email sent); nothing quarantined; the ledger balances; reconciliation finds no difference; every POST carried an idempotency key.
- Re-run on this branch: `_shared/stripe_test.ts` + `billingEmails_test.ts` 9 passed, `billing-webhook/handle_test.ts` 7 passed, the pipeline flow 1 passed, the checkout flow 2 passed, `check.sh` all functions ok.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
