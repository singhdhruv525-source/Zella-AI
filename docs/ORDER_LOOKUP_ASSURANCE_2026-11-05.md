# Order lookup: assurance and disclosure policy (5 Nov 2026, revised)

The AI receptionist's `lookup_order` tool (e-commerce) answers "where is my order?" from the business's Shopify store.
Code: `web/supabase/functions/voice-rules/orders.ts`; database: `sql/zella_store_orders.sql`,
`sql/zella_order_lookup_assurance.sql` (both applied to production 5 Nov), `sql/zella_order_lookup_v2.sql` (not applied).

**Revision.** The first version of this document called caller ID or the order's email "an assurance level" that
allowed status, carrier, date, payment status and the last 4 digits of tracking. That was wrong: neither identifies
the caller. This revision replaces it.

## What the checks are worth

| Check | What it shows | Why it is weak |
| --- | --- | --- |
| Caller ID matches a phone on the order | the call came from, or claims to come from, that number | caller ID can be spoofed; a number is often shared (household, office, reception line); we have no attestation (STIR/SHAKEN) from the phone provider to rely on |
| Email matches the order | the caller knows the address | email addresses are widely known; they are on receipts, forwarded emails and shared mailboxes |
| Both | the caller has the number **and** the address | harder to fake together, still not identity proof |

Nothing here is strong identity verification, so the policy keeps every spoken disclosure to what is low-harm if the
caller is not the buyer, and sends anything more only to contact details that are already on the order.

## Permitted disclosures

| Level | When | The assistant may say | Never |
| --- | --- | --- | --- |
| none | no check matches, or no such order | the same sentence in both cases (no order is confirmed or denied) | anything about the order |
| recipient | calling from the shipping phone only | whether it has shipped (a cancellation is said as "hasn't shipped") | the order number, dates, carrier, cancellation, anything else |
| one_factor | the buyer's phone **or** the order's email | the order number and whether it has shipped, partly shipped, or was cancelled | dates, carrier |
| two_factor | the buyer's phone **and** the order's email | that, plus the day it was placed and the carrier | tracking number, payment |
| any | | | tracking numbers or any part of one (it opens the carrier's page with the delivery address), tracking links, payment status, amounts, items, addresses, names, other orders |

Data minimisation: the store is no longer asked for payment status, tracking numbers or tracking links at all
(`ORDER_QUERY`), so they cannot reach the assistant even by mistake.

## Trusted channel

Tracking details, and anything beyond the table, go only to the phone number or email **on the order**, never to a
number or address the caller gives. On the call, the assistant offers to take a message so the team sends them. An
automatic text or email with the tracking link is not built: it needs customer messaging, which is off in production.
Until then this is a team step, recorded as a message.

## Shipping recipients

A gift's recipient may ask whether it is on its way. Calling from the shipping phone gives the recipient level only.
Giving the buyer's email from that phone counts as one factor (the email), never two: the recipient's phone is not a
buyer factor.

## Attempt limits and enumeration protection

- "Not found" and "doesn't match" give the identical answer.
- A lookup that doesn't match counts against four limits. Past any of them, nothing more is looked up and the store
  isn't asked; the answer is still neutral.
  - 3 per call;
  - 6 per caller number per day;
  - 5 per order number per day, across all phones (guessing emails against one order). The order number is counted by
    a reference: 32 characters of SHA-256 of the business and the number, never stored as given. Short sequential
    order numbers can still be guessed from it, so it is a counter key, not a secret.
  - 30 per business per hour (many phones guessing many order numbers).
- The caller's number checked is the phone network's (`calls.from_number`, else Vapi's signed `call.customer.number`).
  The assistant cannot pass one (`vapi-brain-tools.js` keeps only listed fields and sets `caller_number` itself).
- Every lookup is recorded without content as `found_recipient`, `found_one_factor`, `found_two_factor`, `unverified`,
  `not_found`, `limited` or a store error. Owners and admins see daily counts per level (`zella_order_lookup_report`).

## Tests

`orders_test.ts` (17 tests, with Shopify and the database mocked) covers:
- an unauthorised caller (identical to "no such order");
- a shared or spoofed caller ID (the buyer's number, no email: order number and shipped state only);
- email alone;
- two factors (date and carrier, still no tracking);
- the shipping recipient (shipped state only, no cancellation, no order number);
- tracking, payment and contact details never appearing at any level, even when the store returns them;
- all four limits stopping the lookup before the store is asked;
- order numbers never sent to the database as given;
- the caller being unable to supply the number that is checked.

All 36 voice-rules tests pass.

The same cases run against the earlier code (git HEAD before this change) disclosed the date, payment status, carrier
and the last 4 digits of tracking on caller ID alone, including to the shipping phone. That code was never deployed:
production's voice-rules (v4) has no order lookup, and production has no store connected (read only, 5 Nov). So
nothing was disclosed to anyone.

`tests/orders/run_v2.sh` (isolated database) covers:
- the per-order and per-business counts;
- the old two-argument functions, which the deployed function uses, still working;
- the report by level;
- the updated tool description;
- the new functions being server-only;
- the rollback restoring the functions exactly.

**Not tested:** a real Shopify store. Nothing has called Shopify; the query shape is the one the other session wrote,
minus the removed fields. Before connecting a real store, run one lookup against a development store.

## Deploy order

1. `sql/zella_order_lookup_v2.sql` (new overloads; the deployed function is unaffected).
2. The voice-rules function (it calls the new overloads).
3. A development-store check.

Rollback: `sql/rollback/zella_order_lookup_v2_rollback.sql`, after rolling the function back.
