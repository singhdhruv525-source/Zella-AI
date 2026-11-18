#!/usr/bin/env bash
# sql/zella_ai_eval_admin.sql on an ISOLATED copy of the production schema (never production). Test data only; no
# provider is called and nothing is sent (the cases are checked against knowledge search in the database only).
# Checks: before, a restricted role with businesses.manage can't run a business's tests and nothing is stored (the
# gap); applies, and applies again; the pass rule (every expected phrase in the top answer, "should find nothing" finds
# nothing, at least 3 cases, all passing) gives the same case results as zella_brain_run_evals; each run is stored with
# who ran it and the failed questions; the overview pages the tested businesses with their latest run; who may run
# (businesses.manage) and read (businesses.view); a business owner and anonymous are refused; rollback (twice) removes
# exactly the two functions, keeps the stored runs (server only) for the next apply, and refuses a changed function; applies again; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_ai_eval_admin}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
as() { local c
  case "$1" in
    service) c="set local request.jwt.claims = '{\"role\":\"service_role\"}'; set local role service_role;";;
    anon) c="set local request.jwt.claims = '{\"role\":\"anon\"}'; set local role anon;";;
    *) c="set local request.jwt.claims = '{\"role\":\"authenticated\",\"sub\":\"$1\",\"aal\":\"aal2\"}'; set local role authenticated;";;
  esac
  "${P[@]}" -d $DB -c "begin; $c $2; commit;" 2>&1; }
OWNER=a0000000-0000-0000-0000-0000000000c1; RO=a0000000-0000-0000-0000-0000000000c2; SUPPORT=a0000000-0000-0000-0000-0000000000c3; MEMBER=a0000000-0000-0000-0000-0000000000c4
E() { echo "e0000000-0000-0000-0000-00000000000$1"; }
fp() { q "select concat_ws(',', (select string_agg(p.oid::regprocedure::text, ',' order by 1) from pg_proc p where p.proname in ('zella_admin_eval_run', 'zella_admin_eval_overview')), to_regclass('public.ai_eval_runs'))"; }
q "insert into public.platform_role_permissions (role, permission) values ('support_admin', 'businesses.manage') on conflict do nothing" > /dev/null

v=$(as "$SUPPORT" "select public.zella_brain_run_evals('$(E 1)')"); [[ "$v" == *NOT_ALLOWED* ]] && ok "before: a support admin with businesses.manage can't run a business's tests, and nothing is stored (the gap)" || bad "before $v"
[ "$(fp)" = "" ] && ok "before: no admin AI testing functions or runs table" || bad "before fp $(fp)"
"${P[@]}" -d $DB -f "$REPO/sql/zella_ai_eval_admin.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_ai_eval_admin.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_ai_eval_admin.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

