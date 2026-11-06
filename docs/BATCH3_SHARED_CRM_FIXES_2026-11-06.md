# Batch 3: shared CRM fixes (6 Nov 2026)

**Status: all seven fixes are implemented and tested on isolated data only.** Nothing has been applied or deployed to
production. Branch: `claude/batch3-crm-fixes`, based on `main` at `b4d8dee`.

## Fixes

| ID | Root cause | Solution |
| --- | --- | --- |
| **B3-01** escalation count | `countAttention` stored `countError ? 0 : count`, so a failed query read as "nobody is waiting". | The count is now a state with four values (`web/src/crm/attention.js`): loading, ok (0 is a real 0), stale (the last count is kept and marked out of date), unavailable (no count shown). A non-alarming notice with **Try again** appears when the count can't be checked. Only the newest check may change the state, and an answer for another business is dropped. The banner, badge and **Open** link are unchanged. |
| **B3-02** inbox pagination | Loaded 150 calls and 200 conversations, merged them in the browser and showed 200. | `zella_inbox_page` merges calls and conversations on the server, newest activity first. Ties are ordered by kind, then id, with a keyset cursor. Pages hold 50 items. All seven filters run on the server over the whole inbox. Selection is kept when you change page. |
| **B3-03** lead completeness | Read 1,000 customers; filters and overdue counts were computed from them. | `zella_leads_page` uses the same lead rules on the server. It returns the total, the overdue total and the per-stage column totals over everything that matches. The list is paged by cursor; the pipeline shows the newest 40 per column, with the full count in each header. Search waits 300 ms after typing stops. Stage changes, assignment, notes, callbacks and the Batch 1 lead-creation path are untouched. |
| **B3-04** record pagination | The newest 500 records of a type, then filtered and paged in the browser. | `zella_records_page` filters by type, the Open / Finished / All / per-status choices and search (title, person, field values), excluding archived records as before, with cursor paging. A duplicate found while saving opens even if it is on another page. |
| **B3-05** call history | The newest 300 calls. | `zella_calls_page` applies the six filters and transcripts-only mode on the server. Rows carry no transcript or recording link, only whether one exists (taken from `calls_view`, so this says nothing a person couldn't already see). The opened call is read in full from `calls_view` under the existing privacy rule. Follow-ups attach per row. The "missed calls waiting" count covers the whole history. |
| **B3-06** inbox partial failures | Preview, integration and contact-flag errors became empty data. | Previews, names and contact preferences, and connected channels are loaded separately for the page shown (`zella_inbox_previews` returns at most 160 characters of the last message). Each can fail on its own. The list shows a partial-data notice naming what failed, with **Try again**. A failed integration lookup says "couldn't check", never "not connected". A failed consent lookup **pauses replying** (fails closed). A thread that can't be read says so. The server's opt-out refusal (`zella_inbox_reply`, `OPTED_OUT`) is unchanged. Notices carry no message content. |
| **B3-07** linked records | Titles were looked up for at most 300 ids across 500 loaded rows. | Titles are resolved only for the rows on the current page, in batches of 100 (`web/src/crm/links.js`), under row security and the business id. Unresolvable ids show **Unavailable record** (deleted, or another business's); a failed lookup shows **Couldn't load**. |

**Commit order:** the requested order was B3-01, 06, 07, 03, 04, 05, 02. B3-06 shares `BusinessInbox.jsx` with B3-02, and
B3-07 shares `BusinessRecords.jsx` with B3-04, so those pairs are committed together.

## Changed files

**Frontend**
- `web/src/BusinessApp.jsx`
- `web/src/BusinessInbox.jsx`
- `web/src/BusinessLeads.jsx`
- `web/src/BusinessRecords.jsx`
- `web/src/BusinessCalls.jsx`
- `web/src/BusinessShared.jsx`: `Pager` takes `hasNext` / `busy`; other users of `Pager` are unaffected.

**New frontend files**
- `web/src/crm/attention.js`
- `web/src/crm/pagingState.js`
- `web/src/crm/paging.js`
- `web/src/crm/links.js`
- `web/src/crm/inbox.js`

**Backend:** `sql/zella_batch3_pagination.sql`, with its rollback in `sql/rollback/zella_batch3_pagination_rollback.sql`. No
edge function changed.

**New functions:**
- `zella_leads_page`
- `zella_records_page`
- `zella_calls_page`
- `zella_inbox_page`
- `zella_inbox_previews`
- helpers: `zella_call_row`, `zella_b3_member`, `zella_b3_cursor`, `zella_b3_like`

**New indexes:**
- `customers (business_id, created_at desc, id desc)`
- `calls (business_id, created_at desc, id desc)`
- `conversations (business_id, coalesce(last_message_at, created_at) desc, id desc)`
- `conversation_messages (conversation_id, created_at desc)`
- `callbacks (call_id)`
- `followup_tasks (call_id)`

## Pagination design

- **Keyset cursor.** Rows are ordered by a timestamp then id; inbox ties are ordered by kind then id. The cursor is
  `{t, id}` (inbox: `{t, k, id}`), and the next page starts strictly after it.
  - No row appears twice or is skipped because rows arrive in front of the list. This is tested.
  - A cursor whose row was deleted still works, because it holds values and does no lookup.
  - A malformed cursor is refused with `BAD_CURSOR`.
- **Page size and counts.** Page size is 1–100. Counts are computed over everything that matches the filters.
- **Data changing during paging.** A record edited while you page through Records moves to the front because the list is
  sorted by last change, so it may be missed on later pages until you go back to page 1. Reloading after a save starts
  from the current page's cursor.
- **Browser side.** `useServerPages` keeps one request sequence per filter set.
  - A newer filter wins; an older answer is dropped.
  - A filter or business change returns to page 1 and never shows the old rows.
  - A failed refresh keeps the rows and shows "Showing the last list loaded."

## Security

- **No new privilege.** Every new function is **SECURITY INVOKER** with a fixed search path, so these all apply exactly as
  they do to the screens' direct reads today:
  - row security on `customers`, `crm_records`, `conversations`, `conversation_messages` and `callbacks`;
  - `calls_view`'s checks: membership, the calls module, MFA, and transcript and recording privacy.
- **Explicit membership check.** Each function also requires membership of the requested business (`NOT_A_MEMBER`,
  42501).
- **Execute rights.** Execute is revoked from `anon` and `public`.
- **No change** to policies, private record fields (`crm_record_secrets`), consent enforcement or the Batch 1 changes.

## Performance

These timings come from an isolated local Postgres, run as the signed-in owner, first page of each list.

| Data | Leads | Lead search | Records | Records search | Calls | Inbox |
| --- | --- | --- | --- | --- | --- | --- |
| Fixture (1.2k leads, 0.6k jobs, 360 calls, 240 conversations) | 14 ms | 14 ms | — | 14 ms | 18 ms | 24 ms |
| 10× (13.2k leads, 6.6k jobs, 3.96k calls, 6.8k items) | 290–330 ms | 290–340 ms | 90–110 ms | 150–180 ms | 195–220 ms | 215–245 ms |

**What changed during tuning:**
- **First version:** 2–3 s at 10×. Small helper functions were called once per row (a function with a fixed search path
  can't be inlined), and JSON was built for every row.
- **Fix:** the rules are now written into the queries, and whole rows are built only for the page shown.
- **Noise:** some measurements were up to 1.6 s while other test suites ran at the same time. The figures above were taken
  with the machine otherwise idle.

**What still costs time, and the change I recommend (not made; it needs approval):**
- **The cause:** what remains is mostly the existing row-security policy on `customers`, which calls
  `is_business_member()` once per row. The old screens paid this too.
- **The fix:** a rewrite looks up membership once per query. Trial policy, rolled back:
  `business_id in (select business_id from business_members where user_id = (select auth.uid()) and status = 'active')`.
  It took the 13k-lead page from about 300 ms to **12 ms**.
- **Scope:** the same pattern would help every table, so it is a separate, reviewable change.

## Test evidence

All of the following ran against isolated data. There are no staging or provider tests and nothing was sent.

**Database** (`tests/batch3/run.sh`: a copy of production state, every file applied since, then Batch 1 and Batch 3 twice,
then the rollback): **ALL PASSED.**
- The fixture (`tests/batch3/fixture.sql`) has:
  - two businesses;
  - an owner, staff, a viewer, another business's owner, a person in both businesses, and an outsider;
  - 1,201 leads, 611 jobs and 40 properties, 360 calls, 260 conversations with 5 messages each;
  - opt-outs, 3 open escalations, transcripts and recordings, a lead older than the newest 1,000, a record older than the
    newest 500, and a link to another business's record.
- Each list was walked page by page: every row once, in order, totals equal direct counts.
- Filters and search reached beyond the old caps.
- Pipeline totals equal list totals.
- A row arriving between page loads was not repeated and nothing was skipped.
- Bad cursors and filters were refused.
- Staff without call-content permission see no transcript, recording or sign of one.
- The viewer reads as before.
- Cross-tenant calls to all five functions were refused; the outsider and `anon` were refused.
- All new functions are INVOKER.
- The rollback removes everything.

**Browser** (`tests/browser/crm-batch3.cjs`, real functions and row security through `tests/browser/local-backend.mjs`;
failures injected in the browser): **51 / 51 passed.**
- B3-01: valid zero, three, stale after a failed refresh, unavailable on first failure, Try again, switching from Alpha (3)
  to Beta (no count).
- Leads: 1,201 in 49 pages, Next, search finds the oldest, overdue, pipeline totals.
- Records: 611 across 25 pages to the last one, link titles, "Unavailable record", "Couldn't load", search, open.
- Calls: 360, needs-a-person 3, missed 120, follow-ups, owner transcript, staff none.
- Inbox: 600 items, 50 per page, interleaved, page 6 reachable, unread filter, a thread opens; previews, integrations and
  consent each failed with a warning and recovered with Try again; consent failure leaves no reply box.
- Phone width: list, conversation, Back, no sideways scroll.

**Unit tests:** `web/tests/batch3_unit.test.mjs` **12 / 12**. They caught one real bug, now fixed: a business switch could
not reset the count. The `key` on `Workspace` hid it in practice.

**Regression:**
- Batch 1 security suite: ALL PASSED.
- Batch 1 and Batch 2 unit tests: 11 / 11 and 4 / 4.
- `admin-batch2.cjs`: 79 / 79.
- `admin-permissions.cjs`: 49 / 49.
- `crm-batch1.cjs`: 13 / 13. Its stub now answers `zella_records_page`; the assertions are unchanged.
- 28-industry call suite: 335 / 335.
- `tests/crm_updates`, `tests/security`, `tests/tables`: ALL PASSED.
- CRM page sweep: identical on `main` and this branch (594 visits, the same 65 pre-existing stub-only error pages; none new).
- `npm run build`: ok.
- `npm run lint`: no errors (only existing warnings).
- Edge function type checks: all ok.

## Unverified

- Real Supabase / PostgREST.
  - The browser tests use the local stand-in, which runs the real SQL but is not PostgREST.
  - The RPC payload shapes match what supabase-js sends, but nothing was run against staging.
- Production data sizes and query plans. The timings above are from a local machine.
- Safari and Firefox. Only Chromium was tested.
- The record-link **picker** in the record form still lists the first 500 records of the target type. That is unchanged,
  outside B3-07's scope (which covered display), and a candidate for a search-as-you-type picker.
- Concurrent edits while paging Records, beyond what the design section above describes.

## Deployment order (needs approval; nothing done)

1. Apply `sql/zella_batch3_pagination.sql`. It adds functions and indexes only; the current web app keeps working without
   using them. On large tables, consider creating the indexes `concurrently` first.
2. Publish the web app from `main` after this branch is merged (Cloudflare Pages builds `main`).

## Rollback

1. Roll back the web app first: redeploy the previous Pages build, or revert the merge on `main`. The Batch 3 screens call
   the new functions.
2. Then run `sql/rollback/zella_batch3_pagination_rollback.sql`.

No data is changed by either step.

## Production (6 Nov 2026)

- **Web app:** PR 20 was merged to `main` at 19:37 UTC, and Cloudflare Pages builds from `main`. The database file was applied
  afterwards, so the Leads, Records, Calls and Inbox pages couldn't load their lists until then.
- **Database:** `sql/zella_batch3_pagination.sql` was applied to production about 19:50 UTC (approved: "yes apply"), as
  migration `zella_batch3_pagination`. Checked afterwards:
  - all 9 functions exist, each SECURITY INVOKER with a fixed search path;
  - all 6 indexes exist;
  - `anon` cannot execute the functions; `authenticated` can;
  - a rolled-back call as a real business owner returned that business's totals for leads, calls and the inbox.
- **Follow-ups (PR after 20):** the thread "partial" warning for older text and email records, and CodeRabbit's
  independent refresh of the open conversation after a handover.
