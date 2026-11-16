Payments: Stripe Checkout and the saved card trial for onboarding step 6; the go live gate needs a bound payment
base: claude/lane-f-webhook

## What and why
Lane F, step 3: `docs/PAYMENTS_ARCHITECTURE.md` §6.1 and §6.2, owner onboarding screen 6. **Stacked on PR #92 (`claude/owner-onboarding-backend`) and PR #90 (`claude/owner-onboarding-screens`), both merged into this branch: merge #92 and #90 first**, then this diff is only lane F's (about 900 lines with docs, BACKEND_SCHEMA.md excluded).

- `sql/zella_stripe_checkout.sql`
  - `billing_checkouts` (server only; one open per business).
  - `zella_owner_billing_checkout_start(business, idempotency key)`: the active owner of that business, with a code verified session (`zella_onboarding_authorize`), on step 6, with the current plan version accepted. The amount is computed from `business_plans` only (price + setup fee; $0 for the saved card trial). A double click (same key) and a second tab (another key) get the same Checkout. Audited.
  - The outbox chain, one stored command each: customer `customer:<business>`, product `product:<business>`, plan Price `price:<plan version>`, setup fee Price `price:<plan version>:setup`, session `checkout:<checkout id>`. `zella_stripe_after_<kind>` links each Stripe id to the business (our own map) and queues the next.
  - `checkout.session.completed`: only our stored session, our customer; links the subscription (and wakes events that were waiting for it).
  - `zella_stripe_grant_subscription_create`: the first `invoice.paid` must equal our amount exactly and every line must be one of our prices for that plan version; then the subscription is active for Stripe's period and the period's balances are granted (`zella_billing_open_period`). Trial: a $0 invoice starts the trial with Stripe's dates; the setup fee is queued as a pending invoice item on the first paid invoice (REQ-BIL-12).
  - Replaces three functions of `zella_owner_onboarding.sql` (archived first, guard accepts only that file's version): `zella_onboarding_rules` (`first_payment` stays `pay_before_live`; `payments_connected` = `payments_live`), `zella_onboarding_payment_confirmed_at` (**only a payment bound to our Checkout counts**; before, any succeeded payments row with a provider passed the go live gate), `zella_onboarding_payment` (`checkout_available`, `checkout`, `due_now_minor`, reasons `checkout_open`/`processing`).
- `billing-api` (new edge function): `checkout_start` runs the owner's function with the owner's own token, then sends the queued commands at once with the server key and returns the Checkout URL; `checkout_return` runs the same event step as the worker (the return is never trusted) and returns the payment state. The browser's amount, if any, is ignored.
- Screens (`web/src/onboarding/`): the Pay screen shows "Ready to pay" with the amount from the server, "Pay securely" (or "Add a card and start my trial") opens Checkout, the return shows "Confirming your payment" and polls every 5 s until the server says confirmed; cancelling says nothing was charged. `api.js` gets `startCheckout`/`checkoutReturn`; the stand in has a `pay` scenario.
- `docs/OWNER_ONBOARDING_CONTRACT.md` version 3 (additive).

## Defaults taken (owner can change)
- First payment rule stays `pay_before_live` (`zella_onboarding_rules()`); `trial_with_card` is built and tested.
- Trial setup fee: charged with the first paid invoice (trial end), not at the start (REQ-BIL-12 says nothing is charged until the trial ends). **Confirm in the Stripe sandbox** that a pending invoice item with `subscription` lands on the trial end invoice.
- Checkout return URL: `<app_base_url>/welcome/setup?business=<id>&checkout=return&session_id={CHECKOUT_SESSION_ID}`; `app_base_url` must be an https setting (APP_URL_MISSING otherwise).
- **Confirm in the Stripe sandbox:** that one time Prices in a subscription mode Checkout go on the first invoice as separate lines with their own price ids, and that `expires_at` is set on new sessions.

## Deploy order (each needs the owner's approval)
1. PR #92's SQL, `zella_stripe_pipeline.sql`, then `zella_stripe_checkout.sql`. 2. `billing-api`. 3. The web app. Nothing can be paid until `zella_payments_switch(true, ...)`.

**Production md5s to be confirmed by the supervisor before apply** (the three replaced functions' "before" md5s are those `zella_owner_onboarding.sql` makes on zprod3 + writing cleanup + merged migrations).

## Tests
Automated, local:
- `tests/stripe_checkout/run.sh`: 49 passed. Before: payments "not connected", and an unbound payments row passed the gate. Apply, apply again, rollback twice, apply again, drift refused both ways; anonymous, another business's owner, a team member, an aal1 session, payments off and the wrong step all refused; amount from the plan; double click and second tab; audit once; only the server queues commands; the chain and its keys; session body uses only our prices and customer; Checkout link; foreign session quarantined; processing on return; wrong amount and foreign price quarantined with nothing granted; bound payment: active for Stripe's period, balances granted, one bound payment, balanced ledger, gate passes, step 6 completes; a replayed event grants nothing; trial: $0, 5 days, plan only on the session, Stripe's trial end, 20/5/5 balances, setup fee queued for the first paid invoice, confirmed under `trial_with_card`; rollback refuses with data.
- End to end, `tests/stripe_pipeline/flow.sh tests/stripe_checkout/flow_test.ts zella_owner_onboarding zella_stripe_checkout`: plan saved, owner (own token) starts Checkout through `billing-api`, the fake Stripe receives customer, product, two prices and the session with their keys, completes it, signs the events, `billing-webhook` stores them, `checkout_return` applies them: payment confirmed, subscription active, the go live gate's payment check passes, one bound payment of 89800; other owner, aal1 and anonymous refused; a redelivery of every event changes nothing. 2 passed.
- `node --test web/tests/ownerOnboarding.test.mjs`: 19 passed (2 new). `deno check` all functions (`check.sh`), `npm run lint` 0 errors and 0 dashes, `npx vite build` clean.

Local browser (stand in api, scenario `pay`, deviceScaleFactor 1), `tests/browser/stripe-pay-screen.cjs`: 12 passed at 1440x900 and 390 wide (Ready to pay with $898, no horizontal scroll, back from Stripe shows Payment received, address bar tidied, no page errors, nothing left the machine). The existing `tests/browser/owner-onboarding-journey.cjs`: 61 passed, 0 failed. Screenshots:
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f3-pay-ready-1440.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f3-pay-ready-390.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f3-pay-confirmed-1440.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f3-pay-confirmed-390.png

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
