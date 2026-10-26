# Spam protection and abuse prevention

Working checklist and design. Status is honest: "built" means the code exists and was tested locally; nothing is
live until the SQL is applied and the functions deployed.

## Phase 1-2: what already existed (audit)

| Capability | Where | Use |
|---|---|---|
| Atomic fixed-window rate limiter | `zella_rate_limit(key, max, window)` + `rate_limits` (insert ... on conflict, safe under concurrency) | Reused for every new limit |
| Web lead rate limits | `zella_capture_web_lead`, `website-lead` function | Kept |
| Inbound email rate limit | `zella_receive_inbound_email` | Kept |
| Opt-out / do-not-contact | `customers.do_not_*`, consent records, STOP handling | Kept; different from spam blocking |
| Caller context at call start | `zella_caller_context` (called by `zella_ai_voice` before the AI speaks) | Screening point for calls |
| Server-only channel entry points | `zella_ai_voice`, `zella_ai_booking`, `zella_record_inbound_call`, `zella_receive_inbound_email`, inbound SMS router (service role via n8n) | Enforcement lives behind them |
| Business notifications | `zella_notify` -> `staff_notifications` -> Owner Emails workflow | Reused for spam alerts |
| Platform alerts with grouping | `zella_platform_alert` (dedupe key, occurrences) -> Admin Alerts workflow | Reused for platform abuse and cost alerts |

Missing: any spam incident record, block/allow lists, spam settings, detection, booking abuse limits, call screening,
CRM inbox, admin view.

## Design

- **One incident per sender, channel and day** (`spam_incidents.dedupe_key`), with an occurrence count, so a flood is
  one incident, not a hundred. Each source record (call, text, email, booking) is counted once
  (`spam_incident_events` unique source), so a repeated webhook can't double count.
- **Risk score from several signals**, not one: list match, repeated contact in a window, suspicious links, spam
  phrases, AI manipulation phrases, booking limits, withheld caller ID. Levels: low < 40 <= medium < 70 <= high.
- **No permanent block from one uncertain signal.** Only an explicit list entry blocks. Automatic restriction is
  temporary (24 h), needs two or more distinct signals and a high score, and is reversible.
- **Lists**: business lists (its own, owner/admin/manager) and platform rules (Zella admins only). Channel-specific;
  `all` only when chosen. Platform blocks win; a business allow wins over its own heuristics only.
- **Caller ID and sender addresses can be spoofed**: they are signals, never proof on their own.
- **Content minimisation**: incidents keep reasons, sender and a link to the source record; never message bodies,
  transcripts or recordings. Opening the source uses that record's own access rules.

## Enforcement points

| Channel | Point | What happens |
|---|---|---|
| Calls | `zella_caller_context` (start of call, before the AI speaks) | Blocked or high-risk callers: the AI is told to end politely and take no actions; incident recorded. |
| Calls | after the call is recorded (`calls` insert) | Repeated calls, AI manipulation phrases in the transcript; callbacks for blocked callers are cancelled |
| Bookings | `appointments` before insert, non-staff bookings only | Blocked contact or over the booking limit: kept as a *request* for staff to confirm (never silently dropped, never auto-confirmed) |
| SMS | `sms_messages` insert (inbound) | Flooding, suspicious links/phrases, blocked sender; automatic replies to blocked senders are skipped |
| Email | `email_messages` insert (inbound) | Same, plus the provider's own spam verdict when it sends one |

Not claimed: carrier-level call rejection (Vapi's pre-connect `assistant-request` is not configured, so a blocked
caller is answered and the call ended by the AI), email gateway filtering (Zella only sees mail forwarded to it).

## Where it shows up

