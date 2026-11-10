# Real-call verification on Vapi: setup and run (needs approval; nothing here has been done)

The local scenarios (`tests/e2e/run.sh`) prove what Zella sends and answers. They do not prove that Vapi uses it. These
steps do, on **test resources only**. No live customer assistant or production number is touched.

## What I need from you

1. **Approval** for each step marked "provider" below. Nothing on Vapi is changed or called without it.
2. **A Vapi API key** saved through the session's credential form for `api.vapi.ai`. It must never be pasted into chat.
   Steps 1 and 7 are read-only.
3. **A new test phone number on Vapi**, not a production number. Buy one in Vapi, or tell me which unused one to take.
4. **Two numbers you control** as transfer endpoints, for example two mobiles, to test transfer A and transfer B.
5. **Someone to place the test calls**, or approval for Vapi outbound test calls to a number you control.

## Steps

| # | Kind | What | Evidence kept |
| --- | --- | --- | --- |
| 1 | provider, read | `GET /phone-number` and `GET /assistant`: record which numbers have a fixed `assistantId`, and their `server` URL and credential. No change | a list (ids and settings only; no transcripts) |
| 2 | database, prod | Deploy `voice-rules` (assistant-request) and apply `zella_holiday_availability` and `zella_delivery_evidence` | apply record |
| 3 | database, prod | Create two **test businesses**, `ZTEST Maple Salon` and `ZTEST Oak Dental`, each with an owner test account. Register the test number to ZTEST A in `business_phone_numbers` with its Vapi id | business ids |
| 4 | provider, change | On the **test number only**:<ul><li>`assistantId` = null;</li><li>`server.url` = the voice-rules URL;</li><li>`server.credentialId` = the existing HMAC credential;</li><li>`fallbackDestination` = transfer endpoint A, used only if voice-rules fails</li></ul> | the number's settings before and after |
| 5 | call | Run the ten scenarios of `tests/e2e/scenarios.mjs` by phone:<ul><li>Make each CRM change in the real CRM as the test owner.</li><li>Then call the test number and ask the scenario's question.</li><li>For "B unchanged", re-register the number to ZTEST B and call again.</li></ul> | per call: the Vapi call id, `assistant_deliveries` (config hash, version), tool calls (`ai_tool_calls`), transcript and recording (test data) and the answer heard |
| 6 | check | `zella_assistant_delivery_status` shows delivery configured and a **verified call** whose fingerprint is the current one | status JSON |
| 7 | provider, read | `GET /call/{id}` for each test call: confirm Vapi used the transient assistant (its `firstMessage` and model messages) and called voice-rules for its tools | call JSON (test data) |
| 8 | undo | Set the test number back to how step 1 found it; archive the ZTEST businesses | settings after |

## What "verified" means

A scenario passes only if all of these hold:
- the call's Vapi id appears in `assistant_deliveries` with the fingerprint of the settings at that moment;
- the tool results in `ai_tool_calls` for that call id match;
- what the assistant said, from the transcript or recording, matches the expected answer.

For greeting and language, the check is the spoken first sentence and a reply in Spanish to a Spanish question.

## Risks and how they're contained

| Risk | Containment |
| --- | --- |
| A customer is affected | Only a new test number is changed. Production numbers keep their fixed assistant |
| voice-rules fails | Vapi uses `fallbackDestination` (transfer endpoint A) instead of hanging up |
| A wrong business | The number is registered to exactly one ZTEST business. An unknown number gets a spoken refusal, never another business's settings (local scenario 0) |
| Messages sent | Sending stays off, and no SMS or email automation is enabled |
