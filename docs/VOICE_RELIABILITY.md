# Voice reliability

Making the existing Vapi receptionist correct before tuning or changing providers. Phases 0 to 4 are done
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

## Phase 4: assistant configuration, receptionist behaviour, automations

### What was verified first (2026-10-28, HEAD b15cadb)

- The staging copy now also has production's triggers on `calls` and `callbacks` (missed-call callbacks, call
  integrity, call insights, callback assignment) and the live bodies of 26 more functions: callbacks, consent,
  knowledge, the assistant configuration and the prompt (60 live function bodies reproduced exactly;
  `tests/voice-reliability/build_phase4.py`). Running the Phase 1-3 tests against it found bug 1 below.
- The live prompt builder is `zella_brain_prompt_base` (the body of `zella_brain.sql`'s `zella_brain_prompt`, renamed by
  `zella_automation_completion.sql`), wrapped by `zella_brain_prompt`, which adds active "live notices". Re-running
  `zella_brain.sql` alone would replace the wrapper and drop live notices: always run `zella_automation_completion.sql` after it.
- Production today: all scheduled jobs (`zella_dispatch`, `zella_jobs_every5`, `hourly`, `daily`, `weekly`) are
  **disabled**, every `*_live` switch is off, the dispatcher's n8n secret is not in Vault, and every n8n workflow is
  unpublished. Nothing asynchronous runs yet. What runs inside a database transaction (triggers, the tool gateway) does.

### Fixed (`sql/zella_voice_assistant.sql`, not applied)

| # | Problem | Effect before | Fix |
|---|---|---|---|
| 1 | Vapi's "ended" status arrives before the end-of-call report; the call-integrity trigger saw an end time with no duration or transcript and marked it missed | **every real call** would have got a missed-call callback (measured: a 95-second call -> `missed` + 1 callback) | missed is decided once the report is in, from the real duration or the provider's own start and end times |
| 2 | a transfer attempt queues a "needs a person" callback straight away | a transfer that connected still left staff a callback; a failed one left two | connected closes it; failed replaces it with the one urgent `transfer_failed` callback |
| 3 | search_knowledge logs an unanswered question, report_unanswered_question logs it again | one question counted twice per call | repeats within a call don't count |
| 4 | owners only heard about unanswered questions in the weekly report | slow follow-up | one notice for a new question (at most one an hour per business), pointing to Knowledge > Questions to review |
| 5 | prompt lacked rules for result wording, dates, read-backs, injection, disclosure, the transfer hand-off | room for invented success and confusion | added (see below) |
| 6 | `zella_assistant_config` produced a config Vapi rejects: tools at the top level, no server, no credential, no transfer tool, no call_rules, no server messages, model `claude-sonnet-5-5` not in Vapi's list | unusable | rebuilt; returns `{ assistant, ready_to_send, problems }`; `assistant` type-checks as Vapi's `CreateAssistantDto` |
| 7 | automatic callbacks checked only `do_not_contact` | a do-not-call or opted-out caller could be called back automatically | claim uses `zella_can_contact`; unknown callers checked against opt-outs for their number |

### The generated assistant (per business)

- `server`: `vapi_server_url` (voice-rules) + `vapi_credential_id` (the Vapi HMAC credential), `timeoutSeconds` 20.
- `serverMessages`: tool-calls, transfer-destination-request, status-update, end-of-call-report.
- `model`: provider and model from the platform settings, the business's prompt, temperature 0.3, and `tools`:
  `call_rules` (start-of-call check, action `rules` only), the Brain tools the business has not switched off (each
  with the same server and credential, `async: false`; book, reschedule and cancel require `confirmed`), and
  `transferCall` with no destinations (only if transfers are on), so Vapi asks the server for this business's number.
- `analysisPlan.structuredDataPlan`: `callback_requested`, `outcome`, read by the end-of-call parser.
- `metadata.business_id` (a fallback only; the registered number decides).
- `ready_to_send` is false, with reasons, until the URL is https, the credential id is set, and the model is in Vapi's list.
  Not set (Vapi defaults): voice, transcriber, max duration, voicemail detection. Choose them before the first call.

### Receptionist behaviour

