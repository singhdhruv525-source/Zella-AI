#!/usr/bin/env bash
# sql/zella_automations_resume_all.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, "Pause all" records only a count and there is no resume (the gap); applies, and applies again; pause
# all pauses the same automations and answers the same; "Resume all" resumes exactly those; automations paused by the
# business before the bulk pause, or changed by the business after it, stay as they are; automations paused by a
# suspension stay paused; a suspended or cancelled business is refused; other businesses are untouched; both actions
# are audited with the ids and the admin; the wrong role, a business member and anonymous are refused; a reason is
# required; the rollback (twice) restores the pause function exactly and removes the column, trigger and resume;
# applies again; a changed function stops the rollback and the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_resumeall}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e4000000-0000-0000-0000-000000000001; OPS=e4000000-0000-0000-0000-000000000002; RO=e4000000-0000-0000-0000-000000000003; MEMBER=e4000000-0000-0000-0000-000000000004
B1=e4100000-0000-0000-0000-000000000001; B2=e4100000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@resume.test', now()), ('$OPS', 'ops@resume.test', now()), ('$RO', 'ro@resume.test', now()), ('$MEMBER', 'member@resume.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$OPS', 'platform_operations'), ('$RO', 'read_only_admin');
   insert into public.platform_role_permissions (role, permission) values ('platform_operations', 'integrations.manage'), ('read_only_admin', 'businesses.view') on conflict do nothing;
   insert into public.businesses (id, name, industry_id) select x, 'Resume Test ' || n, (select id from public.industries limit 1) from (values ('$B1'::uuid, 1), ('$B2'::uuid, 2)) v(x, n);
   insert into public.business_members (business_id, user_id, role, status) values ('$B1', '$MEMBER', 'owner', 'active');
   insert into public.automations (business_id, name, trigger_type, status) values
     ('$B1', 'a1 active', 'manual', 'active'), ('$B1', 'a2 active', 'manual', 'active'), ('$B1', 'a3 active then changed by the business', 'manual', 'active'),
     ('$B1', 'a4 paused before', 'manual', 'paused'), ('$B1', 'a5 archived', 'manual', 'disabled'), ('$B2', 'b1 other business', 'manual', 'active')" > /dev/null || exit 1
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
states() { q "select string_agg(left(name, 2) || '=' || status, ',' order by name) from public.automations where business_id in ('$B1', '$B2')"; }
fp() { q "select md5(pg_get_functiondef('public.zella_admin_business_automations_pause(uuid,text)'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_admin_business_automations_pause')"; }
before=$(fp); s0=$(states)

r1=$(as $OWNER "select public.zella_admin_business_automations_pause('$B1', 'Owner asked to stop')"); p1=$(states)
v=$(q "select new_data ? 'ids' from public.audit_logs where action = 'automation.business_paused' order by created_at desc limit 1")
[ "$v" = "f" ] && [ "$(q "select to_regprocedure('public.zella_admin_business_automations_resume(uuid,text)') is null")" = "t" ] && ok "before: pause all records only a count and there is no resume (the gap)" || bad "before: $v"
q "update public.automations set status = (case name when 'a4 paused before' then 'paused' when 'a5 archived' then 'disabled' else 'active' end) where business_id in ('$B1', '$B2')" > /dev/null

"${P[@]}" -d $DB -f "$REPO/sql/zella_automations_resume_all.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_automations_resume_all.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_automations_resume_all.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(states)" = "$s0" ] && ok "applying changes no automation" || bad "apply changed: $(states)"
r2=$(as $OWNER "select public.zella_admin_business_automations_pause('$B1', 'Owner asked to stop')")
[ "$r2" = "$r1" ] && [ "$(states)" = "$p1" ] && ok "pause all pauses the same automations and answers the same" || bad "pause changed: $r1/$r2 $(states)"
v=$(q "select user_id || ':' || jsonb_array_length(new_data -> 'ids') || ':' || (new_data ->> 'paused') from public.audit_logs where action = 'automation.business_paused' order by created_at desc limit 1")
[ "$v" = "$OWNER:3:3" ] && ok "pause all audits the ids it paused, with the admin" || bad "pause audit: $v"
# the business itself resumes a3 then pauses it again after the bulk pause: it is theirs now, not the bulk pause's
q "update public.automations set status = 'active' where name like 'a3%'; update public.automations set status = 'paused' where name like 'a3%'" > /dev/null
[ "$(q "select bulk_paused_at is null from public.automations where name like 'a3%'")" = "t" ] && ok "a change by anyone else clears the bulk pause mark" || bad "mark kept"

