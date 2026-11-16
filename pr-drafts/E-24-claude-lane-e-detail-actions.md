Business page actions: reveal, invitation cancel and cooldown, member support, pause and resume, grant a pack (web; needs owner approval before deploy)
base: claude/lane-e-detail-calls

**Needs owner approval before deploy**, together with the server halves it calls (PRs 14 to 18).

## What and why
The web halves of plan PRs 13 to 18. Every action uses one `business/ActionDialog.jsx` (DialogFocus, Escape safe,
a reason with its length rule, errors kept inside, "Not available yet" when the server doesn't know the action).
- **BIZ-22 (PR 14):** "Show contact details" on People (businesses.manage) asks for a reason; the revealed emails
  replace the masked ones for this visit only (component state; leaving the page hides them). Activity's Support
  access list is in the controls PR.
- **BIZ-21 (PR 15):** "Cancel invitation" with a reason; Resend greyed with "It can be sent again at <time>" while
  the 5 minute cooldown runs (`business/people.js` mirrors the server's rule for display only).
- **UI-06 (PRs 16, 17):** each member row: Deactivate or Reactivate with a reason; "Reset two step" (only when the
  member has it on) needs the "I checked who is asking" box and a reason.
- **UI-09 part b, BIZ-07 (PR 13):** Automations: Pause, and Resume only when the business is live, through the
  applied `zella_admin_automation_set_status` (integrations.manage, audited); "Set up" for automations not set up
  (the wizard, businesses.manage); "Manage in Automations"; the description says turning one on starts it on a live
  business.
- **CFG-22 (PR 18):** Overview Usage card: "Grant a pack" (billing.manage) with a pack select from
  `business_pack_catalog`, a reason, and a `crypto.randomUUID()` key kept for the dialog's life.

## Not in this PR
- Revealed call numbers and connection accounts are returned by the server but only emails are swapped in on People;
  the Calls tab reads the masked `zella_admin_calls` list.
- `/automations/directory?business=<id>`: reading it is lane D's page (polish PR #88 touches it).
- The Deactivate button still shows for the only owner; the server refuses it (409) with a clear message.

## Defaults taken (owner can change)
- Pause and Resume gated on integrations.manage (as the RPC requires); Set up on businesses.manage.

## Deploy order
Web after each server half is deployed (each action degrades to "Not available yet" before that).
Known gap (critic): `zella_admin_automation_set_status` is a browser RPC that skips the function's two step check until
`sql/zella_admin_mfa.sql` is applied; once applied, it needs the same MFA_REQUIRED handling as edge calls (ACC-34).

## Tests
- Automated local: `node --test web/tests/*.test.mjs` 132 pass, 0 fail (new `businessPeople.test.mjs`).
  `npm run lint` passes; `npx vite build` passes.
- Local browser (isolated `zle_ui`, the real function), as `admin@zella.test`, 1440x900 and 390 wide,
  deviceScaleFactor 1, no page errors, no failed requests, no sideways overflow: reveal is disabled without a reason,
  then shows `owner@lanee.test`; Reset two step stays disabled without the identity box; Deactivate then Reactivate
  the staff member; Pause then Resume an automation; Grant a pack shows "Pack granted". The isolated database then
  holds `support.contacts_revealed`, `member.suspended`, `member.reactivated`, `automation.paused`,
  `automation.resumed` with the typed reasons and `billing.pack_granted` with the admin's id. Screenshots in
  `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-e/shots/`:
  `act_reveal_dialog_1440.png`, `act_people_1440.png`, `act_people_390.png`, `act_automations_1440.png`,
  `act_automations_390.png`, `act_grant_1440.png`, `act_grant_390.png`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
