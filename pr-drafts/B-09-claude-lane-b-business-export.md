Business export: job table, private bucket, request and approve actions (SET-DL-EXPORT part 1)
base: claude/lane-b-provisioning-retry

## What and why

**SET-DL-EXPORT.** Only per customer export existed. REQ-LC-20 asks for a whole business export: every table as data, plus the business's files.

New migration `sql/zella_business_export.sql`:
- `business_export_jobs` holds one row per export: requested, approved, running, ready, failed, rejected or expired.
  - It records who asked and why, who decided, its progress (for resuming), its tries, and its 7 day window.
  - Row security is on with no policies. Only the server reads it (select only), and every write goes through the functions.
  - At most one open export per business.
- The private bucket `business-exports`.
- Server only functions, each step audited:
  - `zella_export_request`: any active admin may request.
  - `zella_export_decide`: only a Zella Voice owner may decide, never the requester (`OWN_REQUEST`). A rejection needs a reason.
  - `zella_export_claim`: takes the oldest approved export, or a running one silent for 30 minutes. It ends an export failed after 3 tries, and marks ready exports past 7 days expired.
  - `zella_export_progress` and `zella_export_finish`: a finish makes it ready for 7 days; a failure goes back to approved, so the next run resumes.
  - `zella_export_tables`, `zella_export_rows` and `zella_export_files`: what the worker may read.
- **Never in an export:**
  - the tables integration_secrets, crm_record_secrets, email_unsubscribe_tokens and business_export_jobs;
  - any column named like a token, secret, password, api key, credential or key hash;
  - call recording links;
  - call transcripts and summaries in sensitive industries (`zella_sensitive_industry`, the same rule as call content privacy).

Server, `lifecycle.ts`:
- `export_request` needs businesses.manage.
- `export_decide` needs businesses.manage and the zella_owner role, checked again in the database.
- `export_status` needs security.view (the Data lifecycle page) and lists the last 50 exports with their progress.
- `export_download` needs businesses.manage, and the person who asked or a Zella Voice owner. It only works while the export is ready and within its 7 days. It returns signed links for the manifest and every part, valid until the export ends (at most 7 days), and is audited as `export.downloaded`.

## Defaults taken (owner can change)
- An admin requests, a Zella Voice owner other than the requester approves, and the export downloads through signed links valid for 7 days (the supervisor's chosen default).
- The download is allowed for the person who asked and for any Zella Voice owner.
- What is left out of an export: the list above.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_business_export.sql`.
2. `owner-provision-business`.

The worker and the card come in the next PR. Nothing runs on its own.

## Tests
- **Automated local, isolated DB** (`tests/business_export/run.sh`, on template zprod3, and on zprod3 plus every merged, not applied migration): 32 checks, all passing. They cover:
  - before the migration, there is no export;
  - apply, and apply again;
  - the bucket is private and the jobs table is server only;
  - a non admin can't request, and a second open request is refused;
  - a super admin can't approve, the requester can't approve their own request, and a rejection needs a reason;
  - an owner approves, and another owner approves an owner's own request;
  - the claim takes the oldest approved export;
  - secret tables and columns are never returned, and asking for a secret table is refused;
  - calls keep transcripts in a plain industry but never recording links, and lose transcripts and summaries in a dental business;
  - files come from both buckets, for that business only;
  - a stale claim can't read or write;
  - a failure goes back to approved, and the next claim resumes from the saved progress;
  - a finish makes the export ready for 7 days, and it expires after;
  - three stops end it failed;
  - every step is audited;
  - only service_role can execute;
  - the rollback refuses while an export is ready, then works twice and removes the functions, table and bucket;
  - reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- **Deno** (`lifecycle_test.ts`, 2 new; the whole function 53 passed): who may request and decide (super admin, support admin and no role get 403 with no call); the database refusals in words (OWN_REQUEST 403, EXPORT_OPEN 409, NOT_REQUESTED 409, REASON_REQUIRED 400); the download for the requester or an owner only, ready and unexpired only, with links only under the export's own folder, valid until it ends, and audited. `deno check index.ts` is clean.
- `npm run lint` (0 dashes).
- The local browser journey is in the next PR.

## Migration fingerprints
New functions (this file's versions):

| Function | md5 |
|---|---|
| request | `f47b159a55dbc664012efcc5f31a91d3` |
| decide | `d629f795bb5d2cdbfe5f35ae7d3cc153` |
| claim | `ff8042f03db758b059a9e0d195e6fb6d` |
| progress | `dd7783ebcb736ed012d29a56adfa02cd` |
| finish | `83b5834fc4d29a12c2e5c849c3d93877` |
| tables | `5a84e8a9605c8e20d1ffbfcf4537d600` |
| rows | `b0da0326b04c813ccd7ddd5b443063d9` |
| files | `580156e5758c1d2fbbcae6e8387969c0` |

Production md5s to be confirmed by the supervisor before apply.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
