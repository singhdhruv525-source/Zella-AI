#!/usr/bin/env bash
# sql/zella_voice_admin.sql on an ISOLATED copy of the production schema (never production). Test data only; nothing is
# sent. Checks: before, refusals are not counted, the overview has no auth mode or switches, and the alerts list kinds
# nothing raises (the gaps); applies, and applies again; the counter: one row per hour and combination under a flood,
# header names only (values and unknown names dropped), unknown types and reasons folded, never a payload column, only
# the service role may record; the overview keeps every key and adds the auth mode, refusals and read only switches
# (calls live, enforcement for calls, the call jobs with their state); the alerts: the missed call rate at 5 or more
# inbound calls with 25% or more missed (not at 4, not at 24%), a refusal alert in the last hour only, and raised voice
# alerts appear while unrelated kinds don't; the wrong role, a business member and anonymous are refused; the rollback
# (twice) restores both functions exactly and removes the counter; applies again; a changed function stops the files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_voiceadmin}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_job_intent; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e5000000-0000-0000-0000-000000000001; SUP=e5000000-0000-0000-0000-000000000002; MEMBER=e5000000-0000-0000-0000-000000000003
B5=e5100000-0000-0000-0000-000000000005; B4=e5100000-0000-0000-0000-000000000004; B24=e5100000-0000-0000-0000-000000000024
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@voice.test', now()), ('$SUP', 'support@voice.test', now()), ('$MEMBER', 'member@voice.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$SUP', 'support_admin');
   insert into public.platform_role_permissions (role, permission) values ('support_admin', 'support.manage') on conflict do nothing;
   insert into public.businesses (id, name, industry_id) select x, n, (select id from public.industries limit 1) from (values ('$B5'::uuid, 'Five Calls'), ('$B4'::uuid, 'Four Calls'), ('$B24'::uuid, 'Under A Quarter')) v(x, n);
   insert into public.business_members (business_id, user_id, role, status) values ('$B5', '$MEMBER', 'owner', 'active');
   delete from public.platform_alerts; delete from cron.job where jobname like 'zella%';
   insert into cron.job (jobname, schedule, command, active) values ('zella_jobs_every5', '*/5 * * * *', 'select 1', true), ('zella_jobs_hourly', '0 * * * *', 'select 1', false);
   insert into public.platform_settings (key, value) values ('vapi_auth_mode', '\"bearer\"'), ('usage_enforcement', '{\"calls\": true, \"messages\": false}') on conflict (key) do update set value = excluded.value" > /dev/null || exit 1
# inbound calls: Five Calls 5 with 2 missed (40%); Four Calls 4 with 4 missed (below the minimum); Under A Quarter 25 with 6 missed (24%)
calls() { q "insert into public.calls (business_id, direction, status, from_number, created_at) select '$1', 'inbound', case when g <= $3 then 'missed' else 'completed' end, '+1555010' || lpad(g::text, 4, '0'), now() - interval '1 hour' from generate_series(1, $2) g" > /dev/null; }
calls $B5 5 2; calls $B4 4 4; calls $B24 25 6
q "insert into public.calls (business_id, direction, status, from_number, created_at) select '$B4', 'inbound', 'missed', '+15550200' || g, now() - interval '30 hours' from generate_series(1, 3) g" > /dev/null
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
OV="public.zella_admin_voice_overview(null, null)"
fp() { q "select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.proname) || (select string_agg(grantee || privilege_type, ',' order by routine_name, grantee) from information_schema.routine_privileges where routine_name in ('zella_admin_voice_overview', 'zella_admin_voice_alerts')) from pg_proc p where p.proname in ('zella_admin_voice_overview', 'zella_admin_voice_alerts') and p.pronamespace = 'public'::regnamespace"; }
keys() { as $OWNER "select string_agg(k, ',' order by k) from jsonb_object_keys($OV) k"; }
before=$(fp); keys_before=$(keys)
q "insert into public.platform_alerts (kind, title, severity) values ('repeated_transfer_failures', 'Transfers failing', 'warning'), ('agent_sync_failed', 'Agent sync failed', 'warning'), ('payment_failed', 'Not a voice alert', 'warning')" > /dev/null
kinds() { as $OWNER "select coalesce(string_agg(x ->> 'kind', ',' order by x ->> 'kind'), '') from jsonb_array_elements(public.zella_admin_voice_alerts()) x"; }
v=$(kinds); w=$(as $OWNER "select $OV ? 'switches'")
[[ "$v" != *repeated_transfer_failures* && "$v" != *missed_call_rate* && "$w" = "f" && "$(q "select to_regclass('public.vapi_refusals') is null")" = "t" ]] && ok "before: raised voice alerts don't show, no missed call alert, no switches, refusals not counted (the gaps)" || bad "before: $v $w"

