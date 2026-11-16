#!/usr/bin/env bash
# sql/zella_job_intent.sql on an ISOLATED copy of the production schema (never production). Test people only; nothing
# is sent and no job is switched. Checks: before, the scheduler health says nothing about intent (the gap); applies,
# and applies again; the go live jobs are recorded as deliberately off; each job shows its intended state beside the
# real one, mismatches are counted and intents for jobs that don't exist are listed; every key it returned before is
# still there; saving an intent needs platform.configure and a reason, is audited with the admin's id, and leaves
# cron.job exactly as it was; the wrong role, a business member and anonymous are refused; the table can't be read
# directly; the rollback (twice) restores the function exactly and removes the table; it refuses a changed function;
# applies again; a version that isn't production's stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_jobintent}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e1000000-0000-0000-0000-000000000001; RO=e1000000-0000-0000-0000-000000000002; MEMBER=e1000000-0000-0000-0000-000000000003; OPS=e1000000-0000-0000-0000-000000000004
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@jobs.test', now()), ('$RO', 'readonly@jobs.test', now()), ('$MEMBER', 'member@jobs.test', now()), ('$OPS', 'ops@jobs.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$RO', 'read_only_admin'), ('$OPS', 'platform_operations');
   insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view'), ('platform_operations', 'businesses.view'), ('platform_operations', 'platform.configure') on conflict do nothing" > /dev/null || exit 1
# one statement as a signed in person (or anonymous with an empty id): the first line of output, or the error
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
fp() { q "select md5(pg_get_functiondef('public.zella_admin_scheduler_health()'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_admin_scheduler_health')"; }
cronfp() { q "select md5(coalesce(string_agg(jobname || schedule || command || active, ',' order by jobname), '')) from cron.job"; }
keys() { as $OWNER "select string_agg(k, ',' order by k) from jsonb_object_keys(public.zella_admin_scheduler_health()) k"; }
q "delete from cron.job where jobname like 'zella%';
   insert into cron.job (jobname, schedule, command, active) values ('zella_dispatch', '* * * * *', 'select public.zella_dispatch_n8n()', false),
     ('zella_jobs_daily', '0 4 * * *', 'select public.zella_run_schedule_group(''daily'')', true), ('zella_usage_thresholds', '23 * * * *', 'select public.zella_check_usage_thresholds()', true)" > /dev/null || exit 1
before=$(fp); keys_before=$(keys)
v=$(as $OWNER "select public.zella_admin_scheduler_health() -> 'jobs' -> 0 ? 'intended'")
[ "$v" = "f" ] && ok "before: a job says only on or off, never whether that is on purpose (the gap)" || bad "before: $v"

"${P[@]}" -d $DB -f "$REPO/sql/zella_job_intent.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_job_intent.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_job_intent.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

