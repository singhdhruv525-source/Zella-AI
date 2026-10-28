# Calling minutes: automations

| Automation | Trigger | Component | Success | Failure handling | Idempotency | Status |
|---|---|---|---|---|---|---|
| Record usage for a call | `calls` insert / update of end, duration or report state (trigger `zella_calls_usage`) | Supabase | one `usage` row | `processing_failed` issue; the call write always succeeds | row lock, one usage row per call, idempotency key | tested on staging |
| Correct usage when the provider's duration changes | same trigger; reconciliation step a | Supabase | one `adjustment` row (difference) | as above | numbered adjustment keys | tested |
| Missing / implausible duration | processing; reconciliation step c | Supabase | issue opened, escalated once after a day | platform alert (one per day) | one open issue per call and kind | tested |
| Retry failed processing | reconciliation step b, every 15 min | Supabase (dispatcher `every15`) | recorded, issue resolved | 5 attempts with growing waits, then escalated once | skip-locked issue rows | tested |
| Ledger consistency | reconciliation step d | Supabase | no open mismatch | one open `summary_mismatch` per business | unique open issue | tested |
| Threshold events | after each recorded / adjusted call; existing hourly job `zella_usage_thresholds` | Supabase | event + in-app notice | evaluation errors never affect processing | unique (business, threshold, period); legacy keys honoured | tested with a test-only plan |
| Threshold email / SMS | `staff_notifications` rows | n8n Owner Emails / Staff Texts (existing) | `delivery_status = sent` | existing retries and failure alerts in those workflows | one notice per event | **not run**: workflows unpublished, providers not connected |
| Admin retry | admin action | Supabase (`zella_admin_retry_usage`) | reprocessed, audited | errors returned to the admin | same as processing | tested |

n8n never calculates usage, grants entitlements or writes the ledger; it only delivers notices the database created.
No new n8n workflow was needed. External notifications stay off during development (scheduler disabled, workflows
unpublished, `email_live` / `sms_live` false).
