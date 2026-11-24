#!/usr/bin/env bash
# The isolated copy for sql/zella_admin_languages.sql (never production). Template zal_main: zcar_main (the copy of
# production's schema that tests/cartesia_voices/lib.sh builds) with sql/zella_cartesia_voices.sql applied, which this
# file needs first. zal_main is rebuilt whenever zcar_main or the Cartesia file changes. Databases are named zal_*.
# Test people only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
SOURCE=zcar_main; TEMPLATE=zal_main
. "$REPO/tests/lib/isolated_guard.sh"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
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
fresh_db() {   # fresh_db <name>: sets DB=zal_<name> and creates it from the template
  DB="zal_$1"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; ensure_template
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
}
q() { "${P[@]}" -d "$DB" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -f "$1" 2>&1; }
# as_user <uuid> <sql>: runs <sql> as that signed in person, prints NOTICE R=<value> (or R=ERR:<message>)
as_user() {
  q "do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', 'aal2')::text, true);
    set local role authenticated; begin $2 exception when others then raise notice 'R=ERR:%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1
}
finish() { [ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null; echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }; }
