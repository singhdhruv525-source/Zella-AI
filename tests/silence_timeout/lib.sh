#!/usr/bin/env bash
# The isolated copy for sql/zella_silence_timeout.sql (never production). Template zsil_main: zcar_main (the copy of
# production's schema that tests/cartesia_voices/lib.sh builds) with sql/zella_cartesia_voices.sql applied, which gives
# production's zella_assistant_config (md5 e2ae7cfc..., 25 Nov 2026). zsil_main is rebuilt whenever zcar_main or the
# Cartesia file changes. Databases are named zsil_*. Test people only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
SOURCE=zcar_main; TEMPLATE=zsil_main
. "$REPO/tests/lib/isolated_guard.sh"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; skips=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }; skip() { echo "SKIP $*"; skips=$((skips + 1)); }
ensure_template() {
  zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$TEMPLATE" || exit 1
  local src want
  src=$("${P[@]}" -d postgres -c "select coalesce(shobj_description(oid, 'pg_database'), 'none') from pg_database where datname = '$SOURCE'")
  # no copy of production's schema yet: tests/cartesia_voices/run.sh builds it
  [ -n "$src" ] || { echo "$SOURCE is missing: run tests/cartesia_voices/run.sh once to build it"; exit 1; }
  want=$({ echo "$src"; cat "$REPO/sql/zella_cartesia_voices.sql"; } | md5sum | cut -c1-32)
  if [ "$("${P[@]}" -d postgres -c "select shobj_description(oid, 'pg_database') from pg_database where datname = '$TEMPLATE'")" = "$want" ]; then return 0; fi
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $TEMPLATE" -c "drop database if exists ${TEMPLATE}_build" -c "create database ${TEMPLATE}_build template $SOURCE" > /dev/null || exit 1
  "${P[@]}" -d "${TEMPLATE}_build" -f "$REPO/sql/zella_cartesia_voices.sql" > /dev/null 2>&1 || { echo "template build failed at zella_cartesia_voices"; exit 1; }
  "${P[@]}" -d postgres -c "alter database ${TEMPLATE}_build rename to $TEMPLATE" -c "comment on database $TEMPLATE is '$want'" > /dev/null || exit 1
}
fresh_db() {   # fresh_db <name>: sets DB=zsil_<name> and creates it from the template
  DB="zsil_$1"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; ensure_template
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
  DBS="${DBS:-} $DB"
}
q() { "${P[@]}" -d "$DB" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -f "$1" 2>&1; }
finish() {
  if [ -z "${KEEP:-}" ]; then for d in ${DBS:-}; do "${P[@]}" -d postgres -c "drop database if exists $d" > /dev/null; done; fi
  echo; [ $skips -eq 0 ] || echo "$skips skipped"
  [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
}
