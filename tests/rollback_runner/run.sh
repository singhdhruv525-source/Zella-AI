#!/usr/bin/env bash
# sql/rollback/run.sh: a rollback that fails part-way stops with a non-zero exit and changes nothing, even when the
# caller's ~/.psqlrc turns ON_ERROR_STOP off and ON_ERROR_ROLLBACK on; a clean one applies. Isolated Postgres only; never production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
H=${ZPG_HOST:-/var/lib/postgresql/zella-sec}; PT=${ZPG_PORT:-55433}; DB=zrollback_runner
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$H" "$PT" "$DB" || exit 1   # before anything is dropped
P=(psql -h "$H" -p "$PT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB" > /dev/null || { echo "FAIL setup"; exit 1; }
"${P[@]}" -d $DB -c "create table t (n int); insert into t values (1);" > /dev/null
T=$(mktemp -d); trap 'rm -rf "$T"; "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null' EXIT
printf 'begin;\nupdate t set n = 2;\nselect 1/0;\nupdate t set n = 3;\ncommit;\n' > "$T/bad_rollback.sql"
printf 'begin;\nupdate t set n = 5;\ncommit;\n' > "$T/good_rollback.sql"
printf '\\set ON_ERROR_STOP off\n\\set ON_ERROR_ROLLBACK on\n' > "$T/psqlrc"
fails=0; pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; fails=$((fails + 1)); }
n() { "${P[@]}" -d $DB -c "select n from t"; }

# why the wrapper exists: a bare psql -f (or one that reads such a psqlrc) skips the failed statement and commits
# (the only psql here that reads a startup file: PSQLRC points it at the hostile file and PGSYSCONFDIR at an empty
# directory, so no system-wide psqlrc can change what it does; every other call uses -X and reads none)
mkdir -p "$T/sysconf"
PGSYSCONFDIR="$T/sysconf" PSQLRC="$T/psqlrc" psql -h "$H" -p "$PT" -U postgres -q -d $DB -f "$T/bad_rollback.sql" > /dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 3 ] && pass "bare psql -f: exit 0 and a partial rollback committed (what the wrapper prevents)" \
  || echo "note: bare psql behaved differently here (exit $rc, n=$(n)); the wrapper checks below still apply"
"${P[@]}" -d $DB -c "update t set n = 1" > /dev/null

PSQLRC="$T/psqlrc" "$REPO/sql/rollback/run.sh" "$T/bad_rollback.sql" -h "$H" -p "$PT" -U postgres -q -d $DB > /dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && pass "wrapper: a failing rollback exits non-zero ($rc)" || fail "wrapper exited 0 on a failing rollback"
[ "$(n)" = 1 ] && pass "wrapper: nothing changed (all or nothing), despite ON_ERROR_STOP off and ON_ERROR_ROLLBACK on in psqlrc" || fail "wrapper left n=$(n)"

PSQLRC="$T/psqlrc" "$REPO/sql/rollback/run.sh" "$T/good_rollback.sql" -h "$H" -p "$PT" -U postgres -q -d $DB > /dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 5 ] && pass "wrapper: a clean rollback applies and exits 0" || fail "clean rollback: exit $rc, n=$(n)"

# nothing on the command line can switch the error settings off: anything but a connection option is refused, unrun
for bad in "-v ON_ERROR_STOP=0" "--set=ON_ERROR_STOP=0" "-v ON_ERROR_ROLLBACK=on" "-c select_1" "-f $T/good_rollback.sql" "-1"; do
  # shellcheck disable=SC2086
  "$REPO/sql/rollback/run.sh" "$T/bad_rollback.sql" -h "$H" -p "$PT" -U postgres -d $DB $bad > /dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && [ "$(n)" = 5 ] && pass "wrapper: refuses '$bad' without running anything" || fail "wrapper with '$bad': exit $rc, n=$(n)"
done
"$REPO/sql/rollback/run.sh" "$T/good_rollback.sql" --host="$H" --port="$PT" --username=postgres --dbname=$DB -q > /dev/null 2>&1 \
  && pass "wrapper: long connection options work" || fail "long connection options refused"
"$REPO/sql/rollback/run.sh" > /dev/null 2>&1; [ $? = 2 ] && pass "wrapper: usage error without a file" || fail "no usage error"
"$REPO/sql/rollback/run.sh" "$T/missing.sql" > /dev/null 2>&1; [ $? = 2 ] && pass "wrapper: refuses a missing file" || fail "missing file accepted"

# no rollback file carries psql meta-commands (the SQL Editor rejects them)
if grep -lE '^\\' "$REPO"/sql/rollback/*.sql > "$T/meta"; then fail "psql commands in: $(tr '\n' ' ' < "$T/meta")"; else pass "no rollback file contains a psql command"; fi
# every rollback file runs as one transaction (industry_data_part.sql is a part included in another file, not a rollback)
missing=""; for f in "$REPO"/sql/rollback/*_rollback.sql; do
  grep -qiE '^\s*begin\s*;' "$f" && grep -qiE '^\s*commit\s*;\s*$' "$f" || missing="$missing $(basename "$f")"; done
[ -z "$missing" ] && pass "every rollback file is one transaction (begin ... commit)" || fail "no transaction in:$missing"
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
