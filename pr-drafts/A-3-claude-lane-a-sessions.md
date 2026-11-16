Sign an admin out everywhere when removed or their role changes; audited sign out of other devices (ACC-18, ACC-30 part)
base: claude/lane-a-catalog

## What and why

- **ACC-18:** removing an admin or changing their role only updated `platform_admins`; their devices stayed signed in. `sql/zella_admin_sessions.sql` adds `zella_end_user_sessions(uuid)` (server only) which deletes all of that person's `auth.sessions` (ending their refresh tokens). `admin_update` calls it after a removal or a role change (not on reactivation or no change) and returns `sessionsEnded`; the `admin.updated` audit entry records `sessions_ended`. Before the migration is applied the change still saves and the page says the devices weren't signed out. Users & access warns "They will be signed out on every device." and then says how many were.
- **ACC-30 (sign out other devices):** `zella_revoke_my_other_sessions()` for any signed in person keeps the calling session (`session_id` claim), ends the rest and writes `session.revoked_others` with the count; a token without a session id is refused. Account security uses it (falling back to Supabase Auth's sign out, unaudited, until the migration is applied).
- New module `owner-provision-business/access.ts` (lane A's one module), hooked into index.ts with an import, `?? ACCESS_PERMISSIONS[action]`, and the handler and audit lookups next to `platformHandlers`.

## Defaults taken (owner can change)

- None beyond the plan: sessions end on removal and on any role change.

## Deploy order (each step needs the owner's approval)

1. Apply `sql/zella_admin_sessions.sql`.
2. Deploy `owner-provision-business`.
3. Deploy the web app.

## Tests

- Isolated database, `tests/admin_sessions/run.sh` (zprod3, and again on zprod3 + writing cleanup + the merged unapplied migrations): 21 pass. The gap is shown first; applies twice; all 3 of an admin's sessions end and another person's stays; only `service_role` holds the grant; signed in and anonymous callers are refused; other devices are ended with the current one kept and audited; NO_SESSION; rollback twice; reapply; VERSION_MISMATCH and DRIFT.
- Deno: `access_test.ts` (removal and role change end sessions, nothing else does, a database failure keeps the change); `deno check index.ts`; all owner-provision-business tests pass.
- Web: `node --test web/tests/*.test.mjs` pass; `npm run lint` 0 dashes and the drift test passes; `npx vite build`.
- Local browser, `tests/browser/admin-sessions.cjs` at 1440x900 and 390 wide, no page errors: ALL PASSED. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/sessions/users-confirm-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/sessions/users-confirm-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/sessions/users-done-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/sessions/users-done-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/sessions/security-signed-out-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/sessions/security-signed-out-phone.png

## Production md5s to be confirmed by the supervisor before apply

Both functions are new; the guard expects them absent in production, or exactly this file's version on a rerun:
- `zella_end_user_sessions(uuid)`: 6f2b8fb98e67992744046a81ff295d9f
- `zella_revoke_my_other_sessions()`: c69e201b64008fc9ecb967b83d537738

Computed on an isolated database (zprod3, then `zella_writing_cleanup.sql`, then the merged unapplied migrations).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
