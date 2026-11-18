#!/usr/bin/env bash
# sql/zella_connection_state.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, the old rule (integrations rows with provider telnyx or vapi) calls a business with no number
# connected and a business with a linked number not connected (the gap); applies, and applies again; each fixture
# business gets the expected phone, Vapi link, answering, calendar, leads, problems and live; answering is separate
# from live; email reads not tracked; the counts are the same definition summed; an admin with businesses.view and
# server code may read it, a role without it, a business owner and anonymous are refused, the private definition can't
# be called directly; more than 1000 ids or none are refused; rollback (twice) removes exactly what was added and
# refuses a changed function; applies again; a function changed after applying stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_connection_state}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
# production's chain: the writing cleanup, then the merged migrations that are built but not applied yet
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }
done
"${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
claims() { # run $2 as $1: service | anon | <user id>
  case "$1" in
    service) echo "begin; set local request.jwt.claims = '{\"role\":\"service_role\"}'; set local role service_role; $2; commit;";;
    anon) echo "begin; set local request.jwt.claims = '{\"role\":\"anon\"}'; set local role anon; $2; commit;";;
    *) echo "begin; set local request.jwt.claims = '{\"role\":\"authenticated\",\"sub\":\"$1\",\"aal\":\"aal2\"}'; set local role authenticated; $2; commit;";;
  esac; }
as() { "${P[@]}" -d $DB -c "$(claims "$1" "$2")" 2>&1; }
IDS="array[$(seq -s, 1 8 | sed -E "s/([0-9])/'e1000000-0000-0000-0000-00000000000\1'/g")]::uuid[]"   # literal ids: callers can't read businesses
OWNER=a0000000-0000-0000-0000-0000000000c1; RO=a0000000-0000-0000-0000-0000000000c2; MEMBER=a0000000-0000-0000-0000-0000000000c4
fp() { q "select string_agg(p.oid::regprocedure::text, ',' order by 1) from pg_proc p where p.proname in ('zella_connection_state', 'zella_business_connections', 'zella_connection_counts')"; }

# --- before: the old rule -----------------------------------------------------------------------------------------
old() { q "select exists (select 1 from public.integrations where business_id = 'e1000000-0000-0000-0000-00000000000$1' and lower(provider) = 'telnyx' and status = 'active')"; }
[ "$(old 7)" = t ] && [ "$(old 1)" = f ] && ok "before: the old rule calls a business with no number connected and one with a linked number not connected (the gap)" || bad "old rule $(old 7) $(old 1)"
[ -z "$(fp)" ] && ok "before: no connection functions" || bad "before: $(fp)"

"${P[@]}" -d $DB -f "$REPO/sql/zella_connection_state.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_connection_state.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_connection_state.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

row() { as service "select concat_ws('|', business_state, receptionist, phone, vapi_linked, answering, calendar, leads, array_to_string(lead_sources, ','), email, problems, live) from public.zella_business_connections(array['e1000000-0000-0000-0000-00000000000$1'::uuid])"; }
expect() { local got; got=$(row "$1"); [ "$got" = "$2" ] && ok "business $1: $3" || bad "business $1: $3 (got $got)"; }
expect 1 "active|active|t|t|t|t|t|website|not_tracked|0|t" "linked number, receptionist on, served yesterday: live and answering, calendar and website form"
expect 2 "active|active|t|f|f|f|f||not_tracked|0|f" "a number without its Vapi id is a phone but not linked, so not live; a disabled form isn't a lead source"
expect 3 "active|paused|t|t|f|f|f||not_tracked|0|f" "receptionist paused: not live"
expect 4 "suspended|active|t|t|f|f|f||not_tracked|0|f" "suspended: not live"
expect 5 "setup|active|t|t|f|f|f||not_tracked|0|f" "setup not finished: not live"
expect 6 "active|active|t|t|f|f|t|meta|not_tracked|0|t" "live but last served 10 days ago: live, not answering (answering is its own state)"
expect 7 "active|active|f|f|f|f|f||not_tracked|0|f" "integrations rows alone are not a phone or a Vapi link"
expect 8 "active|active|f|f|f|f|f||not_tracked|3|f" "a paused number isn't a phone; three connections need attention"
v=$(as service "select count(*) from public.zella_business_connections($IDS)"); [ "$v" = 8 ] && ok "one row per business asked for" || bad "rows $v"
v=$(as service "select concat_ws('|', c ->> 'live', c ->> 'answering', c ->> 'phone', c ->> 'vapi_linked', c ->> 'problems', c ->> 'email') from (select public.zella_connection_counts() c) x")
w=$(as service "select concat_ws('|', count(*) filter (where live), count(*) filter (where answering), count(*) filter (where phone), count(*) filter (where vapi_linked), sum(problems), 'not_tracked') from public.zella_business_connections(array(select id from public.businesses))")
[ "$v" = "$w" ] && ok "the counts are the same definition summed over every business ($v)" || bad "counts $v vs $w"

# --- who may read it ------------------------------------------------------------------------------------------------
v=$(as "$OWNER" "select count(*) from public.zella_business_connections($IDS)"); [ "$v" = 8 ] && ok "a Zella Voice owner may read it" || bad "owner $v"
v=$(as "$RO" "select count(*) from public.zella_business_connections($IDS)"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a read only admin without businesses.view is refused" || bad "read only $v"
q "insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null
v=$(as "$RO" "select count(*) from public.zella_business_connections($IDS)"); [ "$v" = 8 ] && ok "with businesses.view granted it may" || bad "read only granted $v"
v=$(as "$RO" "select public.zella_connection_counts() ->> 'live'"); [ "$v" = 2 ] && ok "and may read the counts" || bad "counts granted $v"
v=$(as "$MEMBER" "select count(*) from public.zella_business_connections(array['e1000000-0000-0000-0000-000000000001'::uuid])"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a business owner is refused, even for their own business" || bad "member $v"
v=$(as "$MEMBER" "select public.zella_connection_counts()"); [[ "$v" == *NOT_ALLOWED* ]] && ok "a business owner can't read the counts" || bad "member counts $v"
v=$(as anon "select count(*) from public.zella_business_connections($IDS)"); [[ "$v" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon $v"
v=$(as anon "select public.zella_connection_counts()"); [[ "$v" == *"permission denied"* ]] && ok "anonymous can't read the counts" || bad "anon counts $v"
v=$(as "$OWNER" "select count(*) from public.zella_connection_state(null)"); [[ "$v" == *"permission denied"* ]] && ok "the private definition can't be called directly" || bad "direct $v"
v=$(as service "select count(*) from public.zella_business_connections(array(select gen_random_uuid() from generate_series(1, 1001)))"); [[ "$v" == *TOO_MANY_BUSINESSES* ]] && ok "more than 1000 ids are refused" || bad "too many $v"
v=$(as service "select count(*) from public.zella_business_connections(null)"); [[ "$v" == *BUSINESS_IDS_REQUIRED* ]] && ok "no list is refused (use the counts)" || bad "null $v"
q "delete from public.platform_role_permissions where role = 'read_only_admin' and permission = 'businesses.view'" > /dev/null

# --- rollback and drift ---------------------------------------------------------------------------------------------
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_connection_state_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_connection_state_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ -z "$(fp)" ] && ok "rollback removes exactly the three functions" || bad "after rollback: $(fp)"
"${P[@]}" -d $DB -f "$REPO/sql/zella_connection_state.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_connection_counts() returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_connection_state_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && [ -n "$(fp)" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_connection_state.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
