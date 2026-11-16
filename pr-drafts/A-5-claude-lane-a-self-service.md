Admins' own authenticator and password changes through the server, audited (ACC-30, ACC-01 on the server)
base: claude/lane-a-fresh-code

## What and why

- **ACC-30:** an admin's password change and authenticator add or remove went straight to Supabase Auth, unaudited. `access.ts` adds three self service actions, allowed for every active admin and only for their own account (the user id is never read from the request): `me_mfa_added` (records a verified authenticator that is really theirs), `me_mfa_remove`, `me_password_change` (the app's password rule). Audited as `admin.mfa_added`, `admin.mfa_removed`, `admin.password_changed`; the password is never recorded.
- **ACC-01 gap:** the "keep at least one authenticator" rule was only in the browser. `me_mfa_remove` refuses the last one on the server (409).
- The fresh code gate from ACC-19 (the critic's ordering note) now also covers `me_mfa_remove` and `me_password_change`: Account security asks admins for a code with those changes. Business members keep Supabase Auth's own flow, unchanged.
- The first authenticator set up at sign in (App.jsx, held by the onboarding job) is recorded from `web/src/mfa.js` after verify, best effort, only when `zella_admin_role()` says the person is an admin.
- The stand in answers the server's factor list and delete and records a password change.

## Defaults taken (owner can change)

- The password change uses the server key, which skips Supabase Auth's "reauthenticate first" step; a code entered in the last 5 minutes is the reauthentication instead (MEMORY.md).
- Changing the password does not sign out other devices (the separate Sign out other devices button does).

## Deploy order (each step needs the owner's approval)

1. Deploy `owner-provision-business` (the new actions).
2. Deploy the web app.

## Tests

- Deno `access_test.ts`: own account only, a request's userId ignored; unverified or someone else's factor refused; last factor refused with no delete call; password rule; the password never in the audit entry; a weak password answer from Auth is a 422. All tests pass; `deno check`.
- Web unit tests, lint, build.
- Local browser `tests/browser/admin-self-service.cjs` at 1440x900 and 390 wide: anonymous 401, a business member 403, an admin without a fresh code FRESH_CODE_REQUIRED, last authenticator refused, bad password and made up factor refused; removing one of two, adding one and changing the password from Account security are audited; no page errors. `admin-fresh-code.cjs` and `admin-sessions.cjs` pass on this branch. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/self-service/remove-confirm-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/self-service/remove-confirm-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/self-service/password-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/self-service/password-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/self-service/security-done-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/self-service/security-done-phone.png
- Not run here: `tests/browser/admin-mfa-journey.cjs` (it needs a database with sql/zella_admin_mfa.sql and runs without ZTEST_PASSWORD_AAL2).

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
