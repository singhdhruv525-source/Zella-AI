#!/usr/bin/env bash
# sql/zella_go_live_reads.sql on an ISOLATED copy of the production schema (never production). Test people only.
# Checks: before, nothing reports the platform email triggers (the gap); applies, and applies again; both off read
# false; one switched on reads true; a missing trigger reads null; reading never changes a trigger; the wrong role, a
# business member and anonymous are refused; the rollback (twice) removes the function; applies again; a changed
# function stops both the rollback and the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_golivereads}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e3000000-0000-0000-0000-000000000001; SUPPORT=e3000000-0000-0000-0000-000000000002; MEMBER=e3000000-0000-0000-0000-000000000003
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@golive.test', now()), ('$SUPPORT', 'support@golive.test', now()), ('$MEMBER', 'member@golive.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$SUPPORT', 'support_admin');
   insert into public.platform_role_permissions (role, permission) values ('support_admin', 'support.manage') on conflict do nothing" > /dev/null || exit 1
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
trig() { q "select string_agg(c.relname || ':' || g.tgenabled::text, ',' order by c.relname) from pg_trigger g join pg_class c on c.oid = g.tgrelid where g.tgname = 'zella_kick_platform_emails'"; }
read_() { as $OWNER "select (public.zella_admin_email_triggers() ->> 'platform_emails') || '/' || coalesce(public.zella_admin_email_triggers() ->> 'staff_notifications', 'null')"; }

[ "$(q "select to_regprocedure('public.zella_admin_email_triggers()') is null")" = "t" ] && [ "$(trig)" = "platform_emails:D,staff_notifications:D" ] && ok "before: both triggers exist, switched off, and nothing reports them (the gap)" || bad "before: $(trig)"
"${P[@]}" -d $DB -f "$REPO/sql/zella_go_live_reads.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_go_live_reads.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
t0=$(trig)
[ "$(read_)" = "false/false" ] && ok "both off read off" || bad "off: $(read_)"
q "alter table public.platform_emails enable trigger zella_kick_platform_emails" > /dev/null
[ "$(read_)" = "true/false" ] && ok "a trigger switched on reads on" || bad "on: $(read_)"
q "alter table public.platform_emails enable replica trigger zella_kick_platform_emails" > /dev/null
[ "$(read_)" = "false/false" ] && ok "a replica only trigger (doesn't fire for ordinary inserts) reads off" || bad "replica: $(read_)"
q "alter table public.platform_emails enable always trigger zella_kick_platform_emails" > /dev/null
[ "$(read_)" = "true/false" ] && ok "an always trigger reads on" || bad "always: $(read_)"
q "alter table public.platform_emails disable trigger zella_kick_platform_emails; drop trigger zella_kick_platform_emails on public.staff_notifications" > /dev/null
[ "$(read_)" = "false/null" ] && ok "a missing trigger reads null (not created), never off" || bad "missing: $(read_)"
q "create trigger zella_kick_platform_emails after insert on public.staff_notifications for each statement execute function public.zella_kick_platform_emails(); alter table public.staff_notifications disable trigger zella_kick_platform_emails" > /dev/null
read_ > /dev/null; read_ > /dev/null
[ "$(trig)" = "$t0" ] && ok "reading never changes a trigger" || bad "changed: $(trig)"
[[ "$(as $SUPPORT "select public.zella_admin_email_triggers()")" == *NOT_ALLOWED* ]] && ok "a role without businesses.view is refused" || bad "support allowed"
[[ "$(as $MEMBER "select public.zella_admin_email_triggers()")" == *NOT_ALLOWED* ]] && ok "a business member is refused" || bad "member allowed"
[[ "$(as "" "select public.zella_admin_email_triggers()")" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon allowed"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_go_live_reads_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_go_live_reads_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(q "select to_regprocedure('public.zella_admin_email_triggers()') is null")" = "t" ] && [ "$(trig)" = "$t0" ] && ok "rollback removes the function and leaves the triggers" || bad "after rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_go_live_reads.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_email_triggers() returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_go_live_reads_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_go_live_reads.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a different function of the same name stops the file" || bad "drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
