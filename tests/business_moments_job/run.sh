#!/usr/bin/env bash
# sql/zella_business_moments_job.sql on an ISOLATED copy of the production schema (never production). No data needed.
# Checks: before, zella_run_scheduled_job answers not_allowed for zella_check_business_moments (the gap); the file
# applies over production's version and over production's with the weekly platform report, and again (nothing changes);
# the job is then allowed and every other job keeps its answer; the rollback restores the original byte for byte (md5)
# and runs twice; a changed function stops the file (VERSION_MISMATCH) and the rollback (ROLLBACK_DRIFT).
#   tests/business_moments_job/run.sh        (env: DB=zbmj TEMPLATE=zprod3)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zbmj}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
[[ "$TEMPLATE" =~ ^z[a-z0-9_]{1,40}$ ]] || { echo "REFUSED: '$TEMPLATE' is not a test template name"; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
FILE="$REPO/sql/zella_business_moments_job.sql"; RB="$REPO/sql/rollback/zella_business_moments_job_rollback.sql"
fn="pg_get_functiondef('public.zella_run_scheduled_job(text)'::regprocedure)"
md5() { q "select md5($fn)"; }
fresh() {
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
  for f in zella_writing_cleanup $1; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f applies"; exit 1; }; done
}
for stack in "" zella_weekly_platform_report; do
  label=${stack:-production}; fresh "$stack"
  before=$(md5); others=$(q "select string_agg(public.zella_run_scheduled_job(j), ',' order by j) from unnest(array['no_such_job', 'zella_check_milestones; select 1']) j")
  [ "$(q "select public.zella_run_scheduled_job('zella_check_business_moments')")" = not_allowed ] && ok "$label: before, the hourly job can't run zella_check_business_moments (the gap)" || bad "$label: before"
  "${P[@]}" -d $DB -f "$FILE" > /dev/null 2>&1 && ok "$label: applies" || bad "$label: applies"
  after=$(md5)
  "${P[@]}" -d $DB -f "$FILE" > /dev/null 2>&1 && [ "$(md5)" = "$after" ] && ok "$label: applies again and changes nothing" || bad "$label: second apply"
  [ "$(q "select public.zella_run_scheduled_job('zella_check_business_moments')")" = ok ] && ok "$label: the job is allowed now" || bad "$label: allowed"
  [ "$(q "select string_agg(public.zella_run_scheduled_job(j), ',' order by j) from unnest(array['no_such_job', 'zella_check_milestones; select 1']) j")" = "$others" ] && ok "$label: other names keep their answers" || bad "$label: others"
  [ "$(q "select (length($fn) - length(replace($fn, 'zella_check_business_moments', ''))) / length('zella_check_business_moments')")" = 1 ] && ok "$label: added once" || bad "$label: added once"
  "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && [ "$(md5)" = "$before" ] && ok "$label: the rollback restores the original exactly" || bad "$label: rollback"
  "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && [ "$(md5)" = "$before" ] && [ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_business_moments_job'")" = 0 ] \
    && ok "$label: the rollback runs twice and leaves no archive row" || bad "$label: second rollback"
done
fresh ""
q "select public.zella_patch_function('public.zella_run_scheduled_job(text)', 'zella_test_drift', \$t\$'zella_check_milestones', \$t\$, \$t\$'zella_check_milestones', 'zella_test_drift', \$t\$)" > /dev/null
v=$("${P[@]}" -d $DB -f "$FILE" 2>&1); [[ "$v" == *VERSION_MISMATCH* ]] && [ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_business_moments_job'")" = 0 ] \
  && ok "a changed function stops the file and changes nothing" || bad "drift apply: $v"
fresh ""
"${P[@]}" -d $DB -f "$FILE" > /dev/null 2>&1
q "select public.zella_patch_function('public.zella_run_scheduled_job(text)', 'zella_test_drift', \$t\$'zella_check_milestones', \$t\$, \$t\$'zella_check_milestones', 'zella_test_drift', \$t\$)" > /dev/null
v=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$v" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a function changed since" || bad "drift rollback: $v"
"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
