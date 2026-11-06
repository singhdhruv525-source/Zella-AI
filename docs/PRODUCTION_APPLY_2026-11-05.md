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

## Second apply, 5 Nov evening (approved: "you apply the 7 database files", "apply remaining six")

Database only. Still no edge function deployed, no web build published, no sending enabled.

| # | Migration | md5 (guarded) |
| --- | --- | --- |
| 21 | zella_platform_roles_fix | 1269fe0daafc36ffe4f2014023902fbf |
| 22 | zella_booking_buffers | 53f55d010a3b43a80c8339902a5499c5 (the first attempt timed out at the approval prompt; nothing was applied, checked; sent again) |
| 23 | zella_channel_review | 1b4b30d2dce3c4d5eee7b4141b9351ed |
| 24 | zella_escalation_rules | bcbee4474fb1e7ce1da46b3792d8014b |
| 25 | zella_knowledge_live | 659c9ebec09e30cabc95185e7903bd9a |
| 26 | zella_order_lookup_v2 | 4bb97245c12f3ca337b144571038e240 |
| 27 | zella_config_migration | b11f5a76296e4e068737636f95102d1a |

Before: production matched staging (745 functions; comments and spacing ignored). After: all 764 public functions are
identical to a fresh isolated copy built from the same files (`tests/lib/build_full.sh` + the 7). 27 migrations are
recorded today.

Checks after (read only):
- 0 channel reviews opened (no automation used an AI-call channel), and 0 review notices.
- The overlap guard, knowledge check and channel-review triggers are present.
- 2 pending reminders are unchanged (texts; sending is off).
- 0 config-migration snapshots: the per-business migration has not been run.

Security advisor, new items: `config_migration_snapshots` has row security but no policy (server-only by design), and
`zella_appointment_holds_time` has a mutable search_path (immutable; reads no table). The two hygiene items from the
first apply are gone.

Behaviour that changed from the next call (the server reads it live):
- the booking gap and overlap guard;
- handover reasons for the two businesses that saved them;
- knowledge going live on save;
- order lookup limits (no store is connected).

Assistant wording reaches Vapi only by a manual update (K3).

Still needs approval: deploying voice-rules and owner-provision-business, publishing the web build (after #25; done),
and the per-business config migration (preview first).

## Third apply (5 Nov, late): manifest #8–#11

Applied in order, each with the md5 guard (the text runs only if its md5 matches the file):

| # | File | md5 |
| --- | --- | --- |
| 8 | zella_report_schedules | 572c1c714e7466aa56250451e9b4a985 |
| 9 | zella_knowledge_learning | 550799e2654656b4aea255b2cf6c5c90 |
| 10 | zella_assistant_delivery | f91528483f428bff637d670f81046f7c |
| 11 | zella_plan_languages | 2d254aeed7c30fe4270f1fffbeac920e |

- **Before:** the 6 functions these files replace were compared with the copy the rollbacks were built from. All 6
  matched, so the rollbacks restore production exactly.
- **After:** production has 773 functions, with normalised hash 9379369bd7b3136821e22e475917f5f4. That is identical to
  a staging build of the baseline plus all 11 files.
- **Data:** 0 report schedules, 0 assistant deliveries, and all four migrations are recorded.
- **Effect today:**
  - No daily report is sent, because no business has chosen a time.
  - Viewers can no longer answer or dismiss callers' questions.
  - Per-call delivery is unused until a Vapi number is switched; 0 numbers are registered (PR1).
  - Plan languages have no effect, because there are 0 plans.
- **Not done:** voice-rules and owner-provision-business are not deployed, and the web build is not published.
- **Rollback**, newest first: sql/rollback/zella_plan_languages_rollback.sql, zella_assistant_delivery_rollback.sql,
  zella_knowledge_learning_rollback.sql, zella_report_schedules_rollback.sql.

## Fourth apply and first deploy (6 Nov)

| What | Check | Result |
| --- | --- | --- |
| zella_holiday_availability (H1) | md5 b57ceb2404cb6f0f0b4ebebb72d03540; the patched function matched production before | applied |
| zella_delivery_evidence (E2/E3) | md5 8f639a9aab746aab35739b938155b562; both functions matched production before | applied |
| Production vs staging after | 773 functions, normalised hash bb0998beb057e687d4422b63d68ed149 | identical to the baseline plus all 13 files |
| voice-rules | deployed from main (c4cc392): index.ts, logic.ts, orders.ts, deno.json and the shared vapi-brain-tools / vapi-call-events modules; verify_jwt off as before (its own HMAC check is the gate) | version 4 → **5**, active |
| voice-rules smoke test | an unsigned request from the database (pg_net) | **401 Unauthorized**: the function boots and the signature check runs |
| owner-provision-business | deployed by the owner with the Supabase CLI (`--use-api`, from main at 25a88b6; verify_jwt off as before) | version 13 → **14**, active; a request with no sign-in gets 401 "Please sign in first" |

What changes for callers now:
- **Nothing for any existing number.** No Vapi number was changed, and production has 0 numbers registered in Zella.
- voice-rules answers `assistant-request` only for numbers switched to per-call delivery.
- Tool calls now include order lookup v2, which needs a connected store; 0 stores are connected.

**To undo voice-rules:** redeploy version 4's files, or the commit before c4cc392's voice-rules changes (98f120a^).
**To undo the database files:** run sql/rollback/zella_delivery_evidence_rollback.sql, then
zella_holiday_availability_rollback.sql.
