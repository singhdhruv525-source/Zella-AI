Fresh authenticator code before adding an admin or changing admin access (ACC-19)
base: claude/lane-a-sessions

## What and why

**ACC-19.** Granting owner access or changing roles needed only a session verified once (possibly hours ago). Now `admin_invite` and `admin_update` need an authenticator code entered in the last 5 minutes:
- `mfa_gate.ts`: `codeEnteredAt` reads the newest `totp` time in the token's `amr`; `freshCode` fails closed (no time, older than 5 minutes, or more than a minute in the future); `freshCodeGate` answers 403 `FRESH_CODE_REQUIRED`.
- Users & access asks for a new code when the server says so (a wrong code is refused) and makes the same change again. callOwnerFunction already passes `error.code` through, so the wizard file is not edited.
- The local stand in records the code time in `amr` on verify and keeps it through a refresh.

Not in this PR: `roles_save` (Settings > Platform roles) gets the same check after the open admin polish PR (#88) that edits AdminPanels.jsx merges; until then that page would only show the error, so the server doesn't require it there yet.

## Defaults taken (owner can change)

- Fresh code only, no second owner approval (`FRESH_CODE_ACTIONS` in mfa_gate.ts).
- `FRESH_CODE_MAX_AGE_SECONDS = 300`.

## Deploy order (each step needs the owner's approval)

Only meaningful after ACC-01 (sql/zella_admin_mfa.sql) is live.
1. Deploy the web app (it handles FRESH_CODE_REQUIRED; harmless before the server change).
2. Deploy `owner-provision-business`.

Needs a staging check with real Supabase Auth that re-verifying a code moves the `amr` totp time (the local stand in does; Supabase documents amr timestamps per method).

## Tests

- Deno `mfa_gate_test.ts`: the newest totp time, the 5 minute edge, fail closed cases (no amr, not a list, password only, no or bad time, future time, garbage token), only the listed actions gated. All owner-provision-business tests pass; `deno check`.
- Web unit tests, lint (0 dashes, drift test), build.
- Local browser `tests/browser/admin-fresh-code.cjs` at 1440x900 and 390 wide: the server refuses without a fresh code and creates nothing; the page asks, refuses a wrong code, then adds the admin (audited admin.added); a second change within 5 minutes isn't asked again; no page errors. `admin-sessions.cjs` also passes on this branch. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/fresh-code/fresh-code-asked-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/fresh-code/fresh-code-asked-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/fresh-code/fresh-code-done-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/fresh-code/fresh-code-done-phone.png

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
