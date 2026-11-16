Business page cards: readiness, go live checklist, plan, usage, numbers, alerts, routing, what callers get (web only)
base: claude/lane-e-detail-controls

## What and why
The web halves of plan PRs 10 and 11, reading payload v2 (PR 9). Every card is left out on an older server (field
absent) and says "Not available right now" when the server couldn't read its part.
- **BIZ-11:** Readiness (the server's `zella_business_readiness` ladder, `business/readiness.js`, replaces the
  browser-computed Setup progress when present; it explains that "Voice connection" reads the empty connections
  table), Plan (price only when `pricesShown`), Usage this period (included, used, left, the message reserve), Phone
  numbers, Open alerts (critic: there is no alerts page, so the link goes to Platform operations, `/operations`).
- **BIZ-12 phase 1:** Go live checklist, read only, from `zella_activation_report` and the latest test call (only for
  businesses.manage, as the server decides).
- **UI-06 part b:** People shows Last sign in and Two step when `signInFactsAllowed`.
- **UI-07:** Call routing card (put through, transfer number with the transfer_to.phone fallback, fallback number,
  route, hours) with an advisory "To test" line (the page never places a call) and "Open call routing".
- **COM-03:** What callers get: the next call's configuration (led by config_hash, never "version N"), the last
  served call and whether it matches, the published version and sync, the last not ready reason and the 7 day count.
- **UI-08:** numbers card on Phone & integrations with "Assign a number" (`/voice/numbers?assign=<id>`, only with
  telephony.manage), the fallback number, and the old "Live connections" card renamed "Connection records" with
  honest wording.
- **VoicePanel (critic):** the refusal no longer says "Only owners, admins and managers" to a Zella Voice admin; it
  names who can change the voice. "Hear a voice": the copy says how (call the business's number; a saved voice is used
  from the next call); playback needs a provider and is deferred.

## Not in this PR
- Moving the wizard's RUNGS ladder into a shared component (plan): `CreateBusinessWizard.jsx` is lane B's file; the
  Overview ladder is its own small component.
- `VoiceNumbersPage.jsx` reading `?assign=` to open the assign dialog prefilled: lane D's file. Until then the link
  opens the numbers page.

## Defaults taken (owner can change)
- Alerts card links to Platform operations.

## Deploy order
Web only; safe before or after the PR 9 edge deploy.

## Tests
- Automated local: `node --test web/tests/*.test.mjs` 131 pass, 0 fail (new `businessReadiness.test.mjs`).
  `npm run lint` passes; `npx vite build` passes.
- Local browser (isolated `zle_ui` with seeded test plan, period, balances, number, alerts, delivery), 1440x900 and
  390 wide, deviceScaleFactor 1, no page errors, no failed requests, no sideways overflow:
  - `admin@zella.test` (owner): Overview shows Readiness, Go live checklist, Plan with $99.00, Usage, the number,
    Open alerts and no "None"; People shows Last sign in and Two step; AI receptionist shows Call routing with the
    transfer and fallback numbers and What callers get; Phone shows "Assign a number".
  - `readonly@zella.test`: no Go live checklist, no price, no Two step column, no Assign button.
  Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-e/shots/`:
  `cards_admin_overview_1440.png`, `cards_admin_overview_390.png`, `cards_admin_receptionist_1440.png`,
  `cards_admin_phone_1440.png`, `cards_readonly_overview_1440.png`, `cards_readonly_phone_390.png` (and the rest of
  `cards_*`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
