<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:775260410c885f89d78f1c831e3707abd4501afff7eb4b937adfb9038503dc0a -->

# CodeRabbit findings from singhdhruv525-source/Zella-AI#44 (schema baseline and rollbacks)

Fix list, in the order CodeRabbit posted them. CodeRabbit fixes them on this branch; each fix is checked and re-reviewed before merge.

Status audit (2026-11-10): verified against current code in the original order. Open boxes record existing implementations whose validation or re-review remains outstanding; none claims completion without both.

Status update (2026-11-11): every finding below has a recorded resolution. Checked again on an isolated database: `tests/rollback_security/run.sh` (all passed, including the starter-automation order for insurance businesses) and `tests/tables/restore_test.sh` (seating data restored row for row after rollback and re-apply). Boxes stay open until CodeRabbit's re-review of this PR is clean.

- [ ] `sql/baseline/01_tables.sql:413` — Generate `inbound_email_token` with a cryptographic random source.
  - Resolution: Implemented in `sql/zella_rollback_security.sql` with `gen_random_bytes(16)` and compatible address parsing; the baseline intentionally preserves the historical production snapshot. Security tests passed. Existing migration still awaits re-review.
- [ ] `sql/baseline/10_table_grants.sql:629` — Restrict direct access to call content.
  - Resolution: Already implemented by `sql/zella_call_content_privacy.sql`, applied after the historical baseline. Security tests passed. Existing privacy fix still awaits re-review.
- [ ] `sql/baseline/restore.sh:28` — Skip `MAINTAIN` grants only below PostgreSQL 17.
  - Resolution: Already implemented: `restore.sh` includes MAINTAIN grants for versions >= 170000. PostgreSQL 18 restore passed. PostgreSQL 16/17 boundary testing and re-review remain outstanding.
- [ ] `sql/rollback/industry_data_part.sql:38` — Add a tenant check and a type-conflict guard to the private-value copy-back.
  - Resolution: Already implemented: copy-back joins record and business IDs, requires object data, and preserves conflicting keys. Data-boundary tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/industry_data_part.sql:42` — Restore all backed-up presets, including rows that were deleted.
  - Resolution: Already implemented: missing presets are reinserted from backup. Data-boundary tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/industry_data_part.sql:51` — Restore record types that were deleted since the backup.
  - Resolution: Already implemented: explicit-column reinsertion restores deleted types, preserving replacement IDs on business/key collisions. Data-boundary tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/industry_data_part.sql:69` — Scope automation deletion to the tenant and identify preset-installed copies; preserve tenant-authored rules sharing a preset name.
  - Resolution: Updated here: require matching business and tenant industry, null creator, matching name/description/trigger, active status and unchanged installer actions/conditions; preserve previously run rules. Data-boundary tests passed. Re-review pending.
- [ ] `sql/rollback/industry_data_part.sql:98` — Restrict access to the calendar archive.
  - Resolution: Already implemented: calendar archive enables RLS and revokes PUBLIC/anon/authenticated access before inserting rows. Runtime archive validation and re-review remain outstanding.
- [ ] `sql/rollback/run.sh:15` — Reject files that are not complete rollback scripts.
  - Resolution: Already implemented: `run.sh` invokes `validate.py` to reject fragments and require a complete transaction. Runner tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/zella_channel_review_rollback.sql:21` — A silent no-op `replace()` leaves `zella_replace_reminders` calling a function that this script drops.
  - Resolution: Already implemented: each reverse replacement checks `previous_def` and raises on a no-op before execution. Affected-function rollback validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_escalation_rules_rollback.sql:53` — Do not drop `calls.transfer_approved_at`. Keep the data.
  - Resolution: Already implemented: rollback explicitly retains `calls.transfer_approved_at` and timestamps. Runtime preservation validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_message_settings_fix_rollback.sql:10` — Two `replace()` calls can fail silently and leave the patch partly in place.
  - Resolution: Already implemented: each replacement has a no-op guard before execution. Affected-function rollback validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_order_lookup_v2_rollback.sql:7` — Do not drop `ai_tool_calls.lookup_ref`. The rollback deletes customer data.
  - Resolution: Already implemented: `lookup_ref` is renamed in place, preserving older archive generations. Data-boundary repeat-rename tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/zella_platform_roles_fix_rollback.sql:9` — Add a pre-check for admin rows whose role the restored trigger rejects.
  - Resolution: Already implemented: pre-check counts unsupported admin roles and emits a NOTICE before restoring the trigger. This is advisory: updates to unsupported rows can still fail. Runtime validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_relationships_rollback.sql:14` — Verify the second text replacement before executing the edited definition.
  - Resolution: Already implemented: the final guard rejects definitions still containing the marker or `customer_relationships`, covering a failed second replacement. Affected-function rollback validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_report_schedules_rollback.sql:56` — Make the table archive step safe to repeat and consistent with the other rollbacks.
  - Resolution: Already implemented: archive loop skips absent tables, preserves prior generations and frees index names; RLS and client revokes protect archives. Repeat-archive tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/zella_scheduling_rollback.sql:5` — Kept resource-only blocks become business-wide closures after this rollback.
  - Resolution: Already implemented: resource-only blocks are archived privately and removed before resource fields are dropped; staff/business blocks remain. Repeat/data-boundary tests passed; existing fix awaits re-review.
- [ ] `sql/rollback/zella_setup_enforcement_rollback.sql:33` — Partial `replace()` failure can leave `public.zella_ai_booking` with undeclared variables.
  - Resolution: Already implemented: all reverse replacements check for a no-op before executing the edited definition; the generator retains these guards. Affected-function rollback validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_tables_rollback.sql:109` — Archive per-business data before each destructive operation: deleting `business_capabilities` rows, dropping appointment `table_ids` assignments, dropping waitlist `party_size`/`preferences`/`contact_ok` fields, and dropping `table_states`.
  - Resolution: Already implemented: private `table_data_rolled_back` archive precedes all four removals listed above. Archive-filter tests passed. Complete archive/removal runtime validation and re-review remain outstanding.
- [ ] `sql/rollback/zella_tables_rollback.sql:139` — Set aside the renamed tables the same way the scheduling rollback does.
  - Resolution: Already implemented: prior table generations and index names are set aside; renamed tables enable RLS and revoke PUBLIC/anon/authenticated access. Runtime repeat-rollback validation and re-review remain outstanding.


<!-- /coderabbit-ai-generated:v1 -->