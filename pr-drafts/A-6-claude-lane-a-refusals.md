Record refused admin calls as security events and list them on Users & access (ACC-15)
base: claude/lane-a-self-service

## What and why

**ACC-15.** Refusals by owner-provision-business wrote nothing. `recordRefusal` (access.ts) now runs at the three refusal points (not an admin, two step sign in missing or not used, a role without the permission) and writes `security.admin_refused` with the ip address, user agent, code, action and permission. It never throws or changes the answer, and a flood is capped through `zella_rate_limit`. `security_refusals` (security.view) lists the last 24 hours, shown on Users & access in a new panel (`web/src/settings/panels/SecurityRefusals.jsx`). `security_overview` now includes `security.%` rows and returns `refusals24h`; the Settings Security overview card shows it after the open polish PR (#88) that edits AdminPanels.jsx merges.

## Defaults taken (owner can change)

- `REFUSAL_LIMIT`: 5 per person and refusal code in 10 minutes (access.ts).
- Not recorded: calls with no signed in person (401; Supabase Auth logs those) and FRESH_CODE_REQUIRED (an ordinary step).

## Deploy order (each step needs the owner's approval)

1. Deploy `owner-provision-business`.
2. Deploy the web app.

## Tests

- Deno: recorded with ip and user agent and the rate limit key; nothing over the limit; an action name kept only when it looks like one; never throws when the rate limit, the insert or the network fails.
- Web unit test for the reasons in words; lint, build.
- Local browser `tests/browser/admin-refusals.cjs` (isolated database): unsigned call not recorded; business member NOT_ADMIN, admin without an authenticator MFA_SETUP_REQUIRED and a read only admin NOT_PERMITTED (with action and permission) recorded with ip and user agent; 9 refusals give 5 rows and every answer stays a refusal; an allowed call records nothing; Users & access lists them in words at 1440x900 and 390 wide, no page errors. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/refusals/refusals-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/refusals/refusals-phone.png

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
