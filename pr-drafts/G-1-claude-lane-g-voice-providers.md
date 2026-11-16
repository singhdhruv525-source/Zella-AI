Number orders through Telnyx and Vapi, approved by an owner, switched off (VOICE-PROVIDERS)
base: main

**Depends on PR #88** (`claude/admin-ui-polish-2`): this branch is built on it because both edit `VoiceNumbersPage.jsx` and `AdminPanels.jsx`. Merge #88 first; until then this diff also shows #88's commits.

## What and why
VOICE-PROVIDERS (`docs/ADMIN_AUDIT_2026-11-16.md`): buying and releasing numbers, and the providers' error logs, were not built (Providers said so). Built now, switched off.
- `sql/zella_number_orders.sql`: server only `number_orders`; `zella_number_order_request` (telephony.manage, reason, idempotency key: the same key gives back the same order), `_decide` (a Zella Voice owner who didn't ask: two people for every order), `_claim` (approved to placing once, only by the approver, so a double click never buys twice), `_finish`, `_cancel`, `zella_number_orders_list`. Every step audited in the same transaction. Releases refused while the number is still assigned in Zella Voice; one open order per number. Shared helpers `zella_actor_role`, `zella_actor_can`, `zella_actor_audit` (a verified admin id instead of `auth.uid()`; used by the later lane G files). `number_orders_enabled` = false.
- `owner-provision-business/providers.ts` (new module, hooked into index.ts with an import, `?? PROVIDER_PERMISSIONS[action]` and a handler line next to `platformHandlers`): `provider_overview`, `number_search`, `number_order_request` (typed BUY or RELEASE checked on the server), `number_order_decide` (owner; the number typed; then Telnyx `POST /number_orders`, then Vapi `POST /phone-number`; release: Vapi `DELETE /phone-number/{id}`, Telnyx lookup and `DELETE /phone_numbers/{id}`), `number_order_cancel`, `provider_errors` (Vapi calls ended with an error, Telnyx failed webhook deliveries; read on request, caller numbers shortened, nothing stored). Refused with "Not connected yet" while either key is unset, and while `number_orders_enabled` is off. No answer from a provider records "Check at Telnyx" and is never retried. Provider addresses are injectable (`TELNYX_API_BASE`, `VAPI_API_BASE`; https only, or this machine) and tests use local fakes only.
- UI: new `web/src/admin/ProviderOrders.jsx` (+ pure `numberOrders.js`) on Voice & numbers > Providers & costs, one render line in `VoiceNumbersPage.jsx`; the Settings Telephony "aren't built" note now says what's needed to switch it on.
- Bought numbers are added to Vapi but not assigned to a business: assignment stays the existing audited step.

## Defaults taken (owner can change)
- An owner's own request needs another owner to approve (no self approval).
- Search is US only (D-14), voice and SMS numbers, 10 results.
- A Telnyx success with a failed Vapi import is "Done" with the Vapi step named in the order.
- Reading provider error logs needs telephony.manage.

## Keys and settings the owner adds later
`TELNYX_API_KEY`, `VAPI_API_KEY` (both required), optional `VAPI_TELNYX_CREDENTIAL_ID` (to add bought numbers to Vapi), `TELNYX_CONNECTION_ID`, `TELNYX_MESSAGING_PROFILE_ID`; then `number_orders_enabled` = true (owner).

## Deploy order (each needs the owner's approval)
1. `sql/zella_number_orders.sql` (nothing changes until switched on). 2. `owner-provision-business`. 3. Web app.

## Tests
- Automated local, isolated database: `tests/number_orders/run.sh`: 51 checks, ALL PASSED (gap, apply twice, every refusal, idempotency, two people, single claim, audit order, direct access denied, rollback twice and its refusals, drift).
- Automated local, Deno against a real local HTTP fake of Telnyx and Vapi (any other address fails the test): `providers_test.ts` 17 passed. `deno check index.ts` ok. Web `node --test`: `numberOrders.test.mjs` 3 passed (all web tests 107 passed at the time). `npm run lint`: 0 errors, 0 dashes. `npx vite build` ok.
- Local browser (isolated database, keys unset, then test keys pointed at a local fake): 1440x900 and 390 wide, no page errors, no sideways scroll; an order asked for by a second admin approved by the owner with the number typed reached the fake Telnyx once and the fake Vapi once, and every step was audited. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-providers-off-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-providers-off-390.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-providers-on-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-providers-on-390.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-buy-dialog-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-approve-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g1-after-approve-1440.png.
- Not tested against a real or sandbox provider: request shapes follow the Telnyx and Vapi public API docs and need a sandbox key to confirm.

About 1150 changed lines (about 350 of them tests); it can be split into SQL and UI if reviewers prefer.

production md5s to be confirmed by the supervisor before apply (this file only adds functions; its guard checks this file's own md5s).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
