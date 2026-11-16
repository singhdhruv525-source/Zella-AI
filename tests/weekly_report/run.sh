#!/usr/bin/env bash
# sql/zella_weekly_platform_report.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: the gap first (no weekly platform report: the job isn't allowed, not in the weekly list, no admin read); applies,
# and applies again; the figures for a week match the test rows (and rows outside the week are not counted); running twice
# in a week makes one report and one alert; through the real job runner and the weekly group; two runs at once make one;
# the next week resolves the previous alert; the alert carries no figure, and reaches the email digest only once email
# is live; permissions (Zella Voice owner and super admin yes, read only admin no until the owner grants reports.view,
# a business owner no, anonymous no, no direct table or job access); rollback twice restores both functions exactly;
# applies again; a later change to the weekly list survives the rollback; an unknown version stops the file (drift).
# STACK=1 first applies zella_writing_cleanup.sql and the merged, unapplied migrations (docs/SCHEMA_STATUS.md).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zrep_weekly}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
FILE="$REPO/sql/zella_weekly_platform_report.sql"; RB="$REPO/sql/rollback/zella_weekly_platform_report_rollback.sql"
if [ "${STACK:-0}" = "1" ]; then
  for f in zella_writing_cleanup zella_retry_event_safe zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
    "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "stack: $f failed"; exit 1; }
  done
  echo "(with the merged, unapplied migrations)"
fi
fp() { q "select md5(pg_get_functiondef('public.zella_run_scheduled_job(text)'::regprocedure)) || ',' || md5(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure))"; }
as_user() { # user id, sql -> runs as that signed in user (two step sign in done), prints the result or the error
  local out; out=$("${P[@]}" -d $DB -c "begin; select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', 'aal2')::text, true); set local role authenticated; $2; commit;" 2>&1)
  if grep -q ERROR <<< "$out"; then grep -m1 ERROR <<< "$out"; else tail -1 <<< "$out"; fi; }
before=$(fp)