| Place | What it does | Who |
|---|---|---|
| CRM Today | **Spam** card, last of the analytics cards: real incident count for the selected day, how many need review, trend against the same day last week; opens Spam protection | owner, admin, manager |
| CRM > Calls & Messages > Spam protection (`/app/spam`) | Overview (tiles, by channel, daily bars, Today/7/30/90 days); inbox with search, filters, sort, 25 per page, bulk review; incident panel (why, source record under its own access rules, assign, notes, history, confirm/not spam/block/unblock with confirmation); block and allow lists; settings | view: owner/admin/manager; settings: owner/admin |
| Create Business wizard, Integrations step | Spam protection on by default; only the channels the business has (calls, texts, email, bookings when it takes appointments); booking limit from the industry (2 for dining, lodging and clinics, else 3); extra options under "More options"; shown on Review | admins with businesses.manage (`setup_save_spam`) |
| Admin > Operations > Security & Abuse (`/security-abuse`) | Platform totals, detection accuracy and false-positive rate, by channel, most affected businesses, open flood / call-volume alerts; incidents across businesses filtered by business, channel, status and risk (sender masked, no message text, notes reported only as "a note exists"); which businesses have protection on/off/default; platform defaults; global block rules (reason required, optional expiry) | view: security.view; defaults: platform.configure; rules: security.manage. Every change audited (`platform.spam_policy_updated`, `platform.spam_rule_added`, `platform.spam_rule_removed`) |
| Reschedule link (`/r/<code>`) | 60 requests a minute per IP, 10 changes / 40 reads a minute per link; "Too many tries" message | public |

Business settings override the platform defaults for the limits they save; score bands, alert levels, restriction
length, notification cap and retention always come from the platform defaults.

## Notifications (n8n)

No new workflow was needed. High-risk incidents write a `staff_notifications` row (at most 3 an hour per business,
sender masked), delivered by the existing **Owner Emails** workflow; floods and call-volume spikes raise a
`platform_alerts` row delivered by the existing **Admin Alerts** workflow. Both workflows are **unpublished** in n8n
today, so these notifications are stored and visible in the apps but **not emailed** until those workflows are
published. The `zella_spam_hourly` cron job (review reminders, expired restrictions, retention) is created
**inactive**.

## Deployment (needs approval)

1. Take a backup, then apply `sql/zella_spam_protection.sql` (safe to run more than once; undo steps at the top).
2. Deploy edge functions `owner-provision-business` and `reschedule-appointment`.
3. Optional: turn on the `zella_spam_hourly` cron job; publish Owner Emails and Admin Alerts in n8n.

Until step 1 the CRM card reads "Not set up yet", the CRM page and admin page explain what to apply, and the wizard
saves everything except spam settings (reported, not faked).

## Known limits and risks

- Not carrier-level: a blocked caller is answered and the AI ends the call. Rejecting before connect needs Vapi's
  `assistant-request` server URL, which is not configured.
- Email checks only cover mail forwarded to Zella; there is no gateway filtering.
- Sign-up and login rate limits are Supabase Auth settings, not part of this change.
- A held booking is kept as a request; the AI may still tell the caller it's booked. Staff confirm it in the calendar.
- Under many truly simultaneous contacts from one sender, early contacts in the burst can be undercounted (parallel
  transactions don't see each other); the incident is still created once and the count catches up.
- Caller ID and sender addresses can be spoofed; a global rule on a spoofed number can affect a real person, which is
  why rules need a reason and can expire.

## Checklist

| Item | State |
|---|---|
| Data model, RLS, idempotency, retention | Built; tested on a local Postgres 17 copy (not production) |
| Detection engine and thresholds | Built; tested locally |
| Calls, SMS, email, booking enforcement | Built; tested locally |
| AI security (manipulation phrases, screened callers get no tools) | Built; tested locally |
| Rate limiting (reschedule link) and notification caps | Built; tested locally |
| CRM card and Spam protection page | Built; browser-tested at 1400 px and 390 px against stubbed responses |
| Create Business wizard settings | Built; browser-tested for restaurant and ecommerce |
| Admin Security & Abuse | Built; browser-tested at 1400 px and 390 px, and with a view-only role |
| Applied to production | **No**: waiting for backup and approval |
| n8n delivery | Uses existing workflows, which are **unpublished** |
