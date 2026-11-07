#!/usr/bin/env bash
# Release 2 scheduling checks on an ISOLATED copy of the production state: tests/lib/build_full.sh, every file applied
# since (the pending list of tests/deploy/run_all.sh, Batch 1, Batch 3, Release 1), then sql/zella_scheduling.sql
# twice, tests/scheduling/test.sql, the existing booking checks, the rollback, and a second apply after it.
# Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zsched}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)   # an array: each value stays one argument
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
[ "${#PENDING[@]}" -ge 10 ] || { echo "FAIL could not read the pending list"; exit 1; }
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ "$m" = zella_scheduling ] && continue   # applied below, after the baseline hash is taken
  [ "$m" = zella_slots_resource_blocks ] && continue   # needs this release first; tests/slotblocks/run.sh checks it
  [ "$m" = zella_record_workflows ] && continue   # a later release; tests/workflows/run.sh checks it
  [ -f "$REPO/sql/$m.sql" ] || continue
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
fails=0
guard_before=$("${P[@]}" -d "$DB" -c "select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.proname)) from pg_proc p where p.proname in ('zella_appointment_after', 'zella_appointment_conflict_guard', 'zella_available_slots', 'zella_book_appointment')")
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_scheduling.sql" 2>&1) || { echo "FAIL migration run $i: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }; done
if [ $fails = 0 ]; then echo "PASS sql/zella_scheduling.sql applies twice"; fi
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'
if [ $code -ne 0 ]; then echo "FAIL test.sql: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); fi
# the existing booking functions are untouched (the baseline is taken before the first apply)
guard_after=$("${P[@]}" -d "$DB" -c "select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.proname)) from pg_proc p where p.proname in ('zella_appointment_after', 'zella_appointment_conflict_guard', 'zella_available_slots', 'zella_book_appointment')")
if [ -n "$guard_before" ] && [ "$guard_after" = "$guard_before" ]; then echo "PASS the existing booking guard, slot search, booking function and messaging trigger are unchanged"; else echo "FAIL an existing booking function changed"; fails=$((fails + 1)); fi
# every new SECURITY DEFINER function sets search_path; nothing new for anon (a failed query is a failure, never a pass)
# (zella_dispatch_n8n and zella_schedule_calendar_pulls are older and unrelated)
FN="p.pronamespace = 'public'::regnamespace and p.proname ~ '^zella_(resource|schedule|dispatch|recurring)' and p.proname not in ('zella_dispatch_n8n', 'zella_schedule_calendar_pulls')"
if res=$("${P[@]}" -d "$DB" -c "select count(*), count(*) filter (where p.prosecdef), count(*) filter (where p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search\_path=%')), coalesce(string_agg(p.proname, ',') filter (where has_function_privilege('anon', p.oid, 'execute')), '') from pg_proc p where $FN"); then
  IFS='|' read -r nfn ndef nbad anon <<< "$res"
  if [ "$nfn" -eq 20 ] && [ "$ndef" -eq 18 ] && [ "$nbad" = 0 ] && [ -z "$anon" ]; then echo "PASS exactly the 20 new functions exist (18 run with the owner's rights, all with a fixed search path) and the anonymous role can run none"
  else echo "FAIL catalog: $nfn functions, $ndef definer, $nbad without a search path, anon can run: ${anon:-none}"; fails=$((fails + 1)); fi
else echo "FAIL catalog check could not run"; fails=$((fails + 1)); fi
# rollback keeps the data (renamed tables, columns kept), removes the functions and triggers; a second apply works
"${P[@]}" -d "$DB" -c "insert into public.businesses (id, name, timezone) values ('c8000000-0000-0000-0000-0000000000f1', 'R2 Rollback', 'UTC');
  insert into public.resources (id, business_id, name, kind) values ('c8000000-0000-0000-0000-0000000009f1', 'c8000000-0000-0000-0000-0000000000f1', 'Bay 1', 'bay');
  insert into public.recurring_plans (business_id, title, frequency, weekday, start_at, starts_on) values ('c8000000-0000-0000-0000-0000000000f1', 'Weekly', 'weekly', 1, '09:00', current_date);
  insert into public.blocked_times (business_id, title, start_time, end_time, resource_id) values ('c8000000-0000-0000-0000-0000000000f1', 'Bay repair', date_trunc('week', now()) + interval '14 days', date_trunc('week', now()) + interval '15 days', 'c8000000-0000-0000-0000-0000000009f1');" > /dev/null
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_scheduling_rollback.sql" 2>&1) || { echo "FAIL rollback: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
res=$("${P[@]}" -d "$DB" -c "select (select count(*) from pg_proc p where $FN),
  (select count(*) from pg_trigger where tgname in ('zella_resource_guard', 'zella_resource_block_guard')),
  (select count(*) from public.resources_rolled_back), (select count(*) from public.recurring_plans_rolled_back),
  (select count(*) from public.blocked_times where resource_id = 'c8000000-0000-0000-0000-0000000009f1')")
IFS='|' read -r left trig kept_r kept_p kept_b <<< "$res"
guard_rb=$("${P[@]}" -d "$DB" -c "select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.proname)) from pg_proc p where p.proname in ('zella_appointment_after', 'zella_appointment_conflict_guard', 'zella_available_slots', 'zella_book_appointment')")
if [ "$left" = 0 ] && [ "$trig" = 0 ] && [ "$kept_r" -ge 1 ] && [ "$kept_p" -ge 1 ] && [ "$kept_b" = 1 ] && [ "$guard_rb" = "$guard_before" ]; then
  echo "PASS rollback removes the functions and triggers, keeps the data ($kept_r resource(s), $kept_p plan(s) set aside; the resource block kept), and the booking functions are as before"
else echo "FAIL rollback: $left functions and $trig triggers left; kept $kept_r resources, $kept_p plans, $kept_b blocks"; fails=$((fails + 1)); fi
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_scheduling.sql" 2>&1) || { echo "FAIL re-apply: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
if out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); then echo "PASS re-apply after the rollback: fresh tables, all checks pass again"
else echo "FAIL after re-apply: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); fi
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
