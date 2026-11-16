Owner approved purge of a cancelled business past retention, switched off (BIZ-13d)
base: claude/lane-g-retention-purge

**Depends on lane B's `sql/zella_draft_delete.sql` (branch `claude/lane-b-draft-delete`) and on the owner's ACC-10 decision:** the purge refuses (AUDIT_HISTORY_AT_RISK) until `zella_audit_privileged` keeps a deleted business's rows (lane B's file) AND `audit_logs.business_id` is no longer ON DELETE CASCADE. Lane B's latest version keeps the foreign key CASCADE (ACC-10 needs the owner's approval), so every business purge is refused until the owner decides ACC-10. The test reads that file from this repository, or from lane B's branch until it is merged. The whole business export (lane B B8, B9) isn't built: the final export offer is recorded by hand until it is.

## What and why
BIZ-13d: cancelled businesses were kept forever with no way to delete one. Built now, off.
- `sql/zella_business_purge.sql`: `zella_business_purge_request` (security.manage; only a business the dry run lists: cancelled for the approved period, past `retention_until`, no legal hold; the `cancelled_business` period legally approved; the final export offer recorded with when and how), approved by the same two people as other purge runs, `zella_business_purge_execute` (an approver; purges switched on; the name typed exactly; the offer at least 14 days old; refused while the audit history is at risk, while the business has payment or billing records, offer history or phone numbers), which audits the purge with the name and dates (business id cleared so the row survives), removes released holds, deletes the business (everything that belongs to it cascades) and hands its storage files (verification documents, record files, brand images under its folder) to the server; `zella_business_purge_files_done`.
- `retention.ts`: `business_purge_request`, `business_purge_execute` (removes files per bucket, only from the three known buckets).
- UI: `web/src/settings/panels/BusinessPurge.jsx` in Data retention, and business runs in Purge runs (the name typed to run).
- Nothing is scheduled.

## Needs an owner or legal decision (stored as pending, refused until then)
- ACC-10: `audit_logs.business_id` from ON DELETE CASCADE to SET NULL, so a purged business's audit history is kept for its 7 years (REQ-PRV-01).
- How long payment and billing records are kept after a business is deleted: the purge refuses any business that has them.
- The cancelled business period (architecture 30 days, `retention_days` 90 today) and whether any industry needs longer.

## Defaults taken (owner can change)
- At least 14 days between the final export offer and the purge.
- Phone numbers must be released first (where the Telnyx and Vapi copies are handled); deleting Vapi assistants or recordings at Vapi isn't built.

## Deploy order (each needs the owner's approval)
1. Lane B's `sql/zella_draft_delete.sql`, and the owner's ACC-10 foreign key change. 2. `sql/zella_business_purge.sql` (after `zella_retention_purge.sql`). 3. `owner-provision-business`. 4. Web app.

## Tests
- Automated local, isolated database: `tests/business_purge/run.sh`: 46 checks, ALL PASSED (gap: a delete by hand would cascade the audit rows; request guards; two people; every execute guard incl. AUDIT_HISTORY_AT_RISK before lane B's file and still after it while the foreign key is CASCADE, passing only once the test simulates the owner's ACC-10 change; the business and its rows gone, other businesses untouched, audit history kept with the business id cleared, purge audited with the name; only its storage files listed and recorded; nothing scheduled; direct access denied; rollback before a run twice, refusals after, drift).
- Deno: all 59 passed; `deno check` ok; web tests 112 passed; lint 0 errors, 0 dashes; vite build ok.
- Local browser (with an earlier version of lane B's draft delete applied to the local database, which also set the audit foreign key to ON DELETE SET NULL, as if the owner had decided ACC-10): 1440x900 and 390 wide, no page errors, no sideways scroll; Ask to purge disabled before legal review; asked with the export offer recorded, approved by two owners, the server refused a 14 day young offer and deleted nothing; after 14 days the business was deleted and the purge audited. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g5-ask-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g5-run-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g5-retention-1440.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-g/shots/g5-retention-390.png.

production md5s to be confirmed by the supervisor before apply (new functions only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
