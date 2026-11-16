Business page: every audit action has a label, one automation status language, capitalised names
base: claude/lane-a-catalog (lane A PR #93: open this after #93 merges, then retarget to main)

## What and why

**BIZ-25 (Activity labels).** The Activity tab's labels now come from lane A's shared catalog
(`web/supabase/functions/_shared/catalog.json`, PR #93), whose drift test already fails when SQL or an edge function
writes an action that isn't listed. `web/src/copy/auditActions.js` is a thin reader on top: the database's own change
records (`privileged_*`) name the table they changed from `entity_type` ("Changed business (system record)" instead
of "Changed a protected record"), and anything unknown still reads as words. An earlier commit on this branch had its
own label list and scanner; it was replaced by the catalog so there is one list.

**OPS-22 (one status language).** `AUTOMATION_STATUS` in `web/src/automationCatalog.js`: active is "Active" (success),
paused is "Paused" (warning), disabled is "Turned off" (neutral), as `docs/ZELLA_STATUS_LANGUAGE_GUIDE.md` says. The
business page's automation list uses it (it said "off" with an info tone).

**UI-09 part a (copy).** Catalog titles always start with a capital ("Visit reminders", "No show follow up"), and the
two "None" columns say "Not in use".

## Not in this PR (and why)
- `web/src/ownerFormat.js` still has its own `ACTION_LABELS` (it belongs to the Businesses list job), and
  `AuditLogs.jsx` reads it; lane A's PLT-08 part 2 moves both to the catalog and can reuse `actionLabel` from here.
- `admin/AutomationsPage.jsx` still says "Archived": it was on the open polish branch when this was built. Switching
  it to `automationStatusPill` is one import and three lines, for whoever edits that page next (noted on OPS-22).
- One shared label changed in `catalog.json`: `automation.archived` reads "Turned off automation" (was "Archived
  automation"), to match OPS-22. Tell lane A.

## Defaults taken (owner can change)
- `AUTOMATION_STATUS.disabled.label = "Turned off"` (OPS-22 recommended answer; the language guide already says so).
- The scan scope is lane A's drift test's (critic: "define the scan scope up front"); this PR adds no scanner.

## Deploy order
Web only. No SQL, no edge function. Safe with every edge version (labels for actions not yet written are harmless).

## Tests
- Automated local: `node --test` new `auditActions.test.mjs` (every catalog action reads with its catalog label; every
  action the old list knew is labelled; system records name the table; unknown actions read as words) and
  `automationStatus.test.mjs` (the map, the business tab uses it, capitalised titles): 7 pass, 0 fail.
  `npm run lint`: 0 errors, check-dashes 0 found, catalog drift test "214 audit actions, 62 alert kinds and 19
  permissions match 724 uses". `npx vite build`: built.
- Local browser (isolated `zle_ui`: zprod3, writing cleanup, the merged unapplied migrations, test admins and one test
  business): `/businesses/<test id>` at 1440x900 and 390 wide, deviceScaleFactor 1, no page errors, no sideways
  overflow. Automations shows Active, Paused and Turned off and no "None"; Activity shows "Suspended business",
  "Changed business (system record)", "Changed call routing", "Paused automation", "Changed business hours".
  Screenshots: `scratchpad/lane-e/shots/pr1_automations_1440.png`, `pr1_automations_390.png`,
  `pr1_activity_1440.png`, `pr1_activity_390.png`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
