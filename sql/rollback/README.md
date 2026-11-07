# Rollback files

Each `<name>_rollback.sql` undoes `sql/<name>.sql`. Roll back in **reverse** order of applying (newest first; see
`docs/DEPLOYMENT_MANIFEST_2026-11-05.md`). Every rollback needs the owner's approval before it is run on production.

Two exceptions to the naming rule:

- `industry_2026_11_04_rollback.sql` undoes the **whole group of 17** migrations that `tests/staging/run.sh` applies,
  together. It is generated from a before/after comparison of that group, so it removes everything those 17 added,
  not only the original ten industry migrations of 4 Nov 2026:
  1. `zella_viewer_read_only`
  2. `zella_staff_add_lead`
  3. `zella_call_content_privacy`
  4. `zella_capabilities`
  5. `zella_record_links_secrets`
  6. `zella_money`
  7. `zella_presets_v2`
  8. `zella_automation_presets_v2`
  9. `zella_receptionist_industry_rules`
  10. `zella_readiness`
  11. `zella_appointment_records` (appointment-record links)
  12. `zella_record_files`
  13. `zella_ai_caller_fixes`
  14. `zella_message_courtesy`
  15. `zella_google_leads`
  16. `zella_calendar_providers`
  17. `zella_store_orders`

  There is no rollback for one of them alone: running it rolls back all 17 (see `docs/DEPLOYMENT_REVIEW_2026-11-05.md`,
  section 5, "Rollback and recovery"). Everything applied after them must be rolled back first, newest first. It
  refuses to run without the pre-deploy backups.
- `industry_data_part.sql` is not a rollback to run: it is the hand-written part included at the top of
  `industry_2026_11_04_rollback.sql` (`tests/staging/make_rollback.py` builds that file from it).

Each rollback file is one transaction: an explicit `begin; … commit;` around everything it does, so it either all
happens or none of it does (`tests/rollback_runner/run.sh` checks every file has one).

**Before running one, read its header comment.** Some need a step first, for example:

- `zella_config_migration_rollback.sql`: if a business's settings were migrated (`zella_config_migration_apply`),
  restore that business from its snapshot with `zella_config_migration_restore` first. The rollback removes the
  restore function (the snapshots are kept, renamed `config_migration_snapshots_rolled_back`).
  **A restore overwrites that business's current language and call-routing settings and its knowledge content with
  the snapshot.** Anything the business changed after the migration is lost. So before restoring:
  1. Compare the business's current settings with its snapshot (`config_migration_snapshots`).
  2. Note any later edits.
  3. Restore only if those edits can be lost or re-entered, then re-apply them after the restore.
  4. Leave a business whose later changes must be kept unrestored, and agree the next step with its owner.
- `zella_batch3_pagination_rollback.sql`: roll the web app back first (the Batch 3 screens call these functions).
- `industry_2026_11_04_rollback.sql`: needs the pre-deploy backups (see above).

Run a rollback in one of two ways:

- **Supabase SQL Editor:** paste the whole file and run it. If any statement fails, the editor reports the error and
  nothing is changed.
- **psql:** use the wrapper, not a bare `psql -f`:

  ```bash
  sql/rollback/run.sh sql/rollback/<name>_rollback.sql -h <host> -p <port> -U <user> -d <database>
  ```

  It runs psql with `-X -v ON_ERROR_STOP=1 -v ON_ERROR_ROLLBACK=off` (`-X` so a `~/.psqlrc` can't turn those off) and
  accepts only connection options after the file (`-h`, `-p`, `-U`, `-d`, `-q` and their long forms), so the first
  error stops it with a non-zero exit
  and nothing is half-applied. The files carry no psql settings themselves (the SQL Editor rejects psql commands
  such as `\set`), so a bare `psql -f` can exit 0 after an error.
