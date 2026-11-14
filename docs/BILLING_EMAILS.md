# Zella Voice — Billing emails (structure)

Status: **design, not built.** Nothing here sends anything yet. It is built with the Stripe step (G-1), on top of
`docs/PAYMENTS_ARCHITECTURE.md` (§6.11 is the summary; this file is the full list). Every email is sent by Zella
Voice itself; Stripe's own customer emails are off, so the owner gets one copy of everything.

## 1. Who gets them

| Item | Rule |
|---|---|
| To | the business's **billing email** (the owner's email by default; changed in Settings › Billing) |
| Copy (optional) | up to 3 extra addresses (an accountant, a manager), set in Settings › Billing |
| Never | the business's own customers, or staff who are not on the billing list |
| From | `Zella Voice Billing <billing@…>`, reply-to support |
| Admin | a copy of the important ones (payment failed, service paused, dispute, refund) goes to the admin bell and the business's billing page, not to admin inboxes |

## 2. How the owner pays (their choice)

| Choice | What happens at each renewal | Where they can pay |
|---|---|---|
| **Auto-debit on** (default) | the saved card is charged automatically on the renewal date; the owner only gets emails | nothing to do; if the charge fails: email link **or** in the app |
| **Auto-debit off** | an invoice is issued on the renewal date with a due date (3 days); the owner pays it themselves | the **Pay now** link in the email **or** **Settings › Billing › Invoices › Pay now** in the app |

- The switch is in **Settings › Billing › Payment method**; only the owner (or a billing admin) can change it, and the
  change is audited and confirmed by email.
- Paying in the app and paying by the email link open the same secure Stripe payment page for that invoice, so an
  invoice can never be paid twice; once it is paid, both show "Paid".
- Every unpaid invoice is shown in the app with a **Pay now** button (red banner on the Today page when one is due or
  overdue), whatever the choice.
- An invoice not paid by its due date follows the failed-payment path (section D): reminders, final notice, pause on
  day 5, restored as soon as it is paid.

## 3. Every email, by moment

**M** = mandatory (cannot be turned off: money moved or service changes). **O** = optional (on by default; the owner
can turn it off in Settings › Billing › Emails).

### A. Sign-up and trial

| # | Email | When it is sent | Main content | M/O |
|---|---|---|---|---|
| A1 | Welcome — payment received | first invoice paid | plan, amount, period, invoice PDF, what happens next | M |
| A2 | Trial started | card saved, trial begins | trial end date, amount and date of the first charge, how to cancel | M |
| A3 | Trial ending soon | 3 days before the trial ends | **auto-debit on**: "we will charge card ending 4242 $X on <date>"; **payment needed**: no working card → "add a card" link | M |
| A4 | Trial converted — paid | first charge after the trial succeeds | same as the Paid email (C3) | M |

### B. Before every renewal (monthly and yearly)

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| B1 | Your plan renews on <date> | 3 days before each renewal (Stripe `invoice.upcoming`); **yearly plans also 7 days before** | plan, period, estimated amount (plan + expected pay-as-you-go), and **one of three**: auto-debit on → "we will charge card ending 4242, nothing to do"; auto-debit off → "your invoice will be due on <date>, pay by the link or in the app"; payment needed (auto-debit on but no card / card expires before the date / last charge failed) → "pay now / update card" | M |
| B2 | Card expiring soon | 30 days before the saved card's expiry month ends | last 4 digits, "update card" link | M |

### C. Invoice and payment (every charge)

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| C1 | Your invoice | an invoice is issued (`invoice.finalized`) | invoice number, period, every line (plan, setup fee, packs, pay-as-you-go minutes, credits, tax), total; auto-debit on: the card it will be charged to; auto-debit off: due date and **Pay now** (link and "or pay in the app"); links: invoice page, PDF | M |
| C2 | Receipt (no Stripe invoice) | a yearly pay-as-you-go or pack charge succeeds | same detail from our own `invoices` rows | M |
| C3 | Paid | every successful payment (`invoice.paid`): auto-debit, first payment, the owner paying by the email link, or paying in the app | "paid", amount, card, date, PDF receipt | M |
| C4 | Invoice cancelled | an invoice we already emailed is voided | "this invoice no longer needs paying", reason if given | M |

### D. Failed payment and pause

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| D1 | Payment failed / invoice overdue | first failed charge (auto-debit on) or due date passed unpaid (auto-debit off) | amount, reason in plain words (declined, expired, insufficient funds), "pay now / update card" link, next retry date | M |
| D2 | Action needed — confirm payment | the bank asks for confirmation (3-D Secure) | "confirm on Stripe's page" link | M |
| D3 | Retry failed | each failed retry (days 2, 3, 4) | attempt number, days left before pause, pay link | M |
| D4 | Final notice | the day before the pause (day 4) | "service pauses tomorrow", pay link | M |
| D5 | Service paused | day 5 with no payment | what stops (calls go to voicemail / forwarding), how to restore | M |
| D6 | Payment recovered — service restored | the past-due invoice is paid | Paid detail (as C3) + "everything is back on" | M |

### E. Plan changes and cancel

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| E1 | Plan upgraded | upgrade applied | new plan, prorated amount charged today, next renewal amount | M |
| E2 | Downgrade scheduled | downgrade chosen | new plan from <date>, what changes (minutes, features) | M |
| E3 | Cancellation confirmed | cancel chosen | service continues until <date>, final pay-as-you-go invoice, "change my mind" link | M |
| E4 | Cancellation withdrawn | the owner continues before the end | plan stays, next renewal date and amount | M |
| E5 | Subscription ended | the period ends after a cancel | what stops, data kept for <N> days, final invoice to follow | M |

