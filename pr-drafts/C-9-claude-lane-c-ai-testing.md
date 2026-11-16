AI testing view: stored evaluation runs and the pass rule (AI-TESTING)
base: claude/lane-c-brain-safety-rules

## What and why
`zella_brain_run_evals` checked a business's test questions (`ai_eval_cases`) against its knowledge. It stored nothing, and it let only the two top admin roles or the business's owners run it. Settings showed only a "not shown here yet" note.

`sql/zella_ai_eval_admin.sql` adds, and replaces nothing:
- `ai_eval_runs`: server only (row security on, no policies). It stores each run with who ran it, the totals, the failed questions with what was expected, and whether the business passes.
- `zella_admin_eval_run(uuid)`: needs `businesses.manage`, so a restricted role that has it can run it too. It uses the same case rule as `zella_brain_run_evals`. A business passes with at least 3 cases (`ZELLA_EVAL_MIN_CASES`), all passing.
- `zella_admin_eval_overview(integer, integer)`: needs `businesses.view`. It returns the tested businesses a page at a time (1 to 100) with their latest run, and how many pass.

The AI agents page gets an **AI testing** tab (a new view inside a Lane C page; no menu or route change). It shows:
- each tested business with its number of questions, last run, and Passes, Warning or "Too few questions";
- the failed questions on demand;
- **Run tests**, only with `businesses.manage`.

The page says it checks knowledge retrieval, not live calls, and that a failing run is a warning only and never stops a business going live. No provider is called, nothing is sent, and there is no cost.

**Not done here:**
- The Settings > AI testing note, and the stale "synced to Vapi by n8n" copy in Settings > AI agent configuration (AI-GLOBAL-PROMPT copy fix only). Both are in `web/src/settings/AdminPanels.jsx`, which is still on the open polish PR #88, so they wait for it to merge.
- The go live checklist warning belongs to the Business detail job (BIZ-12). It can read `zella_admin_eval_overview`, or `ai_eval_runs` through its own function.
- The AI-GLOBAL-PROMPT feature itself waits for the owner's decision.

## Defaults taken (owner can change)
- **A failing evaluation is a warning only and never blocks going live** (the AI-TESTING decision's recommended answer).
- **A business passes with at least 3 test questions, all passing** (`ZELLA_EVAL_MIN_CASES`).
- Running needs `businesses.manage`; reading needs `businesses.view`.

## Deploy order (each step needs the owner's approval)
1. Apply `sql/zella_ai_eval_admin.sql`.
2. Deploy the web app. No edge function change: the page calls the two RPCs as the signed in admin.
- If the web app goes first, the tab shows an error until the migration is applied.
- Rollback: the earlier web app, then `sql/rollback/zella_ai_eval_admin_rollback.sql`. The stored runs go with the table.

## Tests
Automated, local, on an isolated database (zprod3, writing cleanup, admin_permissions, admin_mfa, then this):
- `tests/ai_eval_admin/run.sh`, 27 checks, all pass:
  - the gap is reproduced first: a support admin with `businesses.manage` is refused by the old runner;
  - apply, then apply again;
  - all passing gives Passes; a missing expected phrase fails the case and the business; "should find nothing" passes; the case results equal `zella_brain_run_evals`; 2 cases is too few; 0 cases fails;
  - runs are stored with who ran them and the failed question;
  - the overview pages, keeps one latest run per business, and caps at 100;
  - read only admin can read only with `businesses.view` and can't run; a business owner and anonymous are refused; signed in users can't read the table directly; an unknown business reads not found;
  - rollback twice, reapply, ROLLBACK_DRIFT, VERSION_MISMATCH.
- `node --test web/tests/*.test.mjs` passes (110), including `aiTestingWords.test.mjs`: a failing run is never shown as a block.
- `npm run lint` 0 dashes; `npx vite build` passes; `deno check` is clean.
- Every earlier Lane C test passes on this branch.
- `docs/BACKEND_SCHEMA.md` is regenerated, with `ai_eval_runs` described in the generator.

Local browser (stand in; 1440x900 and 390x844, deviceScaleFactor 1; no page errors, no failed calls, no sideways scroll):
- Running tests: Test Evals 1 reads "Passes, 3 of 3"; Test Evals 2 reads "Warning, 2 of 3", with Show failed.
- A read only admin with `businesses.view` sees the results but no Run tests.
- Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-c/`: c10-ai-testing-1440.png, c10-ai-testing-390.png, c10-ai-testing-readonly-1440.png.

## Production md5s
The functions and table are new. The guard needs the functions absent, or exactly this file's versions: run 62985f4f137dc339d4d6cc9cb5b18c72, overview fd4467bf8facbd909b42dd112965b010. Production md5s to be confirmed by the supervisor before apply: these should not exist in production yet.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