# 1. the gap
g=$(q "select public.zella_run_scheduled_job('zella_post_weekly_platform_report') || ',' || (position('zella_post_weekly_platform_report' in pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)) > 0)
       || ',' || (to_regprocedure('public.zella_admin_weekly_reports(integer)') is null)")
[ "$g" = "not_allowed,false,true" ] && ok "before: there is no weekly platform report (job not allowed, not in the weekly list, nothing to read)" || bad "gap: $g"

# 2. applies, twice
"${P[@]}" -d $DB -f "$FILE" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$FILE" 2>&1 | tail -3; exit 1; }
after=$(fp)
"${P[@]}" -d $DB -f "$FILE" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(fp)" = "$after" ] && ok "the second apply changes nothing" || bad "second apply changed a function"
w=$(q "select (length(d) - length(replace(d, 'zella_post_weekly_platform_report', ''))) / length('zella_post_weekly_platform_report') from (select pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure) d) x")
[ "$w" = "1" ] && ok "it is in the weekly list once" || bad "weekly list count $w"

# 3. test data: the week of Mon 2 Nov to Sun 8 Nov 2026 (UTC), reported on Mon 9 Nov 2026 08:00 UTC
IN="'2026-11-04 12:00+00'"; OUT="'2026-11-10 12:00+00'"; EARLY="'2026-11-01 23:00+00'"
q "insert into auth.users (id, email, email_confirmed_at) values
     ('f7000000-0000-0000-0000-000000000001', 'owner@zella.test', now()), ('f7000000-0000-0000-0000-000000000002', 'super@zella.test', now()),
     ('f7000000-0000-0000-0000-000000000003', 'readonly@zella.test', now()), ('f7000000-0000-0000-0000-000000000004', 'owner@biz.test', now());
   insert into public.platform_admins (user_id, role, is_active) values ('f7000000-0000-0000-0000-000000000001', 'zella_owner', true),
     ('f7000000-0000-0000-0000-000000000002', 'super_admin', true), ('f7000000-0000-0000-0000-000000000003', 'read_only_admin', true)
   on conflict (user_id) do update set role = excluded.role, is_active = true;
   update public.platform_admins set is_active = false where user_id::text not like 'f7000000%';
   insert into auth.mfa_factors (id, user_id, factor_type, status) select gen_random_uuid(), id, 'totp', 'verified' from auth.users where id::text like 'f700000%'" > /dev/null || { bad "test people"; exit 1; }
base=$(q "select public.zella_platform_weekly_summary('2026-11-02 00:00+00', '2026-11-09 00:00+00')")   # whatever the copy already has
B1=$(q "insert into public.businesses (name, industry_id, onboarding_status, is_active, created_at) select 'Week Live', id, 'active', true, $IN from public.industries limit 1 returning id" | head -1)
B2=$(q "insert into public.businesses (name, industry_id, onboarding_status, is_active, created_at) select 'Week Setup', id, 'started', false, $OUT from public.industries limit 1 returning id" | head -1)
q "insert into public.business_members (business_id, user_id, role, status) values ('$B1', 'f7000000-0000-0000-0000-000000000004', 'owner', 'active');
   insert into public.calls (business_id, direction, status, from_number, created_at) values ('$B1', 'inbound', 'completed', '+15550100001', $IN), ('$B1', 'inbound', 'missed', '+15550100002', $IN),
     ('$B1', 'outbound', 'completed', '+15550100003', $IN), ('$B1', 'inbound', 'missed', '+15550100004', $OUT), ('$B1', 'inbound', 'completed', '+15550100005', $EARLY);
   insert into public.sms_messages (business_id, direction, status, created_at) values ('$B1', 'outbound', 'sent', $IN), ('$B1', 'outbound', 'delivered', $IN),
     ('$B1', 'outbound', 'dry_run', $IN), ('$B1', 'outbound', 'blocked', $IN), ('$B1', 'inbound', 'received', $IN), ('$B1', 'outbound', 'sent', $OUT);
   insert into public.support_tickets (business_id, subject, status, created_at) values ('$B1', 'Week ticket', 'open', $IN), ('$B1', 'Old ticket', 'resolved', $EARLY);
   insert into public.automations (business_id, name, trigger_type, status) values ('$B1', 'Week reminders', 'appointment_reminder', 'active');
   insert into public.automation_runs (automation_id, business_id, status, created_at) select id, '$B1', 'failed', $IN from public.automations where business_id = '$B1';
   insert into public.automation_runs (automation_id, business_id, status, created_at) select id, '$B1', 'completed', $IN from public.automations where business_id = '$B1';
   insert into public.automation_runs (automation_id, business_id, status, created_at) select id, '$B1', 'failed', $OUT from public.automations where business_id = '$B1';
   select public.zella_platform_alert('scheduler_failed', 'Test alert', 'Test only', 'urgent', null, 'zrep_test')" > /dev/null || { bad "test data"; exit 1; }
d=$(q "with a as (select '$base'::jsonb b), n as (select public.zella_platform_weekly_summary('2026-11-02 00:00+00', '2026-11-09 00:00+00') x)
       select string_agg(k || '=' || ((n.x ->> k)::int - (a.b ->> k)::int), ',' order by k collate \"C\") from a, n,
       unnest(array['new_businesses','live_businesses','calls','missed_calls','texts_sent','texts_received','open_alerts','urgent_alerts','tickets_opened','tickets_open','failed_automations']) k")
[ "$d" = "calls=3,failed_automations=1,live_businesses=1,missed_calls=1,new_businesses=1,open_alerts=1,texts_received=1,texts_sent=2,tickets_open=1,tickets_opened=1,urgent_alerts=1" ] \
  && ok "the week's figures count the test rows in the week only (test mode and blocked texts not counted)" || bad "figures: $d"

# 4. twice in a week: one report, one alert
r1=$(q "select public.zella_post_weekly_platform_report('2026-11-09 08:00+00')"); r2=$(q "select public.zella_post_weekly_platform_report('2026-11-11 15:00+00')")
n=$(q "select count(*) || ',' || min(period_start) || ',' || min(period_end) from public.platform_report_runs")
a=$(q "select count(*) from public.platform_alerts where kind = 'weekly_report'")
[ "$r1,$r2,$n,$a" = "1,0,1,2026-11-02,2026-11-08,1" ] && ok "running twice in a week makes one report (2 to 8 Nov) and one alert" || bad "twice: $r1,$r2,$n,$a"
s=$(q "select (summary ->> 'calls')::int - ('$base'::jsonb ->> 'calls')::int from public.platform_report_runs where period_start = '2026-11-02'")
[ "$s" = "3" ] && ok "the saved report has the week's figures" || bad "saved calls $s"
det=$(q "select title || ' | ' || detail || ' | ' || severity from public.platform_alerts where kind = 'weekly_report'")
[[ "$det" == "The weekly platform report is ready | Week of November 2 to November 8, 2026. Read it in Settings, Analytics and reporting, Reporting configuration. | info" ]] \
  && ok "the alert says where to read it, with no figure" || bad "alert: $det"
[[ "$det" != *-* ]] && ok "the alert has no dash or hyphen" || bad "dash in alert"

# 5. through the real job runner and the weekly group (this week, now())
j=$(q "select public.zella_run_scheduled_job('zella_post_weekly_platform_report')"); g=$(q "select public.zella_run_schedule_group('weekly') ->> 'zella_post_weekly_platform_report'")
c=$(q "select count(*) from public.platform_report_runs where period_start = (date_trunc('week', now() at time zone 'UTC'))::date - 7")
[ "$j,$g,$c" = "ok,ok,1" ] && ok "the job runner allows it and the weekly group runs it; still one report for the week" || bad "runner: $j,$g,$c"

# 6. two runs at once make one report
asleep() { local i; for i in $(seq 1 100); do [ "$(q "select count(*) from pg_stat_activity where application_name = '$1' and wait_event = 'PgSleep'")" = "1" ] && return 0; sleep 0.1; done; return 1; }
PGAPPNAME=zrep_first "${P[@]}" -d $DB -c "begin; select public.zella_post_weekly_platform_report('2026-10-27 08:00+00'); select pg_sleep(3); commit;" > /dev/null 2>&1 & bg=$!
if asleep zrep_first; then
  o=$(q "select public.zella_post_weekly_platform_report('2026-10-28 09:00+00')"); wait $bg; rc=$?
  c=$(q "select count(*) from public.platform_report_runs where period_start = '2026-10-19'")
  [ "$rc,$o,$c" = "0,0,1" ] && ok "two runs at once make one report" || bad "overlap: $rc,$o,$c"
else wait $bg; bad "overlap: the first run never held its row"; fi

# 7. a new week resolves the earlier weeks' alerts: only the latest stays open (the run above for an older week did not
#    resolve the newer ones)
o=$(q "select count(*) from public.platform_alerts where kind = 'weekly_report' and status = 'open'")
[ "$o" = "2" ] && ok "a run for an older week leaves newer weeks' alerts open" || bad "older week resolved newer alerts: $o open"
q "select public.zella_post_weekly_platform_report('2026-11-23 08:00+00')" > /dev/null
o=$(q "select count(*) || ',' || max(dedupe_key) from public.platform_alerts where kind = 'weekly_report' and status = 'open'")
[ "$o" = "1,2026-11-16" ] && ok "only the latest report's alert stays open" || bad "open report alerts: $o"

# 8. the email digest: nothing while email is off; the report alert once email is live
q "insert into public.platform_settings (key, value) values ('email_live', 'false'::jsonb), ('email_from_address', '\"\"'::jsonb) on conflict (key) do update set value = excluded.value" > /dev/null
e=$(q "select jsonb_array_length(public.zella_claim_admin_alert_email(50) -> 'alerts')")
[ "$e" = "0" ] && ok "while email is off the digest claims nothing" || bad "digest while off: $e"
q "update public.platform_settings set value = 'true'::jsonb where key = 'email_live'; update public.platform_settings set value = '\"alerts@zella.test\"'::jsonb where key = 'email_from_address'" > /dev/null
e=$(q "select count(*) from jsonb_array_elements(public.zella_claim_admin_alert_email(50) -> 'alerts') x where x ->> 'kind' = 'weekly_report'")
[ "$e" = "1" ] && ok "once email is live the digest carries the report alert (the latest one only)" || bad "digest while live: $e"
q "update public.platform_settings set value = 'false'::jsonb where key = 'email_live'" > /dev/null

# 9. permissions
R="select jsonb_array_length(public.zella_admin_weekly_reports(12) -> 'reports')"
o=$(as_user f7000000-0000-0000-0000-000000000001 "$R"); s=$(as_user f7000000-0000-0000-0000-000000000002 "$R")
[ "$o" -ge 4 ] && [ "$s" = "$o" ] && ok "the Zella Voice owner and a super admin read the reports ($o)" || bad "owner $o, super $s"
r=$(as_user f7000000-0000-0000-0000-000000000003 "$R")
[[ "$r" == *NOT_ALLOWED* ]] && ok "a read only admin can't, by default" || bad "read only: $r"
q "insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'reports.view')" > /dev/null
r=$(as_user f7000000-0000-0000-0000-000000000003 "$R")
[ "$r" = "$o" ] && ok "once the owner grants reports.view to read only admins, they can" || bad "read only with reports.view: $r"
q "delete from public.platform_role_permissions where role = 'read_only_admin' and permission = 'reports.view'" > /dev/null
r=$(as_user f7000000-0000-0000-0000-000000000004 "$R")
[[ "$r" == *NOT_ALLOWED* ]] && ok "a business owner can't" || bad "business owner: $r"
r=$("${P[@]}" -d $DB -c "begin; set local role anon; $R; commit;" 2>&1 | tail -1)
[[ "$r" == *"permission denied"* ]] && ok "anonymous requests can't" || bad "anon: $r"
r=$(as_user f7000000-0000-0000-0000-000000000001 "select count(*) from public.platform_report_runs")
[[ "$r" == *"permission denied"* ]] && ok "no one reads the table directly, not even the owner" || bad "table: $r"
r=$(as_user f7000000-0000-0000-0000-000000000001 "select public.zella_post_weekly_platform_report()")
[[ "$r" == *"permission denied"* ]] && ok "signed in people can't run the job or build a summary" || bad "job: $r"
sc=$(as_user f7000000-0000-0000-0000-000000000001 "select (x -> 'schedule' ->> 'job_on') || ',' || (x -> 'schedule' ->> 'email_live') || ',' || coalesce(x -> 'schedule' ->> 'next_run_at', 'none') from public.zella_admin_weekly_reports(12) x")
[ "$sc" = "false,false,none" ] && ok "the schedule says the weekly job is off, email is off, no next run" || bad "schedule: $sc"

# the schedule once the owner switches the weekly job on (made and removed again here, in the test copy only)
if q "select cron.schedule('zella_jobs_weekly', '0 8 * * 1', \$c\$select public.zella_run_schedule_group('weekly')\$c\$)" > /dev/null 2>&1; then
  sc=$(as_user f7000000-0000-0000-0000-000000000001 "select (x -> 'schedule' ->> 'job_on') || ',' || (extract(isodow from (x -> 'schedule' ->> 'next_run_at')::timestamptz at time zone 'UTC'))::int || ',' ||
        to_char((x -> 'schedule' ->> 'next_run_at')::timestamptz at time zone 'UTC', 'HH24:MI') || ',' || ((x -> 'schedule' ->> 'next_run_at')::timestamptz > now()) || ',' ||
        ((x -> 'schedule' ->> 'next_run_at')::timestamptz <= now() + interval '7 days') from public.zella_admin_weekly_reports(12) x")
  q "select cron.unschedule('zella_jobs_weekly')" > /dev/null
  [ "$sc" = "true,1,08:00,true,true" ] && ok "with the weekly job on, the next run is the coming Monday at 08:00 UTC" || bad "schedule on: $sc"
else bad "could not make the weekly job in the test copy"; fi

# 10. rollback, twice
"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores both functions exactly" || bad "fingerprints after rollback: $(fp) vs $before"
x=$(q "select (to_regclass('public.platform_report_runs') is null) || ',' || (to_regprocedure('public.zella_admin_weekly_reports(integer)') is null) || ',' ||
       (select count(*) from public.platform_alerts where kind = 'weekly_report' and status <> 'resolved') || ',' || (select count(*) from public.zella_function_archive where migration = 'zella_weekly_platform_report')")
[ "$x" = "true,true,0,0" ] && ok "the table and functions are gone, report alerts resolved, archive cleared" || bad "after rollback: $x"
"${P[@]}" -d $DB -f "$FILE" > /dev/null 2>&1 && [ "$(fp)" = "$after" ] && ok "applies again after the rollback, to the same versions" || bad "reapply"

# 11. a later change to the weekly list survives the rollback; only the report's entry is removed
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure), 'declare j text;', 'declare j text; /* zrep later change */'); end \$\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
k=$(q "select (position('zrep later change' in d) > 0) || ',' || (position('zella_post_weekly_platform_report' in d) = 0) from (select pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure) d) x")
[ "$k" = "true,true" ] && [[ "$out" == *"kept later changes"* ]] && ok "a later change to the weekly list stays; only the report's entry goes" || bad "later change: $k / $out"
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure), ' /* zrep later change */', ''); end \$\$" > /dev/null
[ "$(fp)" = "$before" ] && ok "(and without it the function is the original again)" || bad "cleanup"

# 12. drift: an unknown version stops the file, and nothing is made
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_run_scheduled_job(text)'::regprocedure), 'begin
  if p_job', 'begin
  -- someone else
  if p_job'); end \$\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$FILE" 2>&1)
x=$(q "select (to_regclass('public.platform_report_runs') is null) || ',' || (position('zella_post_weekly_platform_report' in pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)) = 0)")
[[ "$out" == *"VERSION_MISMATCH"* ]] && [ "$x" = "true,true" ] && ok "a version that isn't production's stops the file and changes nothing" || bad "drift: $x / $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
