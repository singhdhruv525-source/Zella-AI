Support replies the business sees and answers, first response in business hours, alerts for urgent requests (OPS-25, OPS-27 part)
base: claude/lane-a-audit-export

## What and why

**OPS-25.** Admins could only add internal notes; the business saw a list of its tickets with no thread; urgent, cancellation and plan change requests raised no alert; there was no first response time (REQ-BIL-47, REQ-CRM-26).
- `sql/zella_support_replies.sql`: `support_ticket_messages` (members of the business read their tickets' messages; nobody writes it directly), kept apart from the internal `support_ticket_notes`; `support_tickets.first_response_at`; `zella_admin_ticket_reply` (server only; sets first_response_at once, moves an open ticket to in progress, tells the opener in the app only: `delivery_status` and `sms_status` skipped); `zella_business_ticket_reply` (owners, admins and managers of that business; reopens a resolved ticket); a trigger raising platform alerts `support_cancellation_request`, `support_plan_change_request`, `support_urgent_ticket` for requests from Settings (`zella_business_request` is not replaced); setting `support_business_hours`.
- owner-provision-business: `ticket_update` takes `reply` (audited in ticket.updated as reply_added); `tickets_list` returns the conversation, age and first reply in business hours and an overdue flag (no reply after 4 business hours), reads the hours setting, and tolerates the migration not being applied yet.
- Support tickets: Conversation with the business (Send reply) apart from Internal notes, the first reply line, a Waiting too long filter and a No reply yet badge.
- Settings > Help and support > Support requests: Conversation per request; owners, admins and managers answer; staff and viewers read. The "replies by email" text is gone; attachments remain not available.
- **OPS-27 (part):** `tickets_list` filters by status and business on the server and offers as assignees only people who may work tickets (owner, super admin, roles with support.manage). Paging stays at the newest 500.

## Defaults taken (owner can change)

- Business hours: Monday to Friday 9:00 to 17:00 America/New_York, first reply goal 4 business hours (`platform_settings.support_business_hours`, `SUPPORT_HOURS_DEFAULT`). No editor yet: the platform settings allowlist belongs to lane D.
- Reply notices in the app only, never email or text.
- Alert severity: urgent for cancellation and urgent issues, info for plan changes.

## Deploy order (each step needs the owner's approval)

1. `sql/zella_support_notes.sql` must be applied first (PR #83, merged, not applied).
2. Apply `sql/zella_support_replies.sql`.
3. Deploy `owner-provision-business`.
4. Deploy the web app.

## Tests

- Isolated database `tests/support_replies/run.sh` (zprod3 with sql/zella_support_notes.sql loaded first; also on the full chain): ALL PASSED. The gap first; applies twice; server only admin reply; first_response_at set once; in app notice only; owner, staff and viewer read, another business and anonymous don't; internal notes hidden; owner and manager answer, staff, another business and anonymous refused; no direct writes; reopen; alerts for cancellation, plan change and urgent, none for feedback or an ordinary issue; the setting; rollback refuses while replies exist, then runs twice; reapply; VERSION_MISMATCH and DRIFT.
- Deno: business hours across nights, weekends and the clock change; the setting read safely; overdue rule. All tests pass; `deno check`.
- Web unit tests, lint (the drift test caught the three new alert kinds until labelled), build.
- Local browser `tests/browser/support-replies.cjs` at 1440x900 and 390 wide: an owner sends an urgent request (alert raised), support replies and notes, the owner reads the reply but never the note and answers, staff read without an answer box and are refused by the database; no page errors. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/support/admin-reply-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/support/admin-reply-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/support/business-thread-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/support/business-thread-phone.png

## Production md5s to be confirmed by the supervisor before apply

All new; the guard expects them absent, or exactly this file's version on a rerun:
- `zella_admin_ticket_reply(uuid,uuid,text)`: 4cfcb7b1370b215f3c58ba007890aba8
- `zella_business_ticket_reply(uuid,text)`: 74292f8c7c40bb7035c6606a86fc6d89
- `zella_support_ticket_alert_trg()`: 7c1e68b078a07f8f175eaf593ec52eb2

Computed on an isolated database (zprod3, then `zella_writing_cleanup.sql`, then the merged unapplied migrations).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
