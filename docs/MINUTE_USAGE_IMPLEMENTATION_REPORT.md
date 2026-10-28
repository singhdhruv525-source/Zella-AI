# Calling minutes: implementation report (2026-10-28)

Development and staging only. Nothing was applied to production, no plans / prices / allowances were created, no
scheduler or workflow was enabled, no message was sent and no call placed.

## Changed

- `sql/zella_call_usage.sql` (new migration): ledger columns and constraints on `usage_records`, `usage_processing_issues`,
  `usage_thresholds`, `usage_threshold_events`, policy and category settings, processing, trigger, summaries,
  allowance, entitlement interface, threshold evaluation (existing hourly job now uses it), reconciliation, admin
  view and retry, status function. `zella_usage_counts` patched to read AI minutes from the ledger.
- `sql/zella_dispatcher.sql`: `zella_reconcile_call_usage` in the every-15-minutes group and the allowed-job list.
- `web/src/settings/CallingUsagePanels.jsx` (new), `web/src/BusinessSettings.jsx` (Billing > Calling usage),
  `web/src/SettingsPage.jsx` (admin Billing > Calling usage).
- Staging: `tests/voice-reliability/usage_test.sql` (new), production tables and the 11 live usage functions added to
  the staging layer (`phase4_tables.sql`, `phase4_md5.txt`), `run_all.sh` and `spam_compat.sh` updated.
- Docs: `MINUTE_USAGE_AUDIT.md`, `MINUTE_USAGE_DESIGN.md`, `MINUTE_USAGE_AUTOMATIONS.md`, `MINUTE_USAGE_OPERATIONS.md`, this file.

## Tests (all run on staging copies built from production's function bodies)

| Required test | Result |
|---|---|
| 1 valid completed call; 2 duplicate completion; 4 out-of-order events | pass |
| 3 duplicate provider event id | pass |
| 5 missing duration; 6 invalid duration; 7 missing call record | pass |
| 8 calculation; 9 configurable rounding (up / down / nearest / minimum / ignore-under; old rows keep their policy) | pass |
| 10 adjustments (history kept, not repeated) | pass |
| 11 reconciliation retries (5 bounded, escalated once) | pass |
| 12 concurrent processing (10 sessions released at once -> 1 row) | pass |
| 13 tenant isolation; 14 unauthorized access (members, other owners, anon, grants) | pass |
| 15 billing-period / date-range queries (no calendar months) | pass |
| 16 missing entitlement; 17 active entitlement; 18 exhausted entitlement (test-only plan in the throwaway database) | pass |
| 19 threshold events; 20 duplicate threshold notifications | pass |
| 21 failed notification delivery (visible to admins) | pass (status shown; actual delivery not run) |
| 22 retry behavior and authorization (read-only refused, billing.manage audited) | pass |
| 23 usage-summary consistency, reconciliation corrections and mismatch detection | pass |
| 24 industry-independent accounting and explicit industry rules | pass |
| 25 existing voice-reliability tests | pass (all suites, both spam-protection migration orders) |

Suite totals: `run_all.sh` ALL PASSED (184 checks); `spam_compat.sh` ALL PASSED (usage_test 19 checks on each order;
all five migrations in both orders, twice each); n8n 386/386; voice-rules 19/19; web lint and build pass.

Not run: the UI in a browser (lint and build only), email / SMS delivery (providers and n8n not live), a real call's
usage (needs Vapi), and anything on production.

## Defects found and fixed while building

- Repeated identical corrections were silently skipped (adjustment key collision): keys are now numbered per call.
- The ledger could not outlive a deleted call (constraint vs `on delete set null`): the provider call id is required instead.

## Outstanding

- Outbound callback / follow-up calls write no `calls` duration (their report updates the callback or task), so they
  are not counted yet. Needs the call-result path to store the outbound call (phase 5 work).
- No provider-billed telephony minutes or Vapi cost are stored; the columns exist.
- The rounding policy default (exact seconds) is for testing; commercial rounding is a business decision for later.
- Production's scheduled-job dispatcher is older than the repo's; re-running `zella_dispatcher.sql` is required.
- Plans integration: define `plans.limits.voice_minutes`, subscription periods from the billing provider, then wire
  `zella_call_entitlement_check` into call admission under a per-business lock.
