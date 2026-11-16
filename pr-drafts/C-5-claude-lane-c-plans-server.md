Plans: business_plans_list, each business's own plan a page at a time (CFG-14 and CFG-21, server part)
base: claude/lane-c-agent-deliveries

## What and why
`plansList` reads only the shared `plans` table and `subscriptions`. Business plans live in `business_plans` and leave `subscriptions.plan_id` empty, so every subscription showed as "Unknown plan" (CFG-14).

The new action `business_plans_list` (`billing.view`, in config.ts):
- pages over businesses ordered by name: 25 by default, 1 to 100, with `offset` and a name `search` (wildcards are taken as text) (CFG-21);
- returns `total`, `withPlan` (businesses with a version 1, which every business with a plan has) and, per business:
  - its state;
  - the latest plan version: version, how many versions, tier, interval, price, setup fee, minutes, texts, emails, seats, numbers, locations, languages, trial, extra minute price, effective from;
  - its newest subscription status.
- Plan and subscription rows are read in pages, so many versions can't hit the 1,000 row cap.
- It reads with the server key, because `business_plans` has no read policy. Nothing charges anyone.

The page that shows it is the next PR (C6, on top of the polish agent's Plans change #89).

## Defaults taken (owner can change)
- Page size 25 (`PLANS_PAGE_SIZE`), at most 100.
- "Latest version" means the highest version number, the same as `zella_billing_plan_current`.

## Deploy order
Deploy `owner-provision-business`, with the owner's approval, before the C6 web app. No SQL.

## Tests
Automated, local:
- `tests/plans_list/run.sh`, 15 checks, all pass. It runs the real function under Deno against the stand in, with reads capped at 1,000 rows, on an isolated database: zprod3, writing cleanup, admin_permissions, admin_mfa, and test fixtures of 30 businesses, two with several versions.
  - The gap is reproduced first: the old `plans_list` calls all 20 subscriptions "Unknown plan".
  - Page 1 has 25 of 34 businesses, 20 with a plan.
  - The three version business shows Pro yearly, version 3 of 3, with its allowances and status.
  - Page 2 has the other 9. Businesses without a plan say so.
  - Search works and wildcards are taken as text. The limit is clamped between 1 and 100.
  - A role without `billing.view` gets 403; with it granted, 200. A business owner gets 403, anonymous 401.
- Deno `config_test.ts`, 8 tests, including `latestPlans`. `deno check index.ts` is clean.
- `npm run lint` 0 dashes; `npx vite build` passes (no web change).

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
