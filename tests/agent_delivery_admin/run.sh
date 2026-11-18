#!/usr/bin/env bash
# sql/zella_agent_delivery_admin.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, a platform admin can't read a business's deliveries (zella_assistant_delivery_status is members
# only: the gap); applies, and applies again; the 7 day counts are right with 1,500 deliveries in the window (past one
# 1,000 row page) and older ones left out; the last outcome, the last problems (jsonb), the version served last and the
# published version with its sync error; a business with no deliveries reads empty, not zero rows missing; the drawer
# lists newest first, keeps the limit between 1 and 100, shortens the call id and returns the problems; an admin with
# businesses.view and server code may read; a role without it, a business owner and anonymous are refused; more than
# 1000 ids or none are refused; an unknown business is not found; rollback (twice) removes exactly what was added and
# refuses a changed function; applies again; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_agent_delivery_admin}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
as() { local c
  case "$1" in
    service) c="set local request.jwt.claims = '{\"role\":\"service_role\"}'; set local role service_role;";;
    anon) c="set local request.jwt.claims = '{\"role\":\"anon\"}'; set local role anon;";;
    *) c="set local request.jwt.claims = '{\"role\":\"authenticated\",\"sub\":\"$1\",\"aal\":\"aal2\"}'; set local role authenticated;";;
  esac
  "${P[@]}" -d $DB -c "begin; $c $2; commit;" 2>&1; }
OWNER=a0000000-0000-0000-0000-0000000000c1; RO=a0000000-0000-0000-0000-0000000000c2; MEMBER=a0000000-0000-0000-0000-0000000000c4
B1=f1000000-0000-0000-0000-000000000001; B2=f1000000-0000-0000-0000-000000000002; B3=f1000000-0000-0000-0000-000000000003
IDS="array['$B1','$B2','$B3']::uuid[]"
fp() { q "select string_agg(p.oid::regprocedure::text, ',' order by 1) from pg_proc p where p.proname in ('zella_admin_agent_deliveries_summary', 'zella_admin_agent_deliveries')"; }

v=$(as "$OWNER" "select public.zella_assistant_delivery_status('$B1')"); [[ "$v" == *NOT_ALLOWED* ]] && ok "before: a Zella Voice owner can't read a business's deliveries (members only: the gap)" || bad "before: $v"
[ -z "$(fp)" ] && ok "before: no admin delivery readers" || bad "before: $(fp)"
"${P[@]}" -d $DB -f "$REPO/sql/zella_agent_delivery_admin.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_agent_delivery_admin.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_agent_delivery_admin.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

row() { as service "select concat_ws('|', coalesce(last_outcome, '-'), served_7d, not_ready_7d, unknown_number_7d, forwarded_usage_7d, coalesce(last_problems ->> 0, '-'), coalesce(served_version::text, '-'), coalesce(published_version::text, '-'), coalesce(published_sync_status, '-'), coalesce(published_sync_error, '-')) from public.zella_admin_agent_deliveries_summary(array['$1'::uuid])"; }
v=$(row $B1); [ "$v" = 'not_ready|1000|400|60|40|Test problem: opening hours missing|1|2|failed|Test sync error' ] \
  && ok "7 day counts are exact over 1,500 deliveries (past one page), the 300 older ones are left out; last outcome, problems, served and published versions" || bad "summary: $v"
v=$(row $B2); [ "$v" = '-|0|0|0|0|-|-|-|-|-' ] && ok "a business with no deliveries reads empty with zero counts" || bad "empty: $v"
v=$(row $B3); [ "$v" = 'unknown_number|0|0|1|0|-|-|-|-|-' ] && ok "a business with only an unknown number delivery" || bad "unknown: $v"
v=$(as service "select count(*) from public.zella_admin_agent_deliveries_summary($IDS)"); [ "$v" = 3 ] && ok "one row per business asked for" || bad "rows $v"

