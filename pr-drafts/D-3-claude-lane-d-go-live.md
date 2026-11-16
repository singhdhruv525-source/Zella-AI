One go live checklist, and the calendar app keys in the server check (UI-23, SET-OAUTH-CHECKS)
base: claude/lane-d-dispatch-response

## What and why

**UI-23:** three partial go live lists (Operations Services, Automations "Go live checklist", Messaging "Sending switches"), each missing items the others had (Resend key, platform emails address, email sender, n8n secret, jobs).
**SET-OAUTH-CHECKS:** Settings, OAuth applications said the calendar app keys weren't in the server configuration check.

- `owner-provision-business/ops.ts`: **lane D's one new module** (the `platform.ts` precedent). `OPS_PERMISSIONS` and `opsHandlers`, hooked into index.ts with additive lines only (import, `?? OPS_PERMISSIONS[action]`, `?? ops.handlers[action]`, `?? ops.audited[action]`).
  - `SERVER_SECRETS`: the existing eight, plus `RESEND_API_KEY` and the five calendar names `calendar-connect` reads (`GOOGLE_CALENDAR_CLIENT_ID`, `_SECRET`, `MICROSOFT_CALENDAR_CLIENT_ID`, `_SECRET`, `CALENDAR_REDIRECT_URL`). `platformStatus` now uses `serverConfiguration(has)` for its configuration list (only that part of the function changed, as agreed with lane C), so Operations' Services picks them up automatically. Set or not set only.
  - `go_live_checklist` (`businesses.view`): secrets set or not set, settings addresses set or not set (never the value), live switches true or false.
- `sql/zella_go_live_reads.sql` (new function only): `zella_admin_email_triggers()`, `businesses.view`, read only: whether the two `zella_kick_platform_emails` triggers are on. Nothing else reported them.
- Web:
  - `web/src/admin/goLive.js` composes the one list from the server action, `zella_admin_scheduler_health` (jobs with intent from #94, the vault secret) and the trigger reader. A part that doesn't load reads "Not checked", never "Ready". Keys appear only as tooltips (UI-21); rows that need the owner to switch them on say so;
  - `web/src/admin/GoLiveChecklist.jsx` on Platform operations (`/operations?view=go-live` scrolls to it once the page has loaded);
  - links: Automations, Scheduler & n8n and Settings, n8n (the old Readiness checklist in `AdminPanels.jsx` becomes a link card; the jobs table stays where the page doesn't already list jobs); Messaging, Senders & providers gets the one link line;
  - `web/src/settings/panels/OauthApps.jsx`: Google and Microsoft calendar apps (set, partly set, not set) and the return address (custom or default). `AdminPanels.jsx` changes are the import plus a one line render, the Readiness block, and one N8nConfig phrase.

## Defaults taken (owner can change)
- The checklist permission is `businesses.view`, the same as `platform_status`, which already shows secret presence.
- An unset `CALENDAR_REDIRECT_URL` counts as ready (calendar-connect falls back to its own address).

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_go_live_reads.sql` (any time; the checklist reads the triggers as "Not checked" until then).
2. Edge function: `owner-provision-business` (ops.ts and the new configuration list).
3. Web app.

## Shared with other lanes
- index.ts: four additive lines for ops.ts, and the `configuration:` list inside `platformStatus` (lane C owns the `brokenIntegrations` lines, untouched).

## Tests
- Deno: `deno test` in owner-provision-business, 33 passed (ops_test.ts: every expected secret listed, set or not set only, **no secret or setting value in the response** with secret looking values set, a read error is passed on, every action has a known permission); `deno check index.ts`.
- Authorization on the local stand in (real function and RPCs): anonymous 401, a business member who isn't an admin 403, a `support_admin` without `businesses.view` 403, the owner 200 with no value in the body.
- Automated local (isolated Postgres): `tests/go_live_reads/run.sh`, 15 checks, ALL PASSED (off, on, not created, reading never changes a trigger, wrong role, member and anonymous refused, rollback twice, reapply, ROLLBACK_DRIFT, VERSION_MISMATCH).
- Web unit: `node --test web/tests/*.test.mjs` 115 pass (goLive.test.mjs: every go live item listed, no keys or dashes in the visible words, unloaded parts read not checked, counts).
- `npm run lint`: 0 errors, 0 dashes; `npx vite build`: built.
- Local browser at 1440x900 and 390 wide, deviceScaleFactor 1, no page errors or failed calls, no sideways scroll: the checklist states on Operations; the link from Automations, Messaging and Settings, n8n each opens it; Settings, OAuth applications. Screenshots in `scratchpad/lane-d/shots/`: `operations_golive_*`, `operations_golive_link_*`, `automations_golive_link_*`, `messaging_golive_link_*`, `settings_n8n_golive_link_*`, `settings_oauth_*`.

Production md5s to be confirmed by the supervisor before apply (new function only: `zella_admin_email_triggers()` `53efb8b2d7ea7ab041e07bd3e1782f79`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
