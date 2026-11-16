Payments: the Stripe webhook only stores events; the worker fetches, binds and applies them in order (C-1 to C-8)
base: claude/lane-f-stripe-client

## What and why
Lane F, step 2. Rebuilds `billing-webhook` to `docs/PAYMENTS_ARCHITECTURE.md` §6.0a, §6.0b and §8, closing gaps C-1 to C-8 of §17. Everything stays off.

- **`billing-webhook`** (rewritten): checks `Stripe-Signature` (HMAC SHA256 over `<t>.<raw body>`, every `v1`, constant time, 5 minute tolerance; `STRIPE_WEBHOOK_SECRET_PREVIOUS` only during a planned rotation), a 500 KB byte limit, strict UTF-8, and that the event's `livemode` matches the key's mode. It only stores the event (`zella_stripe_event_store`): repeated ids and unknown types are 200, a wrong mode is 400 and stores nothing. 503 while `STRIPE_WEBHOOK_SECRET` or `STRIPE_SECRET_KEY` is unset. The old `logic.ts` mapping (grants from the payload) is removed.
- **`billing-worker`** (new, `_shared/billingWorker.ts`): called every minute by the `zella_billing_worker` job (created off) with a Vault secret the database checks. Sends the outbox (stored body and key; 429/5xx/timeout wait and resend the same bytes; other refusals held) and applies events: claims them oldest first per subscription, **fetches each object from Stripe** and hands the fetched object to the database.
- **`sql/zella_stripe_pipeline.sql`**: tables `billing_stripe_links` (our own map from Stripe ids to businesses), `billing_outbox`, `billing_quarantine`, `billing_invoices`, `money_ledger` + `ledger_operation_keys` (double entry, integer cents, each operation once); `billing_events` gains `pipeline`, `livemode`, `object_type`, `object_id`, `ordering_key`, `payload` (a few ids only). `zella_stripe_apply_event` dispatches to one handler per event type (`zella_stripe_on_<type>`) and `invoice.paid` to one grant per billing reason (`zella_stripe_grant_<reason>`), so later branches add handlers without replacing this file's functions. `BINDING:` errors quarantine (nothing kept, 200 to Stripe, urgent alert), `WAITING:` keeps the event for its parent (C-5).
  - C-1: grants only in the worker, on the fetched object. C-2: all §16.5 events stored; handlers per type. C-3: subscription events record state only, never a period or an active status. C-4: `zella_stripe_bind_invoice` (our links, the business's customer, `usd`, fully paid, mode). C-6: per business links, never the old `plans` slug. C-7: outbox, ledger, quarantine, links. C-8: every refund recorded and audited; one outside Zella Voice alerted.
  - A subscription never moves backwards: `zella_subscription_transition_ok` (§7) and events older than the last applied one are recorded only. Three statuses added to the check: `pending_payment`, `paused_nonpayment`, `suspended_dispute`.
  - **`zella_reconcile_billing_events` (live job) keeps its exact body** (md5 `9f59ce3f06d391759dce9a17ff5fef77`, checked in the test); new rows never take `pending`/`failed`, so it never sees them. `zella_process_billing_event` and `zella_apply_billing_event` are untouched.
- `zella_payments_switch(on, worker url)`: the owner's switch (setting `payments_live`, worker address, job on/off), audited.

**Size:** about 1300 hand written lines (BACKEND_SCHEMA.md excluded), above the 800 guide: the pipeline, its two functions and its tests are one unit (none works or can be tested without the others).

## Defaults taken (owner can change)
- An event waiting for its parent doesn't hold back later events of the same subscription (needed because `checkout.session.completed` links the subscription its `invoice.paid` needs).
- Unresolved after 7 days: quarantined with an alert. Outbox: up to 8 tries with back off; a lost reply is resent with the same key within 23 hours, then held.
- **Confirm in the Stripe sandbox:** whether events of a non Connect account carry `account` (not checked; fetch before grant with our key binds the account instead); that `invoice.deleted` objects can't be retrieved (the handler checks our own row).

## Deploy order (each needs the owner's approval)
1. `sql/zella_stripe_pipeline.sql` (after `zella_billing_hardening.sql` and `zella_billing_allowances.sql`, both applied). 2. `billing-webhook` and `billing-worker` (verify_jwt off, in config.toml). Nothing runs until `zella_payments_switch(true, ...)`.

**Production md5s to be confirmed by the supervisor before apply.** md5s here were computed on zprod3 + writing cleanup + the merged unapplied migrations.

## Tests (automated, local)
- `tests/stripe_pipeline/run.sh`: 47 passed (before: a status alone made a past due subscription active, C-3; apply, apply again, rollback twice, apply again, drift refused both ways; reconcile body unchanged and never touches new rows; mode mismatch, unknown and malformed events; store once; nothing claimed while off; oldest first per subscription; waiting; C-3 after; past due; older event recorded only; quarantine for object mismatch, wrong customer, wrong currency, unhandled reason; nothing recorded from quarantine; ledger unbalanced, float and twice; outbox conflict, claim once, retry keeps key, lapsed lease, idempotency conflict held; anon and authenticated refused; switch; rollback refuses with data).
- `tests/stripe_pipeline/flow.sh`: the local fake Stripe signs events, the real webhook handler stores them through `tests/browser/local-backend.mjs`, the worker fetches from the fake and applies: tampered, stale and wrong secret refused before storing; reversed delivery and redelivery stored once; unlinked waits; linked applies; unhandled first payment quarantined with nothing granted.
- `deno test --allow-env billing-webhook/handle_test.ts`: 7 passed (off without secrets, valid, tampered, wrong secret, replayed old, missing, rotation, live key, result mapping, byte limit, bad JSON, bad UTF-8). `deno check` both functions; `npm run lint` 0 errors, 0 dashes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
