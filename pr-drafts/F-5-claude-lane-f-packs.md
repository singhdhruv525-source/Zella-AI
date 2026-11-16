Payments: packs bought by the owner and auto reload on the saved card, one pending reload at a time
base: claude/lane-f-renewals

## What and why
Lane F, step 4b: `docs/PAYMENTS_ARCHITECTURE.md` §6.4, REQ-BIL-23, REQ-BIL-32. Server side only.

- `sql/zella_stripe_packs.sql`
  - `zella_owner_pack_buy(business, pack, key)`: active owner of that business with a code verified session; price only from `billing_pack_catalog`; one purchase per key (another pack with the same key is refused); needs an active plan and a saved card. Audited.
  - Auto reload (`zella_billing_maybe_reload`, from an after insert trigger on `usage_charges`): the owner's settings row is locked, the balance must be at or below their threshold, **one pending reload per business and resource** (partial unique index), and this month's reloads plus the pack must stay within their spend limit (else a notice and an info alert). The trigger catches every error into an alert, so a usage entry (a finished call) is never failed or blocked.
  - One PaymentIntent per purchase on the saved card (`off_session`, `confirm`), key `pack:<purchase id>` or `reload:<purchase id>`; the outbox links it to the purchase.
  - `payment_intent.succeeded` (fetched): our PaymentIntent, exact catalog amount, `usd`, our customer; then the pack balance until the end of the period it was bought in, one bound payment, balanced ledger, a notice. PaymentIntents that pay plan invoices are left to `invoice.paid`. A decline or a bank check fails the purchase and tells the owner; nothing is granted.
  - `zella_stripe_on_customer_subscription_updated` (archived first; guard accepts only step 2's version) also records Stripe's default payment method id (an id, no card details, NN-9).
  - `pack_purchases` (applied in production) is widened only: statuses `pending`, `failed`, `cancelled`; sources `owner_purchase`, `auto_reload`; columns `stripe_payment_intent`, `failure_reason`, `settled_at`. Admin grants are unchanged.
- `billing-api` gains `pack_buy`.

Not in this branch: the buy button and auto reload form on the CRM Billing page (the API exists).

## Defaults taken (owner can change)
- Owner packs are charged on the saved card (a confirmed PaymentIntent), not a second Checkout. **Confirm in the Stripe sandbox:** that Checkout in subscription mode sets the subscription's `default_payment_method`, and that `authentication_required` comes back as a 402 with the PaymentIntent.
- The monthly spend limit counts this calendar month's pending and granted reloads.

## Deploy order
After step 4a: `sql/zella_stripe_packs.sql`, then `billing-api`. **Production md5s to be confirmed by the supervisor before apply.** The trigger lands on `usage_charges`, which is on the live call path: it returns at once while `payments_live` is false and never raises.

## Tests (automated, local)
- `tests/stripe_packs/run.sh`: 28 passed. Before: no owner purchase. Apply, apply again, rollback twice, apply again, drift refused both ways; another business's owner, aal1 and anonymous refused; no saved card refused; double click one purchase; key reuse refused; the command (catalog 2900, our customer, saved card, `pack:` key); wrong amount quarantined; bound payment grants 100 minutes to the period end, bound payment, balanced ledger; second event nothing more; a plan PaymentIntent ignored; a decline fails it with nothing granted; auto reload off while payments are off; five concurrent usage entries make one pending reload and all five entries are kept; `reload:` key; spend limit stops the next one with a notice; a failing reload never fails the usage entry; rollback refuses with bought packs.
- `deno check` billing-api.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