[[ "$(as $RO "select public.zella_admin_business_automations_resume('$B1', 'try it')")" == *NOT_ALLOWED* ]] && ok "a role without integrations.manage is refused" || bad "read only allowed"
[[ "$(as $MEMBER "select public.zella_admin_business_automations_resume('$B1', 'try it')")" == *NOT_ALLOWED* ]] && ok "a business member who isn't an admin is refused" || bad "member allowed"
[[ "$(as "" "select public.zella_admin_business_automations_resume('$B1', 'try it')")" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon allowed"
[[ "$(as $OWNER "select public.zella_admin_business_automations_resume('$B1', 'x')")" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "no reason"
q "update public.businesses set suspended_at = now() where id = '$B1'" > /dev/null
[[ "$(as $OWNER "select public.zella_admin_business_automations_resume('$B1', 'try it')")" == *BUSINESS_NOT_AVAILABLE* ]] && ok "a suspended business is refused" || bad "suspended allowed"
q "update public.businesses set suspended_at = null, cancelled_at = now() where id = '$B1'" > /dev/null
[[ "$(as $OWNER "select public.zella_admin_business_automations_resume('$B1', 'try it')")" == *BUSINESS_NOT_AVAILABLE* ]] && ok "a cancelled business is refused" || bad "cancelled allowed"
q "update public.businesses set cancelled_at = null where id = '$B1'" > /dev/null
# a2 was also paused by a suspension in the meantime: suspension owns it
q "update public.automations set paused_by_suspension = true where name like 'a2%'" > /dev/null
v=$(as $OPS "select public.zella_admin_business_automations_resume('$B1', 'Owner is ready again') ->> 'resumed'")
[ "$v" = "1" ] && ok "a role holding integrations.manage resumes" || bad "resume: $v"
[ "$(states)" = "a1=active,a2=paused,a3=paused,a4=paused,a5=disabled,b1=active" ] && ok "only what pause all paused is resumed: not the business's own, not suspended, not archived, not paused before" || bad "states: $(states)"
v=$(q "select user_id || ':' || (new_data ->> 'resumed') || ':' || jsonb_array_length(new_data -> 'ids') from public.audit_logs where action = 'automation.business_resumed' order by created_at desc limit 1")
[ "$v" = "$OPS:1:1" ] && ok "resume all is audited with the ids and the admin" || bad "resume audit: $v"
v=$(as $OPS "select public.zella_admin_business_automations_resume('$B1', 'Again') ->> 'resumed'")
[ "$v" = "0" ] && ok "a second resume finds nothing left to resume" || bad "second resume: $v"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_automations_resume_all_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_automations_resume_all_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the pause function and its grants exactly" || bad "after rollback: $(fp)"
v=$(q "select count(*) from information_schema.columns where table_name = 'automations' and column_name = 'bulk_paused_at'")$(q "select to_regprocedure('public.zella_admin_business_automations_resume(uuid,text)') is null")$(q "select count(*) from pg_trigger where tgname = 'zella_automation_bulk_mark'")
[ "$v" = "0t0" ] && ok "rollback removes the column, the resume function and the trigger" || bad "leftovers: $v"
"${P[@]}" -d $DB -f "$REPO/sql/zella_automations_resume_all.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_business_automations_pause(p_business_id uuid, p_reason text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_automations_resume_all_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_automations_resume_all.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
