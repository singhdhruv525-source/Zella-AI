Alert rules table and a rule aware zella_platform_alert (SET-ALERT-RULES part 1)
base: claude/lane-d-voice-ui

## What and why

**SET-ALERT-RULES (SQL):** Settings, Alert rules said rules aren't editable; `zella_platform_alert` read no rules.

This branch **merges lane A's catalog branch `claude/lane-a-catalog` (#93)** so the editor (next PR) lists real alert kinds and the drift test in `npm run lint` checks lane D's names. It adds lane D's names to `_shared/catalog.json` (sorted): `scheduled_job.intent_recorded`, `automation.business_resumed`, `alert_rule.saved`, `alert_rule.removed` and the alert kind `n8n_dispatch_refused`. Until #93 merges, its changes appear in this diff too.

`sql/zella_alert_rules.sql` (new, version guarded):
- `platform_alert_rules` (server only), one row per kind: `enabled`, `severity` (or as raised), `destination` (bell, or bell and email), `email_permission` (email admins holding it, or every admin), `repeat_minutes` (5 to 10080), quiet window (`quiet_start`, `quiet_end`, `quiet_tz`; used by part 2).
- `zella_platform_alert` replaced (production md5 `d2dda6716c1f0285a8290ef442f5a90f`, archived) with the **same signature, parameter names, defaults, result and grants**, so all 46 database callers and the n8n event router's named call resolve as before. **With no rule for a kind it behaves exactly as before.** With a rule: switched off raises nothing (returns null; the one caller that uses the id raises `service_incident`, which is protected); a severity replaces the raised one; a repeat interval doesn't open a new alert within that many minutes of the last one being resolved.
- **Urgent alerts can't be switched off or lowered, and are never held back**: an alert raised as urgent, or of a protected kind (`zella_alert_protected_kinds()`: service_incident, scheduler_failed, provider_down, integration_disconnected, tenant_leak), ignores enabled, severity and repeat.
- `zella_admin_alert_rules()` (`businesses.view`): rules, protected kinds, and how often each kind was raised in 30 days. `zella_admin_alert_rule_save(kind, rule, reason)` (`platform.configure`, reason, audited): validates every field, refuses to switch off or lower a protected kind (`URGENT_PROTECTED`), a null rule removes it.
- **`sql/zella_run_all.sql:1519` re-creates the old `zella_platform_alert`.** Never re-run it after this file (rules would silently stop being read); if it ever is, apply this file again (the guard accepts production's body and keeps the table). Recorded in SCHEMA_STATUS and MEMORY.

## Defaults taken (owner can change)
- Safety default from plan.owner_decisions: urgent kinds can't be switched off or lowered, only rerouted; quiet windows and repeat intervals never hold urgent alerts back. The protected list is `zella_alert_protected_kinds()`.
- Reading rules needs `businesses.view`; saving needs `platform.configure`.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_alert_rules.sql`. **Production md5s to be confirmed by the supervisor before apply.** No effect until a rule is saved.

## Fingerprints (isolated copy: zprod3, writing_cleanup, merged unapplied migrations)
- `zella_platform_alert(text,text,text,text,uuid,text,jsonb)` before `d2dda6716c1f0285a8290ef442f5a90f` (no merged migration rewrites it), after `a4d850dbfe1be1b404f97623e8a63c8e`.

## Note on part 2
This PR doesn't change `zella_claim_admin_alert_email`. Part 2 (`claude/lane-d-alert-rules-email`) does, built from production's version (md5 `cd96d330aa78de5fbb9e4091e1ab77c1`), not the test template's older copy. Its rollback refuses to undo this PR first (ROLLBACK_ORDER).

## Tests
- Automated local (isolated Postgres, two copies): `tests/alert_rules/run.sh`, 38 checks, ALL PASSED: the gap; apply twice; same signature, names, defaults, result and grants; **all 46 plpgsql callers still validate**; **every caller shape in `tests/alert_rules/callers.sql` (2 to 7 positional arguments, the n8n named call, nulls, every severity, repeats with meta merge and occurrence counts, and three real callers: `zella_record_provider_check` twice failing then recovering, and `zella_report_service_health`) leaves exactly the same rows as production's function**; off, severity up and down, repeat interval while open, within and after the window; urgent and protected never switched off, lowered or held back; save: protected refused, rerouting allowed, every field validated, audited, removal; wrong role, member and anonymous refused; list; table not readable; raising stays server only; rollback twice exact; reapply; ROLLBACK_DRIFT; VERSION_MISMATCH.
- `npm run lint`: 0 errors, 0 dashes, catalog drift test passes (218 audit actions, 63 alert kinds, 19 permissions).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