"${P[@]}" -d $DB -f "$REPO/sql/zella_voice_admin.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_voice_admin.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_voice_admin.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

rec() { "${P[@]}" -d $DB -c "set role service_role" -c "select public.zella_vapi_refusal_record($1)" > /dev/null 2>&1; }
for i in $(seq 1 200); do rec "'status-update', array['x-signature', 'x-timestamp'], 'bad_signature'"; done
rec "'end-of-call-report', array['authorization'], 'unauthenticated'"
rec "'made-up-type-' || 'x', array['x-evil-header', 'Authorization', 'authorization'], 'weird reason'"
v=$(q "select count(*) || ':' || sum(count) from public.vapi_refusals")
[ "$v" = "3:202" ] && ok "a flood of 200 refusals is one counted row (3 rows for 3 kinds, 202 in all)" || bad "flood: $v"
v=$(q "select message_type || '|' || reason || '|' || header_names from public.vapi_refusals where count = 1 and message_type = 'other'")
[ "$v" = "other|other|authorization" ] && ok "unknown types, reasons and header names are folded or dropped" || bad "fold: $v"
v=$(q "select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_name = 'vapi_refusals'")
[ "$v" = "count,header_names,hour,last_at,message_type,reason" ] && ok "only counts and names are stored: no value, payload or content column" || bad "columns: $v"
[[ "$(as $OWNER "select public.zella_vapi_refusal_record('status-update', '{}', 'expired')")" == *"permission denied"* ]] && ok "an admin can't record a refusal (service role only)" || bad "admin records"
[[ "$(as "" "select public.zella_vapi_refusal_record('status-update', '{}', 'expired')")" == *"permission denied"* ]] && ok "anonymous can't record a refusal" || bad "anon records"
[[ "$(as $OWNER "select count(*) from public.vapi_refusals")" == *"permission denied"* ]] && ok "the counter can't be read directly" || bad "table readable"

