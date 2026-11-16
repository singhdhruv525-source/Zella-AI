Scheduled jobs on Operations with each job's intended state (PLT-07)
base: main

(Already open as PR #94: https://github.com/singhdhruv525-source/Zella-AI/pull/94. CodeRabbit was rate limited on d86ba76, not reviewed.)

## What and why

**PLT-07 (both triage rows, merged into one item): show each scheduled job's state, and whether it is off on purpose.**
Operations showed no job state, and nothing anywhere said whether a job was off deliberately, so a bare "Off" read the same as a fault.

- `sql/zella_job_intent.sql` (new, version guarded):
  - server only table `scheduled_job_intents` (intended on or off, reason, who, when; row security on, no policies, no grants to signed in people);
  - records the nine go live jobs (`zella_dispatch`, every 5, every 15, hourly, daily, weekly, `zella_cron_cleanup`, `zella_platform_emails`, `zella_spam_hourly`) as **"Deliberately off until go live"**; existing rows are never overwritten;
  - `zella_admin_job_intent_save(job, intended, reason)`: `platform.configure`, reason required, audited as `scheduled_job.intent_recorded` with before and after. **It is a record, never a switch: it never runs `cron.alter_job` and never changes `cron.job`.** No job is switched on by this PR; that stays the owner's live switch;
  - `zella_admin_scheduler_health` keeps every key it returned and adds per job `intended`, `intent_reason`, `intent_at`, `intent_by`, `intent_matches`, `drives` (plain words), plus `intent_mismatches` and `intent_only` (intents for jobs not created). Archived through `zella_function_archive`, md5 guarded.
- Web:
  - `web/src/admin/ScheduledJobs.jsx`: a Scheduled jobs panel on Platform operations (state, intended state, "Not as intended", last run, failures in 24 hours, and a Record intent dialog with a reason);
  - `web/src/admin/jobState.js`: shared helpers, including the "Needs the Dispatcher job, which is off (deliberately off until go live)." note, now shown on the n8n line in Services;
  - the helpers live in a new file so `adminOps.jsx` and `AutomationsPage.jsx` (open on the polish branch #88) are not touched. Automations picks up the intent column after #88 merges.

`PlatformMonitoring.jsx`, `StatusPage.jsx`, `OwnerDashboard.jsx` and the cancellations files are not touched.

## Defaults taken (owner can change)
- All nine go live jobs recorded as "Deliberately off until go live" (plan.owner_decisions PLT-07). `zella_usage_thresholds` and `zella_billing_reconcile`, which are on in production, get no intent, so they read plain "On" rather than a false "off on purpose".
- Intents live in their own table (not `platform_settings`); recording one needs `platform.configure`.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_job_intent.sql`. **Production md5s to be confirmed by the supervisor before apply.**
2. Web app. Before step 1 the page still works: jobs show On or Off with "Not recorded".

No edge function change.

## Fingerprints (from an isolated copy: zprod3, then writing_cleanup, then the merged unapplied migrations)
- `zella_admin_scheduler_health()` before: `b8391d24bcdae1a24a42189233432c16` (no merged migration rewrites it); after: `494ea08eb56a1e8283a828c8e0a01926`.

## Tests
- Automated local (isolated Postgres only): `tests/job_intent/run.sh`, 31 checks, ALL PASSED: the gap reproduced first; apply, apply again; the seed; intent vs real state, mismatch count, intent only list; every old key kept; save audited with the admin's id and **cron.job unchanged** (fingerprint before and after every attempt); wrong role, a business member and anonymous refused; reason, job name and value validated; table not readable directly; rollback twice restores the function and grants exactly and removes the table; reapply; ROLLBACK_DRIFT on a changed function; VERSION_MISMATCH on a version that isn't production's.
- Web unit: `node --test web/tests/jobState.test.mjs` (6 pass).
- `npm run lint`: 0 errors, 0 dashes (existing warnings only); `npx vite build`: built.
- Local browser (local stand in on an isolated database, real RPCs): Platform operations at 1440x900 and 390 wide, deviceScaleFactor 1, no page errors, no failed calls, no sideways scroll; recording an intent from the page shows "Meant to be on" and writes the audit row while `cron.job` stays the same.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
