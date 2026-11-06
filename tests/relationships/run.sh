#!/usr/bin/env bash
# Release 1 relationship and consent checks on an ISOLATED copy of the production state: tests/lib/build_full.sh, every
# file applied since (the pending list of tests/deploy/run_all.sh, plus the Batch 1 and Batch 3 files), then
# sql/zella_relationships.sql twice, tests/relationships/test.sql, the rollback, and a second apply after it.
# Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zrel}
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
eval "$(grep -A3 '^PENDING=' "$REPO/tests/deploy/run_all.sh" | sed '/^ROLLBACK=/,$d')"
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ -f "$REPO/sql/$m.sql" ] || continue
  out=$($P -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
fails=0
for i in 1 2; do out=$($P -d "$DB" -f "$REPO/sql/zella_relationships.sql" 2>&1) || { echo "FAIL migration run $i: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }; done
[ $fails = 0 ] && echo "PASS sql/zella_relationships.sql applies twice"
out=$($P -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'
[ $code -ne 0 ] && { echo "FAIL test.sql: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); }
# no SECURITY DEFINER function without a fixed search path; nothing new for anon
bad=$($P -d "$DB" -c "select string_agg(p.proname, ',') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^zella_(people|relationship|consent|is_authorized)' and p.prosecdef and p.proconfig is null")
[ -z "$bad" ] && echo "PASS every new SECURITY DEFINER function has a fixed search path" || { echo "FAIL no search path: $bad"; fails=$((fails + 1)); }
anon=$($P -d "$DB" -c "select string_agg(p.proname, ',') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^zella_(people|relationship|consent|is_authorized)' and has_function_privilege('anon', p.oid, 'execute')")
[ -z "$anon" ] && echo "PASS the anonymous role can run none of the new functions" || { echo "FAIL anon can run: $anon"; fails=$((fails + 1)); }
# rollback keeps the data (renamed tables), removes the functions; a second apply works
$P -d "$DB" -c "insert into public.businesses (id, name, timezone) values ('c7000000-0000-0000-0000-0000000000f1', 'R1 Rollback', 'UTC');
  insert into public.customers (id, business_id, first_name) values ('c7000000-0000-0000-0000-0000000001f1', 'c7000000-0000-0000-0000-0000000000f1', 'A'), ('c7000000-0000-0000-0000-0000000001f2', 'c7000000-0000-0000-0000-0000000000f1', 'B');
  insert into public.customer_relationships (business_id, customer_id, related_customer_id, kind) values ('c7000000-0000-0000-0000-0000000000f1', 'c7000000-0000-0000-0000-0000000001f1', 'c7000000-0000-0000-0000-0000000001f2', 'household');" > /dev/null
before=$($P -d "$DB" -c "select count(*) from public.customer_relationships")
out=$($P -d "$DB" -f "$REPO/sql/rollback/zella_relationships_rollback.sql" 2>&1) || { echo "FAIL rollback: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
left=$($P -d "$DB" -c "select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname ~ '^zella_(people|relationship|consent|is_authorized)'")
kept=$($P -d "$DB" -c "select count(*) from public.customer_relationships_rolled_back")
[ "$left" = 0 ] && [ "$before" -ge 1 ] && [ "$kept" = "$before" ] && echo "PASS rollback removes the functions and keeps the $kept row(s) in customer_relationships_rolled_back" || { echo "FAIL rollback left $left functions, kept $kept of $before rows"; fails=$((fails + 1)); }
out=$($P -d "$DB" -f "$REPO/sql/zella_relationships.sql" 2>&1) || { echo "FAIL re-apply: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
idx=$($P -d "$DB" -c "select count(*) from pg_indexes where tablename = 'customer_relationships'")
out=$($P -d "$DB" -f "$HERE/test.sql" 2>&1) && [ "$idx" -ge 6 ] && echo "PASS re-apply after the rollback: fresh tables with their $idx indexes, all checks pass again" || { echo "FAIL after re-apply (indexes $idx): $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
