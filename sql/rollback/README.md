# Rollback files

Each `<name>_rollback.sql` undoes `sql/<name>.sql`. Roll back in **reverse** order of applying (newest first; see
`docs/DEPLOYMENT_MANIFEST_2026-11-05.md`). Every rollback needs the owner's approval before it is run on production.

Each file is one transaction (`begin; … commit;`): it either all happens or none of it does.

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
