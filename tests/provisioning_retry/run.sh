#!/usr/bin/env bash
# sql/zella_provisioning_retry.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, a failed step can't be retried (the gap); applies, and applies again; the timed job exists and is
# OFF; retrying modules adds only the missing module rows and keeps a module an admin turned off; retrying the
# receptionist adds a disabled receptionist and its settings when they are missing; automations are never invented:
# without any the step stays failed with a note, with some it is done; each retry is audited with its actor and the
# step's alert resolves; the owner invitation email and other steps are refused (manual only); a cancelled business is
# refused; the timed run retries only failed internal steps over an hour old, at most 3 times each; only the server may
# call either; the rollback (twice) removes the job and both functions; applies again; drift stops the file and rollback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_provisioning_retry}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_provisioning_retry.sql"; RB="$REPO/sql/rollback/zella_provisioning_retry_rollback.sql"
ACT=e5000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email) values ('$ACT', 'owner@zella.test')" > /dev/null
IND=$(q "select i.id from public.industries i where i.is_active and (select count(*) from public.industry_modules m where m.industry_id = i.id and m.is_active) >= 2 order by i.name limit 1")
mk() { q "select public.zella_create_business_draft('{\"name\": \"$1\", \"industry_id\": \"$IND\"}'::jsonb) ->> 'business_id'"; }
fail() { q "select public.zella_track_provisioning('$1', '$2', 'failed', 'test failure')" > /dev/null; }
B=$(mk "Retry Test Studio"); fail "$B" modules
[ -z "$(q "select to_regprocedure('public.zella_retry_provisioning(uuid,text,uuid)')")" ] && ok "before: a failed step can't be retried (the gap)" || bad "before"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | grep -v NOTICE | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(q "select count(*) || ',' || bool_or(active)::text from cron.job where jobname = 'zella_provisioning_retry'")" = "1,false" ] && ok "the timed job exists once and is OFF" || bad "job"
total=$(q "select count(*) from public.business_modules where business_id = '$B'")
OFF=$(q "select module_id from public.business_modules where business_id = '$B' limit 1")
q "update public.business_modules set enabled = false where business_id = '$B' and module_id = '$OFF'; delete from public.business_modules where business_id = '$B' and module_id <> '$OFF'" > /dev/null
r=$(q "select public.zella_retry_provisioning('$B', 'modules', '$ACT') ->> 'added'")
[ "$r" = "$((total - 1))" ] && [ "$(q "select count(*) from public.business_modules where business_id = '$B'")" = "$total" ] && [ "$(q "select enabled from public.business_modules where business_id = '$B' and module_id = '$OFF'")" = "f" ] && ok "modules: only the missing rows are added, a module turned off stays off" || bad "modules: $r"
[ "$(q "select status from public.provisioning_steps where business_id = '$B' and step = 'modules'")" = "done" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'provisioning_failed' and business_id = '$B' and status <> 'resolved'")" = "0" ] && ok "the step is done and its alert resolved" || bad "modules status"
[ "$(q "select user_id || ',' || (new_data ->> 'by') from public.audit_logs where action = 'provisioning.step_retried' and business_id = '$B'")" = "$ACT,admin" ] && ok "the retry is audited with the admin" || bad "audit"
q "delete from public.ai_agent_configs where agent_id in (select id from public.ai_agents where business_id = '$B'); delete from public.ai_agents where business_id = '$B'" > /dev/null; fail "$B" receptionist
r=$(q "select public.zella_retry_provisioning('$B', 'receptionist', '$ACT') ->> 'added'")
[ "$r" = "2" ] && [ "$(q "select status from public.ai_agents where business_id = '$B'")" = "disabled" ] && [ "$(q "select count(*) from public.ai_agent_configs c join public.ai_agents a on a.id = c.agent_id where a.business_id = '$B'")" = "1" ] && ok "receptionist: a disabled receptionist and its settings are added" || bad "receptionist: $r"
[ "$(q "select public.zella_retry_provisioning('$B', 'receptionist', '$ACT') ->> 'added'")" = "0" ] && ok "and a second retry adds nothing" || bad "receptionist again"
fail "$B" automations
r=$(q "select public.zella_retry_provisioning('$B', 'automations', '$ACT')")
[ "$(q "select '$r'::jsonb ->> 'status'")" = "failed" ] && [ "$(q "select count(*) from public.automations where business_id = '$B'")" = "0" ] && ok "automations: nothing invented, the step stays failed with a note" || bad "automations: $r"
q "insert into public.automations (business_id, name, trigger_type, status) values ('$B', 'Reminders', 'appointment_reminder', 'disabled')" > /dev/null
[ "$(q "select public.zella_retry_provisioning('$B', 'automations', '$ACT') ->> 'status'")" = "done" ] && ok "with automations saved, the step is done" || bad "automations done"
for s in owner_invitation finish integrations; do out=$(q "select public.zella_retry_provisioning('$B', '$s', '$ACT')" 2>&1); [[ "$out" == *NOT_INTERNAL* ]] || bad "$s retried: $out"; done
ok "the owner invitation email and other steps are refused here (manual only)"
C=$(mk "Cancelled Retry Studio"); q "update public.businesses set cancelled_at = now() where id = '$C'" > /dev/null
out=$(q "select public.zella_retry_provisioning('$C', 'modules', null)" 2>&1); [[ "$out" == *CANCELLED* ]] && ok "a cancelled business is refused" || bad "cancelled: $out"
# the timer
T=$(mk "Timer Retry Studio"); NEW=$(mk "Fresh Failure Studio")
q "delete from public.business_modules where business_id in ('$T', '$NEW')" > /dev/null
fail "$T" modules; fail "$NEW" modules; fail "$T" owner_invitation
q "update public.provisioning_steps set updated_at = now() - interval '2 hours' where business_id = '$T'" > /dev/null
n=$(q "select public.zella_retry_provisioning_due()")
[ "$n" = "1" ] && [ "$(q "select status from public.provisioning_steps where business_id = '$T' and step = 'modules'")" = "done" ] && [ "$(q "select status from public.provisioning_steps where business_id = '$T' and step = 'owner_invitation'")" = "failed" ] && [ "$(q "select status from public.provisioning_steps where business_id = '$NEW' and step = 'modules'")" = "failed" ] && ok "the timed run retries only failed internal steps over an hour old" || bad "timer: $n"
[ "$(q "select new_data ->> 'by' from public.audit_logs where action = 'provisioning.step_retried' and business_id = '$T'")" = "timer" ] && ok "and is audited as the timer" || bad "timer audit"
# a retry by hand holding the business: the timer skips it (same lock order, so no deadlock), and takes it next time
L=$(mk "Locked Retry Studio"); q "delete from public.business_modules where business_id = '$L'" > /dev/null; fail "$L" modules
q "update public.provisioning_steps set updated_at = now() - interval '2 hours' where business_id = '$L'" > /dev/null
PGAPPNAME=zlb_holding "${P[@]}" -d $DB -c "begin; select 1 from public.businesses where id = '$L' for update; select pg_sleep(3); commit;" > /dev/null 2>&1 & bgp=$!
for i in $(seq 1 100); do [ "$(q "select count(*) from pg_stat_activity where application_name = 'zlb_holding' and wait_event = 'PgSleep'")" = "1" ] && break; sleep 0.1; done
n=$(timeout 10 "${P[@]}" -d $DB -c "select public.zella_retry_provisioning_due()" 2>&1)
[ "$n" = "0" ] && [ "$(q "select status from public.provisioning_steps where business_id = '$L' and step = 'modules'")" = "failed" ] && ok "the timer skips a business someone holds, without waiting" || bad "locked: $n"
wait $bgp
[ "$(q "select public.zella_retry_provisioning_due()")" = "1" ] && ok "and retries it on the next run" || bad "next run"
# one setup save's attempt (zella_provisioning_begin / _end): the outcome goes to that attempt's own mark only
V=$(mk "Attempt Studio"); fail "$V" modules
a1=$(q "select public.zella_provisioning_begin('$V', 'modules')"); A1=$(q "select '$a1'::jsonb ->> 'attempt'")
[ "$(q "select '$a1'::jsonb ->> 'before_status'")" = "failed" ] && [ "$(q "select status from public.provisioning_steps where business_id = '$V' and step = 'modules'")" = "pending" ] && ok "begin marks the step pending and returns what it was" || bad "begin: $a1"
a2=$(q "select public.zella_provisioning_begin('$V', 'modules')"); A2=$(q "select '$a2'::jsonb ->> 'attempt'")
[ "$(q "select public.zella_provisioning_end('$V', 'modules', '$A1', 'failed', 'late failure', 'failed', 'old')")" = "f" ] \
  && [ "$(q "select public.zella_provisioning_end('$V', 'modules', '$A1', 'restore', null, 'failed', 'old')")" = "f" ] \
  && [ "$(q "select status from public.provisioning_steps where business_id = '$V' and step = 'modules'")" = "pending" ] && ok "an older attempt's late failure or refusal is ignored once a newer one began" || bad "stale end"
