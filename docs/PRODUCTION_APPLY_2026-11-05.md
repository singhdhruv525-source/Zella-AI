# Production apply, 5 Nov 2026

Approved by the owner ("apply the 17 migration and 3 fixes"). Database only: **no edge function was deployed, the web
build was not published, and no sending was switched on.**

## What was applied (project pffqxlumqhjdbzvvoszm, in this order)

| # | Migration | How it was sent |
| --- | --- | --- |
| 0 | Backups `backup_20261104_presets` (26 rows), `backup_20261104_types` (2), `backup_20261104_records` (0); RLS on, no access for signed-in users | SQL |
| 1-6 | zella_viewer_read_only, zella_staff_add_lead, zella_call_content_privacy, zella_capabilities, zella_record_links_secrets, zella_money | file body without its header comment |
| 7-17 | zella_presets_v2, zella_automation_presets_v2, zella_receptionist_industry_rules, zella_readiness, zella_appointment_records, zella_record_files, zella_ai_caller_fixes, zella_message_courtesy, zella_google_leads, zella_calendar_providers, zella_store_orders | md5-guarded: the file text in a dollar-quoted string, executed only if the server's md5 of it equals the repository file's |
| 18-20 | zella_setup_enforcement, zella_message_settings_fix, zella_order_lookup_assurance | md5-guarded |

All 20 are recorded in `supabase_migrations.schema_migrations`. `zella_appointment_records` timed out once at the approval
prompt (nothing applied, checked) and was sent again.

## Checks after applying (read only)

- Pre-check: production's functions matched the tested baseline (sql/baseline + the live fix files), except
  `zella_platform_admin_email_check` / `zella_platform_admin_trigger` (`zella_platform_roles_fix.sql`, not applied live; none
  of the 20 files touch them).
- After: all 743 public functions (those two excluded) are identical to an isolated copy built from the same 20 files
  (tests/orders/run.sh database), except five older functions (`zella_accept_my_invitations`, `zella_accept_staff_invitations_v2`,
  `zella_apply_billing_event`, `zella_process_billing_event`, `zella_mfa_satisfied`) that differ only in comments (they were
  applied live earlier without them; identical once comments and spacing are removed). This also confirms migrations 1-6,
  which were sent without the md5 guard.
- Deployment review checks: 28 message-policy rows; Orders "unsupported" for all 4 businesses; `lookup_order` offered to
  none; `calls.transcript` and `calls.recording_url` not selectable by signed-in users; 28 presets, 3 record types, 0
  private values moved; private `record-files` bucket; 0 automations switched by the M3 data update.
- Security advisor, items from today: `calls_view` security-definer view (by design: it filters rows itself and blanks
  content), RLS-without-policy on the backups and the Google lead tables (server-only by design), mutable search_path on
  `zella_capability_catalog` and `zella_asset_type_keys` (immutable, no table access), `zella_capability_appointment_trg`
  executable by anon (a trigger function; calling it directly fails). None blocks; the last two are a hygiene follow-up.

## Not done (needs separate approval)

- Edge functions: owner-provision-business, voice-rules, google-lead, record-files, calendar-connect, store-connect.
  Until voice-rules is deployed, `lookup_order` is answered "take a message" by the database (no store is connected anyway).
  Until owner-provision-business is deployed, setup saves don't call `zella_setup_language_apply` or the transfer sync.
- The one-time setup catch-up in `sql/zella_setup_enforcement.sql` (0 setup knowledge items in production now).
- `zella_platform_roles_fix.sql`.

## Rollback

`sql/rollback/zella_order_lookup_assurance_rollback.sql`, `zella_message_settings_fix_rollback.sql`,
`zella_setup_enforcement_rollback.sql` (each reverses only its own file), then `sql/rollback/industry_2026_11_04_rollback.sql`
for the 17 (needs the backups above).

## Evidence note (added 5 Nov, evening)

Statements here about production are one of:
- **current configuration** read on 5 Nov;
- **retained history**: the audit log since 22 Oct and reminders since 23 Oct, which show every reminder ever queued
  was a text and no automation change mentioned an AI-call channel;
- **local tests** on isolated copies.

None comes from a provider test: no real Vapi call, Shopify store, SMS, email or Google request was made. "Changes no
existing row" or "no customer affected" means within that configuration and history, not a proof about earlier
states that left no record. Per-issue labels and statuses: `docs/DEFECT_INVENTORY_2026-11-05.md`.
