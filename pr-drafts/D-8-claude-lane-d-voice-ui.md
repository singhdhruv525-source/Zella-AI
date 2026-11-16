Voice page: tiles open filtered calls, read only switches, refused Vapi requests (UI-14, COM-13, COM-09)
base: claude/lane-d-routing-missing

## What and why

- **UI-14 (tiles):** the Overview tiles ("Missed 121") couldn't be clicked, and the Calls tab took only business, failed only and search as a starting filter.
- **COM-13 (UI):** only a banner said calls were off.
- **COM-09 (UI):** refused Vapi requests and the auth mode weren't shown.

Web only, on `VoiceNumbersPage.jsx` (built on the polish agent's UI-16, UI-18 and UI-21 edits from #88):
- `web/src/admin/voiceView.js`: which calls a tile or an alert opens, the Calls tab's starting filter (status, direction, days, business), and the switches in plain words with the setting key only as help text.
- Overview tiles are buttons (`.ao-tile` in `OwnerPages.css`, existing tokens only): Inbound and Outbound open Calls by direction; Completed, Missed and Failed by status; all for the period chosen on Overview; Active numbers opens Numbers. "In progress" and "Transfers that didn't connect" stay plain (no matching filter).
- "Needs attention": the missed call alert opens that business's missed inbound calls for the last day (the alert's own filter from `zella_voice_admin.sql`); other call alerts behave as before.
- A read only **Switches** panel: outbound AI calls, plan limits for calls, how Vapi requests are checked, and the three call jobs (on, off, off on purpose, not created). No control on it; keys are tooltips (UI-21).
- A "Refused Vapi requests (24 h)" tile with the last one, and on Providers & costs a "Vapi sign in check" panel (auth mode, refused in 24 hours, last refused). Before the migration is applied these don't show.

## Deploy order (each step needs the owner's approval)
- Web app, after `sql/zella_voice_admin.sql` (the tiles work without it; the switches, refusals and missed call alert need it).

## Tests
- Web unit: `node --test web/tests/*.test.mjs` 119 pass (voiceView.test.mjs: tile and alert filters, periods, Calls starting filter, switches in words with no key or dash shown and never "On" when off).
- `npm run lint` 0 errors, 0 dashes; `npx vite build` built.
- Local browser on the local stand in (real RPCs, isolated database), 1440x900 and 390 wide, no page errors or failed calls, no sideways scroll: the Missed tile opens Calls filtered to missed (3 rows, all missed); the missed call alert's Open goes to Calls with direction inbound and the last 24 hours; the switches panel reads in words with no key and no controls; the refusal tile and the Providers panel show 1 refusal. Screenshots `scratchpad/lane-d/shots/voice_overview_static_*`, `voice_overview_*`, `voice_providers_*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