[ "$(q "select public.zella_provisioning_end('$V', 'modules', '$A2', 'done', null, 'pending', null)")" = "t" ] && [ "$(q "select status || ',' || coalesce(attempt_id::text, 'none') from public.provisioning_steps where business_id = '$V' and step = 'modules'")" = "done,none" ] && ok "the newer attempt's outcome is recorded" || bad "newer end"
[ "$(q "select public.zella_provisioning_end('$V', 'modules', '$A2', 'failed', 'again', null, null)")" = "f" ] && ok "and nothing ends twice" || bad "twice"
a3=$(q "select public.zella_provisioning_begin('$V', 'modules')"); A3=$(q "select '$a3'::jsonb ->> 'attempt'")
q "select public.zella_retry_provisioning('$V', 'modules', null)" > /dev/null
[ "$(q "select public.zella_provisioning_end('$V', 'modules', '$A3', 'failed', 'stale', 'done', null)")" = "f" ] && ok "a retry that recorded the step meanwhile wins over a stale attempt" || bad "retry wins"
# overlapping attempts: A is pending, B begins over it (so B's "before" is pending), A finishes (ignored), B is refused:
# the row isn't left pending with no owner; it reads failed, so it can be retried
aa=$(q "select public.zella_provisioning_begin('$V', 'automations')"); AA=$(q "select '$aa'::jsonb ->> 'attempt'")
ab=$(q "select public.zella_provisioning_begin('$V', 'automations')"); AB=$(q "select '$ab'::jsonb ->> 'attempt'")
[ "$(q "select '$ab'::jsonb ->> 'before_status'")" = "pending" ] || bad "B's before is pending"
q "select public.zella_provisioning_end('$V', 'automations', '$AA', 'done', null, null, null)" > /dev/null
[ "$(q "select public.zella_provisioning_end('$V', 'automations', '$AB', 'restore', null, 'pending', null)")" = "t" ] \
  && [ "$(q "select status || ',' || coalesce(attempt_id::text, 'none') from public.provisioning_steps where business_id = '$V' and step = 'automations'")" = "failed,none" ] && ok "a refused attempt over an earlier pending one leaves the step failed (retryable), never pending with no owner" || bad "overlap: $(q "select status || coalesce(attempt_id::text, 'none') from public.provisioning_steps where business_id = '$V' and step = 'automations'")"
