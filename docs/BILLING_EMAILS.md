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
| A5 | Trial ended without payment | trial end with no working card | service paused, "add a card to continue" | M |
| A6 | Setup fee charged | the setup fee is paid (with the first invoice or later for a trial business) | amount, what it covers, receipt | M |

### B. Before every renewal (monthly and yearly)

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| B1 | Your plan renews on <date> | scheduled by our worker from the subscription's period end: 3 days before each renewal; **yearly plans also 7 days before** | plan, period, estimated amount (plan + expected pay-as-you-go), and **one of three**: auto-debit on → "we will charge card ending 4242, nothing to do"; auto-debit off → "your invoice will be due on <date>, pay by the link or in the app"; payment needed (auto-debit on but no card / card expires before the date / last charge failed) → "pay now / update card" | M |
| B2 | Card expiring soon | 30 days before the saved card's expiry month ends | last 4 digits, "update card" link | M |
| B3 | No card on file | auto-debit is on and the saved card was removed or is unusable | "add a card before <next renewal>" | M |
| B4 | Price change notice | 30 days before a plan's price changes for this business | old and new price, from which renewal, how to change plan or cancel | M |
| B5 | Discount ending | 7 days before a discount or promo stops | renewal amount without the discount | M |

### C. Invoice and payment (every charge)

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| C1 | Your invoice | an invoice is issued (`invoice.finalized`) | invoice number, period, every line (plan, setup fee, packs, pay-as-you-go minutes, credits, tax), total; auto-debit on: the card it will be charged to; auto-debit off: due date and **Pay now** (link and "or pay in the app"); links: invoice page, PDF | M |
| C2 | Receipt (no Stripe invoice) | a yearly pay-as-you-go or pack charge succeeds | same detail from our own `invoices` rows | M |
| C3 | Paid | every successful payment (`invoice.paid`): auto-debit, first payment, the owner paying by the email link, or paying in the app | "paid", amount, card, date, PDF receipt | M |
| C4 | Invoice cancelled | an invoice we already emailed is voided | "this invoice no longer needs paying", reason if given | M |
| C5 | Invoice due soon (auto-debit off) | 1 day before the due date, if still unpaid | amount, due date, Pay now (link or in the app) | M |
| C6 | Replacement invoice | an admin re-bills usage after an invoice was cancelled (§6.9) | which invoice it replaces, what changed | M |
| C7 | Credit note | an issued invoice is reduced by a credit note | invoice number, amount reduced, new total, PDF | M |

### D. Failed payment and pause

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| D1 | Payment failed / invoice overdue | first failed charge (auto-debit on) or due date passed unpaid (auto-debit off) | amount, reason in plain words (declined, expired, insufficient funds), "pay now / update card" link, next retry date | M |
| D2 | Action needed — confirm payment | the bank asks for confirmation (3-D Secure) | "confirm on Stripe's page" link | M |
| D3 | Retry failed | each failed retry (days 2, 3, 4) | attempt number, days left before pause, pay link | M |
| D4 | Final notice | the day before the pause (day 4) | "service pauses tomorrow", pay link | M |
| D5 | Service paused | day 5 with no payment | what stops (calls go to voicemail / forwarding), how to restore | M |
| D6 | Payment recovered — service restored | the past-due invoice is paid | Paid detail (as C3) + "everything is back on" | M |
| D7 | Payment partly refunded or reversed by the bank | a payment is reversed outside a dispute | amount, what to do | M |

### E. Plan changes and cancel

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| E1 | Plan upgraded | upgrade applied | new plan, prorated amount charged today, next renewal amount | M |
| E2 | Downgrade scheduled | downgrade chosen | new plan from <date>, what changes (minutes, features) | M |
| E3 | Cancellation confirmed | cancel chosen | service continues until <date>, final pay-as-you-go invoice, "change my mind" link | M |
| E4 | Cancellation withdrawn | the owner continues before the end | plan stays, next renewal date and amount | M |
| E5 | Subscription ended | the period ends after a cancel | what stops, data kept for <N> days, final invoice to follow | M |
| E6 | Switched monthly ↔ yearly | billing period changed | new period, amount, next renewal date, credit for unused time | M |
| E7 | Plan reactivated | a cancelled or ended business subscribes again | plan, amount, next renewal | M |
| E8 | Data deletion warning | 7 days before an ended business's data is deleted | date, how to export or reactivate | M |
| E9 | Account paused by an admin / restored | an admin pauses or restores the account for billing reasons | reason, what stops, how to restore | M |

### F. Usage, packs, auto-reload

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| F1 | 80% of minutes used | allowance reaches 80% | used / included, days left, options (pack, upgrade, pay-as-you-go) | O |
| F2 | Minutes used up | allowance reaches 100% | what happens now (pay-as-you-go rate or packs), monthly spending limit | M |
| F3 | Pack purchased | pack paid | receipt (C2) + new balance | M |
| F4 | Auto-reload charged | auto-reload succeeds | receipt (C2), monthly cap and how much is left | M |
| F5 | Auto-reload failed | auto-reload charge fails | reason, "update card" link, what happens to calls | M |
| F6 | Spending limit reached | the monthly limit stops new pay-as-you-go | limit, how to raise it | M |
| F7 | Pay-as-you-go statement | at each period's close, when pay-as-you-go minutes were used | minutes, rate, amount, which invoice it goes on | O |
| F8 | Pack expiring | 7 days before unused pack minutes expire (if packs expire) | minutes left, expiry date | O |
| F9 | Allowance renewed | at each renewal | new included minutes, texts, emails; rolled-over amounts | O |

