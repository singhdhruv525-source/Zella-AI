Weekly platform report for Zella Voice admins (reports.view)
base: main

## What

The owner's decision on scheduled reports (`docs/ADMIN_AUDIT_2026-11-16.md` ACC-25 and the build checklist item "Scheduled reports and report permissions"): one weekly summary of the whole platform for Zella Voice admins.

- `sql/zella_weekly_platform_report.sql` (version guarded, **not applied**):
  - `platform_report_runs`: one row per week (unique on kind and week start). Row security is on, there are no policies and signed in users get no grants.
  - `zella_platform_weekly_summary(from, to)`: counts only. New businesses, live businesses, calls, missed calls, texts sent and received, open platform alerts (urgent in brackets), support tickets (opened that week, open now) and failed automation runs. Each definition is written in the function and shown on the page.
  - `zella_post_weekly_platform_report(now)`: reports the last complete week (Monday to Monday, UTC) once. A second run, a retry or two runs at once still make one report. It raises one info platform alert `weekly_report` saying where to read the report, with no figures in it, because every admin sees the bell and gets the digest. Alerts for earlier weeks are resolved. The existing admin email digest carries the alert only once `email_live` is on and a sender is set, so `zella_admin_alerts.sql` is unchanged.
  - `zella_admin_weekly_reports(limit)`: the latest reports plus the schedule's state (weekly job on or off, next run, email live). It needs the new permission `reports.view`.
  - Adds itself to `zella_run_scheduled_job`'s allowed list and to `zella_run_schedule_group('weekly')` through `zella_patch_function`. Both functions are md5 checked and archived first; any other version stops the file with VERSION_MISMATCH.
- Exact rollback in `sql/rollback/zella_weekly_platform_report_rollback.sql`:
  - It takes the entry out of both lists. If nothing else changed them, that gives back the archived originals byte for byte. A later change, such as the cancellations hourly patch, is kept.
  - It drops the table and the functions, and resolves open report alerts.
- `reports.view` permission:
  - Added to the permission catalog in `owner-provision-business/settings.ts`.
  - `zella_owner` and `super_admin` get it by default, because `zella_admin_can` already gives them everything except managing admins and roles.
  - A restricted role gets it only when the owner ticks it in Platform roles.
- Settings, Analytics and reporting, Reporting configuration: the "isn't built" note is replaced by:
  - the schedule's state;
  - the latest report, with each figure and its definition;
  - earlier weeks.
  An admin without `reports.view` sees a refusal in plain words instead.
- The alerts bell has an icon for `weekly_report`.

**It runs only once `zella_jobs_weekly` is switched on.** That is the owner's switch, and it is off in production.

**Production md5s:** I have no production access. The known versions were computed on zprod3 + `sql/zella_writing_cleanup.sql` + the merged, unapplied migrations in `docs/SCHEMA_STATUS.md`:
- `zella_run_scheduled_job`: 671ec3ca5b53cc2d660f054b837d67d1
- `zella_run_schedule_group`: 78b7fdfea58e49d1dfb594e7acc9b808 without `zella_cancellations_scheduled.sql`, 5a9bc8c34841edd1ad3d66ff4156a006 with it

Production md5s to be confirmed by the supervisor before this is applied.

Found while building, not fixed here: `zella_check_business_moments` is in the hourly list but not in `zella_run_scheduled_job`'s allowed list, so the hourly job would return not_allowed for it. This is noted in `docs/MEMORY.md`.

## Why

The owner chose one weekly platform summary. It is an in app notification now and goes in the admin email digest only once email is live, and the figures are visible only to `reports.view`. The Reporting configuration page said scheduled reports weren't built.

## Tests

- **Database, local isolated Postgres** (`tests/weekly_report/run.sh`; 33 checks, all passed on zprod3 alone and with `STACK=1`, which adds the writing cleanup and the merged, unapplied migrations):
  - The gap first: the job isn't allowed, it isn't in the weekly list and there is nothing to read.
  - It applies twice with no change on the second apply, and it is in the weekly list once.
  - The week's figures count only the test rows inside the week; test mode and blocked texts are not counted.
  - Running twice in a week makes one report and one alert, through the real job runner and the weekly group too.
  - Two runs at once make one report.
  - A run for an older week doesn't resolve newer alerts, and only the latest alert stays open.
  - The email digest claims nothing while email is off, and claims the report alert once email is live.
  - Permissions:
    - the owner and a super admin can read the reports;
    - a read only admin can't until reports.view is granted;
    - a business owner and anonymous requests can't;
    - nobody can read the table directly;
    - signed in people can't run the job.
  - The schedule reads off, then shows the coming Monday at 08:00 UTC once the job is on.
  - Rollback runs twice and restores both functions exactly. The file applies again afterwards to the same versions.
  - A later change to the weekly list survives the rollback.
  - Drift: an unknown version stops the file and nothing is made.
- **Web unit tests:** `web/src/settings/weeklyReport.test.mjs` has 6 tests covering week labels, every figure and its definition, figures the server didn't send, the schedule wording, the refusal and the dash rule. All 17 web unit tests pass.
- **Local browser, real local backend:** `tests/browser/weekly-report.cjs` uses the isolated database, the local stand in and the real `owner-provision-business` code. 13 checks passed at 1440x900 and 390 px:
  - every figure is shown;
  - earlier weeks are listed;
  - the page says the job is off and email isn't live;
  - there is no dash and no sideways scrolling;
  - the read only admin sees the refusal.
  Screenshots are in the session scratchpad (`report/`).
- `npm run lint` finds 0 dashes, `npx vite build` passes, and `deno check` passes on `settings.ts`.
- No staging run and no real provider test. Nothing was sent.

## Deploy order (each step needs the owner's approval)

1. The supervisor confirms production's md5s for `zella_run_scheduled_job` and `zella_run_schedule_group`.
2. Apply `sql/zella_weekly_platform_report.sql`.
3. Deploy `owner-provision-business`, which adds `reports.view` to the catalog.
4. Deploy the web app.
5. The owner switches on `zella_jobs_weekly` when they want reports to start. The email digest follows `email_live`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
