# CodeRabbit findings from singhdhruv525-source/Zella-AI#44 (schema baseline and rollbacks)

Fix list, in the order CodeRabbit posted them. CodeRabbit fixes them on this branch; each fix is checked and re-reviewed before merge.

- [ ] `sql/baseline/01_tables.sql:413` — Generate `inbound_email_token` with a cryptographic random source.
- [ ] `sql/baseline/10_table_grants.sql:629` — Restrict direct access to call content.
- [ ] `sql/baseline/restore.sh:28` — Skip `MAINTAIN` grants only below PostgreSQL 17.
- [ ] `sql/rollback/industry_data_part.sql:38` — Add a tenant check and a type-conflict guard to the private-value copy-back.
- [ ] `sql/rollback/industry_data_part.sql:42` — Restore all backed-up presets, including rows that were deleted.
- [ ] `sql/rollback/industry_data_part.sql:51` — Restore record types that were deleted since the backup.
- [ ] `sql/rollback/industry_data_part.sql:69` — Fix the automation delete: it matches on name only and ignores tenant scope.
- [ ] `sql/rollback/industry_data_part.sql:98` — Restrict access to the calendar archive.
- [ ] `sql/rollback/run.sh:15` — Reject files that are not complete rollback scripts.
- [ ] `sql/rollback/zella_channel_review_rollback.sql:21` — A silent no-op `replace()` leaves `zella_replace_reminders` calling a function that this script drops.
- [ ] `sql/rollback/zella_escalation_rules_rollback.sql:53` — Do not drop `calls.transfer_approved_at`. Keep the data.
- [ ] `sql/rollback/zella_message_settings_fix_rollback.sql:10` — Two `replace()` calls can fail silently and leave the patch partly in place.
- [ ] `sql/rollback/zella_order_lookup_v2_rollback.sql:7` — Do not drop `ai_tool_calls.lookup_ref`. The rollback deletes customer data.
- [ ] `sql/rollback/zella_platform_roles_fix_rollback.sql:9` — Add a pre-check for admin rows whose role the restored trigger rejects.
- [ ] `sql/rollback/zella_relationships_rollback.sql:14` — Verify the second text replacement before executing the edited definition.
- [ ] `sql/rollback/zella_report_schedules_rollback.sql:56` — Make the table archive step safe to repeat and consistent with the other rollbacks.
- [ ] `sql/rollback/zella_scheduling_rollback.sql:5` — Kept resource-only blocks become business-wide closures after this rollback.
- [ ] `sql/rollback/zella_setup_enforcement_rollback.sql:33` — Partial `replace()` failure can leave `public.zella_ai_booking` with undeclared variables.
- [ ] `sql/rollback/zella_tables_rollback.sql:109` — Archive per-business data before you delete it.
- [ ] `sql/rollback/zella_tables_rollback.sql:139` — Set aside the renamed tables the same way the scheduling rollback does.
