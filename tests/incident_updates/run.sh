#!/usr/bin/env bash
# sql/zella_incident_updates.sql on an ISOLATED copy of the production schema (never production), after
# sql/zella_admin_permissions.sql (merged, not applied). Test people and businesses only.
# Checks: the gap before (a second incident for the same problem opens and notifies everyone again); applies, and
# applies again; SIMILAR_OPEN is returned and nothing is opened unless forced; updates are internal and tell owners
# again only when asked; only support.manage may post or edit; admins who can see incidents read updates, business
# members and anonymous don't; edits are audited and only for open incidents; rollback refuses while updates exist,
# then runs twice; reapply; a changed function stops the file and the rollback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zla_incidents}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_incident_updates.sql"; RB="$REPO/sql/rollback/zella_incident_updates_rollback.sql"
# the production chain this builds on: the writing clean up (applied) and the admin permissions (merged, not applied;
# it is what puts zella_admin_can('support.manage') into zella_open_incident). Both are safe to run again.
for f in zella_writing_cleanup zella_admin_permissions; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "could not load sql/$f.sql"; exit 1; }
done
q "select position('zella_admin_can' in pg_get_functiondef('public.zella_open_incident(text,text)'::regprocedure)) > 0" | grep -q t || { echo "zella_open_incident is not the admin permissions version"; exit 1; }
as() {   # as <sub> <sql>: authenticated with a code (aal2); prints R=<result or error>
  local claims; claims=$(printf '{"role":"%s","aal":"aal2"%s}' "${3:-authenticated}" "${1:+,\"sub\":\"$1\"}")
  q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', '$claims', true); execute 'set local role ${3:-authenticated}';
     begin execute '$2' into r; raise notice 'R=%', r; exception when others then raise notice 'R=%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p'
}
SA=f5000000-0000-0000-0000-000000000001; RO=f5000000-0000-0000-0000-000000000002; OW=f5000000-0000-0000-0000-000000000003
B1=f5000000-0000-0000-0000-0000000000b1
q "insert into auth.users (id, email, email_confirmed_at) select u, 'inc' || right(u::text, 1) || '@incidents.test', now() from unnest(array['$SA','$RO','$OW']::uuid[]) u" > /dev/null || exit 1
q "insert into public.profiles (id) select u from unnest(array['$SA','$RO','$OW']::uuid[]) u on conflict do nothing" > /dev/null || exit 1
q "insert into public.platform_admins (user_id, role, is_active) values ('$SA', 'support_admin', true), ('$RO', 'read_only_admin', true)" > /dev/null || exit 1
q "insert into public.platform_role_permissions (role, permission) values ('support_admin', 'support.manage'), ('support_admin', 'businesses.view'), ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null || exit 1
q "insert into public.businesses (id, name) values ('$B1', 'Incident Test')" > /dev/null || exit 1
q "insert into public.business_members (business_id, user_id, role) values ('$B1', '$OW', 'owner')" > /dev/null || exit 1
notes() { q "select count(*) from public.staff_notifications where business_id = '$B1' and kind like 'incident%'"; }

before=$(notes)
as "$SA" "select public.zella_open_incident(''Texts delayed'', null)::text" > /dev/null
as "$SA" "select public.zella_open_incident(''texts delayed!'', null)::text" > /dev/null
[ "$(q "select count(*) from public.platform_incidents where lower(title) like 'texts delayed%'")" = "2" ] && ok "before: the same problem opens twice and owners are told twice (the gap; $before to $(notes) notices)" || bad "before"
q "delete from public.platform_incidents" > /dev/null

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

r=$(as "$SA" "select public.zella_open_incident_checked(''Text messages delayed'', ''Carrier slow'', false) ->> ''opened''")
[ "$r" = "true" ] && ok "a support admin opens an incident" || bad "open: $r"
INC=$(q "select id from public.platform_incidents where title = 'Text messages delayed'")
n0=$(notes)
r=$(as "$SA" "select public.zella_open_incident_checked(''TEXT MESSAGES delayed!!'', null, false)::text")
[[ "$r" == *"SIMILAR_OPEN"* && "$r" == *"$INC"* ]] && [ "$(q "select count(*) from public.platform_incidents")" = "1" ] && ok "a second one for the same problem returns SIMILAR_OPEN with the open incident, and opens nothing" || bad "similar: $r"
r=$(as "$SA" "select public.zella_open_incident_checked(''Text messages delayed in Texas'', null, false) ->> ''code''")
[ "$r" = "SIMILAR_OPEN" ] && ok "a longer title for the same problem is caught too" || bad "contains: $r"
r=$(as "$SA" "select public.zella_open_incident_checked(''Text messages delayed in Texas'', null, true) ->> ''opened''")
[ "$r" = "true" ] && ok "Open anyway (force) opens it" || bad "force: $r"
r=$(as "$SA" "select public.zella_open_incident_checked(''Calendar sync stopped'', null, false) ->> ''opened''")
[ "$r" = "true" ] && ok "a different problem opens without a warning" || bad "different: $r"
r=$(as "$RO" "select public.zella_open_incident_checked(''Anything else'', null, true)::text")
[[ "$r" == *"NOT_ALLOWED"* ]] && ok "a read only admin can't open one" || bad "ro open: $r"