### F. Usage, packs, auto-reload

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| F1 | 80% of minutes used | allowance reaches 80% | used / included, days left, options (pack, upgrade, pay-as-you-go) | O |
| F2 | Minutes used up | allowance reaches 100% | what happens now (pay-as-you-go rate or packs), monthly spending limit | M |
| F3 | Pack purchased | pack paid | receipt (C2) + new balance | M |
| F4 | Auto-reload charged | auto-reload succeeds | receipt (C2), monthly cap and how much is left | M |
| F5 | Auto-reload failed | auto-reload charge fails | reason, "update card" link, what happens to calls | M |
| F6 | Spending limit reached | the monthly limit stops new pay-as-you-go | limit, how to raise it | M |

### G. Refunds, credits, disputes

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| G1 | Refund requested | the owner asks for a refund | what was asked, when to expect an answer | M |
| G2 | Refund issued | the refund succeeds | amount, card, 5–10 business days to appear | M |
| G3 | Refund declined | an admin declines | reason | M |
| G4 | Credit applied | a correction credit is used on an invoice (§6.9) | which calls were corrected, amount taken off | O |
| G5 | Dispute opened | the bank opens a chargeback | what it means for the service, how to respond | M |
| G6 | Dispute closed | won or lost | outcome, effect on the account | M |

### SMS copies of the urgent ones

D1 (payment failed / overdue), D4 (final notice) and D5 (service paused) are also sent as a short SMS to the owner's
mobile number (Settings › Billing), from the platform's own sender number, never the business's receptionist number.
The SMS has the amount, the date and a link to the billing page; no invoice details. Once per email (key
`sms:<kind>:<invoice id>`), only to an owner who has given a mobile number, and never from development or tests.

## 4. What every email contains (one template)

- Zella Voice header, business name, the email's title in plain words.
- The key facts first (amount, date, card ending, what the owner must do or "nothing to do").
- Invoice details where there is an invoice: number, period, lines, credits, tax, total, currency (USD).
- Buttons: **Pay now** (opens the payment page; "or pay in the app" next to it) and **Update card**, only when action is needed; **View invoice**, **Download PDF**,
  **Billing settings**.
- Dates in the business's own time zone; amounts as `$1,234.56`.
- Footer: support contact, why they get this email, link to the email settings (for optional emails).
- No card numbers beyond the last 4, no full addresses, no customer (caller) data.

## 5. Settings the owner sees (Settings › Billing)

- **Payment method**: saved card, **Auto-debit on/off**, update card.
- **Invoices**: every invoice with its status (due, paid, overdue, cancelled), **Pay now** on unpaid ones, PDF.
- Billing email and up to 3 copy addresses.
- Optional emails on/off (F1, G4). Mandatory ones are listed as "always sent".
- **Billing history**: every invoice and receipt with its PDF, and every billing email sent (when, to whom,
  delivered / bounced), with **Resend** for a past invoice email.

## 6. Admin side

- Per business: the same billing history and email log, and a **Resend** button (audited).
- Alerts: a bounced billing email (the owner may miss a failed payment), an email held because the amounts did not
  match, a send that failed after all retries.

## 7. Rules that make it safe

| Rule | How |
|---|---|
| Never twice | each email is one outbox row, key `email:<kind>:<invoice or event id>` (unique); retries reuse the key |
| Never lost | failed sends retry with backoff; after the last try an admin alert |
| Never a wrong amount | amounts are fetched from Stripe and must match our `invoices` rows; a mismatch holds the email and alerts |
| Bounces | Resend's delivery and bounce events are recorded; a bounce alerts the admin and shows a banner in the owner's billing page |
| Order | a Paid email is never sent before its Invoice email for the same invoice |
| Not in dev or tests | staging uses Stripe's sandbox and a test inbox; real owners only in production, after the owner's approval |

## 8. Data

- `billing_emails`: `id`, `business_id`, `kind` (A1…G6), `key` (unique), `invoice_id` / `stripe_event_id`,
  `to`, `cc`, `subject`, `status` (`queued` → `sending` → `sent` / `failed` / `held`), `provider_message_id`,
  `delivered_at`, `bounced_at`, `attempts`, `created_at`. Business-scoped, readable by the business's billing
  roles, written by the server only.
- `billing_contacts`: `business_id`, `billing_email`, `cc` (≤ 3), `optional_emails` (which optional kinds are on).

## 9. Tests (before anything goes live)

- SMS copies: D1, D4, D5 send one SMS each to the owner's mobile, none when no mobile is set, none from tests.
- One test per email: the right event sends exactly one email with the right content; a repeated event sends none.
- Paying the same invoice by the email link and in the app at once charges it once.
- Auto-debit off: invoice due in 3 days, overdue path on day 4, pause on day 5.
- Renewal notice: auto-debit text with a working card; auto-debit-off text; payment-needed text with no card, an expiring card, or a
  failed last charge.
- Mismatch held; bounce recorded and alerted; optional email off → not sent, mandatory → always sent.
- Stripe sandbox proof that Stripe itself sends no customer email.

## 10. Open choices for the owner

Decided by the owner (14 Nov 2026): owners can switch auto-debit off and pay by the email link or in the app;
renewal reminder 3 days before, and also 7 days before for yearly plans; urgent ones (D1, D4, D5) also by SMS.

Still open: which emails are optional — only F1 and G4 for now.