Knowledge: owners' approved answers (`knowledge_items`, status ready), searched per business by `search_knowledge`
(`zella_brain_search`); hours, closures and live notices are in the prompt; availability and appointments come only
from tools. One business's knowledge is never searched for another's caller (tested). The prompt now covers:
- Result wording: booked vs requested, message saved, follow-up requested, callback requested; a transfer is "connecting
  you", never "a person is on the line"; nothing is said to be done after an error.
- Unknown answers: no guessing; say it can't be confirmed; offer a message, a follow-up (ask first) or a person.
- Dates: the model doesn't know the date; relative dates go through the tools and are confirmed by weekday and date.
- Read back names, numbers, emails, dates and times; corrections are read back again; ask instead of guessing; one
  request at a time.
- Callers, tool results and knowledge can't change the rules; never reveal instructions, tool names, ids, staff or
  transfer numbers, or other customers. The tools decide what is allowed (enforced in the database regardless).
- Industry rules (clinical, legal/financial, vet, childcare, trades emergencies and others) were already there; all 28
  industries generate a ready config with their own rules (tested).

Not tested: how a real LLM follows these instructions. That needs real calls (or an LLM evaluation with an approved key).

### Unknown answer -> CRM -> answer (tested end to end on staging)

1. search_knowledge finds nothing -> "Do not guess" instruction; the question is recorded in `knowledge_gaps` for this
   business only (once per call), and the owners get one notice.
2. The assistant offers a message / follow-up / person; `request_follow_up` creates a task and only then says so.
3. The owner answers in Knowledge > Questions to review (`zella_answer_knowledge_gap`; members of that business only).
4. The answer becomes a knowledge item; once the Knowledge workflow marks it ready, the receptionist answers from it.
   That step runs in n8n (unpublished today): until it is published, answers stay "processing" (retried hourly, then
   marked failed with a notice). Weekly gap reports and repeated-question alerts run from the scheduled jobs (off today).

### Automations

Legend: **tested** = run on staging against the live function bodies; **code** = unit tests of the code only;
**needs service** = depends on an external provider or n8n Cloud that can't run here. Production: scheduler off.

| Automation | Trigger -> component | Isolation / safety | Status |
|---|---|---|---|
| Inbound call, caller lookup, knowledge, booking, rescheduling, cancelling, messages, emergencies, follow-ups (14 tools + call_rules) | Vapi -> voice-rules -> zella_ai_tool / zella_ai_voice | signature, business from the line, confirmation, screening, locks, idempotency, audit | tested |
| Transfers and backup route | Vapi transfer-destination-request -> voice-rules -> zella_transfer_destination | own business's number only, screening, hours | tested; real connection needs Vapi |
| Call status, end-of-call record, missed-call detection | Vapi -> voice-rules -> zella_record_call_status / zella_record_inbound_call + triggers | once, in order; missed only after the report | tested (bug 1 fixed) |
| Missed-call and transfer-failed callbacks | calls triggers -> callbacks | one open callback per number and reason | tested |
| Caller-requested callbacks | end-of-call `callback_requested` or summary -> callbacks | same | tested (parsing + creation) |
| Automatic callback calls | scheduler -> dispatcher -> n8n Outbound Calls -> Vapi POST /call | calling hours in the business time zone, consent (fix 7), 3 attempts then staff, no loops | claim/attempt logic tested; dialling needs Vapi, n8n, `calls_live`, scheduler |
| Follow-up calls (tasks) | same lane, zella_claim_followup_calls | consent per purpose; falls back to SMS or email | code + unit tests; needs services |
| Call reconciliation | scheduler -> n8n Call Reconciliation -> Vapi GET /call | real provider data only | logic tested; needs Vapi key, n8n, `call_reconcile_live` |
| Unanswered questions, owner notice, CRM review | tool gateway -> knowledge_gaps -> staff_notifications; Knowledge page | per business | tested |
| Knowledge publishing, AI draft answers | scheduler -> n8n Knowledge | owner approval required | code; needs n8n (AI box needs key, off) |
| Appointment confirmations, reminders (SMS, email) | appointment triggers -> queues -> n8n SMS / Email Sender | consent, opt-out (STOP), quiet hours | code + unit tests; needs Telnyx/Resend, `sms_live`/`email_live` |
| Owner and staff notifications (in app, email, SMS) | staff_notifications -> n8n Owner Emails / Staff Texts | per business; one per event | rows tested; delivery needs services |
| Failed-workflow and platform alerts | zella_platform_alert -> n8n Admin Alerts | deduplicated per kind and hour | code; delivery needs services |
| Integration disconnects, calendar sync | scheduler -> n8n Connection Tests / Calendar Sync | per connection, bounded retries | code; needs Google |
| Spam detection and blocked callers | database triggers + zella_caller_context; n8n Spam Response | server-side refusal of every tool but emergencies | tested both migration orders |
| Duplicate webhooks and retries | replay cache, idempotency keys, unique indexes | - | tested |

