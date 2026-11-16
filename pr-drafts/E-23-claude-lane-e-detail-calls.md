Business page Calls tab: the masked, paged list from zella_admin_calls (web only)
base: claude/lane-e-detail-cards

## What and why
Plan PR 3, **UI-10 part a.** The Calls tab showed the 10 newest calls from the payload, with full numbers and no way
to see more. It now reads `zella_admin_calls` for this business (already applied; masks the caller in the database;
25 a page with Pager), the same list as Voice & numbers, and offers "See all in Voice & numbers". When `to_number`
wasn't recorded (zella_ai_voice doesn't set it), the column shows the business's own number, otherwise "Not
recorded".

## Critic corrections applied
- **No search on this tab:** `zella_admin_calls p_q` matches digit substrings of the full numbers, so a search box
  would let anyone with businesses.view confirm a caller's number.
- The tab adds no reveal path of its own (the reveal is `business_contacts_reveal`, PR 14).

## Not in this PR
- The call drawer: `CallDrawer` lives in `admin/VoiceNumbersPage.jsx` (lane D's file, on the open polish PR #88).
  Exporting it is one word once #88 merges; then rows open the drawer.
- `/voice/calls?business=<id>`: reading the filter on the Voice page is lane D's.

## Deploy order
Web only. After this is live, `claude/lane-e-drop-detail-calls` (PR 19) can be deployed.
Known gap (critic): the browser RPC skips the function's two step check until `sql/zella_admin_mfa.sql` is applied, as
the Voice page does today.

## Tests
- `npm run lint` passes; `npx vite build` passes; web unit tests unchanged (131 pass).
- Local browser (isolated `zle_ui`, 14 seeded test calls), as `readonly@zella.test`, 1440x900 and 390 wide,
  deviceScaleFactor 1, no page errors, no failed requests, no sideways overflow: "14 calls recorded", callers masked
  (`…0001`), no full caller number anywhere, no search box. Screenshots:
  `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-e/shots/calls_1440.png`,
  `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-e/shots/calls_390.png`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
