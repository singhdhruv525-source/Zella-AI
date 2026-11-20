#!/usr/bin/env bash
# sql/zella_recording_policy.sql on an ISOLATED copy of the production schema (never production). Test people only; no
# call is placed and voice-rules is not touched. Checks: before, there is no recording switch (the gap); applies (after
# zella_number_orders.sql, whose helpers it uses), and applies again; legal approval starts off and the disclosure
# empty; recording is off for every business; switching a business on is refused until a Zella Voice owner records the
# legal answer with a disclosure line, by the function and by a trigger for any other writer; the two settings can't
# be changed any other way, even by the server; withdrawing approval switches every business off; every change is
# audited; signed in people and anonymous can't call the functions or read the table; the rollback (twice) removes it,
# refusing while anything would be lost or a function changed; applies again; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlg_recording_policy}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_retry_event_safe; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
"${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" > /dev/null 2>&1 || { bad "zella_number_orders"; exit 1; }
OWNER=e3000000-0000-0000-0000-000000000001; OPS=e3000000-0000-0000-0000-000000000002; RO=e3000000-0000-0000-0000-000000000003
MEMBER=e3000000-0000-0000-0000-000000000004; SUPER=e3000000-0000-0000-0000-000000000005; BIZ=e3000000-0000-0000-0000-0000000000b1
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@rec.test', now()), ('$OPS', 'ops@rec.test', now()),
     ('$RO', 'readonly@rec.test', now()), ('$MEMBER', 'member@rec.test', now()), ('$SUPER', 'super@rec.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$OPS', 'platform_operations'), ('$RO', 'read_only_admin'), ('$SUPER', 'super_admin');
   insert into public.platform_role_permissions (role, permission) values ('platform_operations', 'businesses.manage'), ('platform_operations', 'businesses.view'),
     ('read_only_admin', 'businesses.view') on conflict do nothing;
   insert into public.businesses (id, name) values ('$BIZ', 'Recording Test Business')" > /dev/null || exit 1
srv() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "set role service_role" -c "$1" 2>&1 | head -1; }
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
eff() { srv "select public.zella_recording_effective('$BIZ')"; }
pset() { srv "select public.zella_recording_policy_set('$1', '$BIZ', $2, '$3') ->> '${4:-recording_on}'"; }
legal() { srv "select public.zella_recording_legal_set('$1', $2, '$3', '$4') ->> '${5:-legal_approved}'"; }

v=$(q "select to_regclass('public.business_recording_policies') is null and not exists (select 1 from public.platform_settings where key like 'recording%')")
[ "$v" = "t" ] && ok "before: there is no recording switch or legal state anywhere (the gap)" || bad "before: $v"
"${P[@]}" -d $DB -f "$REPO/sql/zella_recording_policy.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_recording_policy.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_recording_policy.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(q "select string_agg(key || '=' || value::text, ',' order by key) from public.platform_settings where key like 'recording%'")" = 'recording_disclosure_text="",recording_legal_approved=false' ] \
  && ok "legal approval starts off and the disclosure line empty" || bad "defaults"
[ "$(eff)" = "f" ] && ok "recording is off for a business with no policy" || bad "effective default"

