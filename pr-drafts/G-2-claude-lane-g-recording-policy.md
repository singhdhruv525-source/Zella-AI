Recording on or off per business, off until legal approval is recorded (SET-RECORDING-POLICY)
base: claude/lane-g-voice-providers

## What and why
SET-RECORDING-POLICY: no recording switch existed. Built now, off for every business (D-27, REQ-VOX-09, REQ-BIL-48).
- `sql/zella_recording_policy.sql`: server only `business_recording_policies` (no row means off); settings `recording_legal_approved` = false and `recording_disclosure_text` = "" (the caller disclosure line, empty until legal provides it). A guard trigger refuses any change to those two settings except through `zella_recording_legal_set` (Zella Voice owner only, a reason, the disclosure line to approve; withdrawing approval switches every business off). `zella_recording_policy_set` (businesses.manage; on refused until approved, and a trigger on the table refuses it for any writer). `zella_recording_effective(business)`. Every change audited.
- `owner-provision-business/retention.ts` (new module; hooked like providers.ts): `recording_policy_get`, `recording_policy_set` (RECORD typed to switch on), `recording_legal_set` (owner, APPROVED typed).
- UI: `web/src/settings/panels/RecordingPolicy.jsx` on Settings > Legal, policy and documents > Policy configuration (replaces the "isn't built" note); `SettingsPage.jsx` now passes `me` to that panel.

## Live call path: not changed (needs its own approval)
voice-rules and the assistant config are untouched and don't read the policy. Finding (repository and isolated schema): the assistant config Zella Voice sends never sets Vapi's recording option, so Vapi's own default and dashboard settings decide whether calls are recorded today. Sending "recording off" (or the policy) from voice-rules is a call path change that needs its own approval.

## Defaults taken (owner can change)
- Switching a business on or off needs businesses.manage; legal approval needs a Zella Voice owner.
- Withdrawing legal approval switches every business off at once.

## Keys and settings the owner adds later
`recording_legal_approved` and `recording_disclosure_text`, both through the page (owner only), once legal has reviewed recording consent and the wording.

## Deploy order (each needs the owner's approval)
1. `sql/zella_recording_policy.sql` (after `zella_number_orders.sql`). 2. `owner-provision-business`. 3. Web app.

## Tests
- Automated local, isolated database: `tests/recording_policy/run.sh`: 35 checks, ALL PASSED (gap, apply twice, defaults, on refused before legal by function and by trigger, direct setting changes refused even by the server, other settings unaffected, owner only legal, withdrawal switches all off, audit, direct access denied, number orders rollback refuses while these use its helpers, rollback twice and refusals, drift).
- Deno: `retention_test.ts` (recording part) 5 passed; all owner-provision-business tests 50 passed; `deno check index.ts` ok; lint 0 errors, 0 dashes; vite build ok.
- Local browser: 1440x900 and 390 wide, no page errors, no sideways scroll; On is not offered before legal review; legal approval with the line, a business on, withdrawal switching it off, each audited. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g2-policy-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g2-policy-390.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g2-business-before-legal-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g2-legal-dialog-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g2-after-on-1440.png.

production md5s to be confirmed by the supervisor before apply (new functions only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
