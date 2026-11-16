Approved purge runs for data past its retention period: two people, typed confirmation, off (SET-RETENTION, BIZ-18b)
base: claude/lane-g-retention-dry-run

## What and why
The purge for the periods in the previous PR, impossible to run by accident.
- `sql/zella_retention_purge.sql`: server only `retention_purge_runs` holding the exact rows listed when a run is asked for (at most 1000, oldest first). `zella_retention_run_request` (security.manage; refused while the period is pending legal review, or with nothing to remove), `_approve` (two different people, one a Zella Voice owner, the other an owner or holding security.manage), `_execute` (only an approver; only with `retention_purge_enabled` on; only while the period is still approved; only with "PURGE <rows>" typed; rows now on a hold or no longer past their period are left alone), `_files_done` (records exactly the removed verification files), `_cancel`, `zella_retention_runs`. Every step audited with counts, never content. Whole businesses are not purged here (next PR).
- Finding: emptying a call's transcript makes `zella_call_integrity` re-mark a short old call as missed and `zella_calls_to_callbacks` start a missed call callback. A purged transcript is therefore replaced by "Removed under the retention policy."; the test proves no callback, insight or usage row appears and the call stays completed.
- `retention.ts`: `retention_runs`, `retention_run_request`, `_approve`, `_execute` (removes document files from the `business-documents` bucket in batches, then records exactly which went), `_cancel`.
- UI: `web/src/settings/panels/PurgeRuns.jsx` (+ `purgeRuns.js`) inside Data retention.
- Nothing is scheduled.

## Defaults taken (owner can change)
- At most 1000 rows per run.
- The second person is another owner or someone with security.manage; the requester may be one of the two.
- A file missing from storage leaves the run "Not finished" rather than recording it as removed.

## Keys and settings the owner adds later
Legal approval per period; `retention_purge_enabled` (owner). Provider copies (recordings kept at Vapi) are not deleted: that needs Vapi.

## Deploy order (each needs the owner's approval)
1. `sql/zella_retention_purge.sql` (after `zella_data_retention.sql`). 2. `owner-provision-business`. 3. Web app.

## Tests
- Automated local, isolated database: `tests/retention_purge/run.sh`: 49 checks, ALL PASSED (every guard refuses in turn, only listed rows removed, held and later rows left alone, no side effects on callbacks, insights or usage, message words, audit rows, documents and files, cancel, nothing scheduled, direct access denied, rollback before a run twice, refusals after a run, drift).
- Deno: all owner-provision-business tests 57 passed (purge part: typed confirmation before the database, storage removal per batch, partial and failed storage); `deno check` ok; web tests 112 passed; lint 0 errors, 0 dashes; vite build ok.
- Local browser: 1440x900 and 390 wide, no page errors, no sideways scroll; a run asked for, approved by two owners in two sessions, Run not offered while purges are off, PURGE 2 typed, transcripts marked and the calls still completed, four audit rows. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g4-run-confirm-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g4-runs-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g4-runs-390.png.

production md5s to be confirmed by the supervisor before apply (new functions only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
