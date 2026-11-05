# Order lookup: assurance levels and audit (5 Nov 2026)

The AI receptionist's `lookup_order` tool (e-commerce) tells a caller the status of an order from the business's
Shopify store. Code: `web/supabase/functions/voice-rules/orders.ts` (lookup and checks), `index.ts` (wiring),
`web/supabase/functions/_shared/vapi-brain-tools.js` (argument checks), `sql/zella_store_orders.sql` (one of the 17
pending migrations: store connection, lookup context, log). **Nothing of this is live**: production has no Shopify
integration, no lookup records and no `zella_store_lookup_context` (read only, 5 Nov).

## Assurance levels

| Level | What the caller showed | What they hear |
| --- | --- | --- |
| None | Order number only, or details that don't match | The same answer whether or not the order exists ("couldn't confirm that order"); offered a message to the team |
| Caller ID (`found_caller_id`) | Calls from a phone number on the order (order, customer or shipping phone) | Status only: order name, date placed, payment and shipping status, cancelled or not, carrier and the last 4 digits of tracking |
| Email (`found_email`) | Gives the email address on the order (order or customer email) | The same status only |
| Above that | Not offered | Address, items, amounts, refunds, cancelling or changing an order: never said or done; the assistant takes a message |

Both levels are one weak check (caller ID can be spoofed; an email address may be known to others), comparable to a
store's own "order number + email" status page. That is why both give the same, status-only answer, and why nothing
that changes an order or reveals personal details exists on the call.

## What was checked

| Check | Result |
| --- | --- |
| The caller's number comes from the phone network, never from what is said | OK: from the call record (`calls.from_number`), else Vapi's signed `call.customer.number`; `caller_number` is not an argument the assistant can pass (`vapi-brain-tools.js` keeps only listed fields and sets it itself) |
| Not found and not matching sound the same | OK (unit test) |
| Only status and tracking leave the function | OK: address, items, amounts, phones and emails are read from Shopify for the check but never returned; tracking is cut to the last 4 digits |
| The store token never reaches the assistant or the log | OK: server-only context function, sent only to the store's own `*.myshopify.com` address (checked when connecting) |
| Orders off, no store, store down or token refused | OK: a message is taken, nothing guessed; a refused token marks the integration as in error so lookups stop until reconnected |
| Withheld numbers | OK: no number, so the email is needed |
| **O1** Phone match | **Fixed**: compared only the last 10 digits, so +91 98765 43210 on an order matched a caller from +1 987-654-3210. Now both whole numbers are compared when both carry a country code; the last 10 digits only when the store saved a number without one |
| **O2** Record of what was given out | **Fixed**: the log said only "found". Now `found_caller_id` or `found_email`, and owners and admins can read daily counts per level (`zella_order_lookup_report`; counts only, no order numbers or callers) |
| **O3** Guessing | **Fixed**: only the general limit of 30 tool calls a minute applied, so one call could try many order numbers against an email it knew. Now after 3 lookups that didn't match in one call, or 6 from one number in a day, no more are tried and the store isn't asked (`limited`); the answer still doesn't say whether any order exists |
| Shipping phone counts as caller ID | Kept: the person an order is shipped to may hear its status. Remove `shippingAddress.phone` from the check if the business prefers buyer-only |
| The log's `arg_keys` always says `order_number` even when an email was given | Minor, left: the result (`found_email`) now says which check was used |

## Change and tests

- `web/supabase/functions/voice-rules/orders.ts` (**not deployed**): `samePhone`, `callerAssurance` (and
  `callerMatches` kept), the attempt limit, `found_<level>` in the log, `verified_by` in the tool result.
  `orders_test.ts`: 14 tests (new: levels, numbers abroad, the limit, the email level); all 33 voice-rules tests pass;
  `deno check` and `deno lint` clean.
- `sql/zella_order_lookup_assurance.sql` (class V, **not applied**; after `sql/zella_store_orders.sql`; safe to run
  twice; either it or the function can go first). Rollback:
  `sql/rollback/zella_order_lookup_assurance_rollback.sql` (`python3 -I tests/setup/make_rollback.py orders`).
- `tests/orders/run.sh` on an isolated copy with the 17 pending migrations and the two other fixes of today:
  - with the fix: failed lookups counted per call and per number for a day (not across callers, not counting found
    ones); a `limited` lookup leaves the store's health alone; the owner's report gives the counts per level and no
    call details; someone outside the business can't read it; no signed-in user can reach the lookup context; anon
    can't run the report; the rollback restores both functions exactly (md5) and the fix applies again.
  - `WITHOUT_FIX=1`: fails at the first check (no counts in the lookup context), as expected.
