#!/usr/bin/env bash
# sql/zella_admin_routing_missing.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, there is no list across businesses (the gap); applies, and applies again; transfer read from
# escalation_rules.transfer_number and transfer_to.phone, fallback from fallback_number; a business with transfers off
# isn't flagged for a transfer number; fully routed businesses, cancelled businesses and businesses without a
# receptionist are left out; suspended ones are listed and marked; paging (limit, offset, total, limits clamped);
# the wrong role, a business member and anonymous are refused; the rollback (twice) removes the function; applies
# again; a changed function stops both files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_routingmissing}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e6000000-0000-0000-0000-000000000001; SUP=e6000000-0000-0000-0000-000000000002; MEMBER=e6000000-0000-0000-0000-000000000003
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@routing.test', now()), ('$SUP', 'support@routing.test', now()), ('$MEMBER', 'member@routing.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$SUP', 'support_admin');
   insert into public.platform_role_permissions (role, permission) values ('support_admin', 'support.manage') on conflict do nothing;
   -- the template's own businesses get full routing, so only the test ones below can be listed
   update public.ai_agent_configs set escalation_rules = coalesce(escalation_rules, '{}'::jsonb) || '{\"transfer_number\": \"+15550000001\", \"fallback_number\": \"+15550000002\"}'" > /dev/null || exit 1
mk() { # name, escalation rules json, cancelled, suspended, has receptionist
  local id; id=$(q "insert into public.businesses (name, industry_id, cancelled_at, suspended_at) select '$1', (select id from public.industries limit 1), $3, $4 returning id" | head -1)
  if [ "$5" = "yes" ]; then
    local ag; ag=$(q "insert into public.ai_agents (business_id, name, agent_type, is_default) values ('$id', 'Receptionist', 'receptionist', true) returning id" | head -1)
    q "insert into public.ai_agent_configs (agent_id, business_id, escalation_rules) values ('$ag', '$id', '$2'::jsonb)" > /dev/null
  fi
  echo "$id"; }
A=$(mk "Alpha no routing" '{}' null null yes)
B=$(mk "Bravo transfer only" '{"transfer_number": "+15551110001"}' null null yes)
C=$(mk "Charlie fallback only" '{"fallback_number": "+15551110002"}' null null yes)
Dd=$(mk "Delta transfer_to phone and fallback" '{"transfer_to": {"phone": "+15551110003"}, "fallback_number": "+15551110004"}' null null yes)
E=$(mk "Echo transfers off" '{"transfer_enabled": false, "fallback_number": "+15551110005"}' null null yes)
F=$(mk "Foxtrot cancelled" '{}' "now()" null yes)
G=$(mk "Golf suspended" '{}' null "now()" yes)
H=$(mk "Hotel no receptionist" '{}' null null no)
q "insert into public.business_members (business_id, user_id, role, status) values ('$A', '$MEMBER', 'owner', 'active')" > /dev/null
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
list() { as $OWNER "select string_agg((r ->> 'name') || ':' || (r ->> 'missing_transfer')::boolean::int || (r ->> 'missing_fallback')::boolean::int || (r ->> 'suspended')::boolean::int, ',' order by r ->> 'name') from jsonb_array_elements(public.zella_admin_routing_missing($1, $2) -> 'rows') r"; }

[ "$(q "select to_regprocedure('public.zella_admin_routing_missing(integer,integer)') is null")" = "t" ] && ok "before: no list of businesses without routing (the gap)" || bad "before"
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_routing_missing.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_admin_routing_missing.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_routing_missing.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
v=$(list 25 0)
[ "$v" = "Alpha no routing:110,Bravo transfer only:010,Charlie fallback only:100,Golf suspended:111" ] && ok "missing transfer and fallback read from escalation_rules; transfer_to.phone counts; transfers off isn't flagged; routed, cancelled and no receptionist left out; suspended marked" || bad "list: $v"
v=$(as $OWNER "select (x ->> 'total') || ':' || jsonb_array_length(x -> 'rows') from public.zella_admin_routing_missing(2, 0) x"); [ "$v" = "4:2" ] && ok "paging: the total with the first page" || bad "page 1: $v"
[ "$(list 2 2)" = "Charlie fallback only:100,Golf suspended:111" ] && ok "paging: the second page" || bad "page 2: $(list 2 2)"
v=$(as $OWNER "select (x ->> 'limit') || ':' || (x ->> 'offset') from public.zella_admin_routing_missing(5000, -3) x"); [ "$v" = "100:0" ] && ok "limits are clamped (1 to 100 rows, offset 0 or more)" || bad "clamp: $v"
v=$(as $OWNER "select r ->> 'business_id' from jsonb_array_elements(public.zella_admin_routing_missing(25, 0) -> 'rows') r where r ->> 'name' = 'Alpha no routing'"); [ "$v" = "$A" ] && ok "each row carries the business id to open its routing form" || bad "id: $v"
[[ "$(as $SUP "select public.zella_admin_routing_missing(25, 0)")" == *NOT_ALLOWED* ]] && ok "a role without businesses.view is refused" || bad "support allowed"
[[ "$(as $MEMBER "select public.zella_admin_routing_missing(25, 0)")" == *NOT_ALLOWED* ]] && ok "a business member is refused" || bad "member allowed"
[[ "$(as "" "select public.zella_admin_routing_missing(25, 0)")" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon allowed"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_routing_missing_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_routing_missing_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(q "select to_regprocedure('public.zella_admin_routing_missing(integer,integer)') is null")" = "t" ] && ok "rollback removes the function" || bad "leftover"
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_routing_missing.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_routing_missing(p_limit integer default 25, p_offset integer default 0) returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_routing_missing_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_admin_routing_missing.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a different function of the same name stops the file" || bad "drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
