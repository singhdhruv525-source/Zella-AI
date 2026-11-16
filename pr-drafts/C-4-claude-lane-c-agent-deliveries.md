AI agents list: last delivery outcome, not ready count, served version, deliveries drawer (COM-03 list part)
base: claude/lane-c-connection-ui

## What and why
`assistant_deliveries` records what each call actually got: served, not_ready (with the problems), unknown_number or forwarded_usage. Its only reader, `zella_assistant_delivery_status`, is for a business's own owners, admins and managers, so platform admins couldn't see that a business's calls were getting "not ready", or why.

`sql/zella_agent_delivery_admin.sql` adds two admin readers. They need `businesses.view` or server code, are aggregated in SQL (no raw rows read into the function, since PostgREST returns at most 1000) and replace nothing:
- `zella_admin_agent_deliveries_summary(uuid[])`: per business, the last outcome and time, the last 7 days' counts by outcome, the last problems, the version served last, and the published version with its sync state.
- `zella_admin_agent_deliveries(uuid, integer)`: one business's recent deliveries for the drawer, newest first, 1 to 100 (default 25), with the call id shortened.

In owner-provision-business:
- `agentsList` merges the summary as `delivery`, adds `deliveriesAvailable` and `stats.notReady7d`.
- New action `agent_deliveries` (`businesses.view`, in config.ts, read only, not audited).

On the AI agents page:
- New "Calls served (7 d)" column: last outcome pill and time, served and not ready counts, and the version line ("Serving version 1, published version 2, last check failed").
- A "Calls served" drawer: the 7 day counts, versions, last sync error, last problem, and the 25 most recent calls with their problems.
- The Answering card note counts receptionists with calls not ready this week.

## Shared with Business detail
```sql
public.zella_admin_agent_deliveries_summary(p_business_ids uuid[])
RETURNS TABLE(business_id uuid, last_outcome text, last_at timestamptz, served_7d integer, not_ready_7d integer,
  unknown_number_7d integer, forwarded_usage_7d integer, last_problems jsonb, last_problem_at timestamptz,
  served_version integer, published_version integer, published_sync_status text, published_sync_error text)
-- at most 1000 ids (TOO_MANY_BUSINESSES), null refused (BUSINESS_IDS_REQUIRED), NOT_ALLOWED without businesses.view
public.zella_admin_agent_deliveries(p_business_id uuid, p_limit integer DEFAULT 25) RETURNS jsonb
-- {business_id, limit, deliveries: [{id, at, outcome, problems, version, call}]}; BUSINESS_NOT_FOUND for an unknown id
```
The Business detail job's COM-03 (detail page) can call the same two functions.

## Defaults taken (owner can change)
- The counting window is 7 days, the same as Answering in C2.
- The drawer shows 25 calls by default and at most 100.
- The provider call id is shortened to its last 6 characters.

## Deploy order (each step needs the owner's approval)
1. Apply `sql/zella_agent_delivery_admin.sql`. It adds new functions only.
2. Deploy `owner-provision-business`. If it is deployed before the migration, the column reads "Not available" and the drawer button is hidden.
3. Deploy the web app.
- Real data appears only once the Vapi numbers send assistant-request to voice-rules. That is a separate provider change that needs approval.
- Rollback: deploy the earlier function, then `sql/rollback/zella_agent_delivery_admin_rollback.sql`.

## Tests
Automated, local, on an isolated database (zprod3, writing cleanup, admin_permissions, admin_mfa, then this):
- `tests/agent_delivery_admin/run.sh`, 30 checks, all pass:
  - the gap is reproduced first: a Zella Voice owner is refused by the members only reader;
  - apply, then apply again;
  - exact 7 day counts over 1,500 deliveries (past one 1,000 row page), with 300 older ones left out;
  - the last outcome, the problems (jsonb text lines), and the served and published versions with the sync error;
  - a business with no deliveries reads empty with zero counts;
  - the drawer: default 25, at most 100, at least 1, newest first throughout, the call id shortened, the problems returned;
  - an unknown business reads not found;
  - permissions: owner yes; read only admin no, then yes once `businesses.view` is granted; a business owner no, even for their own business; anonymous gets permission denied; more than 1000 ids or null is refused;
  - rollback twice, reapply, ROLLBACK_DRIFT and VERSION_MISMATCH.
- Deno `config_test.ts`, 7 tests: the `agent_deliveries` limit cleaning, the not applied path, unknown business as 404, other errors raised, and summary chunking. The whole function suite passes (35), and `deno check index.ts` is clean.
- `node --test web/tests/connectionState.test.mjs` passes (4 tests).
- `npm run lint` 0 dashes, `npx vite build` passes.
- The C1 to C3 tests still pass on this branch.

Local browser (stand in; 1440x900 and 390x844, deviceScaleFactor 1; no page errors, no failed calls, no sideways scroll):
- The row for a business with 1,500 deliveries reads "Not ready 5 d ago · 1000 served · 400 not ready · Serving version 1, published version 2, last check failed".
- The drawer lists the counts, "Last check said: Test sync error", the last problem, and recent calls with their problems. A business with none says no calls have reached Zella Voice yet.
- Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-c/`: c4-agents-1440.png, c4-agents-390.png, c4-drawer-1440.png, c4-drawer-390.png.

## Production md5s
The functions are new. The guard needs them absent, or exactly this file's versions: summary 6d674b015fc4b3fc645754f46531dfa7, drawer 48bd7fce72f915cc351b705ed218a0bf. Production md5s to be confirmed by the supervisor before apply: these two functions should not exist in production yet.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
