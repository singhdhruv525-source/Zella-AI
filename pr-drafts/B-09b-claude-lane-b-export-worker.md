Business export worker and the Whole business export card (SET-DL-EXPORT part 2)
base: claude/lane-b-business-export

## What and why

**SET-DL-EXPORT, part 2.** This adds the worker that writes the export, and the admin card that runs the whole flow.

- **New edge function `business-export`** (`logic.ts` and `index.ts`; `verify_jwt = false` in config.toml, like record-files). It works only with the server key (403 otherwise). It claims an export and writes into the private business-exports bucket:
  - `<job>/tables/<table>.json`: every row of every table that holds the business's rows (paged 500 at a time), as the database allows (no secrets, no recording links, no sensitive industries' transcripts);
  - `<job>/files/<bucket>/<path>`: the business's verification documents and files on records;
  - `<job>/manifest.json`: row counts per table, the number of files, and what was left out.

  Progress is saved after each table and every 20 files. A run that stops, fails or runs out of its time budget (about 2 minutes) hands the job back, and the next run resumes. Nothing calls the function until the owner turns its timed call on.
- **Web:** Settings, Data lifecycle gets a **Whole business export** card (`web/src/settings/panels/BusinessExport.jsx`):
  - find a business and Request export, with a reason;
  - a list with state and progress;
  - Approve or Reject (with a reason) for a Zella Voice owner who isn't the requester;
  - Download for the requester or an owner, which shows the signed links and their end date.

  The deletion jobs note stays, pointing at BIZ-13d.
- **Test stand in:** `tests/browser/local-backend.mjs` can now sign several paths at once (`createSignedUrls`), for files it holds. It is test only.

## Defaults taken (owner can change)
- An admin requests, a Zella Voice owner approves, and it downloads through signed links valid for 7 days.
- The worker gets about 2 minutes per run. Each run counts as one of the 3 tries, so a very large business may need the limit raised (in MEMORY.md).

## Deploy order (each step needs the owner's approval)
1. The `business-export` function. It is safe to deploy: it does nothing until it is called with the server key.
2. The web app.
3. Turning on the worker's timed call is a separate live switch for the owner.

## Tests
- **Deno** (`business-export/logic_test.ts`, 5 tests):
  - every table is written (all pages), then the files and the manifest, and it finishes ready with the manifest path;
  - a resumed export skips the tables and files already done;
  - a failed upload hands the job back with the reason, and the saved progress keeps the finished tables;
  - nothing to do is quiet;
  - running out of time saves progress and hands the job back without a manifest;
  - no key, a user token or the anon key get 403 with no call, the server key works, and GET gets 405.
  - `deno check` is clean.
- **owner-provision-business:** 53 passed. **record-files:** 44 passed.
- **Web unit:** `exportState`. `node --test web/tests/*.test.mjs`: 110 passed. `npm run lint` (0 dashes) and `npx vite build` pass.
- **Local browser and worker, end to end** (isolated DB; the real web app, owner-provision-business and business-export against the local stand in): 13 checks, all passing, no page errors. They cover:
  - at 390 wide, a super admin requests an export and is offered no Approve;
  - at 1440, a Zella Voice owner approves;
  - the worker refuses a call without the server key, then prepares the export: 103 tables, none of them secret tables;
  - Download shows 104 signed links (the manifest plus every table);
  - the download is audited;
  - the audit trail reads exactly requested, approved, ready, downloaded;
  - no sideways scroll at either width.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b9-requested-390.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b9-download-1440.png`.

No new migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
