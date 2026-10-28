# Calling minutes: design

Source: `sql/zella_call_usage.sql` (applied to production 2026-10-28). Plan-agnostic: no plans, prices, allowances, overage
charges or minute packs are created or assumed.

## Components reused

`usage_records` (extended, not replaced), `subscriptions` / `plans` (period boundaries and `limits.voice_minutes` when
they exist), `business_usage_preferences` (notify thresholds, their dedupe keys, the owner's fallback),
`zella_check_usage_thresholds` and its existing hourly cron job, `zella_usage_counts` (now reads the ledger),
`zella_notify_owners` / `staff_notifications` and the existing n8n delivery, `audit_logs`, `zella_admin_can`
(`billing.view`, `billing.manage`), `zella_platform_alert`, the dispatcher's scheduled-job groups, the voice-reliability
call record (one row per provider call) and the CRM / admin settings workspaces.

## Ledger (`usage_records`, `usage_type = 'ai_call'`, `unit = 'minute'`)

| Column | Meaning |
|---|---|
| `entry_kind` | `usage` (one per call) or `adjustment` (a later change; history is never overwritten). `reversal` is reserved |
| `call_id`, `provider_call_id`, `provider_event_id` | the internal call (nulled if the call is deleted; the row stays), Vapi's call id, an optional event id |
| `idempotency_key` | `ai_call:<provider call id>` for the usage row; `...:adj<n>:<from>><to>` for the n-th adjustment |
| `duration_seconds` | raw provider duration (adjustments hold the difference) |
| `billable_seconds`, `quantity` | after the policy; `quantity` = billable minutes (4 decimals) |
| `telephony_billed_seconds`, `included_minutes_consumed` | kept separate and empty: not reported / no entitlements yet |
| `policy` | the policy and the industry rule used, stored on the row (a later policy change never rewrites history) |
| `usage_category` | `inbound_ai`, `outbound_ai`, `other_ai` |
| `occurred_at` | the call's start (summaries filter on it) |
| `period_start`, `period_end`, `period_source`, `subscription_id` | the subscription's own period when the call falls in one, else the call's own time (`call`) |
| `reconciliation_status` | `ok`, `adjusted`, `discrepancy` |

Constraints: one `usage` row per call (`usage_records_one_call_idx`), unique idempotency key, unique provider event per
business, and a check that every AI-call row has its provider call id, raw and billable seconds and policy. Members can
only read (existing RLS policy); nobody but the service role writes.

## Processing (`zella_process_call_usage`)

Triggered by `zella_calls_usage` on every insert or update of a call that changes its end, duration or report state;
also by reconciliation and admin retries. Steps: lock the call row (concurrent runs queue) -> provider call id
present -> category and industry rule -> call over and report in (`ended_at`, not `awaiting_report`) -> duration
present (else, after `call_usage_missing_duration_hours`, an issue; never estimated) and plausible (0 to 86 400 s) ->
first time: one `usage` row; later different duration: one `adjustment` with the difference under the original
policy -> resolve open issues -> evaluate thresholds. A failure never breaks the call write: the trigger records a
`processing_failed` issue instead.

Authoritative duration: `calls.duration_seconds`, set by `zella_record_inbound_call` from Vapi's end-of-call report
(`durationSeconds` when sent, else Vapi's `endedAt - startedAt`) or by `zella_reconcile_call` from Vapi `GET /call`.
Vapi's `cost` and telephony billing are not used and not assumed equal to call time.

## Policy (platform setting `call_usage_policy`)

`{"increment_seconds": 1, "rounding": "up", "minimum_billable_seconds": 0, "ignore_under_seconds": 0}` — the
**testing default: exact seconds**, no rounding, no minimum. Not a commercial decision; change it before plans go live.
`increment_seconds` 1 to 3600, `rounding` up / nearest / down, `minimum_billable_seconds` for any counted call,
`ignore_under_seconds` for calls not counted at all. An invalid policy stops processing (issues are recorded, retried
after it is fixed). Category rules (`call_usage_rules`): `counted_categories` by default and per industry key;
default: inbound and outbound AI calls count everywhere. The rule applied is stored on each row.

## Summaries

`zella_call_usage_totals` (ledger only), `zella_call_usage_summary` (members / billing.view admins / server; a date
range, or the subscription's own period; **never a calendar month**; no period = "choose a date range"),
`zella_call_usage_records` (paginated history, caller shown as the last four digits), `zella_call_allowance`
(configured only with an active subscription, its period and a numeric `plans.limits.voice_minutes`; otherwise
`configured: false` with the reason — never zero remaining, never exhausted). `zella_usage_counts.voice_minutes` (the
existing Billing page and notices) now reads the ledger.

## Entitlement interface (`zella_call_entitlement_check`, server only, not wired to call admission)

Returns `status` (`not_configured` | `active` | `exhausted` | `inactive` | `error`), `would_permit`, `enforced: false`,
`reason`, usage, limit, remaining and the owner's fallback. Not configured is explicitly not "unlimited"
(`would_permit: null`); calls continue exactly as today until admission is deliberately connected. Future hard-limit
enforcement: call this inside the call-start path under a per-business advisory lock (as the booking lock does) and
count minutes reserved for calls in progress, so concurrent calls can't overrun the allowance.

## Thresholds

`usage_thresholds` (admin-configured, empty) plus the owner's `business_usage_preferences.notify_thresholds`
(default 70/90/100). Evaluated only when an allowance is configured. Each threshold reached creates one
`usage_threshold_events` row per business, threshold and period (unique), one in-app notice through
`zella_notify_owners` (email / SMS by the existing delivery workflows when they are live), and links the notice so its
delivery status is visible. Old dedupe keys are honoured, so nothing already notified is sent again.

## Reconciliation (`zella_reconcile_call_usage`, every 15 minutes via the dispatcher)

a. Ended AI calls with no usage, or whose duration differs from the ledger -> processed (recorded or adjusted).
b. `processing_failed` issues -> retried at 15, 30, 60, 120, 240 minutes; after 5 attempts escalated once with a
   platform alert (deduplicated per day).
c. Missing or invalid durations open for a day -> escalated once (still not counted).
d. Per business, last 35 days: calls with usage vs their ledger rows; one open `summary_mismatch` until they agree.

## Authorization

Members read their own business (`zella_is_member`); `billing.view` admins read all; `billing.manage` admins retry
(audited as `billing.usage_retry`); the server (no user) may read summaries; anon can execute nothing; processing,
reconciliation, the entitlement check and threshold evaluation are service role only.

## Future plan integration points

`plans.limits.voice_minutes` -> allowance; `subscriptions.current_period_*` -> periods; `usage_records.subscription_id`
and `period_*` already filled when a period exists; `included_minutes_consumed` for split accounting;
`usage_thresholds` for admin thresholds; `zella_call_entitlement_check` for admission; `business_usage_preferences`
for the owner's overage choice.
