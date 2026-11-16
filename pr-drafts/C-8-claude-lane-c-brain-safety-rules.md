Receptionist safety rules read from industry data, byte identical (CFG-05 part 3) · NEEDS ITS OWN APPROVAL (live call path)
base: claude/lane-c-industry-data

> **Needs its own approval.** `zella_brain_prompt_base` builds every live receptionist's instructions. The output is byte identical for every existing industry (tested), but applying it is a version change on the live call path and needs the owner's explicit approval for that specific action.

## What and why
`zella_brain_prompt_base` kept each industry's safety lines in a CASE on the industry key, plus two later lines for legal and healthcare. A new industry could never have its own.

`sql/zella_brain_safety_rules.sql` replaces that CASE with one read of `industry_configurations.safety_rules`, which C7 seeded with exactly that text on the same database.
- Nothing else in the prompt changes.
- The marker comments other migrations patch on are kept (`zella_industry_rules_v2`, `zella_prompt_v4_rules`, `zella_escalation_rules`).
- It refuses to run before `zella_industry_data.sql`. The industry data rollback refuses while the prompt reads the column.

## Defaults taken (owner can change)
None new. The text is today's, unchanged.

## Deploy order
Migration only, after C7's migration, with the owner's explicit approval for this version change.

Rollback: `sql/rollback/zella_brain_safety_rules_rollback.sql`. It restores the CASE exactly and refuses on drift. It also needs approval, since it is the live call path too.

## Tests
Automated, local, on an isolated database: zprod3, writing cleanup, admin_permissions, admin_mfa, production's `zella_sensitive_industry` (so C7's guard sees production's version), the industry data fixtures (test CRM presets so every CASE branch is exercised), and one test business per industry plus one with none.
- `tests/brain_safety_rules/run.sh`, 16 checks, all pass:
  - it refuses to run before the industry data migration;
  - the gap is reproduced first: a new industry's own lines are ignored;
  - apply, then apply again;
  - **every existing business's rendered prompt is byte identical (md5 per business, 33 businesses across all 28 industries and one with none)**, and only the new industry's prompt changed;
  - a new industry now gets its own lines, and editing one industry's lines changes only that industry's prompts;
  - the marker comments are kept;
  - rollback twice restores the function, grants and every prompt exactly; the industry data then rolls back too; both reapply;
  - the industry data rollback refuses while the prompt reads `safety_rules`;
  - ROLLBACK_DRIFT and VERSION_MISMATCH.
- No web or function change, so lint, build and Deno are as in C7 (all pass).

## Production md5s
The guard needs `zella_brain_prompt_base(uuid)` at production's md5 4b4212d6c8a2ee48520ab1d781de5019 (computed on zprod3 plus writing cleanup; none of the unapplied migrations touch it), or this file's f58ea9e2e291a25576eb68de5ad8086f. Production md5s to be confirmed by the supervisor before apply. If production's prompt was patched since (for example by a later prompt change), the guard stops the file and the md5 must be recomputed on the applied chain.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
