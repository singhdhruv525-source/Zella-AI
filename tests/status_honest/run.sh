#!/usr/bin/env bash
# sql/zella_status_honest.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, with nothing checked the page says everything is working, and automations read Working with the
# dispatch job off (the bugs); applies, and applies again; after, nothing checked reads "partial"; automations read
# Working only with the address, the switch, and the zella_dispatch job on with a recent finished run (job off, an
# old run, a failed run or the switch unset all read unknown); every part checked and working reads "operational";
# a slow provider, a published incident and an automation alert still win over "partial"; anyone can still read it;
# the rollback (twice) restores the function exactly; the rollback refuses a changed function; applies again; a
# version that isn't production's stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zstatushonest; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
# production's version of the function comes from the writing cleanup applied on top of the template
"${P[@]}" -d $DB -f "$REPO/sql/zella_writing_cleanup.sql" > /dev/null 2>&1 || { bad "writing cleanup"; exit 1; }
fp() { q "select md5(pg_get_functiondef('public.zella_public_status()'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_public_status')"; }
before=$(fp)
set_() { q "insert into public.platform_settings (key, value) values ('$1', '$2'::jsonb) on conflict (key) do update set value = excluded.value" > /dev/null; }
unset_() { q "delete from public.platform_settings where key = '$1'" > /dev/null; }
overall() { q "select public.zella_public_status() ->> 'overall'"; }
part() { q "select x ->> 'state' from jsonb_array_elements(public.zella_public_status() -> 'components') x where x ->> 'key' = '$1'"; }
job() { # active, minutes since the last run ended, status of that run
  q "delete from cron.job_run_details; delete from cron.job where jobname = 'zella_dispatch';
     insert into cron.job (jobname, schedule, command, active) values ('zella_dispatch', '* * * * *', 'select public.zella_dispatch_n8n()', $1);
     insert into cron.job_run_details (jobid, status, start_time, end_time) select jobid, '$3', now() - interval '$2 minutes', now() - interval '$2 minutes' from cron.job where jobname = 'zella_dispatch'" > /dev/null; }
q "delete from public.provider_health; delete from public.platform_alerts; delete from public.platform_incidents" > /dev/null
unset_ provider_checks_live; set_ n8n_base_url '"https://n8n.example.test"'; unset_ n8n_dispatch_enabled; job false 600 succeeded

[ "$(overall)" = "operational" ] && ok "before: with nothing checked the page says everything is working (the bug)" || bad "before overall: $(overall)"
[ "$(part automations)" = "operational" ] && ok "before: automations read Working with the dispatch job off and the switch unset (the bug)" || bad "before automations: $(part automations)"

"${P[@]}" -d $DB -f "$REPO/sql/zella_status_honest.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_status_honest.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_status_honest.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

[ "$(overall)" = "partial" ] && ok "nothing checked reads partial, never everything is working" || bad "nothing checked: $(overall)"
[ "$(part automations)" = "unknown" ] && ok "automations with the job off and the switch unset read unknown" || bad "automations off: $(part automations)"
set_ n8n_dispatch_enabled true
[ "$(part automations)" = "unknown" ] && ok "switch on but the dispatch job off still reads unknown" || bad "job off: $(part automations)"
job true 30 succeeded; [ "$(part automations)" = "unknown" ] && ok "job on but its last run 30 minutes ago reads unknown" || bad "old run: $(part automations)"
job true 1 failed; [ "$(part automations)" = "unknown" ] && ok "job on but its last run failed reads unknown" || bad "failed run: $(part automations)"
job true 1 succeeded; [ "$(part automations)" = "operational" ] && ok "address, switch and a job that just ran read Working" || bad "running: $(part automations)"
unset_ n8n_dispatch_enabled; [ "$(part automations)" = "unknown" ] && ok "with the switch unset it reads unknown (as the dispatcher sees it)" || bad "switch unset: $(part automations)"
set_ n8n_dispatch_enabled true
[ "$(overall)" = "partial" ] && ok "automations working but the providers unchecked still reads partial" || bad "providers unchecked: $(overall)"
set_ provider_checks_live true
q "insert into public.provider_health (provider, ok, checked_at) values ('vapi', true, now()), ('telnyx', true, now()), ('resend', true, now())" > /dev/null
[ "$(overall)" = "operational" ] && ok "every part checked and working reads operational" || bad "all working: $(overall)"
q "update public.provider_health set ok = false, consecutive_failures = 1 where provider = 'resend'" > /dev/null
[ "$(overall)" = "degraded" ] && ok "a slow provider reads degraded" || bad "slow: $(overall)"
q "update public.provider_health set ok = true, consecutive_failures = 0, checked_at = now() - interval '7 hours' where provider = 'resend'" > /dev/null
[ "$(overall)" = "partial" ] && [ "$(part email)" = "unknown" ] && ok "a check older than 6 hours reads unknown and partial" || bad "stale check: $(overall) $(part email)"
q "insert into public.platform_incidents (title, status, is_public, public_message, component) values ('t', 'open', true, 'Some texts are slow to arrive', 'texts')" > /dev/null
[ "$(overall)" = "degraded" ] && ok "a published incident wins over partial" || bad "incident: $(overall)"
q "delete from public.platform_incidents" > /dev/null
q "insert into public.platform_alerts (kind, title, severity, status) values ('automation_stalled', 'Automations are not being worked', 'urgent', 'open')" > /dev/null
[ "$(part automations)" = "outage" ] && [ "$(overall)" = "outage" ] && ok "an automation alert still reads not working" || bad "alert: $(part automations) $(overall)"
v=$("${P[@]}" -d $DB -c "set role anon; select public.zella_public_status() ? 'overall'" 2>&1)
[ "$v" = "t" ] && ok "anyone can still read it without signing in" || bad "anon: $v"
v=$(q "select count(*) from jsonb_array_elements(public.zella_public_status() -> 'components')"); [ "$v" = "5" ] && ok "same five parts" || bad "parts: $v"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_status_honest_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_status_honest_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the function and its grants exactly" || bad "after rollback: $(fp)"
"${P[@]}" -d $DB -f "$REPO/sql/zella_status_honest.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_public_status() returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_status_honest_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_status_honest.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
