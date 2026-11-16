Retention periods per kind of data, legal holds and a dry run, pending legal review (SET-RETENTION, BIZ-18b)
base: claude/lane-g-recording-policy

## What and why
SET-RETENTION and BIZ-18b: only one retention period existed and nothing listed what is past it.
- `sql/zella_data_retention.sql`: server only `data_retention_policies` with eight kinds, each at the architecture's value (D-13/D-27, REQ-PRV-01) and `pending_legal_review`: call recordings 30 days, call transcripts 90, message words 730, audit and security logs 2555, replaced verification copies 30 (from replacement), owner identity files 90 (from verification; the outcome is kept), a cancelled business's documents 30, the cancelled business 30 (never before its `retention_until`, which still uses `retention_days`, 90 today: the value is not changed, legal decides). Only a Zella Voice owner changes a period or its legal status. `legal_holds` (security.manage places, only an owner releases; a business on hold is never listed and can't be deleted). `retention_removed_files` (filled by the purge, next PR). `zella_retention_candidates` (the one definition of past its period), the dry run `zella_retention_preview` (counts and ids, never content; deletes nothing), `zella_retention_overview`. `retention_purge_enabled` = false, changeable only by `zella_retention_switch_set` (owner; a guard refuses any other change). A purged transcript is marked "Removed under the retention policy." rather than emptied (see the next PR) and isn't listed again.
- `retention.ts`: `retention_overview`, `retention_preview`, `retention_policy_set` (owner; APPROVED typed to approve), `retention_switch_set` (owner; ENABLE PURGES typed), `legal_hold_place`, `legal_hold_release` (owner).
- UI: `web/src/settings/panels/DataRetention.jsx` (+ `retentionLabels.js`) on Settings > Security and privacy > Data retention, replacing the "isn't built" note. Lane B's Data lifecycle panel and `lifecycle.ts` are not touched.
- No job is scheduled anywhere.

## Defaults taken (owner can change)
- All periods as the architecture proposes, pending legal review.
- Placing a hold needs security.manage; releasing one a Zella Voice owner.
- Message bodies are redacted (the record of the message stays), not deleted.

## Keys and settings the owner adds later
Each period's legal status (and days, if counsel differs); `retention_purge_enabled` (owner). Orphan upload files are lane B's (BIZ-18 part).

## Deploy order (each needs the owner's approval)
1. `sql/zella_data_retention.sql` (after `zella_recording_policy.sql`). 2. `owner-provision-business`. 3. Web app.

## Tests
- Automated local, isolated database: `tests/data_retention/run.sh`: 47 checks, ALL PASSED (gap, apply twice, seeds, nothing scheduled, the dry run per kind lists exactly the right rows without content, removed files and marked transcripts not listed again, holds, owner only changes, guard on the switch, nothing changed by any dry run, audit, direct access denied, rollback twice and its refusals, drift).
- Deno `retention_test.ts` 9 passed (all 54); `deno check` ok; web tests incl. `retentionLabels.test.mjs` passed; lint 0 errors, 0 dashes; vite build ok.
- Local browser: 1440x900 and 390 wide, no page errors, no sideways scroll; eight periods pending legal review; the dry run lists the old calls without their words; a hold placed and released (audited); approving a period and switching purges on need the typed words; no call changed. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g3-retention-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g3-retention-390.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g3-approve-period-1440.png.

production md5s to be confirmed by the supervisor before apply (new functions only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
