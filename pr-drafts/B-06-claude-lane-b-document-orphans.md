Verification uploads that were never confirmed are found and removed (BIZ-18a)
base: claude/lane-b-missing-documents

## What and why

**BIZ-18a.** `documentUploadUrl` gives a signed upload for a fresh path before any row exists. If `documentConfirm` never runs, the object stays in the private business-documents bucket forever. The owner onboarding function uploads to the same bucket with the same `<business id>/<kind>/<file>` paths, so this covers its uploads too (critic note).

- Migration `sql/zella_document_orphans.sql` adds two functions and replaces nothing. Both are server only.
  - `zella_document_orphans(p_limit)` lists business-documents objects over 24 hours old with **no** `business_verification_documents` row for that path, oldest first, capped at 1000. Replaced and rejected copies have rows, so they are **not** orphans; removing those is BIZ-18b (retention, legal).
  - `zella_document_orphans_removed(p_paths)` writes one `platform.document_orphans_removed` audit row per run, with the count and up to 100 paths. An empty run writes nothing.
- `record-files/index.ts` gets a new action, `documents_cleanup`. It reuses the record-files cleanup pattern and works only with the server key (403 otherwise). It lists, keeps only paths shaped like `<uuid>/<kind>/<file>`, deletes them through the storage API from **business-documents**, then audits. If the delete fails, nothing is audited and it answers 503. If the audit fails, it answers 503 with the count.

Nothing schedules the cleanup. Running it on a timer is the owner's live switch, as the plan says.

## Defaults taken (owner can change)
- An upload is an orphan after 24 hours without a confirmed row.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_document_orphans.sql`.
2. `record-files`.
3. Turning on any schedule is separate and is the owner's switch.

There is no web change.

## Tests
- **Automated local, isolated DB** (`tests/document_orphans/run.sh`, on template zprod3, and on zprod3 plus the merged, not applied migrations): 13 checks, all passing. They cover:
  - before the migration, nothing lists orphans;
  - apply, and apply again;
  - of seven objects, only the two over 24 hours old with no row are listed (confirmed, rejected, replaced, a fresh upload and another bucket are not);
  - the limit holds;
  - a run is audited with the count and paths, and an empty run writes nothing;
  - only service_role can execute;
  - rollback twice, reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- **Deno** (`record-files/handle_test.ts`, 3 new; the whole function 44 passed):
  - no key, a user token or the anon key gets 403 with no call made;
  - with the server key, only folder shaped paths are deleted from business-documents (`../escape` and `no-folder.pdf` are dropped), and the run is audited with exactly those paths;
  - an empty list makes one call only;
  - a failed delete is not audited.
  - `deno check` is clean.
- `npm run lint` (0 dashes).

There is no browser check, because no page changed.

## Migration fingerprints
New functions (this file's versions): `zella_document_orphans(integer)` `7370e94f2bca0d050f71fc3e47ec7023`, `zella_document_orphans_removed(text[])` `d10ffd0adc3d04a3cb2077334edd057b`. Production md5s to be confirmed by the supervisor before apply.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