v=$(keys); miss=""; for k in ${keys_before//,/ }; do [[ ",$v," == *",$k,"* ]] || miss="$miss $k"; done
[ -z "$miss" ] && ok "the overview keeps every key it returned" || bad "keys missing:$miss"
v=$(as $OWNER "select ($OV ->> 'auth_mode') || '|' || ($OV ->> 'refusals_24h') || '|' || (($OV ->> 'last_refusal_at') is not null)")
[ "$v" = "bearer|202|true" ] && ok "the overview shows the auth mode, refusals in 24 hours and the last one" || bad "overview: $v"
v=$(as $OWNER "select (s ->> 'calls_live') || '|' || (s ->> 'enforcement_calls') || '|' || (s ->> 'vapi_auth_mode') from (select $OV -> 'switches' s) x")
[ "$v" = "false|true|bearer" ] && ok "the switches show calls live, enforcement for calls and the auth mode, as set" || bad "switches: $v"
v=$(as $OWNER "select string_agg((j ->> 'name') || '=' || (j ->> 'active') || ':' || coalesce(j ->> 'intended', '-') || ':' || (j -> 'runs' ->> 0), ',' order by j ->> 'name') from jsonb_array_elements($OV -> 'switches' -> 'jobs') j")
[ "$v" = "zella_jobs_every15=false:off:zella_reconcile_call_usage,zella_jobs_every5=true:off:zella_sweep_stuck_calls,zella_jobs_hourly=false:off:zella_verify_calls" ] && ok "the call jobs show on or off, their intent and what they run" || bad "jobs: $v"

ma() { as $OWNER "select coalesce(string_agg(x ->> 'detail', ';'), '') from jsonb_array_elements(public.zella_admin_voice_alerts()) x where x ->> 'kind' = 'missed_call_rate'"; }
v=$(ma)
[[ "$v" == *"Five Calls: 2 of 5 inbound calls missed"* ]] && ok "5 inbound calls with 40% missed raise the missed call alert" || bad "five: $v"
[[ "$v" != *"Four Calls"* ]] && ok "4 inbound calls don't, even all missed (and calls older than 24 hours don't count)" || bad "four: $v"
[[ "$v" != *"Under A Quarter"* ]] && ok "24% missed doesn't" || bad "24%: $v"
q "update public.calls set status = 'missed' where business_id = '$B24' and status = 'completed' and id = (select id from public.calls where business_id = '$B24' and status = 'completed' limit 1)" > /dev/null
[[ "$(ma)" == *"Under A Quarter: 7 of 25"* ]] && ok "28% missed does" || bad "28%: $(ma)"
v=$(as $OWNER "select (x ->> 'severity') || '|' || (x -> 'filter' ->> 'status') || '|' || (x -> 'filter' ->> 'direction') || '|' || (x -> 'filter' ->> 'days') || '|' || (x ->> 'business_id') from jsonb_array_elements(public.zella_admin_voice_alerts()) x where x ->> 'kind' = 'missed_call_rate' and x ->> 'business_id' = '$B5'")
[ "$v" = "warning|missed|inbound|1|$B5" ] && ok "the alert is a warning linked to that business's missed inbound calls" || bad "filter: $v"
v=$(kinds)
[[ "$v" == *vapi_refused* && "$v" == *repeated_transfer_failures* && "$v" == *agent_sync_failed* && "$v" != *payment_failed* ]] && ok "raised voice alerts and the refusal alert show; other kinds don't" || bad "kinds: $v"
v=$(as $OWNER "select string_agg((x ->> 'title') || ' ' || (x ->> 'detail'), ' ') from jsonb_array_elements(public.zella_admin_voice_alerts()) x where x ->> 'kind' in ('vapi_refused', 'missed_call_rate')")
[[ -n "$v" && "$v" != *-* ]] && ok "the computed alerts read without dashes (status update, not status-update)" || bad "dash: $v"
q "update public.vapi_refusals set last_at = now() - interval '2 hours', hour = date_trunc('hour', now() - interval '2 hours')" > /dev/null
[[ "$(kinds)" != *vapi_refused* ]] && ok "no refusal in the last hour, no refusal alert" || bad "old refusal alerts"
for who in $SUP $MEMBER; do
  for fn in "$OV" "public.zella_admin_voice_alerts()"; do [[ "$(as $who "select $fn")" == *NOT_ALLOWED* ]] || bad "$who reads $fn"; done
done
[[ "$(as "" "select public.zella_admin_voice_alerts()")" == *"permission denied"* ]] && ok "the wrong role, a business member and anonymous are refused" || bad "anon reads"

KEPT=$(q "select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) || '|' || count(*) from public.vapi_refusals t")   # before the rollback
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_voice_admin_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_voice_admin_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores both functions and their grants exactly" || bad "after rollback: $(fp)"
[ "$(q "select to_regprocedure('public.zella_vapi_refusal_record(text,text[],text)') is null")" = "t" ] && ok "rollback removes the record function" || bad "leftovers"
[ "$(q "select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) || '|' || count(*) from public.vapi_refusals t")" = "$KEPT" ] && [ "$(q "select relrowsecurity from pg_class where oid = 'public.vapi_refusals'::regclass")" = t ] \
  && ok "rollback keeps the refusal counts exactly, still server only" || bad "vapi_refusals after rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_voice_admin.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_voice_alerts() returns jsonb language sql stable as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_voice_admin_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_voice_admin.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
