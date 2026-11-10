# Handoff: CodeRabbit full-repository review and fixes (10 Nov 2026, ~19:45 UTC)

Repo: `singhdhruv525-source/Zella-AI`. Read `ZELLA_VOICE_RULES.md` first. Use the GitHub REST API through `gh api` (GraphQL is blocked here).

## What the owner asked for (their words, in order)
- "ask coderabbit review everything and fix and then you can push to main branch"
- "make sure it fixes security issues navigations and everything"
- "make sure before you push anything to main codrabbit review"
- "make sure you fix what coderabit told you to and in the same order coderabbit told you to"
- "let coderabbit fix now" (they upgraded the CodeRabbit plan)
- "the one you fixed let the code rabit review"

## Hard rules (from the owner; they are not optional)
- **Nothing merges to main** until CodeRabbit's review of that PR is clean.
- No production migrations, deploys, publishing, real messages or calls, billing changes or destructive actions without the owner's explicit approval. Don't query production without asking.
- Never edit an applied migration (DB-7). Fixes go in new migrations: version-guarded (DB-3), each with an exact rollback that never deletes customer data (DB-4).
- Never print credentials, and never copy customer data into fixtures. Don't disable tests or weaken authorization or assertions. Database tests run only on the isolated local Postgres (`tests/lib/isolated_guard.sh`).
- No model names in commits or PRs. Refer to the owner as they/them.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, then a `Claude-Session:` line with your own session URL.
- **"Fix comments" box:** the owner ticks CodeRabbit's "Fix comments" checkbox themselves, and only on PRs that target main. Tell them when to tick, and tell them never to tick it on the review-only PRs.

## How the review was split
- `review/full-base` is an orphan branch that holds only `.coderabbit.yaml`, the rules and the architecture doc.
- Each `review/full-NN-*` branch adds one group of main's files (from commit `f7249d2`), so CodeRabbit sees every line as new.
- Those review-only PRs (#38, #39, #40, #41, #44–#48) are **never merged**.

## PR status at handoff
| PR | What | Status / next step |
|---|---|---|
| #42 → main | Fixes from reviews #39 and #40 (web pages and edge functions), branch `claude/full-review-fixes` | Full review was requested at 19:28 and hasn't posted yet. When it does, tell the owner to tick "Fix comments", then verify the fixes and re-review |
| #43 → main | SQL fixes from #38, branch `claude/sql-review-fixes`. New migration `sql/zella_review_sql_fixes.sql`, its rollback and generator (`sql/generators/review_sql_fixes/`), and tests (`tests/review_sql/run.sh`, all passing) | CodeRabbit's review posted 10 findings, the owner ticked "Fix comments", and CodeRabbit's autofix is running. Separately, CodeRabbit agreed to fix the 31 open #38 findings (31 rows in the PR's findings table) and the 18 findings from #38's second review, in its order. When commits land: check them, regenerate the SQL from the spec if the spec changed, run `tests/review_sql/run.sh` and `node n8n/test.mjs`, then post `@coderabbitai review` |
| #41 | Review-only, SQL part 2 | Review requested, not posted yet. When it lands, open a fix PR the same way as #49–#52 |
| #49 → main | Fixes for #44 (baseline and rollbacks, 20 findings) | CodeRabbit was asked to fix them in order. Wait for its commits, then verify and review |
| #50 → main | Fixes for #47 (tests part A, 12 findings) | Same as #49 |
| #51 → main | Fixes for #45 (web part B, 29 findings) | Same as #49 |
| #52 → main | Fixes for #48 (tests part B and root files, 11 findings) | Same as #49 |
| #46 | Review-only, n8n | Review not posted yet. When it lands, open a fix PR the same way |

Each fix PR has a checklist in `docs/review/FINDINGS_PR<n>.md`, in CodeRabbit's order.
- **How a fix PR was made:**
  1. Branch from main.
  2. Commit the findings list.
  3. Open the PR to main.
  4. Comment `@coderabbitai Please fix all N findings ... in the order you posted them`.
- **Before anything merges:**
  1. Verify every CodeRabbit commit against the code.
  2. Run the repo's tests:
     - web: `cd web && npx vite build && node --test tests/*.test.mjs`
     - edge functions: `deno check` / `deno test` per function
     - n8n: `node n8n/test.mjs`
     - database: the suites in `tests/*/run.sh`, on the isolated database
  3. Re-request review until it's clean.

## Isolated test database
- Start it:
  `su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/zella-sec/data -l /var/lib/postgresql/zella-sec/log.txt -o '-p 55433 -k /var/lib/postgresql/zella-sec -c listen_addresses=' start"`
- Build a copy at production state: `tests/lib/build_full.sh <zdb>`, then apply the PENDING list from `tests/deploy/run_all.sh`, then batch1 and batch3. `tests/review_sql/run.sh` does all of this itself.

## Waiting on the owner (production; nothing has been applied)
- After the merges, applying the migrations and deploying the edge functions and n8n workflows each needs their approval.
- In Supabase Auth, keep "Confirm email" on. Findings #9 and #10 of #38 depend on it.