n1=$(notes)
r=$(as "$SA" "select public.zella_incident_post_update(''$INC'', ''Carrier confirmed the delay'', false) ->> ''notified_businesses''")
[ "$r" = "0" ] && [ "$(notes)" = "$n1" ] && ok "an update is internal by default: no owner is told" || bad "quiet update: $r $(notes) $n1"
r=$(as "$SA" "select public.zella_incident_post_update(''$INC'', ''Messages are flowing again slowly'', true) ->> ''notified_businesses''")
[ "${r:-0}" -gt 0 ] && [ "$(notes)" -gt "$n1" ] && ok "with Tell affected businesses, owners are told ($r businesses)" || bad "notify: $r"
[ "$(q "select count(*) from public.audit_logs where action = 'platform.incident_updated' and entity_id = '$INC'")" = "2" ] && ok "each update is audited" || bad "update audit"
r=$(as "$RO" "select public.zella_incident_post_update(''$INC'', ''hello there'', false)::text")
[[ "$r" == *"NOT_ALLOWED"* ]] && ok "a read only admin can't post updates" || bad "ro post: $r"
r=$(as "$SA" "select public.zella_incident_post_update(''$INC'', ''x'', false)::text")
[[ "$r" == *"BAD_INPUT"* ]] && ok "a too short update is refused" || bad "short: $r"
r=$(as "$RO" "select count(*)::text from public.platform_incident_updates")
[ "$r" = "2" ] && ok "a read only admin reads the timeline" || bad "ro read: $r"
r=$(as "$OW" "select count(*)::text from public.platform_incident_updates")
[ "$r" = "0" ] && ok "a business owner reads none of it" || bad "owner read: $r"
r=$(as "" "select count(*)::text from public.platform_incident_updates" anon)
[[ "$r" == *"permission denied"* ]] && ok "anonymous reads nothing" || bad "anon: $r"
r=$(as "$SA" "insert into public.platform_incident_updates (incident_id, body) values (''$INC'', ''direct write'') returning id::text")
[[ "$r" == *"permission denied"* ]] && ok "nobody writes the timeline directly" || bad "direct: $r"

n2=$(notes)
r=$(as "$SA" "select public.zella_incident_edit(''$INC'', ''Text messages delayed (one carrier)'', ''Only one carrier'')::text")
[ "$r" = "true" ] && [ "$(q "select title from public.platform_incidents where id = '$INC'")" = "Text messages delayed (one carrier)" ] && [ "$(notes)" = "$n2" ] && ok "an open incident is edited without telling anyone" || bad "edit: $r"
[ "$(q "select old_data ->> 'title' from public.audit_logs where action = 'platform.incident_edited' and entity_id = '$INC'")" = "Text messages delayed" ] && ok "the edit is audited with the old and new text" || bad "edit audit"
r=$(as "$RO" "select public.zella_incident_edit(''$INC'', ''Changed by read only'', null)::text")
[[ "$r" == *"NOT_ALLOWED"* ]] && ok "a read only admin can't edit" || bad "ro edit: $r"
q "update public.platform_incidents set status = 'resolved', resolved_at = now() where id = '$INC'" > /dev/null
r=$(as "$SA" "select public.zella_incident_edit(''$INC'', ''Too late'', null)::text")
[[ "$r" == *"NOT_OPEN"* ]] && ok "a resolved incident can't be edited" || bad "resolved edit: $r"

out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && ok "the rollback refuses while updates exist" || bad "rollback with updates: $out"
o1=$(PGOPTIONS="-c zella.drop_incident_updates=yes" "${P[@]}" -d $DB -f "$RB" 2>&1); e1=$?; o2=$("${P[@]}" -d $DB -f "$RB" 2>&1); e2=$?
[ $e1 -eq 0 ] && [ $e2 -eq 0 ] && ok "with the flag, the rollback runs, and again once nothing is left" || bad "rollback: $o1 $o2"
[ -z "$(q "select coalesce(to_regclass('public.platform_incident_updates')::text, '') || coalesce(to_regprocedure('public.zella_open_incident_checked(text,text,boolean)')::text, '')")" ] && ok "rollback removes the table and functions" || bad "left over"
[ -n "$(q "select to_regprocedure('public.zella_open_incident(text,text)')")" ] && ok "zella_open_incident itself is untouched" || bad "open_incident gone"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_incident_edit(p_incident uuid, p_title text, p_detail text default null) returns boolean language sql security definer set search_path = '' as \$f\$ select true \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file (VERSION_MISMATCH)" || bad "drift: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && ok "and the rollback (DRIFT)" || bad "rollback drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
