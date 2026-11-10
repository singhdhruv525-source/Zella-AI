#!/usr/bin/env bash
# sql/zella_report_schedules.sql on an ISOLATED copy of the production state. WITHOUT_FIX=1 runs without it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zreports
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
APPLIED=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration)
FIX=("$REPO/sql/zella_report_schedules.sql" "$REPO/sql/zella_report_schedules.sql"); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
"$REPO/tests/lib/build_full.sh" $DB $(for m in "${APPLIED[@]}"; do echo "$REPO/sql/$m.sql"; done) "${FIX[@]}" || exit 1
out=$($P -d $DB -f "$HERE/report_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
[ "${WITHOUT_FIX:-}" = 1 ] && { echo "ALL PASSED"; exit 0; }
# rollback: functions back to exactly the state without the file, then the file applies again
H="select md5(string_agg(oid::regprocedure::text||':'||md5(regexp_replace(regexp_replace(pg_get_functiondef(oid),'--[^\n]*','','g'),'\s+','','g')), ',' order by oid::regprocedure::text collate \"C\")) from pg_proc where pronamespace='public'::regnamespace and prokind='f'"
"$REPO/tests/lib/build_full.sh" ${DB}_base $(for m in "${APPLIED[@]}"; do echo "$REPO/sql/$m.sql"; done) >/dev/null || exit 1
$P -d $DB -f "$REPO/sql/rollback/zella_report_schedules_rollback.sql" >/dev/null || { echo "FAIL rollback did not run"; exit 1; }
a=$($P -d $DB -c "$H"); b=$($P -d ${DB}_base -c "$H")
[ "$a" = "$b" ] && echo "PASS rollback: every function matches the state without the file" || { echo "FAIL rollback: functions differ"; exit 1; }
$P -d $DB -f "$REPO/sql/zella_report_schedules.sql" >/dev/null && echo "PASS re-apply after rollback" || { echo "FAIL re-apply"; exit 1; }
echo "ALL PASSED"
