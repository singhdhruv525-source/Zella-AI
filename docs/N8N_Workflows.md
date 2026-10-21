# Zella — n8n workflow catalog

Every automation runs the same way: **n8n calls a database function with the service-role key → does the real-world action (Telnyx / Vapi / email) → reports the result back through a function.** The database owns the rules (calling hours, retry limits, consent, idempotency); n8n only moves messages. Functions below are callable only by `service_role`, never by a browser.

Use one Supabase credential in n8n (service role, stored in n8n credentials, never in a workflow body). Call functions with `POST {SUPABASE_URL}/rest/v1/rpc/<name>`.

## A. Queue workers (poll every 1–2 minutes)

| # | Flow | Claim | Act | Report back |
|---|------|-------|-----|-------------|
| 1 | Callbacks | `zella_claim_callbacks(p_limit)` | Start Vapi outbound call (or SMS fallback) | `zella_record_callback_attempt` |
| 2 | Reminders and confirmations | `zella_claim_reminders(p_limit)` | Send SMS / call | `zella_complete_reminder(id, ok, error)` |
| 3 | Follow-up tasks (no-show, quote, reactivation, waitlist offer, post-visit) | `zella_claim_followup_tasks` | Send SMS / email / call | `zella_complete_followup_task` |
| 4 | Staff notifications | `zella_claim_notifications(p_limit)` | Send email / SMS to staff | `zella_fail_notification(id, error)` on failure |
| 5 | Knowledge updates | `zella_claim_knowledge_updates` | Push approved answers to the Vapi assistant | `zella_complete_knowledge_update` |
| 6 | Knowledge drafts | `zella_claim_gaps_for_suggestion` | Ask the model to draft an answer | store the draft for the person to check and submit |
| 7 | Agent config sync | `zella_claim_agent_syncs` | Update the business's Vapi assistant | `zella_complete_agent_sync(version, ok, error)` |
| 8 | Platform alerts | `zella_claim_platform_alerts` | Email the Zella owner | `zella_set_alert_status` |

Rules for every worker: claim first (rows are locked with SKIP LOCKED and the attempt counter goes up), never retry on your own, and always report success or failure — an unreported claim is retried by the database after its timeout.

## B. Schedulers (each is one function call)

| Flow | Function | Every |
|------|----------|-------|
| Missed calls → callbacks | `zella_calls_to_callbacks` | 1 min |
| Overdue leads | `zella_flag_overdue_leads` | 5 min |
| Quote follow-ups | `zella_queue_quote_followups` | 15 min |
| Lead reactivation | `zella_queue_lead_reactivation` | daily |
| No-show follow-up | `zella_queue_no_show_followup` | 5 min |
| Expire held slots | `zella_expire_holds` | 5 min |
| Expire waitlist offers | `zella_expire_waitlist_offers` | 5 min |
| Transfer failures | `zella_detect_transfer_failures` | 5 min |
| Invitation reminders | `zella_check_invitations` (then `zella_mark_invitation_reminded` after each email) | hourly |
| Setup incomplete | `zella_check_setup_incomplete` | daily |
| Trials | `zella_check_trials` | daily |
| Payment policy | `zella_apply_payment_policy` | daily |
| Data retention | `zella_retention_due` | daily |
| Weekly review | `zella_post_weekly_reviews` | Monday morning |

Billing results are reported in with `zella_record_payment_result`. No prices live anywhere in the app.

## C. Tools the Vapi assistant calls (webhook → n8n → database)

| Tool | Function |
|------|----------|
| Find times | `zella_available_slots` |
| Book | `zella_book_appointment` |
| Can't confirm a time | `zella_request_appointment` (stays "requested", never "booked") |
| Hold while customer decides | `zella_hold_slot` / `zella_confirm_hold` |
| Reschedule | `zella_reschedule_appointment` |
| Capture lead | `zella_capture_lead`, `zella_save_qualification` |
| Ask for callback | `zella_create_callback` |
| Question it couldn't answer | `zella_log_knowledge_gap` |
| Call failed | `zella_report_call_failure` |
| Telephony events | `zella_report_telephony_event` |
| Create an industry record (job, vehicle, viewing…) | `zella_ai_save_record` (a possible duplicate becomes a review task, never an overwrite) |
| Customer replies to a reminder | `zella_reminder_response` |
| Waitlist reply | `zella_accept_waitlist_offer` / `zella_decline_waitlist_offer` |

Look up callers with `zella_match_customer` first; uncertain matches become a duplicate review for a person, not a silent merge.

## D. Go-live and health

`zella_activation_report` shows the checklist; the owner's "Request activation" calls `zella_request_activation`. n8n records test results with `zella_record_activation_test`, service health with `zella_report_service_health`, and provisioning stages with `zella_track_provisioning` / `zella_verify_provisioning`.

## E. Safety rules the database already enforces

- Calls only between 9 am and 7 pm in the business's time zone.
- Attempts are capped per automation; callbacks stop when the customer answers, books, or is marked do-not-contact.
- Reminders for an old time are replaced when an appointment moves.
- Automations stay paused until the business is live.
- Members can read their own business only; all writes go through functions.

## F. What still needs real accounts

Nothing here places a call or text until Telnyx, Vapi, an email sender and these n8n flows are connected. Text and calls to customers need their consent (TCPA); build opt-out handling into the SMS flow and keep every message tied to a real prior interaction.
