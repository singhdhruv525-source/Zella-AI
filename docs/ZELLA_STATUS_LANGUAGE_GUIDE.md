# Zella Voice: status language guide

The user-facing words for Zella's system states. Internal values (database `CHECK` constraints, API fields, webhook
payloads) are never renamed for wording; the label is mapped in `web/src/copy/labels.js` (`humanize`, `callResult`)
or, where a screen needs a context-specific label, in that screen.

Internal values were read from the live database's `CHECK` constraints on 30 Oct 2026. "Source" says whether the
state is confirmed by an external system (provider callback), set by Zella itself, or inferred.
**Review** marks states whose exact moment of assignment was not verified in code and should be confirmed by
engineering before the label is relied on for support answers.

## Calls (`calls.status`)

| Value | Label | Meaning | Source | Next actions |
|---|---|---|---|---|
| `initiated` | In progress | The call record exists; the call hasn't been answered yet. | Vapi event | Wait |
| `ringing` | In progress | The line is ringing. | Vapi event | Wait |
| `answered` | Answered | Someone (the AI receptionist or the team) picked up. | Vapi event | View call details |
| `completed` | Answered | The call was answered and has ended. | Vapi end-of-call report | View details, set outcome |
| `missed` | Missed | Nobody answered. | Vapi event | Call back, schedule callback, mark followed up |
| `failed` | Didn't connect | The call couldn't be connected (provider or network failure). | Vapi event | Call back if the number is known |

Before 30 Oct 2026 every status except `missed` was shown as "Answered", and the "Answered" filter and the Reports
"answered" count included failed and still-ringing calls. Now only `answered` and `completed` count as answered.
**Review:** confirm whether `completed` can ever be set for a call nobody answered (for example a voicemail
end-of-call report). If it can, the label "Answered" is wrong for that case.

"Handled by" is a separate fact: `ai_handled` = "AI receptionist", otherwise "Team".
"Needs a person": the call has an open escalation (`isOpenEscalation`): the AI receptionist handed it over.

### Transfers (`calls.transfer_status`)

| Value | Label | Meaning |
|---|---|---|
| `not_needed` | Not needed | No transfer was requested. |
| `attempted` | Attempted | Zella tried to transfer; the result isn't known yet. |
| `connected` | Connected | The caller was connected to a person. |
| `failed` | Failed | The transfer was tried and didn't connect. |
| `no_one_available` | No one available | No authorized number was available (on-call rota or hours). |

## Text messages and emails (`sms_messages.status`, `email_messages.status`)

| Value | Label | Meaning | Source |
|---|---|---|---|
| `queued` | Queued | Waiting to be handed to the provider. | Zella |
| `sent` | Sent | Accepted by the provider (Telnyx or Resend). **Not proof of delivery.** | Provider API response |
| `delivered` | Delivered | The provider reported delivery to the phone or mailbox. | Provider webhook |
| `failed` | Failed | The provider refused it or reported a delivery failure. | Provider response or webhook |
| `received` | Received | An incoming message from the customer. | Provider webhook |
| `dry_run` | Not sent (test mode) | Live sending is off (`sms_live` / `email_live`), so it was recorded but never sent. | Zella |
| `blocked` | Blocked | Zella refused to send it (opt-out, spam rules or quiet hours). | Zella |

Rules: never show "Delivered" for `sent`; never show `dry_run` as sent. **Review:** the exact reasons that produce
`blocked` should be listed so the label can say why ("Not sent: the person opted out").

## Scheduled sending: reminders, follow-ups, social posts

`appointment_reminders.status`, `followup_tasks.status`, `meta_outbox.status`

| Value | Label | Meaning |
|---|---|---|
| `pending` / `queued` | Scheduled (with its due time) | Waiting for its time or for the sender. |
| `sending` / `in_progress` | Sending | Being sent right now. |
| `sent` / `done` | Sent / Done | Handed to the provider (reminders) or completed (follow-ups). |
| `failed` | Sending failed | Zella tried and couldn't send it (after its retries). |
| `cancelled` | Canceled | No longer needed (for example the appointment was canceled). |
| `skipped` | Skipped | Deliberately not sent (for example no consent or no contact details). |

**"Sending failed" page** (`/app/failed`, formerly "Didn't send"): lists rows with status `failed` from the last 7
days (`zella_failed_work`). It means a send *attempt* failed. It does not distinguish "the provider rejected it" from
"no provider is connected" except through the stored reason (`outcome` / `error`), which is shown in words
(`dry_run…` reasons as "Not sent (test mode: no provider connected)"). **Retry sending** resets the row to pending
(`zella_retry_failed`); success means "queued to send again", not "sent". Reminders whose appointment has passed
can't be retried.

