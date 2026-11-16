Audit rows record before and after; a failed audit write raises an alert (edge)
base: claude/lane-e-verification-filter

## What and why
**BIZ-17.** Suspend recorded only the reason, reactivate nothing, and no setup row had a before value.
- Each setup and lifecycle handler returns its before values through `withBefore(result, before)` (`detail.ts`): a
  **Symbol key**, which `JSON.stringify` leaves out, so the AUDITED builders read them and the browser never gets
  them. (Critic: "before values must not leak into the response". No dispatcher change needed.)
- `business_suspend` and `business_reactivate` re-read the lifecycle fields (`is_active`, `onboarding_status`,
  `suspended_at`, `cancel_at`, `cancelled_at`) before and after the RPC. `business_cancel` and `business_undo_cancel`
  record cancel_at and the reason before and after. `setup_finish` records the lifecycle fields before and after.
- `setup_save_business` records changed fields with old and new values, except a business's contact fields (email,
  phone, address lines, postal code), which are recorded by name only (`contact_fields_changed`).
- Terminology, modules (module ids before and after), receptionist (service and FAQ counts, personality,
  `config_hash`), integrations and automations record their slice before and after.
- `owner.saved` and `invitation.resent` now mask emails (`a…@example.com`) and record `email_changed`, and invitation
  errors are masked (`maskText`), so no audit row holds a full email or phone (DB-13, PRV-2).
- `writeAudit` returns whether it wrote. On failure it calls `zella_platform_alert('audit_write_failed', …, 'urgent',
  business_id, dedupe per action)` and the dispatcher adds `auditWarning` to the response.
- `business_detail`'s activity select now includes `old_data` (critic: so BIZ-17 can be seen; the Activity before and
  after view is in the Business page web PR).

**COM-04 option B (server half).** Confirmed from the function definitions: a receptionist edit reaches the next call.
The audit row records `config_hash` before and after, read from `zella_assistant_delivery_status`'s
`current_config_hash` (the same md5 the deliveries record; the edge function can't reproduce the SQL jsonb text, as
the critic noted). The "applies to the next call" label is in the web PR (agreed wording with the list job's BIZ-15).

## Critic correction: fail closed
The dispatcher writes the audit row after the handler has committed, so "refuse when the audit write fails" can't be
done there. **Chosen: alert and warn for every action** (`audit_write_failed`, urgent, plus `auditWarning`). Suspend,
reactivate and cancel are additionally recorded by the database trigger `zella_audit_privileged` on the businesses
row, so they are never unrecorded. Failing closed would need the audit row written first inside each handler (as the
reveal and two step reset do); not built. Owner can ask for it.

## Shared catalog (lane A, PR #93)
- New alert kind `audit_write_failed` added to `catalog.json`.
- `tests/catalog/scan.mjs` gains `tsAlertKinds` (alert kinds passed to `zella_platform_alert` from edge functions,
  which it didn't read), with a test. Tell lane A.

## Not in this PR
`onboarding.ts` actions (lane B's file) keep their audit builders unchanged.

## Defaults taken (owner can change)
- On a failed audit write: alert (urgent, deduplicated per action) and warn; never fail the action.
- Contact fields recorded by name only; emails masked in audit rows.

## Deploy order
Edge function (window B, needs approval). No SQL: `zella_platform_alert` exists and the server key can execute it
(checked on the isolated database). `auditWarning` and the `after` fields are additive.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 60 passed, 0 failed. New `audited_test.ts` (imports index.ts with `Deno.serve`
  stubbed): every setup and lifecycle builder gives non empty old_data and new_data; no full email and no 7+ digit
  number in any row; contact fields named only; the response JSON leaves the before values out; receptionist rows
  record config_hash before and after; a failed insert calls `zella_platform_alert` with `audit_write_failed`, the
  business and urgent, and returns false; a good insert raises nothing. `deno check index.ts` passes.
- `npm run lint` (oxlint, check-dashes 0, catalog drift "63 alert kinds … match 729 uses", scanner unit tests) passes.
- Local end to end (isolated `zle_ui`): suspend then reactivate the test business. `business.suspended` old
  `{is_active: true, suspended_at: null, …}` new `{is_active: false, suspended_at: <time>, reason: "Lane E test"}`;
  `business.reactivated` the reverse. The responses carry only the new state. `zella_platform_alert` called twice as
  the service role for the same action keeps one alert with occurrences 2 (dedupe).
- No browser check: no web change in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
