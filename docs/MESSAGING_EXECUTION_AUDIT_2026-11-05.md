# Messaging and reminder execution audit (5 Nov 2026)

Question: does every setting an owner picks for an automation (setup wizard step "Automations", and Settings >
Automations, both from `web/src/automationOptions.js`) reach the code that queues and sends the message, and does a
later change reach messages already queued?

Method: every option key was traced to the database function that reads it (`trigger_config ->> '<key>'`, checked
against the function definitions on an isolated copy with the 17 pending migrations), then each mismatch was
reproduced in a test (`tests/messaging/`). Production was only read (counts of automation settings and pending
reminders by channel; no customer data copied). Texting and email sending are off in production, so none of this has
reached a customer yet.

## Propagation by automation

| Automation | Setting (key) | Read by | Verdict |
| --- | --- | --- | --- |
| Appointment reminder | hours_before | `zella_replace_reminders` (on booking / change) | OK when booked. **M4**: a later change didn't reach queued reminders |
| | channel (Text / AI call / Text and AI call) | `zella_replace_reminders` → `appointment_reminders.channel` | **M3**: call options were queued but never sent |
| Booking confirmation | hours_before | `zella_replace_reminders` | OK. **M4**: switching off didn't withdraw queued ones |
| | channel (Text / AI call) | same | **M3** |
| No-show follow-up | minutes_after, channel | `zella_queue_no_show_followup` | OK |
| Missed-call callback | minutes_after, max_attempts, fallback_sms | `zella_create_callback`, `zella_record_callback_attempt` | OK |
| New-lead callback | minutes_after, max_attempts, retry_after_hours, fallback_sms | `zella_create_callback`, `zella_record_callback_attempt` | OK |
| | contact_within_minutes / escalate_after_minutes | `zella_capture_lead` / `zella_flag_overdue_leads` | OK |
| Post-visit follow-up | hours_after | `zella_appointment_after` | OK |
| | channel (Text / Email) | `zella_appointment_after` | **M2**: Email was sent as a text |
| Quote follow-up | hours_after, max_attempts | `zella_issue_quote` | **M1**: read other key names, so the defaults were always used |
| | channel (Text / Email) | `zella_queue_quote_followups` | **M2** |
| Lead reactivation | days_inactive, channel | `zella_queue_lead_reactivation` | OK (Email used when the customer has a valid address) |
| Waitlist offer | offers, offer_minutes | `zella_offer_slot` | OK |
| | channel (Text / AI call) | `zella_offer_slot` | **M5**: always a text (documented, not changed) |
| Staff unavailable | channel (Text / AI call) | `zella_handle_staff_unavailable` | OK |

## Findings

**M1 Quote follow-ups ignored their timing and tries.** The screens save `hours_after` (24/48/72) and `max_attempts`
(1-3); `zella_issue_quote` read `every_days` and `max_follow_ups`, so every quote got 3 follow-ups every 3 days. Fixed:
the saved names are read first (hours rounded up to whole days), the old names still work.

**M2 "Send by: Email" was never used** for quote and post-visit follow-ups: anything that wasn't `call` was queued as
a text. Fixed: Email is used when the customer has a valid email address, otherwise a text as before. The email sender
already handles both kinds (`n8n/src/email-task-plan.js`).

**M3 Reminders and confirmations set to "AI call" or "Text and AI call" were never sent.** They were stored as channel
`call` / `sms_and_call`, but `zella_claim_reminders` only claims `sms` and `email`, so they stayed pending for ever and
no failure count showed them. AI reminder calls aren't built. Fixed: they are queued as texts; the screens and the
setup function no longer offer the call options; an automation saved with them is switched to text, keeping what was
asked as `channel_requested`; pending reminders with another channel are moved to text.

**M4 Changing or switching off reminders didn't reach reminders already queued** for future appointments; the sender
re-checked the appointment, not the automation. Fixed: a change to the reminder automation re-plans the waiting
reminder rows of that business's future appointments (`zella_resync_reminders`; waiting booking confirmations are
kept), switching confirmations off withdraws waiting confirmations, and the sender skips a reminder whose automation
is no longer on (`automation_off`) as a safety net.

**M5 Waitlist offers set to "AI call" go as a text.** `zella_offer_slot` always queues `sms`. Texts are sent, so nothing
is lost, but the setting has no effect. Not changed: decide whether to build AI waitlist calls or remove the option.
Production has no waitlist automation.

## Production (read only, 5 Nov)

Every reminder automation, confirmation automation and pending reminder uses text; the only follow-up automations are
two post-visit ones set to text (one disabled, one paused). No waitlist, quote or reactivation automations. So the
data part of the fix changes no existing row, and M1/M2/M4/M5 have no current customer impact.

## Change and tests

- `sql/zella_message_settings_fix.sql` (class M, **not applied**; run after the 17 pending migrations and
  `sql/zella_setup_enforcement.sql`; safe to run twice). Rollback: `sql/rollback/zella_message_settings_fix_rollback.sql`
  (generated by `python3 -I tests/setup/make_rollback.py messaging`).
- `web/src/automationOptions.js`, `web/src/CreateBusinessWizard.jsx`: call options removed for reminders and
  confirmations. `owner-provision-business/index.ts`: saves those as text (**not deployed**).
- `tests/messaging/run.sh` builds an isolated copy and runs `settings_fix_test.sql`:
  - with the fix: M1, M2 (quote, post-visit with and without email), M3, M4 pass; the rollback restores the five
    functions exactly (md5) and removes the new ones; the fix applies again after it.
  - `WITHOUT_FIX=1`: fails at the first check ("a call reminder was queued"), as expected.
