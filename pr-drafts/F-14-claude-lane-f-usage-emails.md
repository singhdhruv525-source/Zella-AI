Billing emails: usage alerts at 80% and 100% of minutes, held until payments and email are live
base: claude/lane-f-payment-gate

## What and why
Owner decision relayed by the supervisor (16 Nov 2026): build both sets of billing emails now (those that need Stripe, step 11, and those that don't), held until email is live and Stripe is live. Step 11 already decides the renewal coming (B1) and trial ending (A3) notices from our own rows; this adds the usage alerts.

- `sql/zella_stripe_usage_emails.sql`: an after insert trigger on `usage_threshold_events` (already written once per period and threshold by the usage rules) decides F1 at 80% of minutes (minutes used, included, days left) and F2 at 100% (the business's pay as you go rate and monthly limit), keyed on the business and period, **only while `payments_live` is true**; the platform outbox then holds the email until `email_live` is on. A missing rate or limit holds that notice (strict rendering); the trigger never fails the threshold row.

## Defaults taken (owner can change)
- Minutes only (texts and emails thresholds send no email yet).

## Deploy order
After step 13. **Production md5s to be confirmed by the supervisor before apply.**

## Tests (automated, local)
- `tests/stripe_usage_emails/run.sh`: 12 passed (before: none; apply, apply again, rollback twice, apply again, drift refused both ways; nothing while payments are off; F1 with 400 minutes, F2 with $0.20 a minute and the $300.00 limit; texts nothing; rows kept).
- On this top branch, with every lane F migration: the end to end journey (`tests/stripe_e2e/journey_test.ts`) 2 passed and the plan change flow 2 passed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
