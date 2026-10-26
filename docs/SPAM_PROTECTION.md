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

## Checklist

See the completion report at the end of the session; updated as phases finish.
