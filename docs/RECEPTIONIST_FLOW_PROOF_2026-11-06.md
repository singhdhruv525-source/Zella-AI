# Business creation → settings → CRM changes → knowledge → the assistant on Vapi (6 Nov 2026)

**Bottom line:** every step up to the call handler is proven on an isolated copy of production through the real
voice-rules code: 11 scenarios, all pass, with evidence in `tests/e2e/out/evidence.json`. The last step, Vapi actually
using it on a phone call, has **not** been proven. No real call was made, and the provider configuration was not read,
because both need your approval and a Vapi key (`tests/e2e/PROVIDER_PLAN.md`). Two defects were found and fixed in
the repository (H1, E2/E3). Neither is applied yet.

## 1. Setup fields that affect calls

**Where a field reaches the call:**
- **prompt:** the instructions built at the start of each call;
- **tool:** server-checked on every tool call, read live;
- **search:** `search_knowledge`, read live from `knowledge_items` with status `ready`.

| Field | Stored | Reaches the call | Notes |
| --- | --- | --- | --- |
| Name, industry, time zone, city/state, website, business phone | `businesses` | prompt; tools (time zone) | |
| Business email, legal name | `businesses` | **not used on calls** (by design) | proven absent from the model input (scenario 11) |
| Greeting, languages | `business_languages` (setup copies `voice_config` there) | prompt: `firstMessage`, transcriber, voice model, language rules | scenario 5 |
| Services, approved prices | `ai_agent_configs.knowledge_base.services` (setup and Settings > Service catalog) | prompt: "SERVICES, the only services you may offer; quote a price only where one is given" | scenario 2. Prices are free text; only the listed price may be quoted |
| Opening hours | `business_hours` | prompt; tools: `check_open_hours`, availability, after-hours replies | scenario 1 |
| Holidays and special hours | `business_closures` | prompt ("Upcoming closures"); tools: `check_open_hours`; **availability (H1, fixed)** | scenario 8; failed before the fix |
| Service area, about, business details, setup FAQs and policies | copied to `knowledge_items` (`setup:`) | search | D2 (applied) |
| Owner's FAQs and documents | `knowledge_items` | search | scenarios 3–4 |
| Booking rules (length, notice, horizon, gap), booking abilities | `appointment_rules` | prompt (tool list); tools | scenario 7; tests/booking |
| Restrictions, booking notes | `knowledge_base.restrictions`, `appointment_rules.notes` | prompt (labelled instructions only; not enforceable) | scenario 9 checks they arrive |
| Transfer destination | `escalation_rules.transfer_to` (and routing precedence, D4) | tool only: `zella_transfer_destination`. The number is **never** given to the model | scenario 6; scenario 11 |
| Handover reasons, emergency | `escalation_rules.triggers` / emergency settings | prompt and tool | tests/escalation |
| After-hours behaviour | `escalation_rules.after_hours_mode` (default take a message) | tool: `zella_ai_voice` | scenario 6 (closed: refused, message offered) |
| Enabled capabilities (scheduling, orders, ...) | `business_capabilities` | tool list (prompt) and tool refusal | matrix, 28 industries |
| Team members | `staff_members` | tools (availability) | contact details proven absent from the model input |

**Saved but unused on calls:**
- the integrations-step calendar and email choices (intent only; the calendar has its own connection);
- `appointments.party_size`, which no booking model reads (restaurant capacity is not built);
- the channel abilities "texts, emails, follow up leads", which no tool reads;
- the agent `goals` field, which reaches the context but not the prompt text.

None of these is presented to owners as something the receptionist does.

**What the model never receives** (checked on the actual assistant JSON, scenario 11):
- credentials or the HMAC secret;
- server keys;
- transfer numbers;
- the business email;
- staff phone numbers and emails;
- any other business's settings.

The server block carries Vapi's credential *id*, which is a reference, not a secret, and is needed by Vapi.

## 2. Building the assistant per business

- **Approach: dynamic, per call.** Vapi sends `assistant-request` at the start of each inbound call to a number with no
  fixed assistant. voice-rules checks the signature, finds the business **from the number only** (the Vapi phone number
  id or E.164), and returns the assistant built from that business's settings at that moment.
- **No fallback:**
  - a number registered to no active business gets a spoken refusal and nothing else;
  - the call's metadata business id is ignored for this lookup;
  - see scenario 0, and tests/assistant (suspended business).
- **Provider support:** confirmed from Vapi's SDK 3.0.0 types.
  - A phone number sends `assistant-request` to its server URL when `assistantId`, `squadId` and `workflowId` are
    unset.
  - The reply `{ assistant }` (or `{ assistantId }`, or `{ error }`) is the documented shape.
  - `fallbackDestination` is used if the request fails.
- **Not verified:** the *actual* configuration of your Vapi numbers (step 1 of the provider plan). Today production
  has 0 numbers registered in `business_phone_numbers`, so per-call delivery cannot work until they are registered.

## 3. Stages and timing

