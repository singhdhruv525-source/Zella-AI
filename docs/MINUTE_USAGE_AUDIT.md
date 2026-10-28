# Calling minutes: audit of what exists (2026-10-28)

Read-only inspection of the repository and the production database (project pffqxlumqhjdbzvvoszm). Production has
3 businesses, 0 calls, 0 usage records, 0 subscriptions and 0 plans.

## Tables

| Table | What it holds | Rows | Access |
|---|---|---|---|
| `calls` | one row per provider call (one row guaranteed by the voice-reliability unique index); `duration_seconds`, `started_at`, `answered_at`, `ended_at`, `ai_handled`, `direction`, `status`, `metadata` (provider status, ended reason, `ended_at_source`, reconcile state) | 0 | members by RLS |
| `usage_records` | generic usage: `business_id`, `subscription_id`, `usage_type`, `quantity numeric(12,4)`, `unit`, `period_start`, `period_end` (both required), `source_id`, `metadata`, `created_at` | 0 | RLS on; members may select; no writers in the repo |
| `subscriptions` | `plan_id`, `status`, `billing_interval`, `provider`, `external_subscription_id`, trial dates, `current_period_start`, `current_period_end`, grace / cancel dates | 0 | members may select |
| `plans` | `name`, `slug`, prices, `features`, `limits` (allowances, e.g. `voice_minutes`) | 0 | anyone may select active plans |
| `payments` | provider payments | 0 | - |
| `business_usage_preferences` | the owner's choice for usage beyond the allowance (`stop` / pay as you go / top-up, spend limit, fallback), notify thresholds (70/90/100 by default) and which thresholds were already notified | 0 | functions only |
| `voice_pricing` | provider per-minute rates for estimated cost | 0 | functions only |
| `notifications`, `notification_preferences` | an older notification table and per-user preferences | 0 | - |
| `staff_notifications` | the notification system in use (`zella_notify` / `zella_notify_owners`), with `delivery_status`, `sms_status`; delivered by n8n Owner Emails / Staff Texts | - | - |
| `audit_logs` | `action`, `entity_type`, `entity_id`, `old_data`, `new_data` | - | - |

## Functions (all match the repo exactly; source `sql/zella_settings_system.sql`)

- `zella_usage_counts(business, from, to)`: **live sum** of `calls.duration_seconds / 60` (1 decimal) for `ai_handled`
  calls by `created_at`, plus SMS, numbers, seats, automations, integrations. No ledger, no per-call record, no
  idempotency, no audit, no corrections; a call whose duration changes changes history silently.
- `zella_current_subscription`, `zella_business_entitlements` (members / `businesses.view` admins),
  `zella_business_entitlements_internal`: plan, `limits`, period, usage. **With no subscription the period falls back to
  the calendar month**.
- `zella_entitlement_allows(business, key, add)`: **no plan or no limit = allowed**. Used for team seats and phone
  numbers only; voice minutes are not enforced anywhere.
- `zella_check_usage_thresholds()`: hourly pg_cron job `zella_usage_thresholds` — **the one active scheduled job in
  production**. Notifies owners at the business's thresholds of `plans.limits.voice_minutes`; deduplicated per period
  in `business_usage_preferences.notified`. With no plans it does nothing.
- `zella_voice_usage_summary(from, to)`: platform-wide estimated cost from `voice_pricing`.
- Admin permissions: `platform_role_permissions` has `billing.view`, `billing.manage`, `plans.manage`, `audit.view` and
  others; `zella_admin_can(permission)`.

## How call duration arrives (voice-reliability phases 1 to 4)

- Vapi end-of-call report -> `voice-rules` -> shared parser -> `zella_record_inbound_call`: `p_seconds` = Vapi's
  `durationSeconds` when present, otherwise `endedAt - startedAt` from Vapi's own timestamps (the report schema in
  `@vapi-ai/server-sdk` 3.0.0 has no duration field). A missing value stays null; a later report changes nothing.
- Reconciliation (`zella_reconcile_call`, phase 1) fills a call whose report was lost from Vapi `GET /call/{id}`
  (`startedAt` / `endedAt`), marked `ended_at_source = provider`.
- Status updates (`zella_record_call_status`) set `ended_at` from the event but never a duration.
- Outbound callback and follow-up calls: their end-of-call report updates the callback or task
  (`zella_record_call_result`); **no `calls` row with a duration is written for them**, so they can't be counted yet.
- Provider-billed telephony minutes and Vapi `cost` are in the report but not stored.

## UI

- CRM: Settings > Phone system > Voice usage and Billing > Usage and charges (`UsageCard`: "AI voice minutes X of Y"
  from `zella_business_entitlements`), AI usage protection, usage notification settings.
- Admin: business details show plan and "AI minutes"; Plans > Plan entitlements edit `plans.limits`; no usage-record,
  failure or reconciliation views.

## Gaps against the requirements

1. No usage ledger: nothing records what each call consumed, when, under which policy, or its corrections.
2. No duplicate protection beyond the single call row; no processing status, failures or reconciliation of usage.
3. Rounding is a fixed "seconds / 60, 1 decimal" inside a read query.
4. Missing plan = allowed, and calendar-month periods when there is no subscription.
5. Threshold events have no record of their own (only a key in a jsonb column), no delivery status, no admin view.
6. Outbound AI calls are not counted.
7. No admin tools to investigate or retry usage processing.

What is reused rather than rebuilt: `usage_records`, `subscriptions`/`plans` (period boundaries and `limits` when
they exist), `business_usage_preferences` thresholds and their dedupe keys, `zella_check_usage_thresholds` and its
cron job (now evaluated from the ledger), `zella_notify_owners`/`staff_notifications` and the existing n8n delivery,
`audit_logs`, `zella_admin_can`, the dispatcher's scheduled-job groups, and the CRM/admin settings pages.
