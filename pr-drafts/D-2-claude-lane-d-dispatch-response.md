Store and show n8n's answer per workflow (OPS-17)
base: claude/lane-d-job-state

## What and why

**OPS-17:** the dispatcher handed work to n8n with `net.http_post` and threw the request id away, so an unpublished workflow (404) or a wrong secret (401) still showed "Last handed over".

- `sql/zella_dispatch_response.sql` (new, version guarded):
  - five columns on `n8n_dispatch_state`: `last_request_id`, `response_request_id`, `last_status_code`, `last_response_at`, `last_error`. No response body is stored;
  - `zella_dispatch_n8n` replaced from **production's version, the one patched on 15 Nov 2026 by `sql/zella_email_delivery.sql`** (md5 `4333da07a5c57d91aa8f018e75368345`, reproduced on zprod3 plus the applied chain). The 4 Nov copy in `sql/baseline` does not match and is refused (tested). Changes: it keeps the request id, and on its next run reads that request's `net._http_response` (pg_net fills it later, so nothing waits). Columns are read through `to_jsonb`, so the real pg_net table (`error_msg`, `timed_out`) and the local stub both work. Everything else is the production body unchanged;
  - 401 or 403: one urgent `n8n_dispatch_refused` alert for all workflows (dedupe `n8n_secret`); 404: a warning for that workflow; a later 2xx resolves them. Every alert goes through the existing `zella_platform_alert`;
  - `zella_admin_dispatch_responses()`: `businesses.view`, the answer per workflow.
- Web (Automations, Scheduler & n8n):
  - the queue table gets an "n8n answer" column (`web/src/admin/dispatchAnswer.js`): Accepted (200), Refused: wrong secret (401), Workflow not published (404), No answer: error, Waiting for the answer. Before the migration is applied it reads "Not available";
  - the scheduled jobs table becomes the shared `ScheduledJobs` panel from PLT-07 (#94), so Automations shows each job's intended state too. This was held back from #94 because the polish branch had the file open.
- This branch merges `claude/admin-ui-polish-2` (#88) to build on its Automations edits. Until #88 merges, its changes appear in this diff too.

## Defaults taken (owner can change)
- 401 or 403 is urgent and raised once for all workflows; 404 is a warning per workflow; a later success resolves the alert.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_dispatch_response.sql` (after `sql/zella_job_intent.sql`). No effect while `zella_dispatch` is off. **Production md5s to be confirmed by the supervisor before apply.**
2. Web app.

## Fingerprints (isolated copy: zprod3, writing_cleanup, the merged unapplied migrations)
- `zella_dispatch_n8n()` before: `4333da07a5c57d91aa8f018e75368345`; after: `080309d80bc02fcea61b6d10a185fa8f`.

## Catalog (PLT-08, #93)
If #93 merges first, add the alert kind `n8n_dispatch_refused` ("n8n refused the dispatcher") to `_shared/catalog.json`.

## Tests
- Automated local (isolated Postgres, pg_net stub): `tests/dispatch_response/run.sh`, 29 checks, ALL PASSED: the gap first; apply twice; **same result, same requests, same counters and same switched off answer as production's function**; request ids kept; no answer yet is waiting and never waited for; 200, 401, 404 recorded on the next run; alerts raised once and resolved by a later 200; pg_net's error column read; reader refuses a business member and anonymous; no body stored; rollback twice restores the function and grants exactly and drops the columns; the restored dispatcher still runs; reapply; ROLLBACK_DRIFT; VERSION_MISMATCH, including for the `sql/baseline` body.
- Web unit: `node --test web/tests/dispatchAnswer.test.mjs web/tests/jobState.test.mjs` (9 pass).
- `npm run lint`: 0 errors, 0 dashes; `npx vite build`: built.
- Local browser (local stand in, isolated database): Automations, Scheduler & n8n at 1440x900 and 390 wide, deviceScaleFactor 1, no page errors or failed calls, no sideways scroll. Screenshots: `scratchpad/lane-d/shots/automations_infrastructure_1440.png`, `_390.png`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
