#!/usr/bin/env bash
# sql/zella_slots_resource_blocks.sql on an ISOLATED copy of the production state (tests/lib/build_full.sh plus every
# file applied since: the pending list of tests/deploy/run_all.sh, Batch 1 and Batch 3). Checks: the test fails
# before the fix (so it tests something), the fix applies twice, the test passes, only the one line of slot search
# changed and nothing else, the rollback restores slot search exactly, and a second apply passes again.
# Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zslotblocks}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)   # an array: each value stays one argument
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
[ "${#PENDING[@]}" -ge 10 ] || { echo "FAIL could not read the pending list"; exit 1; }
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ "$m" = zella_slots_resource_blocks ] && continue   # applied below, after the baseline is taken
  [ "$m" = zella_record_workflows ] && continue   # a later release; tests/workflows/run.sh checks it
  [ -f "$REPO/sql/$m.sql" ] || continue
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
fails=0
SLOTS="pg_get_functiondef('public.zella_available_slots(uuid,timestamptz,timestamptz,integer,uuid,integer,integer,uuid)'::regprocedure)"
# every public function except slot search, so a change anywhere else is caught
OTHERS="select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname <> 'zella_available_slots'"
slots_before=$("${P[@]}" -d "$DB" -c "select $SLOTS")
others_before=$("${P[@]}" -d "$DB" -c "$OTHERS")
# the test must fail without the fix
if "${P[@]}" -d "$DB" -f "$HERE/test.sql" > /dev/null 2>&1; then echo "FAIL the test passes without the fix, so it tests nothing"; fails=$((fails + 1)); else echo "PASS without the fix the test fails (a resource block closes the business)"; fi
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_slots_resource_blocks.sql" 2>&1) || { echo "FAIL migration run $i: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }; done
[ $fails = 0 ] && echo "PASS sql/zella_slots_resource_blocks.sql applies twice"
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'
if [ $code -ne 0 ]; then echo "FAIL test.sql: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); fi
# exactly one line of slot search changed, to exactly the new rule; nothing else changed
slots_after=$("${P[@]}" -d "$DB" -c "select $SLOTS")
delta=$(diff <(echo "$slots_before") <(echo "$slots_after"))
changed=$(grep -c '^[<>]' <<< "$delta")
want='          and ((bt.staff_id is null and bt.resource_id is null) or bt.staff_id = r.sid)   /* zella_slots_resource_blocks: a block on a resource doesn'"'"'t close the business */'
if [ "$changed" = 2 ] && grep -qxF "> $want" <<< "$delta" && [ "$("${P[@]}" -d "$DB" -c "$OTHERS")" = "$others_before" ]; then
  echo "PASS only the one block rule in slot search changed; every other function is unchanged"
else echo "FAIL unexpected change: $changed changed lines in slot search, or another function changed"; fails=$((fails + 1)); fi
# the rollback puts slot search back exactly; a second apply passes again
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_slots_resource_blocks_rollback.sql" 2>&1) || { echo "FAIL rollback: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d "$DB" -c "select $SLOTS")" = "$slots_before" ] && [ "$("${P[@]}" -d "$DB" -c "$OTHERS")" = "$others_before" ]; then echo "PASS the rollback restores slot search exactly"; else echo "FAIL rollback left slot search changed"; fails=$((fails + 1)); fi
if out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_slots_resource_blocks.sql" 2>&1 && "${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); then
  echo "PASS re-apply after the rollback: the test passes again"
else
  echo "FAIL after re-apply: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1))
fi
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
