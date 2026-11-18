#!/usr/bin/env bash
# Shared by the security fix suites: each one makes its own isolated copy of the production schema (never production)
# named zsec_fix_<suite>, from template zprod3. Test people only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
fresh_db() {   # fresh_db <name>: sets DB=zsec_fix_<name> and creates it from the template
  DB="zsec_fix_$1"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
}
q() { "${P[@]}" -d "$DB" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -f "$1" 2>&1; }
# as_user <uuid> <aal> <sql>: runs <sql> as the signed in role with that person's claims, prints NOTICE R=<value>
as_user() {
  q "do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')::text, true);
    set local role authenticated; begin $3 exception when others then raise notice 'R=ERR:%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1
}
finish() { "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null; echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }; }
