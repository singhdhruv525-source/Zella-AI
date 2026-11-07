#!/usr/bin/env bash
# Release 1 relationship and consent checks on an ISOLATED copy of the production state: tests/lib/build_full.sh, every
# file applied since (the pending list of tests/deploy/run_all.sh, plus the Batch 1 and Batch 3 files), then
# sql/zella_relationships.sql twice, tests/relationships/test.sql, the rollback, and a second apply after it.
# Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zrel}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)   # an array: each value stays one argument
# the pending list of run_all.sh, read as words (file names only), never run as shell code
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
[ "${#PENDING[@]}" -ge 10 ] || { echo "FAIL could not read the pending list"; exit 1; }
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ -f "$REPO/sql/$m.sql" ] || continue
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
fails=0
# the guard itself, with psql stood in (no database is touched): refusals must come from the guard's own checks
if out=$(bash "$REPO/tests/lib/isolated_guard_test.sh" 2>&1); then echo "$out" | grep '^PASS'; else echo "FAIL guard checks: $(echo "$out" | grep -m1 -E 'FAIL|REFUSED|rror')"; fails=$((fails + 1)); fi
merge_before=$("${P[@]}" -d "$DB" -c "select md5(pg_get_functiondef('public.zella_merge_customers(uuid,uuid,uuid)'::regprocedure))")
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_relationships.sql" 2>&1) || { echo "FAIL migration run $i: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }; done
[ $fails = 0 ] && echo "PASS sql/zella_relationships.sql applies twice"
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'
[ $code -ne 0 ] && { echo "FAIL test.sql: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); }
# every new SECURITY DEFINER function sets search_path; nothing new for anon (a failed query is a failure, never a pass)
FN="p.pronamespace = 'public'::regnamespace and p.proname ~ '^zella_(people|relationship|consent|is_authorized)'"
if res=$("${P[@]}" -d "$DB" -c "select count(*) filter (where p.prosecdef), count(*) filter (where p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search\_path=%')), coalesce(string_agg(p.proname, ',') filter (where p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search\_path=%')), '') from pg_proc p where $FN"); then
  IFS='|' read -r ndef nbad badnames <<< "$res"
  [ "$ndef" -eq 12 ] && [ "$nbad" = 0 ] && echo "PASS exactly the 12 new SECURITY DEFINER functions exist and all set a search path" || { echo "FAIL search path: $ndef definer functions found, without: ${badnames:-none}"; fails=$((fails + 1)); }
else echo "FAIL search path check could not run"; fails=$((fails + 1)); fi
if res=$("${P[@]}" -d "$DB" -c "select count(*), coalesce(string_agg(p.proname, ',') filter (where has_function_privilege('anon', p.oid, 'execute')), '') from pg_proc p where $FN"); then
  IFS='|' read -r nfn anon <<< "$res"
  [ "$nfn" -eq 14 ] && [ -z "$anon" ] && echo "PASS exactly the 14 new functions exist and the anonymous role can run none of them" || { echo "FAIL anon: $nfn functions found, anon can run: ${anon:-none}"; fails=$((fails + 1)); }
else echo "FAIL anon check could not run"; fails=$((fails + 1)); fi
# replaying sql/zella_customer_records.sql (it redefines the merge) must keep the relationship step, then everything passes again
merge_hooked=$("${P[@]}" -d "$DB" -c "select md5(pg_get_functiondef('public.zella_merge_customers(uuid,uuid,uuid)'::regprocedure))")
if out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_customer_records.sql" 2>&1); then
  hook=$("${P[@]}" -d "$DB" -c "select position('zella_relationships_merge' in pg_get_functiondef('public.zella_merge_customers(uuid,uuid,uuid)'::regprocedure)) > 0")
  replayed=$("${P[@]}" -d "$DB" -c "select md5(pg_get_functiondef('public.zella_merge_customers(uuid,uuid,uuid)'::regprocedure))")
  if [ "$hook" = t ] && [ "$replayed" = "$merge_hooked" ] && out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); then
    echo "PASS a replay of sql/zella_customer_records.sql keeps the relationship step in the merge (same definition), and all checks pass after it"
  else echo "FAIL after replaying zella_customer_records.sql: hook $hook, same definition $([ "$replayed" = "$merge_hooked" ] && echo yes || echo no) $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); fi
else echo "FAIL replay of zella_customer_records.sql: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); fi
# rollback keeps the data (renamed tables), removes the functions; a second apply works
"${P[@]}" -d "$DB" -c "insert into public.businesses (id, name, timezone) values ('c7000000-0000-0000-0000-0000000000f1', 'R1 Rollback', 'UTC');
  insert into public.customers (id, business_id, first_name) values ('c7000000-0000-0000-0000-0000000001f1', 'c7000000-0000-0000-0000-0000000000f1', 'A'), ('c7000000-0000-0000-0000-0000000001f2', 'c7000000-0000-0000-0000-0000000000f1', 'B');
  insert into public.customer_relationships (business_id, customer_id, related_customer_id, kind) values ('c7000000-0000-0000-0000-0000000000f1', 'c7000000-0000-0000-0000-0000000001f1', 'c7000000-0000-0000-0000-0000000001f2', 'household');" > /dev/null
before=$("${P[@]}" -d "$DB" -c "select count(*) from public.customer_relationships")
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_relationships_rollback.sql" 2>&1) || { echo "FAIL rollback: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
left=$("${P[@]}" -d "$DB" -c "select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname ~ '^zella_(people|relationship|consent|is_authorized)'")
kept=$("${P[@]}" -d "$DB" -c "select count(*) from public.customer_relationships_rolled_back")
merge_after=$("${P[@]}" -d "$DB" -c "select md5(pg_get_functiondef('public.zella_merge_customers(uuid,uuid,uuid)'::regprocedure))")
[ "$merge_after" = "$merge_before" ] && echo "PASS rollback restores the customer merge function exactly" || { echo "FAIL rollback changed zella_merge_customers"; fails=$((fails + 1)); }
[ "$left" = 0 ] && [ "$before" -ge 1 ] && [ "$kept" = "$before" ] && echo "PASS rollback removes the functions and keeps the $kept row(s) in customer_relationships_rolled_back" || { echo "FAIL rollback left $left functions, kept $kept of $before rows"; fails=$((fails + 1)); }
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_relationships.sql" 2>&1) || { echo "FAIL re-apply: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
idx=$("${P[@]}" -d "$DB" -c "select count(*) from pg_indexes where tablename = 'customer_relationships'")
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1) && [ "$idx" -ge 6 ] && echo "PASS re-apply after the rollback: fresh tables with their $idx indexes, all checks pass again" || { echo "FAIL after re-apply (indexes $idx): $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
