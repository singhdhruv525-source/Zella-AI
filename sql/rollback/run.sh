#!/usr/bin/env bash
# Runs one rollback file with psql so that it stops at the first error and exits non-zero, all or nothing.
# The rollback files carry no psql settings of their own (so they also paste into the Supabase SQL Editor), so run them
# through this rather than a bare `psql -f`, which can exit 0 after an error.
#   -X                    ignore ~/.psqlrc (it could turn ON_ERROR_STOP off or ON_ERROR_ROLLBACK on)
#   ON_ERROR_STOP=1       stop at the first error, exit non-zero
#   ON_ERROR_ROLLBACK=off never skip a failed statement inside the file's transaction
# Only connection options are accepted after the file, so nothing on the command line can switch those off.
# Usage: sql/rollback/run.sh <rollback file> [-h HOST] [-p PORT] [-U USER] [-d DATABASE] [-q]
#        (also --host=, --port=, --username=, --dbname=). PGHOST, PGPORT, PGUSER, PGDATABASE and a password file work too.
set -euo pipefail
usage() { echo "usage: $0 <rollback file> [-h HOST] [-p PORT] [-U USER] [-d DATABASE] [-q]" >&2; exit 2; }
[ $# -ge 1 ] || usage
file=$1; shift
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }
conn=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|-p|-U|-d) [ $# -ge 2 ] || usage; conn+=("$1" "$2"); shift 2 ;;
    --host=*|--port=*|--username=*|--dbname=*|-q) conn+=("$1"); shift ;;
    *) echo "refused: '$1' (only connection options are accepted; the error settings can't be changed)" >&2; exit 2 ;;
  esac
done
exec psql "${conn[@]}" -X -v ON_ERROR_STOP=1 -v ON_ERROR_ROLLBACK=off -f "$file"