### G. Refunds, credits, disputes

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| G1 | Refund requested | the owner asks for a refund | what was asked, when to expect an answer | M |
| G2 | Refund issued | the refund succeeds | amount, card, 5–10 business days to appear | M |
| G3 | Refund declined | an admin declines | reason | M |
| G4 | Credit applied | a correction credit is used on an invoice (§6.9) | which calls were corrected, amount taken off | O |
| G5 | Dispute opened | the bank opens a chargeback | what it means for the service, how to respond | M |
| G6 | Dispute closed | won or lost | outcome, effect on the account | M |
| G7 | Usage waived | an admin waives usage after a cancelled invoice (§6.9) | which usage, amount, "nothing to pay" | M |
| G8 | Refund partly issued | only part of a requested refund is approved | amount refunded, the rest and why | M |

### H. Billing settings and security (confirmations)

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| H1 | Auto-debit switched off / on | the owner or a billing admin changes it | who changed it, when, what happens at the next renewal | M |
| H2 | Card updated | the saved card is added, replaced or removed | new card's last 4, who changed it | M |
| H3 | Billing email changed | the billing email or copy list changes | sent to the **old and the new** address, who changed it | M |
| H4 | Spending limit or auto-reload changed | the monthly limit or auto-reload settings change | old and new values, who changed it | M |
| H5 | Billing details changed | business name, address or tax ID on invoices changes | new details, from which invoice | M |
| H6 | Billing role added / removed | someone is given or loses access to billing | who, by whom | M |

### I. Statements

| # | Email | When | Main content | M/O |
|---|---|---|---|---|
| I1 | Yearly billing summary | each January (for the year before) | every invoice and refund, totals, tax, one PDF for the accountant | O |
| I2 | Monthly statement | first of each month | invoices, payments, credits and balance for the month before | O |

### SMS copies of the urgent ones

D1 (payment failed / overdue), D4 (final notice), D5 (service paused), A5 (trial ended without payment) and
E8 (data deletion warning) are also sent as a short SMS to the owner's
mobile number (Settings › Billing), from the platform's own sender number, never the business's receptionist number.
The SMS has the amount, the date and a link to the billing page; no invoice details. Once per email (key
`sms:<kind>:<object id>:<occurrence>`, the same object as the email: the invoice when there is one, otherwise
our own row, e.g. the data-deletion schedule for E8), only to an owner who has given a mobile number, and never from development or tests.

## 4. What every email contains (one template)

- Zella Voice header, business name, the email's title in plain words.
- The key facts first (amount, date, card ending, what the owner must do or "nothing to do").
- Invoice details where there is an invoice: number, period, lines, credits, tax, total, currency (USD).
- Buttons: **Pay now** (opens the payment page; "or pay in the app" next to it) and **Update card**, only when action is needed; **View invoice**, **Download PDF**,
  **Billing settings**.
- Dates in the business's own time zone; amounts as `$1,234.56`.
- Footer: support contact, why they get this email, link to the email settings (for optional emails).
- No card numbers beyond the last 4: only the card brand, last 4 digits and expiry month and year from Stripe (owner decision R59, 27 Nov 2026); no full addresses, no customer (caller) data.

## 5. Settings the owner sees (Settings › Billing)

- **Payment method**: saved card, **Auto-debit on/off**, update card.
- **Invoices**: every invoice with its status (due, paid, overdue, cancelled), **Pay now** on unpaid ones, PDF.
- Billing email and up to 3 copy addresses.
- Optional emails on/off (F1, F7, F8, F9, G4, I1, I2). Mandatory ones are listed as "always sent".
- **Billing history**: every invoice and receipt with its PDF, and every billing email sent (when, to whom,
  delivered / bounced), with **Resend** for a past invoice email.

## 6. Admin side

- Per business: the same billing history and email log, and a **Resend** button (audited).
- Alerts: a bounced billing email (the owner may miss a failed payment), an email held because the amounts did not
  match, a send that failed after all retries.

## 7. Rules that make it safe

| Rule | How |
|---|---|
| Never twice | each email is one outbox row, key `email:<kind>:<object id>:<occurrence>` (unique). The object is the business object the notice is about, never a Stripe event id (Stripe can send two events for one change): the invoice; for renewal notices the subscription and renewal date; otherwise our own row (refund, dispute, purchase, settings change, deletion schedule). The occurrence names the notice (`d7`, `d3`, `retry2`…`retry4`, or `1`) |
| A lost reply | the outbox row stores the exact request body at its first send attempt; every retry sends the same bytes with Resend's `Idempotency-Key` = the row's key, so a retry returns the first result; a `409 invalid_idempotent_request`, or an outcome still unknown after Resend's idempotency window, holds the row and alerts an admin, never a blind resend |
| Billing email changed | queued emails not yet attempted are rebuilt for the new address in the same transaction; emails already attempted keep their body (they may have been delivered); a held one whose recipient is no longer on the billing list is never resent, only resolved by a person |
| Never lost | failed sends retry with backoff; after the last try an admin alert |
| Never a wrong amount | amounts are fetched from Stripe (the invoice; for charges without one — yearly pay-as-you-go, packs, auto-reload — the PaymentIntent, after the binding check) and must match our `invoices` / `invoice_lines` rows; a mismatch holds the email and alerts |
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

Optional (on by default, owner can turn off): F1, F7, F8, F9, G4, I1, I2. Everything else is always sent.
The list is complete for every money and billing-settings event in `docs/PAYMENTS_ARCHITECTURE.md`; any new money flow
adds its email here in the same change.
