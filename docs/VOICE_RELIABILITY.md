# Voice reliability

Making the existing Vapi receptionist correct before tuning or changing providers. Phases 0 to 3 are done
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
| Brain Tools, Voice Rules, Appointment Booking and Assistant Tools answered only the first tool call in a request | CONFIRMED | old "Plan" code of each workflow |
| Appointment Booking called the booking functions directly, skipping `zella_ai_tool`: no caller confirmation, no retry protection, no result check, no audit row | CONFIRMED | old `n8n/src/booking-tool-plan.js` |
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
Vapi's `error` field; unknown tools still get an answer and do nothing; every answer is one line. The same holds for
Voice Rules, Assistant Tools and Appointment Booking in n8n, and for `call_rules` in the `voice-rules` edge function.
Appointment Booking now uses the Brain Tools code limited to its five tools, so it goes through `zella_ai_tool`
(confirmation, retry protection, result check, audit). Its Vapi tools need the boolean `confirmed` added.

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

## Phase 2: endpoints and authentication

### What Vapi supports (checked 2026-10-27)

docs.vapi.ai is blocked from the build environment, so the source is Vapi's own server SDK, `@vapi-ai/server-sdk`
3.0.0 (published 2026-10-09, generated from Vapi's API schema), plus Vapi's server-authentication page as listed by
search. Confirmed from the schema:

| Topic | What the schema says | Used how |
|---|---|---|
| Authentication | A `Server` (assistant, tool or phone number) takes a `credentialId`; credential types: **HMAC**, **Bearer**, OAuth2. Static `headers` can be added too | HMAC by default, Bearer as a fallback |
| HMAC | `secretKey`; `algorithm` sha256 / sha512 / sha1; `signatureHeader` default `x-signature`; `timestampHeader` default `x-timestamp`; `includeTimestamp` default true; `payloadFormat` default `{timestamp}.{body}`; `signatureEncoding` default hex; optional `signaturePrefix`, `messageIdHeader`, `secretIsBase64` | Exactly these defaults, sha256 |
| Bearer | `token`, header default `Authorization`, `Bearer ` prefix by default | Exact token |
| Tool calls | `message.type = tool-calls`, `toolCallList[]` of `{ id, type, function: { name, arguments (string) } }` | Both this and `{ id, name, arguments }` accepted |
| Tool reply | `{ results: [{ name, toolCallId, result? , error?, message? }] }` (`name` required) | `name` added to every answer (it was missing) |
| Where tool calls go | first of tool.server.url, assistant.server.url, phoneNumber.server.url, org | Brain tools keep their own n8n URL; `call_rules` uses the assistant URL |
| Async tools | `async: true` means Vapi does not wait for the answer | Every Zella tool must stay synchronous |
| Transfer | Transfer tool with no destinations -> `transfer-destination-request` to the server URL. Reply `{ destination: { type: number, number, message? }, message?, error? }`; `error` = "the transfer should not be made" | Refusal uses `error` (now confirmed) |
| Status update | `status` scheduled, queued, ringing, in-progress, forwarding, ended, not-found, deletion-failed; `endedReason` only when ended; `timestamp` is a number (unit not stated) | ringing to ended recorded; ms assumed, seconds detected |
| End-of-call report | `endedReason`, `startedAt` / `endedAt` (ISO), `artifact.transcript`, `artifact.recordingUrl`, `analysis.summary` / `structuredData`, `cost`; no duration field | Fixed: these were read from old top-level names, so transcripts and recordings were lost and every callback without `durationSeconds` counted as "no answer" |
| GET /call/{id} | `id, status, startedAt, endedAt, endedReason, phoneNumberId, customer, artifact, analysis` | Reconciliation reads these (unchanged) |
| Timeouts, retries | `Server.timeoutSeconds` default 20; `backoffPlan` default none (no retries), `maxRetries`, `excludedStatusCodes` | Budget 12 s per request, 4 s per database call; leave retries off |

**Not confirmed (needs a real call):** the HMAC timestamp's unit (seconds or ms, both accepted); whether a retry is
re-signed with a new timestamp; whether HMAC (or any credential) applies to `transfer-destination-request`,
`status-update` and `end-of-call-report` the same as to tool calls; the exact `phoneNumber` / `call.type` values on
real inbound calls; whether `endedReason` is `assistant-forwarded-call` after every successful transfer.

### Request paths

| Request | Vapi waits? | Goes to | Answer |
|---|---|---|---|
| `call_rules` tool (hours, message, emergency, transfer) | yes | `voice-rules` edge function (assistant server URL) | per tool call, after the database |
| 14 Receptionist Brain tools (incl. booking, reschedule, cancel, unanswered question) | yes | phase 2: n8n Brain Tools (`responseNode`: answers only after `zella_ai_tool`); since phase 3: `voice-rules` | per tool call |
| Transfer (`transfer-destination-request`) | yes | `voice-rules` | authorised number or refusal |
| `status-update` | no | `voice-rules` | `{}` after recording |
| `end-of-call-report` | no | `voice-rules` | `{}` after recording (callbacks and follow-up calls included, via call metadata) |
| Outbound callback / follow-up call | - | n8n Outbound Calls starts it (`POST /call`); its events come back to the same assistant server URL | - |
| Reconciliation | - | n8n Call Reconciliation, every few minutes when calls are missing a report | - |

The n8n Call Results webhook acknowledges before it runs, so it can never answer a transfer request: the assistant server
URL moves to `voice-rules`. Call Results stays (secured, same parsing code) until the switch is verified. The old
Voice Rules, Assistant Tools and Appointment Booking webhooks are not part of the target setup; they are secured the
same way in case they stay imported.

### Authentication and replay protection

- **One check, in the database** (`sql/zella_vapi_auth.sql`, `zella_vapi_authenticate(raw body, headers)`), used by the
  edge function and by every Vapi-facing n8n webhook (Read request -> Check signature -> Signed). The secret is only
  in Vault (`zella_vapi_hmac_secret`); the edge function, n8n and the browser never hold it.
- **HMAC mode (default):** sha256 over `{timestamp}.{exact body bytes}` must match `x-signature` (hex). The timestamp
  must be within 5 minutes of the database clock. A signature that has been accepted once is stored
  (`vapi_request_receipts`) and refused the next time: a replay, even inside the 5 minutes, gets 401 before anything runs.
- **Bearer mode** (`vapi_auth_mode = bearer`, token `zella_vapi_bearer_token`): exact token only. No expiry and no
  replay protection: use only if HMAC can't be set up.
- **Fails closed:** no secret, an unknown mode, or a database that can't be reached means every request is refused
  (401 or 503). There is no "off". The old `X-Zella-Secret` header alone is no longer accepted by `voice-rules`;
  n8n keeps it as an extra outer check.
- **Order:** size limit -> signature -> JSON shape -> action. A refused request reads or writes nothing except the receipt.
- **Limits:** a valid request can't be refused as a replay unless it's an exact duplicate; if Vapi retries without
  re-signing, the retry is refused (Vapi retries are off by default, and every action is idempotent anyway). The
  receipt table is cleaned opportunistically (rows older than 15 minutes).

### Also fixed in phase 2

- **Screened callers were only blocked by instruction.** With spam protection applied, a caller on a business's call
  block list could still book, look up appointments or update details if the model ignored the instruction.
  `zella_ai_tool` now refuses every tool except `report_emergency` for a screened caller (`zella_ai_tool_screening`).
- **"Booked" for a request.** When spam protection's booking rule (or anything else) kept a booking as a request, the
  gateway still told the assistant "booked". Now it says "requested" (`zella_ai_tool_confirmed_only`).
- Tool answers carry `name`; status timestamps in seconds no longer become 1970; malformed messages get 400.

### Tests (phase 2, all run on staging copies)

- `auth_test.sql` (15): right signature, replay, one-byte body change, changed timestamp, missing / malformed headers,
  other secret, 400 s old or ahead, ms timestamp, bearer in HMAC mode, non-ASCII body, bearer mode, unknown mode,
  no secret, anon / signed-in users can't call it or read receipts.
- `edge-e2e.mjs` (36): over HTTP with real HMAC signatures: no / wrong / tampered / expired / replayed signatures (and
  a replayed tool call returns no data), malformed JSON, 405, 413, multiple tool calls with names, transfer allowed /
  refused (other business, unregistered line, no call), business routing by registered number, end-of-call report
  (duration from Vapi's times, transcript, recording), late and repeated events, slow database (safe answers within
  the budget), slow or unreachable signature check (503).
- `brain-flow.mjs` (+3): the n8n gate code against the real check (accepted, replayed, gateway header alone refused).
- `spam_compat.sh`: all three migrations in both orders, twice each; booking race, call rows, rules, lifecycle,
  transfer and auth tests on both; blocked-caller checks; the HTTP suite on the spam-last database.
- `n8n/test.mjs` and `voice-rules` unit tests: the gate is the only way into each Vapi workflow's plan; tool names;
  end-of-call fields; event times; malformed messages.

Not run: anything against real Vapi, n8n Cloud or production.

### What still needs a real call (test assistant, test number)

1. A signed tool call reaches `voice-rules` and is accepted (proves header names, payload format, timestamp unit).
2. Two tools in one turn: both answered and spoken correctly (`name` + `toolCallId`).
3. A brain tool (n8n) with the credential and `X-Zella-Secret` header: accepted, answered within the timeout.
4. Booking: the assistant asks for confirmation, then books once; a retry does not double-book.
5. Transfer: `transfer-destination-request` arrives signed, the business's number is dialled; a closed business or a
   blocked caller is refused and the assistant says so; `transfer_status` is recorded.
6. `status-update` events and the end-of-call report arrive signed; `calls` has real times, duration, transcript.
7. A request replayed by hand (same headers and body) gets 401; one with an old timestamp gets 401.
8. A callback placed by Outbound Calls: its report updates the callback with the right outcome.

## Phase 3: Brain tools off n8n

### Verified before changing anything (2026-10-27, HEAD bef9171)

All 14 Receptionist Brain tools were already implemented in ONE audited database function, `zella_ai_tool`
(`sql/zella_brain.sql`, patched by `zella_voice_reliability.sql`). n8n Brain Tools only parsed the request, looked up
the business, called `zella_ai_tool` once per tool call and formatted the answers. So the move is a move of that thin
layer, not of any booking or business logic: no SQL changed in phase 3.

Before: Vapi -> n8n Brain Tools (webhook, signature check, plan, number lookup, `zella_ai_tool`, reply) for the 14
tools; Vapi -> `voice-rules` for `call_rules`, transfers and call events.
After: Vapi -> `voice-rules` for everything synchronous (all tools, transfers) and for call events. n8n keeps only
work nobody waits for (follow-ups, notifications, outbound calls, integrations, reconciliation, spam follow-up).

### The 14 tools

Every tool: arguments checked for shape, only known fields kept (strings trimmed, max 1500 characters; numbers finite),
the caller known only by the network number, the business from the call row or the registered number (never from
the model), then `zella_ai_tool`, which refuses tools the business switched off, refuses screened callers (except
emergencies), requires `confirmed=true` where marked, serialises and remembers consequential calls by
`<call id>:<tool call id>`, verifies the result and writes `ai_tool_calls`. Every database call: 4 s limit, 12 s per
request; on failure, timeout or a malformed answer the tool gets `{ error }` and nothing is claimed.

| Tool | Inputs (validated) | Answer (`result` JSON) | Database | Side effects | Idempotency | Status |
|---|---|---|---|---|---|---|
| search_knowledge | query | status confirmed / partial / no_information, results (title, answer) | zella_brain_search, zella_report_unanswered | none, or a knowledge gap logged when nothing is found | read; repeat may count the question again | moved |
| check_open_hours | - | status open / closed, open, can_transfer, emergency_words | zella_ai_voice (rules) | creates the call row if none | read | moved |
| lookup_caller | - | recognised + first_name, or not_recognised | customers (exact single match on the network number) | none | read | moved |
| update_caller | first_name, last_name, email, phone, preferred_contact_method (call/sms/email) | saved / need_info | zella_capture_lead or customers update (own business, own record) | creates or updates the caller's customer | consequential, once per tool call | moved |
| check_availability | date (YYYY-MM-DD), days (1-14), duration_minutes (5-480) | slots: times (say, start) | zella_ai_booking (availability) | none | read | moved |
| book_appointment | start (as offered), first_name, last_name, phone, email, title, notes, duration_minutes, confirmed | booked / requested / need_confirmation / unavailable / unverified | zella_ai_booking -> zella_book_appointment (per-business lock, hours, staff, holds) | appointment (or request), notifications by the normal rules | consequential, needs confirmed, once per tool call; retries wait for the first | moved |
| find_my_appointments | - | appointments (appointment_id, title, say) | zella_ai_manage_booking (find) | none | read | moved |
| reschedule_appointment | appointment_id (uuid from find), start, confirmed | rescheduled / need_confirmation / unverified | zella_ai_manage_booking -> zella_reschedule_appointment | moves the caller's own appointment | consequential, needs confirmed, once | moved |
| cancel_appointment | appointment_id, confirmed | cancelled / need_confirmation / unverified | zella_ai_manage_booking | cancels the caller's own appointment | consequential, needs confirmed, once | moved |
| take_message | message, name, phone | message_saved | zella_ai_voice (message) | call_messages row, callback | consequential, once | moved |
| report_emergency | summary | transfer / alerted / not_enabled | zella_ai_voice (emergency) | call_messages, owner alert, urgent callback, transfer attempt | consequential, once; allowed for screened callers | moved |
| transfer_to_human | reason | transfer (use_transfer_tool; number never in the answer) / no_one_available | zella_ai_voice (transfer); the number comes later via transfer-destination-request | call marked for a person, callback if no one is available | consequential, once | moved |
| request_follow_up | reason, when | requested | zella_create_task | follow-up task | consequential, once | moved |
| report_unanswered_question | question | logged | zella_report_unanswered | knowledge gap (max 5 per call) | not consequential in the tool list: a repeat counts the question again (needs a tool-list change; left unchanged) | moved |

Needs design work, left unchanged: `report_unanswered_question` and `search_knowledge` are not marked consequential,
so a redelivered tool call can count a question twice (harmless, capped at 5 per call; changing it means changing
`zella_brain_tool_defs`). `zella_assistant_config` builds per-tool server URLs from `brain_tools_url` but no
`credentialId`, so a config sent as-is would be refused by the signature check; Vapi assistant configuration is
phase 4.

### Migration, step by step

1. One shared implementation of the thin layer (`web/supabase/functions/_shared/vapi-brain-tools.js`): parsing,
   argument checks, the `zella_ai_tool` arguments and the answer format. n8n Brain Tools inlines it at build time and
   the edge function imports it, so both send the same database call and give the same answer (tested).
2. `voice-rules` routes each tool call by name: `call_rules` -> `zella_ai_voice`, the 14 -> `zella_ai_tool`, anything
   else -> error answer. Same signature check, replay protection, limits and failure answers as phase 2.
3. Cut-over is per tool in Vapi (each tool's server URL), so it can be done one tool at a time, read-only tools first:
   check_open_hours, lookup_caller, search_knowledge, check_availability, find_my_appointments; then take_message,
   report_unanswered_question, request_follow_up, update_caller; then book / reschedule / cancel; then
   report_emergency and transfer_to_human (after a transfer test).
4. Rollback for any tool: point its server URL back at n8n Brain Tools (kept, rebuilt with the same shared code). No
   database change to undo.

Never two executions of one side effect: Vapi sends each tool call to exactly one server URL. Even if the same tool
call reached both endpoints, both go through `zella_ai_tool` with the same idempotency key, so a consequential tool
runs once and the second gets the saved result (tested by redelivery).

### Latency (staging, measured)

Staging: `voice-rules` on Deno -> `mock-rest.mjs` -> local Postgres 16. mock-rest starts a new psql process per
database call (about 31 ms each, measured), real PostgREST does not, so absolute numbers are pessimistic; the
comparison uses the same setup on both sides. `tests/voice-reliability/bench.sh`, n = 40, ms:

| Request | Phase 2 code (bef9171) p50 / p95 | Phase 3 code p50 / p95 |
|---|---|---|
| call_rules, 1 tool call | 146 / 165 | 118 / 137 |
| call_rules, 3 tool calls | 290 / 320 | 126 / 140 |
| lookup_caller (Brain tool) | n8n path not measurable here | 112 / 122 |
| 3 Brain tools | n8n path not measurable here | 124 / 134 |
| status-update | - | 80 / 91 |

Phase 3 breakdown (3 Brain tools): signature check 35, business lookup + rate limits (together) 39, tools (together)
47. Inside Postgres the same functions take: `zella_vapi_authenticate` 0.10 / 0.21, `zella_business_for_number`
0.04 / 0.15, `zella_ai_tool` lookup_caller 0.73 / 1.48, check_availability 0.37 / 1.28 (p50 / p95). So the time is
round trips, not database work: a request is three round trips after the change (check, lookup, tools) instead of
2 + 2 per tool call. 0 non-200 answers and 0 tool errors in all measured runs. The n8n Cloud path was not measured (no
n8n instance in staging; the workflows point at production), so no claim is made about n8n vs edge.

### Tests (phase 3, all run)

- `brain-e2e.mjs`: 37 checks on the reliability database, 40 on each spam-protection order (adds screening and the
  rate limit): all 14 tools over signed HTTP with their real effects, answers in order with names, confirmation
  required (missing or "yes" as text), redelivery = one appointment and one audit row, replay = 401, 10 simultaneous
  HTTP bookings of one time = 1, another business's line can't see, cancel or search this business's data, malformed
  arguments refused before the database, unknown tools, one tool's database call failing, malformed database answer,
  slow database (answers within the budget), business lookup down, call_rules and Brain tools mixed, Server-Timing.
- `voice-rules` unit tests: 19 (4 new). `n8n/test.mjs`: 386 (2 new: n8n and edge build the same database call and
  answer; the shared tool list equals the database's).
- The test database stand-in now runs calls concurrently (it ran them one at a time before, which hid parallelism).

## Not yet done (later phases)

- A real Vapi call to confirm the items under "Not confirmed" above.
- Assistant configuration, phone numbers, multi-business routing, latency metrics (phases 4 to 6).