[[ "$(pset $OPS true "Owner asked for it")" == *RECORDING_NOT_APPROVED* ]] && ok "switching a business on is refused before legal review" || bad "on before legal"
[ "$(pset $OPS false "Confirming off")" = "false" ] && ok "switching it off is always allowed" || bad "off"
[[ "$(pset $RO false "Not mine")" == *NOT_ALLOWED* ]] && ok "a role without businesses.manage can't change it" || bad "ro set"
[[ "$(pset $MEMBER false "Not mine")" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't change it" || bad "member set"
[[ "$(pset $OPS false "x")" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "reason"
[[ "$(srv "select public.zella_recording_policy_set('$OPS', 'e3000000-0000-0000-0000-0000000000ff', false, 'Wrong one')")" == *BUSINESS_NOT_FOUND* ]] && ok "an unknown business is refused" || bad "unknown business"
[[ "$(srv "update public.business_recording_policies set recording_on = true")" == *RECORDING_NOT_APPROVED* ]] && ok "even the server can't write recording on directly (trigger)" || bad "direct write"
[[ "$(srv "update public.platform_settings set value = 'true' where key = 'recording_legal_approved'")" == *RECORDING_SETTING_OWNER_ONLY* ]] && ok "the legal setting can't be changed directly, even by the server" || bad "direct legal"
[[ "$(q "delete from public.platform_settings where key = 'recording_disclosure_text'" 2>&1)" == *RECORDING_SETTING_OWNER_ONLY* ]] && ok "nor deleted" || bad "direct delete"
q "update public.platform_settings set value = '120' where key = 'retention_days'; insert into public.platform_settings (key, value) values ('retention_days', '120') on conflict (key) do update set value = excluded.value" > /dev/null \
  && ok "other platform settings still save as before" || bad "other settings blocked"

[[ "$(legal $OPS true "Recording may be used" "Counsel approved")" == *OWNER_REQUIRED* ]] && ok "only a Zella Voice owner records the legal answer" || bad "ops legal"
[[ "$(legal $SUPER true "Recording may be used" "Counsel approved")" == *OWNER_REQUIRED* ]] && ok "a super admin can't either" || bad "super legal"
[[ "$(legal $OWNER true "" "Counsel approved")" == *DISCLOSURE_REQUIRED* ]] && ok "approval needs the caller disclosure line" || bad "no disclosure"
[[ "$(legal $OWNER true "This call may be recorded." "x")" == *REASON_REQUIRED* ]] && ok "the owner gives a reason" || bad "legal reason"
[ "$(legal $OWNER true "This call may be recorded." "Counsel approved on 1 Dec")" = "true" ] && ok "the owner records legal approval and the disclosure line" || bad "approve"
[ "$(pset $OPS true "Owner asked for it")" = "true" ] && [ "$(eff)" = "t" ] && ok "then a business can be switched on, and recording is in effect for it" || bad "on after legal"
v=$(srv "select (public.zella_recording_policies('$RO') -> 'businesses' -> 0 ->> 'effective') || '/' || (public.zella_recording_policies('$RO') ->> 'live_call_path')")
[ "$v" = "true/false" ] && ok "the list says which businesses would record, and that the live call path doesn't read it yet" || bad "list: $v"
[ "$(legal $OWNER false "This call may be recorded." "Counsel withdrew it" businesses_switched_off)" = "1" ] && ok "withdrawing approval switches every business off" || bad "withdraw"
[ "$(eff)/$(q "select recording_on from public.business_recording_policies")" = "f/f" ] && ok "and recording is off again, stored and in effect" || bad "after withdraw"
v=$(q "select string_agg(action || ':' || user_id, ',' order by created_at, action) from public.audit_logs where action in ('business.recording_policy_set', 'platform.recording_legal_set')")
[ "$v" = "business.recording_policy_set:$OPS,platform.recording_legal_set:$OWNER,business.recording_policy_set:$OPS,platform.recording_legal_set:$OWNER" ] \
  && ok "every change is audited with who made it" || bad "audit: $v"

for fn in "zella_recording_policy_set('$OPS', '$BIZ', false, 'Direct')" "zella_recording_legal_set('$OWNER', false, '', 'Direct')" "zella_recording_policies('$OWNER')" "zella_recording_effective('$BIZ')"; do
  [[ "$(as $OWNER "select public.$fn")" == *"permission denied"* ]] || { bad "a signed in owner could call $fn directly"; continue; }
  [[ "$(as "" "select public.$fn")" == *"permission denied"* ]] || bad "anonymous could call $fn"
done && ok "signed in people (even an owner) and anonymous can't call the functions directly"
[[ "$(as $OWNER "select count(*) from public.business_recording_policies")" == *"permission denied"* ]] && ok "the table can't be read directly" || bad "table readable"

out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_recording_policy_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses while the disclosure line is recorded" || bad "rollback with text: $out"
[ "$(legal $OWNER false "" "Clearing for the rollback")" = "false" ] || bad "clear"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_number_orders_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the number orders rollback refuses while this file uses its helpers" || bad "orders rollback: $out"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_recording_policy_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_recording_policy_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
v=$(q "select to_regclass('public.business_recording_policies') is not null and exists (select 1 from public.business_recording_policies) and not exists (select 1 from pg_trigger where tgname = 'zella_recording_policy_guard') and to_regprocedure('public.zella_recording_effective(uuid)') is null and not exists (select 1 from public.platform_settings where key like 'recording%') and not exists (select 1 from pg_trigger where tgname = 'zella_recording_setting_guard')")
[ "$v" = "t" ] && ok "rollback removes the guards, functions and settings, and keeps every business policy" || bad "leftovers"
[ "$(q "select count(*) from public.audit_logs where action in ('business.recording_policy_set', 'platform.recording_legal_set')")" = "5" ] && ok "the audit trail survives the rollback" || bad "audit lost"
"${P[@]}" -d $DB -f "$REPO/sql/zella_recording_policy.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_recording_effective(p_business uuid) returns boolean language sql as \$f\$ select true \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_recording_policy_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_recording_policy.sql" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
