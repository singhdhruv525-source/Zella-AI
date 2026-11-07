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

  **It loses data that was added or changed since those migrations.**
  - **Appointment links.** It drops `appointments.record_id` and `appointments.record_suggested_id`, so every link
    between an appointment and a record is lost.
  - **Record types.** It puts every record type back to its pre-deploy copy (`backup_20261104_types`): names, icons,
    labels, statuses and fields edited since are overwritten, and types added since are deleted.
  - **Starter automations.** It deletes every automation named like one of the 15 starter automations that has never
    run (no `industry_automation_runs` row), even one a business installed and then customised.

  Save all three **inside the rollback's own transaction**, so nothing can change between the copy and the rollback.
  1. Make a copy of `industry_2026_11_04_rollback.sql`.
  2. In the copy, paste these lines right after its first `begin;`:

     ```sql
     -- give up after 5 seconds instead of queueing behind (and in front of) other work; the whole run is undone
     set local lock_timeout = '5s';
     -- block writes to these tables until the rollback commits, so the copies are complete
     lock table public.appointments, public.crm_record_types, public.automations, public.industry_automation_runs
       in share row exclusive mode;
     -- a private schema: not exposed through the API, no client role can read it
     create schema if not exists rollback_keep;
     revoke all on schema rollback_keep from public, anon, authenticated;
     create table rollback_keep.appointment_links as select id, business_id, record_id, record_suggested_id
       from public.appointments where record_id is not null or record_suggested_id is not null;
     create table rollback_keep.record_types as select * from public.crm_record_types;
     -- every automation that has never run: a superset of what step 6 deletes, whatever the preset table holds now
     create table rollback_keep.automations as select a.* from public.automations a
      where not exists (select 1 from public.industry_automation_runs r where r.automation_id = a.id);
     revoke all on all tables in schema rollback_keep from public, anon, authenticated;
     ```

  3. Run the copy as usual, **in a maintenance window**. The locks are held until the whole rollback commits, so
     bookings, record-type edits and automation changes for every business wait until then. If a lock can't be
     taken within 5 seconds, or anything else fails, none of it happens, the copies included; run it again.

  Compare the saved copies (`rollback_keep.appointment_links`, `rollback_keep.record_types`,
  `rollback_keep.automations`) with the result
  afterwards, and re-enter what still applies once the group is re-deployed. Drop the `rollback_keep` schema when you
  no longer need it.
- `industry_data_part.sql` is not a rollback to run: it is the hand-written part included at the top of
  `industry_2026_11_04_rollback.sql` (`tests/staging/make_rollback.py` builds that file from it).

Each rollback file is one transaction: an explicit `begin; … commit;` around everything it does, so it either all
happens or none of it does (`tests/rollback_runner/run.sh` checks every file has one).

**Before running one, read its header comment.** Some need a step first, for example:

- `zella_config_migration_rollback.sql`: if a business's settings were migrated (`zella_config_migration_apply`),
  restore that business from its snapshot with `zella_config_migration_restore` first. The rollback removes the
  restore function (the snapshots are kept, renamed `config_migration_snapshots_rolled_back`).
  **Restore the right snapshot.** Every call to `zella_config_migration_apply` takes a new snapshot, even one that
  changes nothing. A later snapshot already contains the migrated settings, so restoring it puts the migration back.
  **First, stop new applies until the rollback commits.** Otherwise an apply that runs after your restore migrates
  the settings again, and the rollback then removes the restore function. Only `service_role` may call it:

  ```sql
  revoke execute on function public.zella_config_migration_apply(uuid) from service_role;
  ```

  Wait for any apply already running to finish (`select pid, query from pg_stat_activity where query ilike
  '%zella_config_migration_apply%' and pid <> pg_backend_pid();` returns nothing). Leave it revoked: the rollback
  drops the function. If you decide not to roll back after all, give it back with
  `grant execute on function public.zella_config_migration_apply(uuid) to service_role;`.

  List **all** of the business's snapshots, restored ones too, oldest first:

  ```sql
  select id, taken_at, restored_at, applied, count(*) over (partition by taken_at) as same_time
    from public.config_migration_snapshots
   where business_id = '<business id>' order by taken_at;
  ```

  - **`same_time` is more than 1 on the first row:** stop. Two applies ran in one transaction and got the same
    `taken_at`, so the order shown is not the order they were taken in. Don't restore either until you know which
    one holds the pre-migration settings (compare their `languages`, `escalation_rules` and `setup_knowledge`).

  - **The first one has `restored_at` empty:** restore that one. It holds the settings from before the first apply.
  - **The first one was already restored:** don't restore a later one by default. Check the business's current
    settings first. They may already be the original ones, and a later snapshot would put the migrated settings back.

  **A restore overwrites that business's current language and call-routing settings and its knowledge content with
  that snapshot.** Anything the business changed after the migration is lost. Do the comparison and the restore
  in **one transaction**, with the three tables the restore writes locked, so the business can't change its
  settings in between (this pauses those settings for every business, so keep the transaction short):

  ```sql
  begin;
  set local lock_timeout = '5s';
  lock table public.business_languages, public.ai_agent_configs, public.knowledge_items in share row exclusive mode;
  -- compare and note later edits here, then:
  select public.zella_config_migration_restore('<snapshot id>');
  -- re-apply the edits you noted, then:
  commit;   -- or rollback; to change nothing
  ```

  Inside it:
  1. Compare the business's current settings with the snapshot you chose.
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
