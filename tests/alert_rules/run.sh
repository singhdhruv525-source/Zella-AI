#!/usr/bin/env bash
# sql/zella_alert_rules.sql on ISOLATED copies of the production schema (never production). Test data only; nothing is
# sent. Checks: before, nothing can switch off, lower or space out an alert (the gap); applies, and applies again; the
# signature, parameter names, defaults and grants of zella_platform_alert are unchanged, so every one of its callers
# resolves as before; with no rules every caller shape (tests/alert_rules/callers.sql, including three real callers
# and the n8n named call) leaves exactly the same rows as production's function; a rule switches a kind off, changes
# its severity and respects its repeat interval; an alert raised as urgent and a protected kind ignore all three; the
# save refuses to switch off or lower a protected kind, validates every field, is audited and needs platform.configure
# (the wrong role, a business member and anonymous are refused); the list shows rules and protected kinds; the
# rollback (twice) restores the function exactly and removes the rules; applies again; a changed function stops both.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_alertrules}; REF=${REF:-zld_alertrules_ref}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$REF" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
for d in $DB $REF; do "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $d" -c "create database $d template $TEMPLATE" > /dev/null || exit 1; done
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
for d in $DB $REF; do
  for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
    "${P[@]}" -d $d -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f on $d"; exit 1; }
  done
done
OWNER=e7000000-0000-0000-0000-000000000001; RO=e7000000-0000-0000-0000-000000000002; MEMBER=e7000000-0000-0000-0000-000000000003
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@alerts.test', now()), ('$RO', 'ro@alerts.test', now()), ('$MEMBER', 'member@alerts.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$RO', 'read_only_admin');
   insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null || exit 1
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
SIG="'public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)'::regprocedure"
sig() { q "select pg_get_function_arguments($SIG) || ' -> ' || pg_get_function_result($SIG) || ' ' || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_platform_alert')"; }
fp() { q "select md5(pg_get_functiondef($SIG))"; }
snap() { "${P[@]}" -d $1 -c "select string_agg(concat_ws('|', kind, title, length(detail), left(detail, 40), severity, (business_id is not null), dedupe_key, meta::text, occurrences, status), E'\n' order by kind, dedupe_key, title) from public.platform_alerts"; }
callers=$(q "select count(*) from pg_proc where prosrc like '%zella_platform_alert(%' and proname <> 'zella_platform_alert'")
sig0=$(sig); before=$(fp)
q "select public.zella_platform_alert('t_gap', 'Before', null, 'warning')" > /dev/null
[ "$(q "select to_regclass('public.platform_alert_rules') is null")" = "t" ] && ok "before: no rules table, nothing can switch off, lower or space out an alert (the gap)" || bad "before"

"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(sig)" = "$sig0" ] && ok "same signature, parameter names, defaults, result and grants: all $callers database callers and the n8n named call resolve as before" || bad "signature: $(sig)"
v=$(q "select count(*) filter (where ok) || '/' || count(*) from (select p.proname, (select true from (select plpgsql_validator(p.oid)) x) ok from pg_proc p join pg_language l on l.oid = p.prolang
       where l.lanname = 'plpgsql' and p.prosrc like '%zella_platform_alert(%' and p.proname <> 'zella_platform_alert') y")
[ "$v" = "$callers/$callers" ] && ok "every plpgsql caller still validates against the new function ($v)" || bad "callers validate: $v"
"${P[@]}" -d $REF -f "$HERE/callers.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$HERE/callers.sql" > /dev/null 2>&1 && ok "every caller shape runs on both" || bad "callers.sql failed"
a=$(snap $REF); b=$(snap $DB)
[ -n "$a" ] && [ "$a" = "$b" ] && ok "with no rules, every caller leaves exactly the rows production's function leaves ($(echo "$a" | wc -l) alerts)" || { bad "rows differ"; diff <(echo "$a") <(echo "$b") | head -10; }

raise() { q "select coalesce(public.zella_platform_alert('$1', 'Test', null, '$2', null, '${3:-}')::text, 'null')"; }
sev() { q "select string_agg(severity || ':' || occurrences, ',') from public.platform_alerts where kind = '$1' and status <> 'resolved'"; }
q "delete from public.platform_alerts; insert into public.platform_alert_rules (kind, enabled) values ('t_off', false), ('service_incident', false);
   insert into public.platform_alert_rules (kind, severity) values ('t_up', 'urgent'), ('t_down', 'info');
   insert into public.platform_alert_rules (kind, repeat_minutes) values ('t_repeat', 60)" > /dev/null
