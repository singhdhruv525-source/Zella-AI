One shared list of audit actions, alert kinds and permissions, with a drift test (PLT-08)
base: main

**Already open as PR #93** (https://github.com/singhdhruv525-source/Zella-AI/pull/93). CodeRabbit round 1 (6 findings) and round 2 (2 findings) are fixed and their threads resolved; the last push (d57b4c8) is not yet reviewed.

## What and why

**PLT-08 (part 1): one shared list of alert kinds, audit actions and permissions, plus a drift test.**

- `web/supabase/functions/_shared/catalog.json`: 214 audit actions with labels, 62 platform alert kinds with labels,
  19 admin permissions with descriptions, the run time prefixes (`'attendance.' || p_action`, `"legal." + r.to`, ...)
  and the two owner only permissions. Each list is sorted, one entry per line, so lanes adding names don't touch
  the same line. Deno and Vite can both import it. This adds labels for every name that had none (including the 21
  dotted names missing from `ACTION_LABELS` and the undotted trigger names such as `platform_admin_granted`).
- `tests/catalog/scan.mjs` + `drift_test.mjs`: reads every SQL file, every edge function module under
  `web/supabase/functions/` (a new module file is covered automatically), the n8n code nodes and `web/src`. It follows
  SQL variables to their assignments and helper parameters (`zella_admin_audit`, `zella_people_audit`,
  `zella_schedule_audit`) to every caller. It fails when a name is used but not listed, built from an undeclared
  prefix, or can't be worked out; when a listed name is unused, unlabelled or has a dash in its label; when
  `settings.ts` `PERMISSION_CATALOG` differs from the list; and when an `ownerFormat.js` label key isn't a real action.
- `tests/catalog/scan.test.mjs`: 17 unit tests for the scanner and the check, including "a new unlabelled action fails".
- `web/package.json`: `npm run lint` runs the drift test and the unit tests.
- **No code moves.** One fix the test found: `security_overview` filtered on `action.like.roles%`, which matches no
  action (role changes are `platform.roles_updated`, already covered by `platform.%`). The dead filter is removed, so
  the output doesn't change.

Not in this PR: reading the UI labels from the list (PLT-08 part 2). `web/src/ownerFormat.js` is held by the
Businesses list job, so that swap waits for it to merge. `growth.manage` in PRODUCT.md isn't checked, because the test
reads code, not docs (that's ACC-36, waiting on the owner).

## Defaults taken (owner can change)

- `PLT08_CI`: the test runs in `npm run lint`, not in GitHub Actions. There is no CI in the repo, and adding Actions is
  an owner decision (the recommended answer in the plan).

## Deploy order

Nothing to deploy. The list and the test aren't deployed. The one line `settings.ts` change can go out with the next
approved deploy of `owner-provision-business`, and it changes nothing visible.

## Tests (all automated, local)

- `node tests/catalog/drift_test.mjs`: "214 audit actions, 62 alert kinds and 19 permissions match 722 uses in the code."
- `node --test tests/catalog/scan.test.mjs`: 17 pass.
- `npm run lint` in web: exit 0, check-dashes 0 found, drift test passes.
- `node --test web/tests/*.test.mjs`: 98 pass.
- `deno check index.ts` and `deno test` in owner-provision-business: 28 pass.
- `npx vite build`: built.

No migration, so no md5s. No browser check: no page changes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
