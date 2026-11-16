Data lifecycle: retention dates and the past retention list (BIZ-13c)
base: claude/lane-b-abandoned-drafts

## What and why

**BIZ-13c.** `zella_retention_due()` exists but has no caller, and Settings, Data lifecycle showed cancelled businesses with only their cancelled date. PR #84 (cancellations, which sets cancelled_at and so retention_until) is merged, so this could start.

- `settings.ts` `privacy_overview` (Lane B owned) now also returns:
  - `cancelled`: every cancelled business with `retention_until` and `past_retention`, oldest due first, at most 500;
  - `retentionSetting`: "set" or "default".

  It reads `businesses.retention_until` directly. `zella_retention_due` is granted to service_role only and gives only the past ones, so reading the column covers both lists with one query.
- `web/src/settings/panels/DataLifecycle.jsx` (the panel moves out of AdminPanels.jsx, the panel file rule) shows:
  - a **Past their retention date** list;
  - a Retention date column and a State pill (Past retention, Kept, No retention date) on Canceled businesses;
  - the retention days setting with a hint that the value is **Pending legal review**: the architecture says 30 days, and the database uses `retention_days` or falls back to 90. The value is **not changed** (legal).
- `web/src/businessLifecycle.js` `retentionState()`.

Read only: nothing on the page deletes anything. The purge is BIZ-13d, which is blocked on the owner and legal.

## Defaults taken (owner can change)
None new. The 30 versus 90 day value stays as it is and is labelled pending legal review.

## Deploy order (each step needs the owner's approval)
1. `owner-provision-business`.
2. Web app.

There is no migration.

## Coordination
Stacked on `claude/lane-b-abandoned-drafts`. In AdminPanels.jsx, the DataLifecycle function becomes a re-export.

## Tests
- **Deno** (`lifecycle_test.ts`, 1 new): `privacy_overview` filters on cancelled_at, keeps 90 as the fallback, reports "default", and marks a past date true, a future date false and no date false. The whole function: 41 passed. `deno check index.ts` is clean.
- **Web unit:** `retentionState` for past, kept, the server flag and no date. `node --test web/tests/*.test.mjs`: 107 passed.
- `npm run lint` (0 dashes) and `npx vite build` pass.
- **Local browser** (isolated DB with two cancelled test businesses, one past its retention date and one not; 1440x900 and 390x844, deviceScaleFactor 1): 10 checks, all passing, no page errors. They cover:
  - the past list has only the overdue business;
  - the full list shows dates and states;
  - "Pending legal review" is shown;
  - no sideways scroll.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b3-retention-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b3-retention-390.png`.

No migration, so there are no md5s to confirm.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