run() { as "$1" "select concat_ws('|', j ->> 'total', j ->> 'passed', j ->> 'business_passes', j -> 'failed' -> 0 ->> 'question') from (select public.zella_admin_eval_run('$2') j) x"; }
v=$(run "$SUPPORT" "$(E 1)"); [ "$v" = "3|3|true" ] && ok "a support admin with businesses.manage runs it: 3 of 3, the business passes (\"should find nothing\" found nothing)" || bad "e1 $v"
v=$(run "$OWNER" "$(E 2)"); [ "$v" = "3|2|false|Is there parking?" ] && ok "one expected phrase missing from the top answer fails that case and the business" || bad "e2 $v"
v=$(as service "select (public.zella_brain_run_evals('$(E 2)') ->> 'passed')"); [ "$v" = 2 ] && ok "the case results equal zella_brain_run_evals for the same business" || bad "same rule $v"
v=$(run "$OWNER" "$(E 3)"); [ "$v" = "2|2|false" ] && ok "two passing cases are too few: the business doesn't pass (at least 3)" || bad "e3 $v"
v=$(run "$OWNER" "$(E 4)"); [ "$v" = "0|0|false" ] && ok "no cases: nothing passes" || bad "e4 $v"
v=$(q "select count(*) || '|' || count(*) filter (where run_by = '$SUPPORT') || '|' || (select failed -> 0 ->> 'expected' from public.ai_eval_runs where business_id = '$(E 2)' order by run_at desc limit 1) from public.ai_eval_runs")
[ "$v" = "4|1|valet" ] && ok "every run is stored with who ran it and the failed question with what was expected" || bad "stored $v"
v=$(as "$OWNER" "select concat_ws('|', j ->> 'total', j ->> 'passing', jsonb_array_length(j -> 'businesses'), j -> 'businesses' -> 1 -> 'last_run' ->> 'passed') from (select public.zella_admin_eval_overview(2, 0) j) x")
[ "$v" = "4|1|2|2" ] && ok "the overview pages the 4 tested businesses (1 passing) with their latest run" || bad "overview $v"
run "$OWNER" "$(E 2)" > /dev/null
v=$(as "$OWNER" "select count(*) from jsonb_array_elements(public.zella_admin_eval_overview(500, 0) -> 'businesses')"); [ "$v" = 4 ] && ok "a rerun keeps one row per business in the overview (its latest run)" || bad "latest $v"
v=$(as "$OWNER" "select public.zella_admin_eval_overview(500, 0) ->> 'limit'"); [ "$v" = 100 ] && ok "at most 100 a page" || bad "limit $v"

v=$(as "$RO" "select public.zella_admin_eval_overview()"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a read only admin without businesses.view can't read the overview" || bad "ro overview $v"
q "insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null
v=$(as "$RO" "select public.zella_admin_eval_overview() ->> 'total'"); [ "$v" = 4 ] && ok "with businesses.view it can" || bad "ro granted $v"
v=$(run "$RO" "$(E 1)"); [[ "$v" == *NOT_ALLOWED* ]] && ok "but can't run tests without businesses.manage" || bad "ro run $v"
v=$(run "$MEMBER" "$(E 1)"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a business owner can't run the admin tests" || bad "member run $v"
v=$(as "$MEMBER" "select public.zella_admin_eval_overview()"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a business owner can't read the overview" || bad "member overview $v"
v=$(run anon "$(E 1)"); [[ "$v" == *"permission denied"* ]] && ok "anonymous can't run" || bad "anon run $v"
v=$(as anon "select public.zella_admin_eval_overview()"); [[ "$v" == *"permission denied"* ]] && ok "anonymous can't read" || bad "anon overview $v"
v=$(as "$MEMBER" "select count(*) from public.ai_eval_runs"); [[ "$v" == *"permission denied"* || "$v" = 0 ]] && ok "signed in users can't read the runs table directly" || bad "table $v"
v=$(run "$OWNER" "00000000-0000-0000-0000-000000000000"); [[ "$v" == *BUSINESS_NOT_FOUND* ]] && ok "an unknown business is not found" || bad "unknown $v"

RUNS=$(q "select count(*) from public.ai_eval_runs")   # before the rollback
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_ai_eval_admin_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_ai_eval_admin_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "ai_eval_runs" ] && ok "rollback removes exactly the two functions" || bad "after rollback $(fp)"
[ "$(q "select count(*) from public.ai_eval_runs")" = "$RUNS" ] && [ "$RUNS" -gt 0 ] && [ "$(q "select relrowsecurity from pg_class where oid = 'public.ai_eval_runs'::regclass")" = t ] \
  && [[ "$(as "$MEMBER" "select count(*) from public.ai_eval_runs")" == *"permission denied"* ]] \
  && ok "the stored runs are kept, still server only ($RUNS runs)" || bad "runs after rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_ai_eval_admin.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
v=$(as "$OWNER" "select public.zella_admin_eval_overview(500, 0) ->> 'total'"); [ "$v" = 4 ] && ok "applying again reuses the kept runs" || bad "reuse $v"
q "create or replace function public.zella_admin_eval_run(p_business_id uuid) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_ai_eval_admin_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && [ -n "$(fp)" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_ai_eval_admin.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
