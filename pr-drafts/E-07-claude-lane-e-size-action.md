Business size saved through an admin function action, audited with before and after (edge)
base: claude/lane-e-detail-payload

## What and why
**BIZ-08 (server half).** The business page calls `zella_set_business_size` from the browser. That RPC accepts only
owner and super admin (so `businesses.manage` roles are refused), and skips the function's two step check.
`business_size_save` (in `detail.ts`, permission `businesses.manage`):
- accepts small, medium, large or not set, and refuses anything else (400);
- reads the current size and saves only if it is unchanged since (compare and set; 409 "changed by someone else
  meanwhile");
- records `business.size_changed` with `old_data {size}` and `new_data {size}` (already in the shared catalog);
- the same value changes nothing and records nothing.

`index.ts` gains `detailHandlers(...)` in the handler chain and its `audited` in the audit lookup (one line each, next
to platform's), as supervisor rule 1 says.

**UI-05 and the switch from the RPC** are the web half (the Business page web PRs on top of the Businesses list
branch): a labelled field, a primary Save that is disabled until changed, "Saving…", a status notice, friendly errors.

## Defaults taken (owner can change)
- BIZ-08: the edge action (recommended: deploy only, gets the two step gate), not applying
  `sql/zella_admin_permissions.sql`. `businesses.manage` gates business size.

## Deploy order
Edge function first (window A, needs approval), then the web half. The old web app keeps using the RPC, which still
works for owner and super admin. Revoking EXECUTE on `zella_set_business_size` from signed in users is deferred (after
`zella_admin_permissions.sql` is applied or dropped, whose md5 guard covers that function); recorded in MEMORY.md.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 54 passed, 0 failed. New `business_size_test.ts`: needs businesses.manage; saves and
  records before and after (set, change, clear); the same value records nothing; a wrong value, a malformed id, an
  unknown business (404) and a change meanwhile (409, nothing written) are refused. `deno check index.ts` passes.
  `npm run lint` catalog drift test passes (728 uses).
- Local end to end (isolated `zle_ui`): `ops@zella.test` (platform_operations with businesses.manage, which the RPC
  refuses) saves small to large, 200; exactly one `business.size_changed` row, old `{"size":"small"}`, new
  `{"size":"large"}`, user the ops admin; saving large again records nothing; `readonly@zella.test` 403; anonymous
  401; unknown business 404; "xl" 400.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
