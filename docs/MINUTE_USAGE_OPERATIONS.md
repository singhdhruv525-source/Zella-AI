# Calling minutes: operations

## Where to look

- Admin > Settings > Billing and financial operations > Calling usage (`billing.view`): usage records by business and
  date, open issues, threshold events with notice delivery status, the policy in force, usage audit history.
- CRM > Settings > Billing and subscription > Calling usage: the business's own totals, corrections, calls waiting to
  be counted, allowance (or "will appear here when your subscription plan is configured"), paginated history.
- SQL (service role): `select zella_call_usage_status();` (6 true), `select zella_reconcile_call_usage();`,
  `select * from usage_processing_issues where status <> 'resolved' order by created_at desc;`

## Investigating

| Issue | Meaning | What to do |
|---|---|---|
| `missing_duration` | the call ended but no provider duration arrived (report lost, reconciliation off or failing) | turn on / check Call Reconciliation (`call_reconcile_live`); the call is counted automatically once Vapi's record is fetched |
| `invalid_duration` | the provider sent an impossible value (negative or over 24 h) | check the call in Vapi; correct `calls.duration_seconds` from Vapi's own record, and the next reconciliation records it |
| `processing_failed` | an error while recording (e.g. an invalid `call_usage_policy`) | fix the cause, then Retry (billing.manage) or wait for the automatic retries |
| `summary_mismatch` | calls with usage and their ledger rows disagree for a business (usually a hand-edited ledger or an escalated call) | compare `usage_records` with `calls` for that business; never edit ledger rows: fix the call, and the next run adjusts |

Escalated issues raise a platform alert once a day (`usage_processing_failed`, `usage_missing_duration`).

## Changing the policy

Update the platform setting `call_usage_policy` (increment, rounding, minimum, ignore-under). It applies to calls
recorded afterwards; existing rows keep the policy stored with them. Category rules: `call_usage_rules`.

## Deployment (needs approval; not done)

After the voice-reliability migrations: `sql/zella_call_usage.sql`, then re-run `sql/zella_dispatcher.sql` (adds the
reconciliation job; production's dispatcher is older than the repo's). Check `zella_call_usage_status()`. Rollback:
`drop trigger zella_calls_usage on calls`; re-run `zella_settings_system.sql` sections 3 and 6 to restore the previous
`zella_usage_counts` and `zella_check_usage_thresholds`; the added columns and tables can stay (unused) or be dropped.
