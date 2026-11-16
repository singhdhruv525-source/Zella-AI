Business page data: no calls array, no caller numbers (edge; ship only after the Calls tab web PR is live)
base: claude/lane-e-pack-grant

## What and why
**UI-10 part b, BIZ-22 part c.** `business_detail` no longer reads `calls` (numbers included); `calls` is `[]` for one
release because older web apps read `data.calls.length`; `callCount` stays. The Calls tab reads `zella_admin_calls`
(masked, paged) in the Calls tab web PR (PR 3).

## Deploy order
Edge function, only after the web app with PR 3's Calls tab is live (the critic notes the admin web app's hosting is
still "Planned" in MEMORY.md, so "live" means whoever publishes the web app confirms it). No SQL.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Defaults taken (owner can change)
None.

## Tests
- Automated local: `deno test` 88 passed, 0 failed. New: the whole response has no `from_number` or `to_number`,
  `calls` is `[]`, `callCount` is a number, and no calls numbers are read. `deno check index.ts` passes;
  `npm run lint` passes.
- No browser check here: the old Calls tab shows its empty state; the new one is in PR 3.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