v=$(q "select count(*) filter (where intended = 'off' and reason = 'Deliberately off until go live' and decided_by is null) || '/' || count(*) from public.scheduled_job_intents")
[ "$v" = "9/9" ] && ok "the nine go live jobs are recorded as deliberately off until go live" || bad "seed: $v"
job() { as $OWNER "select j ->> '$2' from jsonb_array_elements(public.zella_admin_scheduler_health() -> 'jobs') j where j ->> 'name' = '$1'"; }
[ "$(job zella_dispatch intended)/$(job zella_dispatch intent_matches)/$(job zella_dispatch active)" = "off/true/false" ] && ok "an off job recorded as off matches its intent" || bad "dispatch: $(job zella_dispatch intended)/$(job zella_dispatch intent_matches)"
[ "$(job zella_jobs_daily intended)/$(job zella_jobs_daily intent_matches)" = "off/false" ] && ok "a job that is on but recorded as off is a mismatch" || bad "daily: $(job zella_jobs_daily intent_matches)"
[ -z "$(job zella_usage_thresholds intended)" ] && [ -z "$(job zella_usage_thresholds intent_matches)" ] && ok "a job with nothing recorded has no intent and no verdict" || bad "thresholds: $(job zella_usage_thresholds intent_matches)"
[ -n "$(job zella_dispatch drives)" ] && [ -n "$(job zella_usage_thresholds drives)" ] && ok "each job says what it drives" || bad "drives"
v=$(as $OWNER "select public.zella_admin_scheduler_health() ->> 'intent_mismatches'"); [ "$v" = "1" ] && ok "mismatches are counted" || bad "mismatches: $v"
v=$(as $OWNER "select string_agg(x ->> 'name', ',' order by x ->> 'name') from jsonb_array_elements(public.zella_admin_scheduler_health() -> 'intent_only') x")
[[ "$v" == *zella_jobs_every5* && "$v" != *zella_dispatch* && "$v" != *zella_jobs_daily* ]] && ok "intents for jobs that don't exist are listed apart" || bad "intent only: $v"
v=$(keys); [[ ",$v," == *",intent_mismatches,"* ]] && for k in ${keys_before//,/ }; do [[ ",$v," == *",$k,"* ]] || { bad "key $k missing"; break; }; done && ok "every key it returned before is still there" || bad "keys: $v"

c0=$(cronfp)
v=$(as $OWNER "select public.zella_admin_job_intent_save('zella_jobs_daily', 'on', '  Owner approved daily jobs  ') ->> 'intended'")
[ "$v" = "on" ] && ok "an owner records an intent" || bad "save: $v"
[ "$(cronfp)" = "$c0" ] && ok "recording an intent leaves cron.job exactly as it was" || bad "cron.job changed"
[ "$(job zella_jobs_daily intent_matches)/$(job zella_jobs_daily intent_reason)/$(job zella_jobs_daily intent_by)" = "true/Owner approved daily jobs/owner@jobs.test" ] && ok "the new intent shows with its reason and who recorded it" || bad "after save: $(job zella_jobs_daily intent_reason)/$(job zella_jobs_daily intent_by)"
v=$(q "select user_id || '|' || (old_data ->> 'intended') || '|' || (new_data ->> 'intended') || '|' || (new_data ->> 'job') from public.audit_logs where action = 'scheduled_job.intent_recorded' order by created_at desc limit 1")
[ "$v" = "$OWNER|off|on|zella_jobs_daily" ] && ok "the change is audited with the admin's id, before and after" || bad "audit: $v"
v=$(as $OPS "select public.zella_admin_job_intent_save('zella_cron_cleanup', 'on', 'Only deletes old run history') ->> 'job'")
[ "$v" = "zella_cron_cleanup" ] && ok "a role holding platform.configure may record an intent" || bad "ops: $v"
[[ "$(as $RO "select public.zella_admin_job_intent_save('zella_dispatch', 'on', 'not allowed')")" == *NOT_ALLOWED* ]] && ok "a role without platform.configure is refused" || bad "read only allowed"
[[ "$(as $MEMBER "select public.zella_admin_job_intent_save('zella_dispatch', 'on', 'not allowed')")" == *NOT_ALLOWED* ]] && ok "a business member who isn't an admin is refused" || bad "member allowed"
[[ "$(as "" "select public.zella_admin_job_intent_save('zella_dispatch', 'on', 'not allowed')")" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon allowed"
[[ "$(as $MEMBER "select public.zella_admin_scheduler_health()")" == *NOT_ALLOWED* ]] && ok "a business member can't read the scheduler health" || bad "member reads health"
[[ "$(as $OWNER "select public.zella_admin_job_intent_save('zella_dispatch', 'on', 'x')")" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "no reason"
[[ "$(as $OWNER "select public.zella_admin_job_intent_save('other_job', 'on', 'a reason')")" == *INVALID_JOB* ]] && ok "only zella jobs can have an intent" || bad "other job"
[[ "$(as $OWNER "select public.zella_admin_job_intent_save('zella_dispatch', 'maybe', 'a reason')")" == *INVALID_INTENT* ]] && ok "the intent is on or off only" || bad "bad intent"
[[ "$(as $OWNER "select count(*) from public.scheduled_job_intents")" == *"permission denied"* ]] && ok "the intents table can't be read directly" || bad "table readable"
[ "$(cronfp)" = "$c0" ] && ok "cron.job is still unchanged after every attempt" || bad "cron.job changed"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_job_intent_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_job_intent_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the function and its grants exactly" || bad "after rollback: $(fp)"
v=$(q "select to_regclass('public.scheduled_job_intents') is null and to_regprocedure('public.zella_admin_job_intent_save(text,text,text)') is null"); [ "$v" = "t" ] && ok "rollback removes the table and the save function" || bad "leftovers"
"${P[@]}" -d $DB -f "$REPO/sql/zella_job_intent.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_scheduler_health() returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_job_intent_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_job_intent.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