a4=$(q "select public.zella_provisioning_begin('$V', 'receptionist')"); A4=$(q "select '$a4'::jsonb ->> 'attempt'")
[ "$(q "select public.zella_provisioning_end('$V', 'receptionist', '$A4', 'restore', null, null, null)")" = "t" ] && [ "$(q "select count(*) from public.provisioning_steps where business_id = '$V' and step = 'receptionist'")" = "0" ] && ok "a refusal with nothing before removes its own pending mark" || bad "restore none"
A=$(mk "Stubborn Studio"); q "delete from public.automations where business_id = '$A'" > /dev/null
for i in 1 2 3 4; do fail "$A" automations; q "update public.provisioning_steps set updated_at = now() - interval '2 hours' where business_id = '$A'" > /dev/null; q "select public.zella_retry_provisioning_due()" > /dev/null; done
[ "$(q "select count(*) from public.audit_logs where action = 'provisioning.step_retried' and business_id = '$A'")" = "3" ] && ok "at most 3 timed attempts per step" || bad "attempts: $(q "select count(*) from public.audit_logs where action = 'provisioning.step_retried' and business_id = '$A'")"
g=$(q "select has_function_privilege('authenticated', 'public.zella_retry_provisioning(uuid,text,uuid)', 'execute')::text || has_function_privilege('anon', 'public.zella_retry_provisioning_due()', 'execute')::text")
[ "$g" = "falsefalse" ] && ok "only the server may call either" || bad "grants: $g"
"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(q "select count(*) from pg_proc where proname in ('zella_provisioning_begin', 'zella_provisioning_end')")$(q "select count(*) from information_schema.columns where table_name = 'provisioning_steps' and column_name = 'attempt_id'")" = "00" ] && ok "rollback drops the attempt functions and column" || bad "attempt leftovers"
[ "$(q "select count(*) from cron.job where jobname = 'zella_provisioning_retry'")$(q "select count(*) from pg_proc where proname in ('zella_retry_provisioning', 'zella_retry_provisioning_due')")" = "00" ] && ok "rollback removes the job and both functions" || bad "after rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_retry_provisioning_due() returns integer language sql as \$f\$ select 0 \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
