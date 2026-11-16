Resume all for a business, resuming only what Pause all paused (OPS-20)
base: claude/lane-d-n8n-status

## What and why

**OPS-20:** Automations offered "Pause all for this business" with no "Resume all", and the pause audited only a count, so nothing recorded which automations it paused.

- `sql/zella_automations_resume_all.sql` (new, version guarded):
  - `automations.bulk_paused_at`: set by Pause all on what it paused. A `before update of status` trigger clears it on **any other** status change (the business resuming or pausing one, a suspension, an admin's single change), so Resume all never touches an automation someone changed since;
  - `zella_admin_business_automations_pause` replaced (production md5 `89d2fc68649486ca8d2cb1d2801728ae`, archived): same permission, reason, rows and answer; it now sets the mark and lists the ids in its audit row;
  - `zella_admin_business_automations_resume(business, reason)`: `integrations.manage`, reason required, `BUSINESS_NOT_AVAILABLE` for a suspended or cancelled business, resumes only automations still marked and **not `paused_by_suspension`**; audited as `automation.business_resumed` with the ids.
- Web: Automations, Directory: "Resume all for this business" next to "Pause all", with a ReasonDialog that says what stays paused.

## Defaults taken (owner can change)
- Resume all needs the same permission as Pause all (`integrations.manage`).

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_automations_resume_all.sql`. **Production md5s to be confirmed by the supervisor before apply.**
2. Web app (its Resume all button needs step 1).

## Fingerprints (isolated copy: zprod3, writing_cleanup, merged unapplied migrations)
- `zella_admin_business_automations_pause(uuid,text)` before `89d2fc68649486ca8d2cb1d2801728ae` (no merged migration rewrites it); after `ff8907607f62387511208ac1ae03ce70`.

## Catalog (PLT-08, #93)
If #93 merges first, add the audit action `automation.business_resumed` ("Resumed all automations for a business").

## Tests
- Automated local (isolated Postgres): `tests/automations_resume_all/run.sh`, 23 checks, ALL PASSED: the gap first; apply twice; applying changes nothing; pause answers and pauses exactly as before and audits the ids; a later change by the business clears the mark; wrong role, member, anonymous and no reason refused; suspended and cancelled businesses refused; only what Pause all paused is resumed (not the business's own, not one paused by a suspension, not archived, not paused before; the other business untouched); audited with ids and admin; a second resume finds nothing; rollback twice restores the function exactly and removes the column, trigger and resume; reapply; ROLLBACK_DRIFT; VERSION_MISMATCH.
- `npm run lint` 0 errors, 0 dashes; `npx vite build` built.
- Local browser at 1440x900 (Pause all then Resume all on a test business: 2 paused, 2 resumed, the one paused before stays paused) and 390 wide, no page errors. Screenshots `scratchpad/lane-d/shots/automations_resume_all_*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
