#!/usr/bin/env bash
# sql/zella_cancellations_scheduled.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, the scheduled path cancels a business but leaves its receptionist on and its subscription active,
# with no audit row; applies, and applies again; after, the scheduled path does the full cancellation, audited; the
# "cancellation coming" reminder still goes to a business due in two days, once; it is in the hourly list as well as the
# daily one; two runs at once cancel and audit a business once; a business not yet due is untouched; the rollback (twice) restores all three functions exactly; applies again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zcancellations; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
fp() { q "select md5(pg_get_functiondef('public.zella_apply_scheduled_cancellations()'::regprocedure)) || md5(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)) || md5(pg_get_functiondef('public.zella_process_cancellations()'::regprocedure))"; }
before=$(fp)
OWNER=f4000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@cancel.test', now())" > /dev/null || exit 1
# a business past its cancel_at with a receptionist, an automation and a subscription
mk() { # name, cancel_at expression -> id
  local b; b=$(q "insert into public.businesses (name, industry_id, is_active, cancel_at, cancel_requested_at) select '$1', id, true, $2, now() from public.industries limit 1 returning id" | head -1)
  q "insert into public.business_members (business_id, user_id, role, status) values ('$b', '$OWNER', 'owner', 'active');
     insert into public.ai_agents (business_id, name, agent_type, status) values ('$b', 'Ava', 'receptionist', 'active');
     insert into public.automations (business_id, name, trigger_type, status) values ('$b', 'Reminders', 'appointment_reminder', 'active');
     insert into public.subscriptions (business_id, status) values ('$b', 'active')" > /dev/null || exit 1
  echo "$b"
}
state() { q "select (b.cancelled_at is not null) || ',' || b.is_active || ',' || (select string_agg(status, '/') from public.ai_agents where business_id = b.id) || ',' ||
  (select string_agg(status, '/') from public.automations where business_id = b.id) || ',' || (select string_agg(status, '/') from public.subscriptions where business_id = b.id) || ',' ||
  (select count(*) from public.audit_logs where business_id = b.id and action = 'business.cancelled') from public.businesses b where b.id = '$1'"; }

B0=$(mk "Before Fix" "now() - interval '1 hour'")
q "select public.zella_apply_scheduled_cancellations()" > /dev/null || bad "the run before the fix failed"
s=$(state "$B0")
# (automations are paused by the business lifecycle trigger when the business goes inactive)
[ "$s" = "true,false,active,paused,active,0" ] && ok "before: the scheduled path leaves the receptionist on and the subscription active, unaudited (the bug)" || bad "before: $s"

"${P[@]}" -d $DB -f "$REPO/sql/zella_cancellations_scheduled.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_cancellations_scheduled.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_cancellations_scheduled.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

B1=$(mk "Due" "now() - interval '1 hour'"); B2=$(mk "Soon" "now() + interval '2 days'"); B3=$(mk "Later" "now() + interval '20 days'")
n=$(q "select public.zella_apply_scheduled_cancellations()") || bad "the scheduled run failed"
[ "$n" = "1" ] && ok "the scheduled path cancels the one business that is due" || bad "cancelled $n"
s=$(state "$B1")
[ "$s" = "true,false,disabled,disabled,cancelled,1" ] && ok "fully: receptionist and automations off, subscription cancelled, business inactive, audited" || bad "after: $s"
s=$(state "$B2"); [[ "$s" == false,true,active,active,active,0 ]] && ok "a business due in two days keeps running" || bad "soon: $s"
r=$(q "select count(*) from public.staff_notifications where business_id = '$B2' and kind = 'cancellation_coming'")
[ "$r" -ge 1 ] && ok "and its owner gets the cancellation coming reminder" || bad "reminder: $r"
q "select public.zella_apply_scheduled_cancellations()" > /dev/null || bad "the second run in the same hour failed"
r2=$(q "select count(*) from public.staff_notifications where business_id = '$B2' and kind = 'cancellation_coming'")
[ "$r2" = "$r" ] && ok "running again in the same hour doesn't repeat the reminder" || bad "reminder repeated: $r -> $r2"
s=$(state "$B3"); [[ "$s" == false,true,active,active,active,0 ]] && ok "a business due later is untouched" || bad "later: $s"
h=$(q "select position(\$t\$'zella_team_scorecard_nudge', 'zella_apply_scheduled_cancellations'\$t\$ in pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)) > 0
       and (length(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)) - length(replace(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure), 'zella_apply_scheduled_cancellations', ''))) / length('zella_apply_scheduled_cancellations') = 2")
[ "$h" = "t" ] && ok "it runs hourly as well as daily" || bad "schedule: $h"

# two runs at once: the second skips the business the first is still cancelling, so it is cancelled and audited once
B4=$(mk "Overlap" "now() - interval '1 hour'")
( "${P[@]}" -d $DB -c "begin; select public.zella_apply_scheduled_cancellations(); select pg_sleep(2); commit;" > /dev/null 2>&1 ) &
sleep 0.7
n2=$(q "select public.zella_process_cancellations()"); wait
[ "$n2" = "0" ] && [ "$(state "$B4")" = "true,false,disabled,disabled,cancelled,1" ] && ok "two runs at once cancel and audit a business once" || bad "overlap: second run $n2, state $(state "$B4")"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_cancellations_scheduled_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_cancellations_scheduled_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores all three functions exactly" || bad "fingerprints after rollback"
[ "$(state "$B1")" = "true,false,disabled,disabled,cancelled,1" ] && ok "businesses already cancelled stay cancelled" || bad "rollback changed a cancelled business"
"${P[@]}" -d $DB -f "$REPO/sql/zella_cancellations_scheduled.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_apply_scheduled_cancellations() returns integer language plpgsql as \$f\$ begin return public.zella_process_cancellations(); end \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_cancellations_scheduled.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "an unknown version that already calls the full cancellation stops the file too" || bad "marker drift: $out"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_cancellations_scheduled_rollback.sql" > /dev/null 2>&1
q "create or replace function public.zella_apply_scheduled_cancellations() returns integer language sql as \$f\$ select 0 \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_cancellations_scheduled.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