d() { as service "select $1 from (select public.zella_admin_agent_deliveries('$B1', $2) j) x"; }
v=$(d "jsonb_array_length(j -> 'deliveries') || '|' || (j ->> 'limit')" 25); [ "$v" = "25|25" ] && ok "the drawer returns 25 by default" || bad "drawer default $v"
v=$(d "jsonb_array_length(j -> 'deliveries') || '|' || (j ->> 'limit')" 1000); [ "$v" = "100|100" ] && ok "at most 100" || bad "drawer max $v"
v=$(d "jsonb_array_length(j -> 'deliveries') || '|' || (j ->> 'limit')" 0); [ "$v" = "1|1" ] && ok "at least 1" || bad "drawer min $v"
v=$(d "(j -> 'deliveries' -> 0 ->> 'outcome') || '|' || (j -> 'deliveries' -> 0 ->> 'call') || '|' || (j -> 'deliveries' -> 0 -> 'problems' ->> 1)" 5)
[ "$v" = "not_ready|…001400|Test call 1400" ] && ok "newest first, the call id shortened, the problems returned" || bad "drawer row $v"
v=$(as service "with x as (select e ->> 'at' a, row_number() over () n from jsonb_array_elements(public.zella_admin_agent_deliveries('$B1', 100) -> 'deliveries') e) select bool_and(x.a >= y.a) from x join x y on y.n = x.n + 1")
[ "$v" = t ] && ok "the drawer is ordered newest first throughout" || bad "order $v"
v=$(as service "select public.zella_admin_agent_deliveries('00000000-0000-0000-0000-000000000000')"); [[ "$v" == *BUSINESS_NOT_FOUND* ]] && ok "an unknown business is not found" || bad "unknown $v"

v=$(as "$OWNER" "select count(*) from public.zella_admin_agent_deliveries_summary($IDS)"); [ "$v" = 3 ] && ok "a Zella Voice owner may read the summary" || bad "owner $v"
v=$(as "$RO" "select count(*) from public.zella_admin_agent_deliveries_summary($IDS)"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a read only admin without businesses.view is refused" || bad "read only $v"
v=$(as "$RO" "select public.zella_admin_agent_deliveries('$B1')"); [[ "$v" == *NOT_ALLOWED* ]] && ok "and can't open the drawer" || bad "read only drawer $v"
q "insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null
v=$(as "$RO" "select count(*) from public.zella_admin_agent_deliveries_summary($IDS)"); [ "$v" = 3 ] && ok "with businesses.view granted it may" || bad "granted $v"
v=$(as "$RO" "select jsonb_array_length(public.zella_admin_agent_deliveries('$B1', 3) -> 'deliveries')"); [ "$v" = 3 ] && ok "and may open the drawer" || bad "granted drawer $v"
q "delete from public.platform_role_permissions where role = 'read_only_admin' and permission = 'businesses.view'" > /dev/null
v=$(as "$MEMBER" "select public.zella_admin_agent_deliveries('$B1')"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a business owner is refused, even for their own business" || bad "member $v"
v=$(as "$MEMBER" "select count(*) from public.zella_admin_agent_deliveries_summary($IDS)"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a business owner can't read the summary" || bad "member summary $v"
v=$(as anon "select public.zella_admin_agent_deliveries('$B1')"); [[ "$v" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon $v"
v=$(as anon "select count(*) from public.zella_admin_agent_deliveries_summary($IDS)"); [[ "$v" == *"permission denied"* ]] && ok "anonymous can't read the summary" || bad "anon summary $v"
v=$(as service "select count(*) from public.zella_admin_agent_deliveries_summary(array(select gen_random_uuid() from generate_series(1, 1001)))"); [[ "$v" == *TOO_MANY_BUSINESSES* ]] && ok "more than 1000 ids are refused" || bad "too many $v"
v=$(as service "select count(*) from public.zella_admin_agent_deliveries_summary(null)"); [[ "$v" == *BUSINESS_IDS_REQUIRED* ]] && ok "no list is refused" || bad "null $v"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_agent_delivery_admin_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_agent_delivery_admin_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ -z "$(fp)" ] && ok "rollback removes exactly the two functions" || bad "after rollback: $(fp)"
"${P[@]}" -d $DB -f "$REPO/sql/zella_agent_delivery_admin.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_agent_deliveries(p_business_id uuid, p_limit integer default 25) returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
defs() { q "select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p where p.proname in ('zella_admin_agent_deliveries_summary', 'zella_admin_agent_deliveries')"; }
before=$(defs)
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_agent_delivery_admin_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && [ "$(defs | tr ',' '\n' | wc -l)" = 2 ] && [ "$(defs)" = "$before" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_agent_delivery_admin.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
