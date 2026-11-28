# Emails from Zella Voice to businesses

Every email Zella Voice sends to a business (its owner, billing contacts and team). The wording, the shared layout
and this list come from one file, `web/supabase/functions/_shared/businessEmails.js` (the app imports it through `web/src/emails/businessEmails.js`); the admin preview (Admin, Messaging, Emails to
businesses) and the server sender render from the same file. Billing emails keep their codes and rules from
`docs/BILLING_EMAILS.md`. Emails to a business's own customers are separate (`email_messages`).

## How an email will be sent (intended flow; no sender is connected yet)

1. The server renders it (`renderEmail(code, values)`) and queues it with `zella_queue_platform_email`, keyed
   `email:<code>:<object id>:<occurrence>`, unique per business. The same key again changes nothing, so an email is
   never sent twice.
2. The sender claims due emails (`zella_claim_platform_emails`). While `email_live` is off, they are marked test mode
   (`dry_run`) and nothing is handed out.
3. The sender sends with `<business_id>:<key>` as the provider's idempotency key (unique across businesses) and reports back (`zella_finish_platform_email`)
   with the claim token it was handed, so a late answer from an older claim changes nothing.
   A failure waits 1, 4, 9 and 16 minutes; after 5 tries the email is held for a person and an admin alert is raised.
4. Optional emails respect the person's choice (`notification_preferences`, type `email:<code>`); emails marked
   always sent are about the account, the service or money and can't be switched off.

Status: the catalogue, layout and admin preview are built; the outbox (`sql/zella_platform_emails.sql`) is tested
on the isolated database and **not applied**; no sender is connected and nothing has been sent.

## Writing

