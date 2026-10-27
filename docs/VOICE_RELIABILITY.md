# Voice reliability

Making the existing Vapi receptionist correct before tuning or changing providers. Phases 0 and 1 are done
(branch `voice-reliability`); nothing here has been applied to production or configured in Vapi.

Target: phone call → telephony → Vapi → secure Zella endpoint → Supabase. n8n only for work that doesn't make the
caller wait (post-call processing, notifications, follow-ups, outbound, reconciliation).

## Phase 0: what the live system looked like (2026-10-27)

| Finding | Status | Evidence |
|---|---|---|
| No call has ever reached Zella: 0 rows in `calls`, `ai_tool_calls`, `business_phone_numbers`; `vapi_assistant_id`, `vapi_phone_number_id`, `brain_tools_url` empty | CONFIRMED | production, read-only queries |
| Booking writers check availability, then write, with no lock and no overlap constraint | CONFIRMED | live `zella_book_appointment`, `zella_hold_slot`, `zella_confirm_requested_appointment`, `zella_reschedule_appointment` |
| 20 simultaneous bookings of one free slot: **7 to 18 appointments** (varies per run) | CONFIRMED (measured on a staging copy) | `tests/voice-reliability/run_all.sh` |
| 20 identical in-flight AI booking retries: 1 booked, **19 told "could not be completed"** (unique index on finished tool calls) | CONFIRMED (measured) | same |
| 20 different callers via the AI tool: **2 to 7 booked into one slot** | CONFIRMED (measured) | same |
| No unique key on `calls.external_call_id`; 10 parallel first tool calls made **7 to 9 rows for one call** | CONFIRMED (measured) | same |
| Brain Tools answered only the first tool call in a request | CONFIRMED | old `n8n/workflows/zella-brain-tools.json` "Plan" |
| Brain Tools reply dropped the transfer number and caller screening; Voice Rules handed the raw number to the model | CONFIRMED | old reply code |
| Call history depended on the end-of-call report alone; a report without a duration stored 0 seconds | CONFIRMED | live `zella_record_inbound_call` |
| Staff create appointments directly in the CRM without availability checks (deliberate double booking possible) | CONFIRMED, kept | `BusinessForms.jsx`, `BusinessMore.jsx`, `BookingPanel.jsx` |

The staging copy is built from the repo's SQL and checked against production: every one of the 33 live function
bodies involved is reproduced byte for byte (md5 of `prosrc`, `tests/voice-reliability/prod_md5.txt`).

## Phase 1: what changed

**Booking concurrency** (`sql/zella_voice_reliability.sql`). The four booking writers, and the AI booking path, take a
per-business transaction lock (`zella_booking_lock`) before checking availability. All customer, AI, reschedule-link,
waitlist and social booking paths go through them. The availability rules are unchanged (hours, staff, durations, time
zones, holds, requested bookings). A database-wide overlap constraint was not used: blocking depends on time (holds
expire) and staff may deliberately double-book in the CRM. Identical consequential tool requests wait for each other
(`zella_ai_tool`), so a retry or redelivered webhook returns the first result.

**Every tool call answered.** Brain Tools is now built by `n8n/src/build.mjs` (it was hand-edited JSON outside the
tests): one item per tool call, each with its own `toolCallId`, collected into one `{ results: [...] }`. Failures use
Vapi's `error` field; unknown tools still get an answer and do nothing; every answer is one line. The `voice-rules`
edge function does the same for `call_rules`.

**Transfers.** The model is never given the number. When Vapi asks (`transfer-destination-request`), `voice-rules`
answers with `zella_transfer_destination`: the business comes from the call record or registered number only, and
the number from that business's own receptionist settings (enabled, valid E.164, open hours if required, backup route,
spam screening). Otherwise the transfer is refused. The outcome is recorded from Vapi's ended reason:
`assistant-forwarded-call` means connected; anything else after an attempt means failed, which feeds the existing
repeated-failure alert and backup switch.

**Call tracking.** One row per provider call id (unique index plus `on conflict` in both writers). Vapi
`status-update` events (ringing, in-progress, forwarding, ended) create the call as it starts and are applied once
and in order (`zella_record_call_status`, from Call Results in n8n and from `voice-rules`). Calls whose report never
arrives are fetched from Vapi's API (`GET /call/{id}`) by the new **Zella - Call Reconciliation** workflow
(`zella_calls_to_reconcile`, `zella_reconcile_call`; off until `call_reconcile_live`). No invented data: a missing
duration stays empty, and an estimated end time is labelled `received_time`.

`zella_voice_reliability_status()` shows which patches are in place. Re-running an older source file
(`zella_workflows.sql`, `zella_ai_booking.sql`, `zella_brain.sql`, `zella_voice_rules.sql`, `zella_inbound_calls.sql`)
restores an unpatched function, so this file must run after them.

## Tests (phase 1, all run)

`tests/voice-reliability/run_all.sh` builds the staging copy, applies the migration twice and runs everything below,
before (unpatched) and after:

- 20 simultaneous bookings → 1; mixed book/hold/reschedule → 1; two free staff → 2 (not over-restricted)
- 20 identical in-flight AI retries → 20 × "booked", 1 appointment; 20 different callers → 1 booked, 19 offered other times
- confirmation, business hours, holds, requested bookings, business isolation and staff direct bookings unchanged
- 10 parallel first tool calls → 1 call row; status events in order, once; unknown number → no row
- lost report → reconciled from the provider record (real duration); late report ignored; transfer outcome recorded
- transfer destination: own business only; refused for unknown line, transfers off, invalid number, closed, screened
- Brain Tools code nodes against the patched functions: 6 tool calls → 6 answers, partial failure kept, redelivery safe
- `voice-rules` over HTTP: multiple tool calls, transfer-destination-request, status-update, 401/400/405

Not covered yet: a real Vapi call, the workflows running inside n8n, slow-database and n8n-outage behaviour (phases 3
and 7), and anything on production.

## Not yet done (later phases)

- Signature verification and replay protection for Vapi requests (phase 2). Today: a static shared secret.
- Moving the 14 brain tools off n8n (phase 3); the Brain Tools workflow is still the endpoint `brain_tools_url` names.
- Pointing Vapi's server URL at an endpoint that can answer `transfer-destination-request`. The n8n Call Results
  webhook replies before it runs, so it can't; `voice-rules` can (phase 2/4 decision).
- Assistant configuration, phone numbers, multi-business routing, latency metrics (phases 4 to 6).
