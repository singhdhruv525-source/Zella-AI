#!/usr/bin/env bash
# sql/zella_order_lookup_v2.sql on an ISOLATED copy of the production state (tests/lib/build_full.sh), twice, then the
# tests and the rollback. WITHOUT_FIX=1 runs the tests without it.   Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zorders2
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
"$REPO/tests/lib/build_full.sh" $DB || exit 1
FNS="select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p where p.proname in ('zella_brain_tool_defs', 'zella_order_lookup_report', 'zella_store_lookup_context', 'zella_store_lookup_log')"
before=$($P -d $DB -c "$FNS")
if [ "${WITHOUT_FIX:-}" != 1 ]; then for i in 1 2; do out=$($P -d $DB -f "$REPO/sql/zella_order_lookup_v2.sql" 2>&1) || { echo "FAIL fix: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done; fi
out=$($P -d $DB -f "$HERE/v2_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
$P -d $DB -f "$REPO/sql/rollback/zella_order_lookup_v2_rollback.sql" > /dev/null 2>&1 || { echo "FAIL rollback did not run"; exit 1; }
[ "$($P -d $DB -c "$FNS")" = "$before" ] || { echo "FAIL the rollback does not restore the functions exactly"; exit 1; }
$P -d $DB -f "$REPO/sql/zella_order_lookup_v2.sql" > /dev/null 2>&1 || { echo "FAIL re-applying after the rollback"; exit 1; }
echo "PASS rollback restores the four functions exactly (the new overloads go); the fix applies again after it"
echo "ALL PASSED"
