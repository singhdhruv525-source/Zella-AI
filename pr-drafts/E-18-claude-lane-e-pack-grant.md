Packs from the Business page: catalog and grant with a reason, as the admin (edge; needs owner approval before deploy)
base: claude/lane-e-member-mfa-reset

**Needs owner approval before deploy**, and each real grant on production needs approval for that grant (a billing
change on live balances).

## What and why
**CFG-22 (server half).** No admin screen could grant a pack, though `zella_admin_pack_grant` exists (applied).
- `business_pack_catalog` (billing.view): the active `billing_pack_catalog` rows.
- `business_pack_grant` (billing.manage): calls `zella_admin_pack_grant` through **`callerClient`** (the admin's own
  JWT, after the function's two step gate), never the server key, so the database checks billing.manage for that
  admin, refuses a reason under 5 characters, uses the dialog's idempotency key (a double click grants once) and
  records `billing.pack_granted` with their id. No second audit row from the dispatcher.
- Refusals read as words: NOT_ALLOWED, REASON_REQUIRED, BAD_IDEMPOTENCY_KEY, UNKNOWN_PACK, NO_CURRENT_PERIOD (409:
  "no current billing period"; never worked around by opening one), IDEMPOTENCY_CONFLICT.
- `index.ts`: `detailHandlers(…, user.id, callerClient)`; one argument added.

The web half (a Balances card from PR 9's direct reads, shown with billing.view, and a DialogFocus grant dialog with a
pack select, a reason and a `crypto.randomUUID()` key kept for the dialog's life) is in the Business page web PRs.
Balances never call `zella_billing_overview`, so opening the page writes nothing.

## Defaults taken (owner can change)
- Grants on the Business page (not /plans); billing.manage grants; billing.view sees the catalog.

## Deploy order
Edge function on its own (needs approval), then the web half. No SQL.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Isolated database, `tests/pack_grant/run.sh` (zprod3, simulated admin JWT claims as the caller client sends them):
  ALL PASS. A billing.manage admin grants once; the same key again is a duplicate; one pack balance and one
  `billing.pack_granted` row with the admin's id; a read only admin refused; a business with no current period refused
  with NO_CURRENT_PERIOD and no period opened.
- Automated local: `deno test` 87 passed, 0 failed. New `billing_admin_test.ts`: permissions; the grant runs on the
  caller client only (never the server client) with the dialog's key; every refusal mapped to its words and status;
  a short reason and no pack refused before calling; the catalog. `deno check index.ts` passes.
- Local end to end (isolated `zle_ui`): catalog for the owner admin lists packs; `readonly@zella.test` 403; a grant
  on the test business (no billing period) 409 with the words; `ops@zella.test` (no billing.manage) 403; anonymous 401.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
