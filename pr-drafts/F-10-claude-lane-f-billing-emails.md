Payments: billing emails decided in the database and rendered into the platform outbox, held while email_live is off
base: claude/lane-f-disputes

## What and why
Lane F, step 11: `docs/PAYMENTS_ARCHITECTURE.md` §6.11, `docs/BILLING_EMAILS.md`. Uses the existing platform outbox and catalogue (`sql/zella_platform_emails.sql`, `_shared/businessEmails.js`, Messaging "Emails to businesses"). **Nothing is sent**: the outbox stays in test mode while `email_live` is off, and this branch never touches that switch.

- `sql/zella_stripe_emails.sql`
  - `billing_email_intents` (server only): one notice per key `email:<code>:<business object>:<occurrence>`, never a Stripe event id, so doubled events never queue twice.
  - Needing Stripe (triggers on our own records, which only verified events change): C1 invoice issued, A1 first payment received, C3 paid, D1 payment failed, C4 invoice cancelled (`billing_invoices`); D5 service paused, D6 payment recovered, A2 trial started (`subscriptions`); F3 pack bought (`pack_purchases`).
  - Not needing Stripe (`zella_billing_email_sweep`, run by the worker): B1 plan renews in 3 days (and 7 days for yearly plans), A3 trial ends in 3 days.
  - `zella_billing_email_claim` / `_done`: the worker takes due notices with the business's active owners as recipients.
  - `zella_usd_text`: integer cents to "$1,234.56" with integer arithmetic only.
- `_shared/billingEmails.ts` (in the billing worker): renders each notice with `renderEmail(code, data, { strict: true })` and queues one copy per owner (`zella_queue_platform_email`, mandatory, key `<notice key>:<user>`). A missing fact holds the notice for a person instead of inventing a value.

## Owner decision needed (not covered by the design)
Most billing templates say "card ending 4242" (A2, A3, A4, A6, B1, B2, C1, C2, C3, D1). `docs/PAYMENTS_ARCHITECTURE.md` §9 says Zella Voice never stores card details, "not even the last 4 digits". Until the owner decides (read the last 4 from Stripe at render time, which then sits in the outbox email body, or reword the templates without the card), those notices are **held** with `MISSING_FIELD:<code>:card`. Card free notices (A1, C4, D2, D5, ...) are queued.

Not built: usage alerts by email (F1, F2) and the other card free notices without a hook yet (A5, D3, D4, E1 to E9); the billing contact list (owners only for now).

## Defaults taken (owner can change)
- Recipients: the business's active owners.

## Deploy order
After step 10: the SQL, then `billing-worker`. **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_emails/run.sh`: 19 passed (before: no email; apply, apply again, rollback twice, apply again, drift refused both ways; first invoice C1 then A1 once each; renewal C1, D1, C4; $299.00 from cents; pause D5 and recovery D6; nothing while payments are off; renewal notice once however often the sweep runs; yearly 7 and 3 day notices; owners as recipients; claimed once; signed in users refused; rollback refuses while notices wait).
- `deno test _shared/billingEmails_test.ts`: 2 passed (rendered once per owner with the right keys; a missing card fact and a business without owners are held, nothing queued). `check.sh` all functions ok.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