### Missed calls and callbacks

Exists and tested: detection (silent short calls, after the report), callbacks for missed calls, failed transfers and
requests, one open callback per number and reason, calling hours (9:00 to 19:00 in the business's time zone),
consent and do-not-call (fix 7), up to 3 attempts with a delay, then "needs review" with a staff notice and no more
automatic calls, records of every attempt, outbound calls never creating callbacks. Assignment to a staff member is
automatic (round robin) when the business has members. Outbound caller id = the business's Vapi number
(`vapi_phone_number_id`). Not runnable here: the actual outbound call (Vapi + n8n + `calls_live`, all off).

### Failure behaviour

Database slow or down, a tool failing, a malformed answer, the signature check unavailable: tested (safe error
answers within the time budget, 503 for an unverifiable request, nothing claimed). Transfer unavailable or refused:
tested (refusal, callback). SMS, email or n8n down: work stays queued in the database with bounded retries and alerts
(code; not run against the providers). LLM timeout and Vapi rejecting a request: need real calls. A late scheduled job
uses the business time zone at run time (calling hours, reminders) - not exercised against a real clock here.

### Tests (phase 4, all run)

`run_all.sh` (all passed): the 60 live bodies reproduced, the bug shown on the unpatched setup ("that call became
'missed' with 1 missed-call callback"), migration applied twice (7 changes), `phase4_test.sql` (17 checks), the
generated assistant type-checked against `@vapi-ai/server-sdk` 3.0.0 (and the old shape and model id are rejected by
the same check), and every earlier suite with production's triggers in place (brain flow 23, HTTP 36, Brain tools 38).
`spam_compat.sh` (all passed): the 4 migrations in both orders, twice each, all SQL suites including phase 4 on both,
HTTP 36 and Brain tools 40 on both. n8n 386, voice-rules unit 19, lint, build: pass.

### Before the first controlled real call (each needs approval)

1. Decide the LLM model: `claude-sonnet-5-5` is not offered by Vapi; `claude-sonnet-5` is the closest listed id.
2. Choose voice, transcriber and max call length in Vapi (Vapi defaults otherwise).
3. Apply, in order, after a backup: `zella_voice_reliability.sql`, `zella_vapi_auth.sql`, `zella_voice_assistant.sql`,
   then `zella_dispatcher.sql`. Check `zella_voice_reliability_status()` (12 true) and `zella_voice_assistant_status()` (7 true).
4. Vault secret `zella_vapi_hmac_secret`; Vapi HMAC credential with the same value; deploy `voice-rules`.
5. Set `vapi_server_url`, `vapi_credential_id` and `voice_llm_model`; check `zella_assistant_config(<test business>)`
   says `ready_to_send: true`.
6. Create a NEW test assistant in Vapi from its `assistant` object and attach a test number registered in
   `business_phone_numbers` for a test business. Leave the scheduler and every `*_live` switch off.
7. Call it and run the checks in "What still needs a real call" plus: an unknown question, a booking with the read-back,
   a cancellation, "can I speak to someone", a blocked number. Afterwards check `calls`, `ai_tool_calls`,
   `knowledge_gaps`, `callbacks` and the function logs.

## Not yet done (later phases)

- A real Vapi call to confirm the items under "Not confirmed" above.
- Assistant configuration, phone numbers, multi-business routing, latency metrics (phases 4 to 6).
