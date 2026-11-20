#!/usr/bin/env bash
# Shared by the security fix suites: each one makes its own isolated copy of the production schema (never production)
# named zsec_fix_<suite>, from template zprod3. Test people only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; BASE=${BASE:-zprod3}
# main's state: zprod3 + sql/zella_writing_cleanup.sql + the production fixtures the schema regeneration loads, then
# every migration docs/SCHEMA_STATUS.md lists as built, not applied, in order, except this branch's own files
TEMPLATE=zsec_fix_main
MINE="zella_create_business_revoke zella_admin_pause_sticky zella_caller_verification zella_oauth_states zella_website_fetch_guard zella_invitation_limits zella_call_limits"
. "$REPO/tests/lib/isolated_guard.sh"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
ensure_template() {
  zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$TEMPLATE" || exit 1
  [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = '$TEMPLATE'")" = 1 ] && return 0
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists ${TEMPLATE}_build" -c "create database ${TEMPLATE}_build template $BASE" > /dev/null || exit 1
  local m f
  for f in sql/zella_writing_cleanup.sql tests/industry_data/production_zella_sensitive_industry.sql tests/alert_rules_email/prod_claim_admin_alert_email.sql; do
    "${P[@]}" -d "${TEMPLATE}_build" -f "$REPO/$f" > /dev/null 2>&1 || { echo "template build failed at $f"; exit 1; }
  done
  for m in $(grep "built, not applied" "$REPO/docs/SCHEMA_STATUS.md" | sed -n 's/^| `\([^`]*\)\.sql`.*/\1/p'); do
    case " $MINE " in *" $m "*) continue;; esac
    "${P[@]}" -d "${TEMPLATE}_build" -f "$REPO/sql/$m.sql" > /dev/null 2>&1 || { echo "template build failed at $m"; exit 1; }
  done
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
