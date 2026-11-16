Verification queue: optional filter to one business (edge)
base: claude/lane-e-size-action

## What and why
**BIZ-31 (server half).** "Review" on a business's Verification card opens the setup wizard instead of the
verification queue. The queue action `documents_queue` (platform.ts) now takes an optional `businessId`, checked with
`requireId`, and narrows both the documents and the status totals to that business. Without it, nothing changes. The
response echoes `businessId`.

The web half (Review goes to `/verification?business=<id>`, the queue reads it and offers "Show all", both buttons
hidden for cancelled businesses and without businesses.manage) is in the Business page web PRs. Until this edge
change is live, the queue filters in the browser.

Note for lane B: `platform.ts` `documentsQueue` gets three added lines only.

## Defaults taken (owner can change)
None.

## Deploy order
Either order with the web half (window A for the edge, needs approval). No SQL.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 55 passed, 0 failed. New in `platform_test.ts`: no filter without businessId; with it,
  both the list and the totals are filtered; a malformed id is refused. `deno check index.ts` passes.
- No browser check: no web change in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
