Payments: disputes recorded, the account suspended while one is open, shown to admins
base: claude/lane-f-invoices

## What and why
Lane F, step 10: `docs/PAYMENTS_ARCHITECTURE.md` §6.8 and §7, REQ-BIL-37.

- `sql/zella_stripe_disputes.sql`: `billing_disputes` (server only, one row per Stripe dispute).
  - `charge.dispute.created` (fetched): suspends the account (`suspended_dispute`); the state it came from is saved on the subscription once, so a second dispute never overwrites it; urgent alert with the respond by date; audited. A dispute on a cancelled subscription is recorded only. A dispute for a payment not recorded yet waits.
  - `charge.dispute.updated`: Stripe's status. `funds_withdrawn` / `funds_reinstated`: ledger postings, once each.
  - `charge.dispute.closed`: won closes it and restores the saved state only when no other dispute is open; lost posts the loss once, alerts, and the account stays suspended until a person settles it.
  - `zella_admin_disputes` (`billing.view`), shown in the admin Payments panel's Disputes tab (step 9's component).

## Defaults taken (owner can change)
- A lost dispute keeps the account suspended; nothing is cancelled automatically (a person decides).
- Evidence is submitted by a person in Stripe; nothing here submits it.

## Deploy order
After step 9. **Production md5s to be confirmed by the supervisor before apply.**

## Tests
- `tests/stripe_disputes/run.sh`: 21 passed (before: nothing recorded; apply, apply again, rollback twice, apply again, drift refused both ways; suspend saving past due; alert; second dispute keeps the saved state; repeated event one row; withdrawn posted once; partial win keeps the suspension; last win restores past due; withdrawn and reinstated balance; loss posted once and stays suspended; unknown payment waits; billing.view admin reads, owner refused; rollback refuses with data).
- Local browser, `tests/browser/stripe-admin-payments.cjs`: 14 passed at 1440x900 and 390 (the open dispute listed with its amount; no page errors; nothing left the machine). Screenshots:
  - /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f9-payments-disputes-1440.png
  - /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/f9-payments-disputes-390.png

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