[ "$(raise t_off warning)" = "null" ] && [ -z "$(sev t_off)" ] && ok "a kind switched off raises nothing" || bad "off: $(sev t_off)"
[ "$(raise t_off urgent)" != "null" ] && [ "$(sev t_off)" = "urgent:1" ] && ok "an alert raised as urgent is never switched off" || bad "urgent off: $(sev t_off)"
raise t_up warning > /dev/null; [ "$(sev t_up)" = "urgent:1" ] && ok "a rule can raise the severity" || bad "up: $(sev t_up)"
raise t_down warning > /dev/null; [ "$(sev t_down)" = "info:1" ] && ok "a rule can lower a warning" || bad "down: $(sev t_down)"
raise t_down urgent x > /dev/null; [ "$(q "select severity from public.platform_alerts where kind = 't_down' and dedupe_key = 'x'")" = "urgent" ] && ok "an alert raised as urgent is never lowered" || bad "urgent lowered"
raise service_incident warning > /dev/null; [ "$(sev service_incident)" = "warning:1" ] && ok "a protected kind ignores a rule that switches it off" || bad "protected: $(sev service_incident)"
raise t_repeat warning > /dev/null; raise t_repeat warning > /dev/null
[ "$(sev t_repeat)" = "warning:2" ] && ok "while open, repeats are counted as before" || bad "repeat open: $(sev t_repeat)"
q "update public.platform_alerts set status = 'resolved', resolved_at = now() - interval '10 minutes' where kind = 't_repeat'" > /dev/null
raise t_repeat warning > /dev/null; [ -z "$(sev t_repeat)" ] && ok "within the repeat interval after it was resolved, it isn't raised again" || bad "repeat window: $(sev t_repeat)"
q "update public.platform_alerts set resolved_at = now() - interval '61 minutes' where kind = 't_repeat'" > /dev/null
raise t_repeat warning > /dev/null; [ "$(sev t_repeat)" = "warning:1" ] && ok "after the repeat interval, it is raised again" || bad "after window: $(sev t_repeat)"
q "update public.platform_alerts set status = 'resolved', resolved_at = now() where kind = 't_repeat'" > /dev/null
raise t_repeat urgent > /dev/null; [ "$(sev t_repeat)" = "urgent:1" ] && ok "an urgent alert is never held back by the repeat interval" || bad "urgent repeat: $(sev t_repeat)"
q "delete from public.platform_alert_rules" > /dev/null

save() { as ${3:-$OWNER} "select public.zella_admin_alert_rule_save('$1', $2, 'Owner asked for this')"; }
[[ "$(save service_incident "'{\"enabled\": false}'")" == *URGENT_PROTECTED* ]] && ok "a protected kind can't be switched off" || bad "protected off saved"
[[ "$(save scheduler_failed "'{\"severity\": \"warning\"}'")" == *URGENT_PROTECTED* ]] && ok "a protected kind can't be lowered" || bad "protected lowered"
v=$(save provider_down "'{\"destination\": \"bell_and_email\", \"email_permission\": \"platform.configure\"}'")
[[ "$v" == *'"email_permission": "platform.configure"'* ]] && ok "a protected kind can be rerouted" || bad "reroute: $v"
for bad_rule in '{"severity": "loud"}' '{"destination": "sms"}' '{"repeat_minutes": 1}' '{"quiet_start": "22:00"}' '{"quiet_start": "25:99", "quiet_end": "06:00"}' '{"quiet_tz": "Mars/Base"}' '{"email_permission": "everyone"}' '{"enabled": "no"}'; do
  [[ "$(save t_x "'$bad_rule'")" == *INVALID_* ]] || bad "accepted $bad_rule"
done; ok "every field is validated"
[[ "$(save "Bad-Kind" "'{}'")" == *INVALID_KIND* ]] && ok "the kind is checked" || bad "bad kind"
v=$(save t_x "'{\"enabled\": false, \"severity\": \"info\", \"repeat_minutes\": 30, \"quiet_start\": \"22:00\", \"quiet_end\": \"07:00\", \"quiet_tz\": \"America/Chicago\"}'")
[[ "$v" == *'"enabled": false'* && "$v" == *'"quiet_tz": "America/Chicago"'* ]] && ok "an owner saves a rule" || bad "save: $v"
v=$(q "select user_id || '|' || (new_data ->> 'kind') || '|' || (new_data ->> 'reason') from public.audit_logs where action = 'alert_rule.saved' order by created_at desc limit 1")
[ "$v" = "$OWNER|t_x|Owner asked for this" ] && ok "saving is audited with the admin's id and reason" || bad "audit: $v"
[[ "$(save t_x null)" == *'"removed": true'* ]] && [ "$(q "select count(*) from public.audit_logs where action = 'alert_rule.removed'")" = "1" ] && ok "a null rule removes it, audited" || bad "remove"
[[ "$(save t_x "'{}'" $RO)" == *NOT_ALLOWED* ]] && ok "a role without platform.configure can't save" || bad "read only saved"
[[ "$(save t_x "'{}'" $MEMBER)" == *NOT_ALLOWED* ]] && ok "a business member can't save" || bad "member saved"
[[ "$(as "" "select public.zella_admin_alert_rule_save('t_x', '{}', 'nope')")" == *"permission denied"* ]] && ok "anonymous can't save" || bad "anon saved"
v=$(as $RO "select (x -> 'protected') ? 'service_incident' and jsonb_array_length(x -> 'rules') = 1 from public.zella_admin_alert_rules() x")
[ "$v" = "t" ] && ok "businesses.view lists the rules and the protected kinds" || bad "list: $v"
[[ "$(as $MEMBER "select public.zella_admin_alert_rules()")" == *NOT_ALLOWED* ]] && ok "a business member can't list them" || bad "member lists"
[[ "$(as $OWNER "select count(*) from public.platform_alert_rules")" == *"permission denied"* ]] && ok "the rules table can't be read directly" || bad "table readable"
[[ "$(as $OWNER "select public.zella_platform_alert('t', 'x')")" == *"permission denied"* ]] && ok "raising an alert stays server only" || bad "admin raises"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && [ "$(sig)" = "$sig0" ] && ok "rollback restores the function, its signature and grants exactly" || bad "after rollback: $(fp)"
[ "$(q "select to_regclass('public.platform_alert_rules') is null and to_regprocedure('public.zella_admin_alert_rule_save(text,jsonb,text)') is null")" = "t" ] && ok "rollback removes the rules and their functions" || bad "leftovers"
"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_platform_alert(p_kind text, p_title text, p_detail text default null, p_severity text default 'warning', p_business_id uuid default null, p_dedupe_key text default '', p_meta jsonb default '{}') returns uuid language sql as \$f\$ select null::uuid \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"
"${P[@]}" -d postgres -c "drop database if exists $REF" > /dev/null
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
