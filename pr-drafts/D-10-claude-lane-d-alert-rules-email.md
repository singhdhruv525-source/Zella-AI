Alert rules editor and rule aware admin alert email (SET-ALERT-RULES part 2)
base: claude/lane-d-alert-rules

## What and why

**SET-ALERT-RULES (UI and email):** admin alert email went to every active admin with no per kind destination or quiet window, and Settings, Alert rules was a "not built" note.

- `sql/zella_alert_rules_email.sql` (new, version guarded; needs `zella_alert_rules.sql`): `zella_claim_admin_alert_email` replaced, **built from production's body** (md5 `cd96d330aa78de5fbb9e4091e1ab77c1`, confirmed by the supervisor; the test template's older copy differs), archived first. Production's per admin email opt out (`admin_alert_prefs.email_enabled`) and its retry of a claim that never finished (after 15 minutes, at most 3 tries in all, `meta.email_claimed_at` and `email_attempts`) are kept unchanged:
  - a bell only kind isn't emailed: marked handled (`meta.email_skipped = bell_only`), it stays open in the bell. **Urgent alerts are always emailed**;
  - a rule's quiet window (its own time zone, may cross midnight) holds warning and info alerts until it ends. **A quiet window never delays an urgent alert.** An unknown time zone never holds anything back;
  - a rule's email permission sends that kind only to active admins holding it (the owner holds every one); when nobody holds it, every admin gets it, so an alert is never lost; opted out admins never get one;
  - one call claims one recipient group (the group of the most urgent waiting alert), so the **n8n Admin Alerts workflow is unchanged** (one digest to `to`); the next run takes the next group. The answer gains `group`.
  - With no rules the answer is exactly production's (tested against a second copy).
  - The dispatcher still counts held alerts as waiting during a quiet window, so it may start the workflow and get an empty claim; harmless, and it backs off after 12 tries.
- Web: `web/src/settings/panels/AlertRules.jsx` and `alertRules.js`. Lists **every alert kind from the shared catalog** (`_shared/catalog.json`, PLT-08, merged in the previous branch) with its rule in one sentence, "Always urgent" for protected kinds and how often each was raised in 30 days. The editor sets on or off, severity, bell only or email to admins holding a permission (from the catalog's permissions), how often it may open again, and quiet hours, with a reason; "Back to as raised" removes the rule. Protected kinds can't be switched off or lowered in the form (and the database refuses it too). Saving calls `zella_admin_alert_rule_save` directly as the signed in admin (like the other admin pages), so no edge function action is needed; editing is shown only with `platform.configure`. `AdminPanels.jsx` gets an import and a one line render; `SettingsPage.jsx` passes `me` to the panel.

## Defaults taken (owner can change)
- When no admin holds a rule's email permission, every admin is emailed.
- Quiet hours default to 22:00 to 07:00, America/New_York, when switched on.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_alert_rules.sql` (previous PR), then `sql/zella_alert_rules_email.sql`. **Production md5s to be confirmed by the supervisor before apply.**
2. Web app. Email only goes out once `email_live` is on.

## Fingerprints (isolated copy: zprod3, writing_cleanup, merged unapplied migrations, production's `zella_claim_admin_alert_email`, then zella_alert_rules.sql)
- `zella_claim_admin_alert_email(integer)` before `cd96d330aa78de5fbb9e4091e1ab77c1` (production's, from the supervisor's read; no merged migration rewrites it), after `098de63ccdfe5d723ce9d20ea8b1b801`. The test loads production's definition first (`tests/alert_rules_email/prod_claim_admin_alert_email.sql`).

## Tests
- Automated local (isolated Postgres, two copies): `tests/alert_rules_email/run.sh`, 28 checks, ALL PASSED: starts from production's version (cd96d330); the gap; applies after part 1, twice; same answer as production with no rules; email off claims and marks nothing; bell only skipped but urgent of that kind emailed; quiet window holds warning and info, never urgent, releases them in order after, crosses midnight, ignores an unknown time zone; email permission groups one per claim, owner only permission, nobody holds it falls back to every admin; opted out admin never emailed; a claim that never finished is retried, at most 3 tries in all (kept from production); only the server may claim; the part 1 rollback refuses while this is applied (ROLLBACK_ORDER); rollback twice exact; reapply; ROLLBACK_DRIFT; VERSION_MISMATCH.
- Web unit: `node --test web/tests/*.test.mjs` 123 pass (alertRules.test.mjs: kinds from the catalog with rules, protection and counts; rule summaries; protected kinds can't be switched off or lowered from the form; bell only and quiet hours).
- `npm run lint`: 0 errors, 0 dashes, catalog drift test passes; `npx vite build` built.
- Local browser on the local stand in at 1440x900 and 390 wide, no page errors or failed calls: 63 real kinds listed, protected kinds marked, the protected kind's on switch disabled, a rule saved from the editor (offer_ending_soon to Info) shows in the list and wrote `alert_rule.saved`. Screenshots `scratchpad/lane-d/shots/settings_alert_rules_*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
