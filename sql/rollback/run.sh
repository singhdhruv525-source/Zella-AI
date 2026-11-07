#!/usr/bin/env bash
# Runs one rollback file with psql so that it stops at the first error and exits non-zero, all or nothing.
# The rollback files carry no psql settings of their own (so they also paste into the Supabase SQL Editor), so run them
# through this rather than a bare `psql -f`, which can exit 0 after an error.
#   -X                    ignore ~/.psqlrc (an ON_ERROR_ROLLBACK there would let psql carry on past a failed statement)
#   ON_ERROR_STOP=1       stop at the first error, exit non-zero
#   ON_ERROR_ROLLBACK=off never skip a failed statement inside the file's transaction
# Usage: sql/rollback/run.sh <rollback file> [psql connection options, e.g. -h HOST -p PORT -U USER -d DB]
# Connection details can also come from the usual PGHOST, PGPORT, PGUSER, PGDATABASE (and a password file).
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <rollback file> [psql connection options...]" >&2; exit 2; }
file=$1; shift
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }
exec psql -X -v ON_ERROR_STOP=1 -v ON_ERROR_ROLLBACK=off "$@" -f "$file"
