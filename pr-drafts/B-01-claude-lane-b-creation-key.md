Create business: one creation key per wizard session and a duplicate warning (BIZ-14)
base: main

## What and why

**BIZ-14 (REQ-LC-03, REQ-LC-05).** `saveBusiness` called `zella_create_business_draft` whenever no businessId was sent, and the wizard learnt the id only from the reply. So a retry after a timeout created a second business. There was also no duplicate check.

- **Migration `sql/zella_business_creation_key.sql`** (additive, replaces nothing):
  - adds `businesses.creation_key uuid`, with a unique partial index;
  - adds `zella_create_business_draft(p_fields, p_creation_key)`. It takes an advisory lock on the key, then returns the business already made with that key (`existing: true`). Otherwise it calls the unchanged one argument function and stamps the key. The old one argument function keeps working for the deployed web app and server;
  - adds `zella_business_duplicates(p_name, p_phone, p_website, p_exclude, p_creation_key)`. It lists businesses that are not cancelled with the same normalised name (letters and digits), phone number (last 10 digits, at least 7 given) or web domain (no scheme, www, path or port; it must contain a dot). It leaves out the business itself and the one this session's own first try made, so a retry never warns about itself;
  - both functions are server only (service_role).
- **Server** (`owner-provision-business`):
  - new module `lifecycle.ts`, Lane B's one module. It is hooked into index.ts with an import, `?? LIFECYCLE_PERMISSIONS[action]`, and handlers and audited next to `platformHandlers` (supervisor change 1);
  - `createDraft()` sends the key, and falls back to the old function when the new one is missing (PGRST202), so either deploy order works;
  - `saveBusiness` (Lane B range) passes `creationKey`. On a retry that finds the existing business, it saves the values on that business, audited as `business.updated`;
  - new action `setup_check_duplicates` (businesses.manage, read only).
- **Web:**
  - `CreateBusinessWizard.jsx` makes one creation key per session (`web/src/businessDuplicates.js`) and checks for duplicates before the first save. If there are any, it shows the possible duplicates with what matched and their state, plus Change details and Create anyway;
  - changing the business fields clears the warning.

## Coordination
- `CreateBusinessWizard.jsx` is also on the open polish PR #89 (UI-30, three lines in a different place). A test merge with `claude/admin-ui-polish-3` has one conflict, in `docs/PRODUCT.md` (the same wizard row), which is resolved by keeping both sentences. **Merge this after #89, merging origin/main in first.**
- No CSS changed. The warning reuses `.wiz-unsaved` and `.wiz-footer-right`, because CreateBusinessWizard.css is on #89 too.

## Defaults taken (owner can change)
- A duplicate is a business that is not cancelled with the same normalised name, last 10 phone digits or web domain. At most 10 are listed.
- "Create anyway" is allowed for anyone with businesses.manage. It is not audited separately: the `business.draft_created` entry is written as before.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_business_creation_key.sql`.
2. `owner-provision-business`. Before step 1 it falls back to the old function, so this order is not required, only preferred.
3. Web app.

A later PR may drop the one argument function once every caller has moved.

## Shared with Business detail
None. No shared RPC is changed.

## Tests
- **Automated local, isolated DB** (`tests/business_creation_key/run.sh`, on template zprod3, and on zprod3 plus writing_cleanup and every merged, not applied migration): 24 checks, all passing. They cover:
  - before the migration, a retry makes two businesses (the bug);
  - apply, and apply again;
  - the same key twice gives one business and one receptionist, and twice at once (concurrent sessions) also gives one;
  - a new key makes a new business, and a missing key is refused;
  - duplicates by name, phone and domain are found, every match is named, and cancelled businesses, the business itself and the session's own first try are left out;
  - only service_role may execute;
  - rollback twice removes both functions and the column, and leaves the one argument function byte for byte the same;
  - reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- **Deno** (`lifecycle_test.ts`, 6 tests): every lifecycle action has a permission and none shadows another module's action; createDraft sends the key, falls back on PGRST202 and without a key, and passes other errors through; setup_check_duplicates maps the rows, keeps only known match kinds, leaves the business out, refuses a bad id or key, and returns empty before the migration. `deno test` for the whole function: 34 passed. `deno check index.ts` is clean.
- **Web unit** (`web/tests/businessDuplicates.test.mjs`): the key is a v4 uuid, with or without randomUUID; the match words; the state words. `node --test web/tests/*.test.mjs`: 104 passed.
- **Lint and build:** `npm run lint` (0 dashes), `npx vite build`.
- **Local browser** (real wizard and real owner-provision-business against the local stand in and an isolated DB, 1440x900 and 390x844, deviceScaleFactor 1): 17 checks, all passing, no page errors. They cover:
  - a create whose reply is dropped (timeout) leaves one draft, and the retry sends the same key, keeps one business, moves on and doesn't warn about itself;
  - a new session with the same name is warned, and Change details creates nothing;
  - at 390, the warning names the match, Create anyway makes the second business, and there is no sideways scroll;
  - through the real function, anonymous gets 401 and read_only_admin gets 403.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b1-duplicate-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b1-duplicate-390.png`.

## Migration fingerprints
New functions (this file's versions): `zella_create_business_draft(jsonb,uuid)` `9a8eecb43decf5cf400010631027c208`, `zella_business_duplicates(text,text,text,uuid,uuid)` `59e78ac5dcdb883c0b7bf59256f0de5c`. The guard needs the one argument function to exist. It is unchanged, at `83a944fdfe10d614387fafbaaaf395cb` on zprod3. Production md5s to be confirmed by the supervisor before apply.

Rollback: `sql/rollback/zella_business_creation_key_rollback.sql` drops both functions, the index and the column, and refuses on drift.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