Creative but professional, the facts first, one clear button, the reason for the email in the footer. No dashes or
hyphens, no emoji, no caller data, card numbers only as the last 4 digits. Colours are copied from
`web/src/styles/tokens.css` (email clients can't read CSS variables); a test checks they still match.


## Every email (93)

### Notifications

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| N1 | Notification | a notification someone gets by email (summaries, warnings, urgent alerts) | Yes |

### Account and setup

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| S1 | Welcome to Zella Voice | the business account is created | No, always sent |
| S2 | Team invitation | someone is invited to join a business | No, always sent |
| S3 | Finish setting up | setup is unfinished 3 days after the account was created | Yes |
| S4 | Documents needed | verification documents are missing or were not accepted | No, always sent |
| S5 | Business verified | verification is approved | No, always sent |
| S6 | Your AI receptionist is live | the receptionist starts answering real calls | No, always sent |
| S7 | Phone number connected | a phone number is connected or moved | No, always sent |

### Sign in and access

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| K1 | New sign in | someone signs in from a new device | No, always sent |
| K2 | Two step sign in changed | two step sign in is turned on or off | No, always sent |
| K3 | Password changed | the password is changed or reset | No, always sent |
| K4 | Your access changed | a person's role in the business changes or is removed | No, always sent |

### Summaries

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| R1 | Daily summary | 8:00 each morning, when there is something to report | Yes |
| R2 | Weekly review | Monday morning | Yes |
| R3 | Monthly report | the first of each month | Yes |

### Alerts

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| L1 | Urgent: a person is needed | an emergency or urgent call needs someone now | No, always sent |
| L2 | Callbacks waiting | callbacks are overdue | Yes |
| L3 | Calendar disconnected | the connected calendar stops syncing | No, always sent |
| L4 | A connection stopped working | an integration fails repeatedly | No, always sent |
| L5 | Google reviews disconnected | review syncing stops | Yes |
| L6 | Weekend on call cover | Thursday or Friday, when part of the weekend has nobody on call | Yes |
| L7 | Weekly spam report | Monday, when spam was stopped | Yes |
| L8 | Texts not delivered | several texts to customers fail | Yes |
| L9 | Questions your receptionist couldn't answer | weekly, when callers asked something it didn't know | Yes |

### Texts and emails used

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| U1 | 80% of texts used | texts reach 80% of the plan | Yes |
| U2 | Texts used up | texts reach 100% of the plan | No, always sent |
| U3 | 80% of emails used | emails reach 80% of the plan | Yes |
| U4 | Emails used up | emails reach 100% of the plan | No, always sent |

### Service and privacy

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| V1 | Service incident | a problem affects calls or messages | No, always sent |
| V2 | Incident resolved | the incident is fixed | No, always sent |
| V3 | Scheduled maintenance | 7 days before planned maintenance | No, always sent |
| V4 | Terms updated | 30 days before the terms or privacy policy change | No, always sent |
| V5 | Privacy request received | a customer asks to see or delete their data | No, always sent |
| V6 | Data export ready | an export the owner asked for is ready | No, always sent |

### Billing: sign up and trial

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| A1 | Welcome, payment received | the first invoice is paid | No, always sent |
| A2 | Trial started | a card is saved and the trial begins | No, always sent |
| A3 | Trial ending soon | 3 days before the trial ends | No, always sent |
| A4 | Trial converted, paid | the first charge after the trial succeeds | No, always sent |
| A5 | Trial ended without payment | the trial ends with no working card | No, always sent |
| A6 | Setup fee charged | the setup fee is paid | No, always sent |

### Billing: before each renewal

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| B1 | Your plan renews soon | 3 days before each renewal (yearly plans also 7 days before) | No, always sent |
| B2 | Card expiring soon | 30 days before the saved card expires | No, always sent |
| B3 | No card on file | automatic payment is on but the card was removed or can't be used | No, always sent |
| B4 | Price change notice | 30 days before the plan's price changes | No, always sent |
| B5 | Discount ending | 7 days before a discount ends | No, always sent |

### Billing: invoices and payments

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| C1 | Your invoice | an invoice is issued | No, always sent |
| C2 | Receipt | a pay as you go or pack charge succeeds without a Stripe invoice | No, always sent |
| C3 | Paid | every successful payment | No, always sent |
| C4 | Invoice canceled | an invoice already emailed is canceled | No, always sent |
| C5 | Invoice due tomorrow | 1 day before the due date, if unpaid and automatic payment is off | No, always sent |
| C6 | Replacement invoice | usage is billed again after an invoice was cancelled | No, always sent |
| C7 | Credit note | an issued invoice is reduced | No, always sent |

### Billing: failed payments

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| D1 | Payment failed | the first charge fails, or the due date passes unpaid | No, always sent |
| D2 | Confirm your payment | the bank asks for confirmation (3D Secure) | No, always sent |
| D3 | Retry failed | each failed retry | No, always sent |
| D4 | Final notice | the day before the pause | No, always sent |
| D5 | Service paused | 5 days after the failed payment | No, always sent |
| D6 | Payment recovered | the overdue invoice is paid | No, always sent |
| D7 | Payment reversed by the bank | a payment is reversed outside a dispute | No, always sent |

### Billing: plan changes and cancelling

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| E1 | Plan upgraded | an upgrade is applied | No, always sent |
| E2 | Downgrade scheduled | a downgrade is chosen | No, always sent |
| E3 | Cancellation confirmed | the owner cancels | No, always sent |
| E4 | Cancellation withdrawn | the owner continues before the end | No, always sent |
| E5 | Subscription ended | the period ends after a cancellation | No, always sent |
| E6 | Billing period changed | the plan switches between monthly and yearly | No, always sent |
| E7 | Plan reactivated | an ended business subscribes again | No, always sent |
| E8 | Data deletion warning | 7 days before an ended business's data is deleted | No, always sent |
| E9 | Account paused or restored | an admin pauses or restores the account for billing reasons | No, always sent |

### Billing: minutes, packs and auto reload

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| F1 | 80% of minutes used | minutes reach 80% of the plan | Yes |
| F2 | Minutes used up | minutes reach 100% of the plan | No, always sent |
| F3 | Pack purchased | a pack is paid | No, always sent |
| F4 | Auto reload charged | auto reload succeeds | No, always sent |
| F5 | Auto reload failed | the auto reload charge fails | No, always sent |
| F6 | Spending limit reached | the monthly limit stops new pay as you go minutes | No, always sent |
| F7 | Pay as you go statement | at each period's close, if pay as you go minutes were used | Yes |
| F8 | Pack expiring | 7 days before unused pack minutes expire | Yes |
| F9 | Allowance renewed | at each renewal | Yes |

### Billing: refunds, credits and disputes

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| G1 | Refund requested | the owner asks for a refund | No, always sent |
| G2 | Refund issued | the refund succeeds | No, always sent |
| G3 | Refund declined | an admin declines the refund | No, always sent |
| G4 | Credit applied | a correction credit is used on an invoice | Yes |
| G5 | Dispute opened | the bank opens a chargeback | No, always sent |
| G6 | Dispute closed | the dispute is won or lost | No, always sent |
| G7 | Usage waived | an admin waives usage after a cancelled invoice | No, always sent |
| G8 | Refund partly issued | only part of a refund is approved | No, always sent |

### Billing: settings changed

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| H1 | Automatic payment changed | automatic payment is switched on or off | No, always sent |
| H2 | Card updated | the saved card is added, replaced or removed | No, always sent |
| H3 | Billing email changed | the billing email or copy list changes (sent to the old and new address) | No, always sent |
| H4 | Spending limit or auto reload changed | the limit or auto reload settings change | No, always sent |
| H5 | Billing details changed | the name, address or tax ID on invoices changes | No, always sent |
| H6 | Billing access changed | someone gains or loses billing access | No, always sent |

### Billing: statements

| Code | Email | Sent when | Can be switched off |
|---|---|---|---|
| I1 | Yearly billing summary | each January | Yes |
| I2 | Monthly statement | the first of each month | Yes |
