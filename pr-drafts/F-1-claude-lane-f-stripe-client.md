Payments: one Stripe client with a pinned version and idempotency keys, and a local fake Stripe for tests
base: main

## What and why
Lane F, step 1 of the Stripe integration built switched off (owner: "complete everything, once Stripe is made we can just add the webhook"). `docs/PAYMENTS_ARCHITECTURE.md` §16.2, §8.1.

- `web/supabase/functions/_shared/stripe.ts`: the only Stripe client. Server side, plain `fetch`, form encoded, `Stripe-Version` pinned (`STRIPE_API_VERSION`), 10 s timeout, an `Idempotency-Key` required on every POST (printable ASCII, at most 255), errors classified for the outbox (429, 5xx, network and timeout retry the same request; `idempotency_error` is held), live mode read from the key prefix (`sk_live_`/`rk_live_`). The base URL is injectable for tests.
- Webhook signature helpers moved here (`verifyStripeSignature`, every `v1` in constant time, `t` within 5 minutes, one `t` only, `v0` never trusted, two secrets during a planned rotation) plus `signStripePayload` for tests.
- Field access that works on the pinned invoice shape and the older one (`parent.subscription_details.subscription` vs `subscription`, `payments` vs `payment_intent`, subscription item periods).
- `tests/stripe_fake/fake_stripe.ts`: an in-memory Stripe for tests only: customers, products, prices, Checkout Sessions, subscriptions (update, cancel at period end, upgrade with `pending_if_incomplete`, delete), schedules, invoices (draft, finalize, pay, void, preview, lines), invoice items, PaymentIntents, refunds, disputes, portal sessions, events; Stripe style idempotency (same key and body replay, other body is `idempotency_error`); refuses live keys; signs and delivers events (or tampers, replays, reorders them).

No SQL, no deploy, no secrets. Nothing reaches api.stripe.com: the client test fails if any request goes anywhere but 127.0.0.1.

## Defaults taken (owner can change)
- `STRIPE_API_VERSION = "2025-09-30.clover"`. **Confirm in the Stripe sandbox** that this is the version the account and webhook endpoints are pinned to.

## Deploy order
Nothing to deploy on its own; the edge functions of the next branches import it.

## Tests (automated, local)
- `deno test --no-lock --allow-net=127.0.0.1 web/supabase/functions/_shared/stripe_test.ts`: 7 passed (form encoding, key mode, idempotency key required, error classes incl. timeout, signatures: valid, tampered, wrong secret, old, future, missing t, two t, v0, several v1, rotation; both invoice shapes; against the fake: replay, idempotency conflict, checkout events, refund cap, live key refused).
- `deno check` on the client and the fake: clean. `npm run lint`: 0 errors, 0 dashes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
