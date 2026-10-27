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
| Calls | `voice-rules` edge function -> `zella_ai_voice` -> `zella_caller_context` (the assistant's `call_rules` tool at the start of the call) | Blocked or high-risk callers: the AI is told to end politely and take no actions. Answered by the backend directly, never through n8n. |
| Calls | `zella_ai_voice` transfer / message during the call | A screened caller can't be transferred or leave a callback, whatever the AI asks for; emergencies are always allowed |
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

## What must never depend on n8n

Detection, scoring, call screening, booking holds, block lists, rate limits, tenant authorization and saving the
incident all happen in the database (and, for calls, the `voice-rules` edge function) before n8n is involved.
A slow or stopped workflow can't let a blocked caller through, hold a call up, or lose an incident.

```
Vapi call ──> voice-rules (edge) ──> zella_ai_voice / zella_caller_context ──> decision back to Vapi
                                                         │
          texts, emails, bookings, calls ──> triggers ──>│ zella_spam_assess ──> zella_spam_record ──> spam_incidents
                                                                                                       │ (queued: medium/high)
                                                         dispatcher ──> n8n "Zella - Spam Response"    │
                                                         Evaluate severity ─ log ─────────────────────┐ │
                                                                          └ alert / investigate        │ │
                                                         Check repeat offender ─ (Ask AI, optional) ──┤ │
                                                         zella_spam_finish_work: re-checks, decides, ◄┘ │
                                                         notifies, applies approved policy, records ────┘
```

## Spam Response workflow (n8n)

Workflow **Zella - Spam Response** (`n8n/workflows/zella-spam-response.json`, instance id `a7Nfsi9mkQbBmc0L`,
**unpublished**), lane `spam-response` on the existing dispatcher. No new tables: it adds workflow columns to
`spam_incidents`, three settings to `spam_settings`, and one history kind (`workflow`).

| Responsibility | Where |
|---|---|
| Severity routing (log / alert / investigate) | n8n (advisory) — the database decides severity again |
| Configurable notifications (high, optionally medium), escalation to urgent for repeat offenders | `zella_spam_finish_work`, through the existing staff notifications (Owner Emails, Staff Texts) |
| Repeat-offender investigation | counts from `zella_spam_sender_facts` (this business, other businesses as counts only) |
| Approved policy | 24 h channel-only restriction only if auto-restrict is on and the team confirmed this sender twice (none marked "not spam"); platform alert when confirmed at 3+ businesses — admins decide global rules |
| AI classification | optional, medium-risk texts/emails only, redacted, monthly cap; stored as a suggestion; never blocks |
| Weekly report | `zella_spam_save_report`, once per business per week |
| Idempotency and retries | claim tokens, replay refused, backoff 5/20/45 min, failed after 3, stuck runs reclaimed after 10 min |
| Fallback | `zella_spam_hourly` sends the high-risk alert itself if the workflow hasn't within 15 minutes |

Off by default (`spam_workflow_live`); while off, incidents are handled in the database exactly as before (high-risk
alerts written immediately). Alerts are emailed by the existing **Owner Emails** workflow and platform alerts by
**Admin Alerts**; both are **unpublished**, so today alerts appear in the apps but aren't emailed. The
`zella_spam_hourly` cron job is created **inactive**.

### Environment and settings

| Name | Where | Purpose |
|---|---|---|
| `ZELLA_VAPI_SECRET` | Supabase function secret (new) | the `X-Zella-Secret` value Vapi sends to `voice-rules` |
| `ZELLA_SERVER_SECRET_KEY`, `SUPABASE_URL` | Supabase function secrets (existing) | server access for `voice-rules` |
| `spam_workflow_live`, `spam_ai_live`, `spam_ai_model`, `spam_ai_monthly_limit` | `platform_settings` (Admin > Security & Abuse > Automation) | switches and limits, all off / conservative by default |
| `n8n_base_url`, Vault `zella_n8n_secret` | existing | the dispatcher calling n8n |
| "Zella Supabase service role", "Zella gateway secret" | n8n credentials (existing, already attached) | workflow access |
| Anthropic key | n8n "Ask AI" box, by hand | only if AI review is switched on |

## Deployment (needs approval)

1. Take a backup, then apply `sql/zella_spam_protection.sql` (safe to run more than once; undo steps at the top), then
   re-run `sql/zella_dispatcher.sql` (adds the `spam-response` lane; it also re-schedules the Zella timers, as at go-live).
2. Deploy edge functions `voice-rules` (new), `owner-provision-business` and `reschedule-appointment`; set `ZELLA_VAPI_SECRET`.
3. In Vapi point the `call_rules` tool at `.../functions/v1/voice-rules` (header `X-Zella-Secret`); test with a blocked number.
4. Publish "Zella - Spam Response" in n8n and switch it on in Admin > Security & Abuse > Automation.
5. Optional: AI review (Anthropic key on "Ask AI", then switch on); turn on `zella_spam_hourly`; publish Owner Emails and Admin Alerts.

Until step 1 the CRM card reads "Not set up yet", the CRM page and admin page explain what to apply, and the wizard
saves everything except spam settings (reported, not faked).

## Known limits and risks

- Not carrier-level: a blocked caller is answered and the AI ends the call. Rejecting before connect needs Vapi's
  `assistant-request` server URL, which is not configured and hasn't been tested against a Vapi account.
- Screening at call start relies on the assistant calling `call_rules` first (its prompt says so); transfers and
  callbacks are refused by the database regardless, but a misbehaving assistant could still talk to the caller.
- The n8n "Voice Rules" workflow in the instance still has the old reply (drops the screening note); the repo copy is
  fixed. Moving Vapi to `voice-rules` makes that moot.
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
| Spam Response workflow | Built; 369 n8n tests; code nodes run against the real database functions (16 checks); created in n8n **unpublished** |
| Workflow backend (queue, claim/finish, policy, AI gate, reports, fallback) | Built; 18 database checks on a local Postgres copy |
| `voice-rules` edge function + screened-caller guard | Built; 8 unit tests; 9 end-to-end checks against the rebuilt production `zella_ai_voice` |
| Applied to production | **No**: waiting for backup and approval |
| n8n delivery | Existing Owner Emails / Admin Alerts, **unpublished** |