`staff_notifications.delivery_status`: `pending`, `sending`, `sent`, `failed`, `skipped`, same labels as above.

## Appointments (`appointments.status`)

| Value | Label | Meaning |
|---|---|---|
| `scheduled` | Scheduled | Booked, not yet confirmed by the customer. |
| `confirmed` | Confirmed | The customer confirmed. |
| `completed` | Completed | The visit took place. |
| `cancelled` | Canceled | Canceled by the customer or the business (reason in `cancel_reason`). |
| `no_show` | No-show | The customer didn't come. |

The industry's own word replaces "appointment" (Booking, Reservation, Service call).

## Callbacks (`callbacks.status`)

| Value | Label | Value | Label |
|---|---|---|---|
| `new` | New | `contacted` | Contacted |
| `scheduled` | Scheduled | `reschedule_requested` | Reschedule requested |
| `due` | Due | `retry_scheduled` | Retry scheduled |
| `in_progress` | In progress | `waiting_on_customer` | Waiting on customer |
| `completed` | Completed | `escalated` | Escalated |
| `cancelled` | Canceled | `needs_review` | Needs review |

## Conversations, tasks, messages for the team

- `conversations.status`: `open` Open, `pending` Pending, `closed` Closed.
- `crm_tasks.status`: `open` Open (or "Due …"), `done` Done, `cancelled` Canceled.
- `call_messages.status`: `new` New, `read` Read, `handled` Handled.
- `message_drafts.status` (Suggested messages): `pending` Waiting for approval, `sent` Sent, `dismissed` Dismissed.
  Nothing in Suggested messages is sent until a person presses Send.

## Automations

- `automations.status` / `ai_agents.status`: `active` Active, `paused` Paused, `disabled` Turned off.
- `automation_runs.status`: `queued` Waiting to run, `running` Running, `waiting` Waiting, `completed` Done,
  `failed` Failed, `cancelled` Canceled.
- `automation_events.status`: `received`, `processing`, `processed`, `failed`, `rejected` (admin only).
- `workflow_executions.status`: `running`, `succeeded`, `failed`, `cancelled` (admin only).

## Integrations

- `integrations.status`: `active` Active, `inactive` Inactive, `error` Error, `disconnected` Disconnected.
- `meta_connections.status`: `connected` Connected, `needs_reconnect` Needs reconnecting, `error`, `disconnected`.
- `calendar_connections.status`: `active`, `paused`, `error`, `disconnected`.
- `review_sources.status`: `active`, `paused`, `error`.

"Error" alone is weak: where the screen knows the reason it should add it ("Error: sign-in expired, reconnect").
**Review:** providers' error reasons are not yet stored in a consistent field.

## Knowledge base

- `knowledge_items.status`: `draft` Draft, `processing` Processing, `ready` Ready (the receptionist can use it),
  `failed` Failed, `archived` Archived. Items become ready only through the n8n Knowledge workflow.
- `knowledge_gaps.status` (unanswered questions): `open` Open, `answered` Answered, `dismissed` Dismissed.
- `ai_answer_reports.status`: `open`, `fixed`, `dismissed`.
- AI-written answers are never labeled "verified"; they are suggestions until a person approves them.

## Accounts, billing, access

- `subscriptions.status`: `trial` Trial, `active` Active, `renewal_due` Renewal due, `past_due` Past due,
  `grace_period` Grace period, `cancelled` Canceled, `expired` Expired.
- `payments.status`: `pending`, `processing`, `succeeded` Succeeded, `failed`, `refunded` Refunded, `cancelled`.
- `business_invitations.status`: `pending`, `sent`, `accepted`, `expired`, `failed`, `revoked`.
- `business_members.status`: `invited`, `active`, `suspended`.
- Roles: owner Owner, admin Admin, manager Manager, staff Staff.
- `contact_consents.status`: `opted_in` Opted in, `opted_out` Opted out.

## Review, spam, verification

- `business_verification_documents.status`: `pending_review` Awaiting review, `verified` Verified, `rejected`,
  `replaced` Replaced.
- `spam_incidents.status`: `new`, `under_review` Under review, `confirmed_spam` Confirmed spam, `false_positive`
  Not spam, `resolved`, `escalated`.
- `reviews.status`: `drafted` Draft ready, `approved`, `posting` Posting, `posted` Posted, `skipped`, `failed`,
  `replied_elsewhere` Replied elsewhere.
- `lead_submissions.status`: `accepted`, `duplicate`, `spam`, `invalid`, `rate_limited` Too many attempts, `failed`.

## Values not listed

`humanize()` turns any other value into readable words ("receptionist.voice_changed" → "Receptionist voice
changed", "ai_setup" → "AI setup", "cancelled" → "Canceled"). An unlisted value showing up on a business screen is
a sign it needs an entry here and in `labels.js`.
