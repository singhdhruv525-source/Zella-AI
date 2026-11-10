#!/usr/bin/env bash
# Batch 1 database checks on an ISOLATED copy of the production state: tests/lib/build_full.sh (production as of 5 Nov),
# plus every file applied since (the pending list of tests/deploy/run_all.sh, all live as of 6 Nov), then
# sql/zella_batch1_security.sql twice, then tests/security/batch1/test.sql; then the rollback and the test's
# holds_time section must fail against the rolled-back function. Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zbatch1}
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
eval "$(grep -A3 '^PENDING=' "$REPO/tests/deploy/run_all.sh" | sed '/^ROLLBACK=/,$d')"
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}"; do out=$($P -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
fails=0
for i in 1 2; do out=$($P -d "$DB" -f "$REPO/sql/zella_batch1_security.sql" 2>&1) || { echo "FAIL batch1 migration run $i: $out"; fails=1; }; done
echo "PASS sql/zella_batch1_security.sql applies twice"
out=$($P -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'
[ $code -ne 0 ] && { echo "FAIL batch1_test: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); }
# rollback restores the old definition exactly
out=$($P -d "$DB" -f "$REPO/sql/rollback/zella_batch1_security_rollback.sql" 2>&1) || { echo "FAIL rollback: $out"; fails=$((fails + 1)); }
got=$($P -d "$DB" -c "select provolatile::text || coalesce(proconfig::text, '-') from pg_proc where oid = 'public.zella_appointment_holds_time(text,text,timestamptz)'::regprocedure")
[ "$got" = "i-" ] && echo "PASS rollback restores IMMUTABLE with no fixed search path" || { echo "FAIL rollback left: $got"; fails=$((fails + 1)); }
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