| Stage | Where it shows | Set by |
| --- | --- | --- |
| Draft saved | `zella_assistant_delivery_status.draft`; Knowledge "Draft" | receptionist editor save; knowledge draft |
| Processing / validation pending | version `valid` or `invalid` (with the reasons); knowledge `processing`, then `ready` or refused with the reason | validate; knowledge save check |
| Published configuration ready | version `published`, sync `pending` ("Waiting for the next call") | publish |
| Provider delivery configured | `delivery.configured` (Vapi has asked for this business's assistant), and `last_served.is_current` | the first `assistant-request` |
| Verified in a real call | `verified_call`: a call that received the current fingerprint and completed with a duration | a real completed call only. **Empty in every local run** |

Each call's delivery record holds the fingerprint (`config_hash`) of exactly what that call received (E2). The status
compares it with what a call would get now.

**When a change applies:**
- **New calls:** from the next call. Nothing is cached at the provider. Measured locally: building the assistant takes
  about 80 ms. From the publish to the next call's answer, about 0.6 s.
- **Settings saved outside versions** (hours, services, languages, closures): also from the next call, with a new
  fingerprint.
- **Calls already in progress** keep the instructions, greeting and voice they started with. Everything read through
  tools applies to them at the next tool call:
  - knowledge (scenario 3: an answer added mid-call was found by that call's next search);
  - availability;
  - holidays;
  - transfers;
  - booking refusals.
- **Not measured:** Vapi's own time to fetch the assistant on a real call.

## 4. Knowledge

Answers use **live retrieval**: `search_knowledge` reads `ready` items of the call's own business on every search, and
the prompt carries topic titles only. Scenarios 3–4, through voice-rules:

1. **Added:** used, including by a call already in progress.
2. **Edited:** only the new answer is used.
3. **An empty edit:** refused (`KNOWLEDGE_ANSWER_EMPTY`), and the last good answer stays in use.
4. **Unpublished** (back to draft): not used.
5. **Republished:** used.
6. **Removed** (the CRM's Remove archives the item and keeps the history; there is no hard delete in the CRM): not used.
7. **Business B:** never received A's answer.

A caller's claim, and a model's confident suggestion, never become an answer until an owner, admin, manager or staff
member approves it. Viewers can't (K4, applied; tests/knowledge).

## 5–6. Scenarios and evidence

Two isolated test businesses:
- **A:** Maple Salon, Chicago, `5e000000-…000a`, number +15125558001;
- **B:** Oak Dental, New York, `5e000000-…000b`.

Each scenario ran through voice-rules over HTTP with Vapi-signed messages. "Delivered" is
`outcome:version:fingerprint` from `assistant_deliveries`; `v-` means a setting saved outside versions.

| Scenario | Call ids | Version published | Delivered (before → after) | Result |
| --- | --- | --- | --- | --- |
| 0 number → business (and an unknown number gets nothing) | e2e-a-2, e2e-b-3, e2e-unknown | — | A 5caff600, B 14e5b2eb | PASS |
| 1 hours 9–5 → 10–2 (instructions and offered times) | e2e-a-4, e2e-a-6 | — | 5caff600 → 60524cde | PASS |
| 2 Haircut $40 → $45 (same fingerprint on a repeat call) | e2e-a-9, e2e-a-10 | — | 60524cde → 5e880cf8 | PASS |
| 3–4 FAQ: add, mid-call, edit, refused edit, unpublish, republish, remove; B isolated | e2e-a-12, e2e-a-15 | — | (live search) | PASS |
| 5 greeting and language → "Hola and welcome to Maple Salon!", multilingual | e2e-a-24, e2e-a-25 | — | 5e880cf8 → 633140b2 | PASS |
| 6 transfer: closed → refused, message offered; open: +1512555**0101** → **0109** | e2e-a-26/28/30 | 174e9757 | 550435f7 (unchanged: the number is server-side) | PASS |
| 7 booking off: tools removed, and refused if called anyway; nothing booked | e2e-a-32, e2e-a-33 | 085759a4 | v1 550435f7 → v2 56ddc30d | PASS |
| 8 holiday tomorrow: no times that day; the call is told | e2e-a-36, e2e-a-38 | — | (tools) | PASS (**fails without H1**) |
| 9 stages: pending → live → failed with reason → live; draft shown; no verified call | e2e-a-40/41/42 | 63477986 | live, current | PASS |
| 10 B byte-for-byte unchanged; B's knowledge and transfer unchanged | e2e-b-1, e2e-b-43 | — | same hash | PASS |
| 11 no credentials or private data in the model input | e2e-a-45 | — | — | PASS |

**What this does not show:**
- **Spoken behaviour:** the greeting actually said, and replies in Spanish. Only the configuration and tool answers
  are proven, not what was heard.
- **Vapi's use of the assistant.**
- **Real transfers to a phone.**

That is the provider plan, which needs your approval.

## Defects found and fixed (in the repository; not applied)

- **H1** (`sql/zella_holiday_availability.sql`): holidays and special hours were ignored by availability. Bookings
  could be offered and made on a day the business is closed, by the AI, the CRM and the reschedule link.
- **E2/E3** (`sql/zella_delivery_evidence.sql`): calls weren't tied to the exact settings they received when those
  were saved outside versions, and the status didn't separate delivery configured from a verified real call.

## Blockers

1. **Provider verification** (the plan in `tests/e2e/PROVIDER_PLAN.md`). It needs:
   - your approval;
   - a Vapi key via the credential form;
   - a new test number;
   - two numbers you control as transfer endpoints;
   - someone to place the calls.
2. **Production deployment of voice-rules** (assistant-request), and approval to apply H1 and E2/E3.
3. **PR1:** 0 numbers registered in production. Register each before switching any number.
