#!/usr/bin/env bash
# Shared by the security fix suites: each one makes its own isolated copy of the production schema (never production)
# named zsec_fix_<suite>, from template zprod3. Test people only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; BASE=${BASE:-zprod3}
# production today = the schema copy zprod3 plus sql/zella_writing_cleanup.sql (applied in production on 18 Nov 2026)
TEMPLATE=zsec_fix_template
. "$REPO/tests/lib/isolated_guard.sh"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
ensure_template() {
  zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$TEMPLATE" || exit 1
  [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = '$TEMPLATE'")" = 1 ] && return 0
  "${P[@]}" -d postgres -c "create database ${TEMPLATE}_build template $BASE" > /dev/null || exit 1
  "${P[@]}" -d "${TEMPLATE}_build" -f "$REPO/sql/zella_writing_cleanup.sql" > /dev/null 2>&1 || { echo "template build failed"; exit 1; }
  "${P[@]}" -d postgres -c "alter database ${TEMPLATE}_build rename to $TEMPLATE" > /dev/null || exit 1
}
fresh_db() {   # fresh_db <name>: sets DB=zsec_fix_<name> and creates it from the template
  DB="zsec_fix_$1"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; ensure_template
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
}
q() { "${P[@]}" -d "$DB" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -f "$1" 2>&1; }
# as_user <uuid> <aal> <sql>: runs <sql> as the signed in role with that person's claims, prints NOTICE R=<value>
as_user() {
  q "do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')::text, true);
    set local role authenticated; begin $3 exception when others then raise notice 'R=ERR:%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1
}
finish() { [ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null; echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }; }
