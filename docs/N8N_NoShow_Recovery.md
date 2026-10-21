# No-show recovery call — n8n + Vapi setup

What it does: when a customer is marked no-show, Zella phones them to offer a new time.
No answer → one more try about 2 hours later (inside calling hours). Two tries total, then it stops and the team sees it in the CRM.

Needs: the "No-show follow-up" automation active for the business, a live phone line (Telnyx), that business's Vapi assistant, and n8n connected.
The database does everything else (queueing, calling hours, retry count, never calling do-not-contact customers).

## n8n workflow (one workflow for all businesses)

1. **Schedule trigger** — every 2 minutes.
2. **HTTP Request** — POST `{SUPABASE_URL}/rest/v1/rpc/zella_claim_followup_tasks`
   Headers: `apikey` + `Authorization: Bearer {SERVICE_ROLE_KEY}`. Body: `{"p_limit": 10, "p_kinds": ["no_show_follow_up"]}`.
   Each returned task is already locked to you and its attempt counter is already incremented — two runs can never take the same task.
3. **Split in batches** — one item per task. Each has `business`, `customer`, `appointment`, `attempts`, `max_attempts`.
4. **HTTP Request → Vapi** — POST `https://api.vapi.ai/call` with:
   - `assistantId`: the business's Vapi assistant
   - `phoneNumberId`: the business's Telnyx-backed number
   - `customer.number`: customer phone
   - `assistantOverrides.firstMessage`: "Hi {first_name}, this is {business_name}. We missed you for your {time} appointment today. Would you like to book a new time?"
   - `assistantOverrides.variableValues`: appointment id, task id, business id
   - `metadata.task_id`: the task id (so the end-of-call webhook can find it)
5. **On Vapi error** → call `zella_complete_followup_task` with `outcome = failed` (retries automatically).

## Vapi assistant tools (call your n8n webhooks)

- `find_times` → `zella_available_slots(business_id, from, to, duration, staff_id)` returns open times (respects hours, breaks, blocked time, existing bookings).
- `move_appointment` → update the SAME appointment (new start/end, status `scheduled`) — never create a duplicate. Only after the customer says yes to a specific time.
- `request_human` → set the call as needs-human.

Script rules: offer 2–3 real times from `find_times`; never promise a time that was not returned; if the customer declines, say thanks and end; if they ask for a person, hand off.

## End-of-call webhook (Vapi → n8n → database)

POST `zella_complete_followup_task` with `task_id` and one outcome:

| What happened | outcome |
|---|---|
| Customer picked a new time | `rescheduled` |
| Customer wants someone to call them | `wants_callback` (flags "Needs a human") |
| Customer says no | `declined` |
| Rang out | `no_answer` |
| Voicemail | `voicemail` |
| Call could not connect | `failed` |

`no_answer`, `voicemail`, `failed` retry once after ~2 hours if attempts remain, then finish. Moving the appointment out of no-show cancels any waiting task automatically.

## Before real calls go out
- Get proper consent for automated/AI outbound calls (US TCPA rules) and keep calls inside local calling hours — the database already limits to 9am–7pm business time. Confirm the details with a lawyer.
- Keep do-not-contact respected (already enforced).
