# Rollback files

Each `<name>_rollback.sql` undoes `sql/<name>.sql`. Roll back in **reverse** order of applying (newest first; see
`docs/DEPLOYMENT_MANIFEST_2026-11-05.md`). Every rollback needs the owner's approval before it is run on production.

Two exceptions to the naming rule:

- `industry_2026_11_04_rollback.sql` undoes **all ten** industry migrations of 4 Nov 2026 together. There is no
  rollback for one of them alone: running it rolls back the whole group (see `docs/DEPLOYMENT_REVIEW_2026-11-05.md`,
  section 5, "Rollback and recovery"). It refuses to run without the pre-deploy backups.
- `industry_data_part.sql` is not a rollback to run: it is the hand-written part included at the top of
  `industry_2026_11_04_rollback.sql` (`tests/staging/make_rollback.py` builds that file from it).

Each rollback file is one transaction (`begin; … commit;`): it either all happens or none of it does
(`tests/rollback_runner/run.sh` checks every file has one).

**Before running one, read its header comment.** Some need a step first, for example:

- `zella_config_migration_rollback.sql`: if a business's settings were migrated (`zella_config_migration_apply`),
  restore that business from its snapshot with `zella_config_migration_restore` first. The rollback removes the
  restore function (the snapshots are kept, renamed `config_migration_snapshots_rolled_back`).
- `zella_batch3_pagination_rollback.sql`: roll the web app back first (the Batch 3 screens call these functions).
- `industry_2026_11_04_rollback.sql`: needs the pre-deploy backups (see above).

Run a rollback in one of two ways:

- **Supabase SQL Editor:** paste the whole file and run it. If any statement fails, the editor reports the error and
  nothing is changed.
- **psql:** use the wrapper, not a bare `psql -f`:

  ```bash
  sql/rollback/run.sh sql/rollback/<name>_rollback.sql -h <host> -p <port> -U <user> -d <database>
  ```

  It runs psql with `-X -v ON_ERROR_STOP=1 -v ON_ERROR_ROLLBACK=off` (`-X` so a `~/.psqlrc` can't turn those off),
  so the first error stops it with a non-zero exit
  and nothing is half-applied. The files carry no psql settings themselves (the SQL Editor rejects psql commands
  such as `\set`), so a bare `psql -f` can exit 0 after an error.
