#!/usr/bin/env bash
# CFG-01 and CFG-08 on an ISOLATED copy of the production schema (never production). Test data only, nothing sent.
# Runs the real owner-provision-business code under Deno against the local stand in (tests/browser/local-backend.mjs),
# which caps every read at 1,000 rows like PostgREST's max_rows.
# Checks: the per module counts match zella_module_on for 1,101 businesses (past one page); switching a used module off
# with an empty confirmation is refused and changes nothing (the gap: before this change it went through silently);
# with the module confirmed it is switched off, zella_module_on turns false for those businesses and the audit row names
# the module and the count; an older app that sends no confirmation still works and the audit says so; an unused module
# needs no confirmation; deactivate and reactivate are audited once each, a repeat writes no row, existing businesses
# keep their modules, a new business can't be created in an inactive industry; the wrong role, a business owner and
# anonymous callers are refused.
#   tests/industry_modules/run.sh        (env: BPORT=54333 FPORT=54432 TEMPLATE=zprod3)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_industry_modules}; TEMPLATE=${TEMPLATE:-zprod3}
BPORT=${BPORT:-54333}; FPORT=${FPORT:-54432}; B=http://localhost:$BPORT
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
"${P[@]}" -d $DB -f "$REPO/sql/zella_writing_cleanup.sql" > /dev/null 2>&1 || { echo "FAIL writing cleanup"; exit 1; }
"${P[@]}" -d $DB -f "$HERE/seed.sql" > /dev/null || { echo "FAIL seed"; exit 1; }
"${P[@]}" -d $DB -c "insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }

for port in $BPORT $FPORT; do curl -s -o /dev/null --max-time 2 "http://localhost:$port/" && { echo "FAIL port $port is already in use: stop that server or set BPORT and FPORT"; exit 1; }; done
LOG=$(mktemp -d)
ZDB=$DB PORT=$BPORT ZMAX_ROWS=1000 ZTEST_PASSWORD_AAL2=1 ZFUNCTIONS="{\"owner-provision-business\":$FPORT}" node "$REPO/tests/browser/local-backend.mjs" > "$LOG/backend.log" 2>&1 &
BPID=$!
SUPABASE_URL=$B SUPABASE_ANON_KEY=sb_publishable_local_test_only ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only ZELLA_APP_URL=http://localhost:5160 \
  deno run -A --no-lock --config "$REPO/web/supabase/functions/owner-provision-business/deno.json" "$REPO/tests/browser/run-function.ts" owner-provision-business $FPORT > "$LOG/fn.log" 2>&1 &
FPID=$!
trap 'kill $BPID $FPID 2>/dev/null; rm -rf "$LOG"' EXIT
for _ in $(seq 60); do grep -q "on $FPORT" "$LOG/fn.log" 2>/dev/null && grep -q "stand-in" "$LOG/backend.log" 2>/dev/null && break; sleep 0.5; done

token() { curl -s "$B/auth/v1/token?grant_type=password" -H 'content-type: application/json' -d "{\"email\":\"$1\",\"password\":\"Test-pass-1\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
ADMIN=$(token admin@zella.test); RO=$(token readonly@zella.test); OWNER=$(token owner@glow.test); ANON=sb_publishable_local_test_only
call() { curl -s -o "$LOG/out" -w '%{http_code}' "$B/functions/v1/owner-provision-business" -H "authorization: Bearer $1" -H "apikey: $ANON" -H 'content-type: application/json' -d "$2"; }
body() { cat "$LOG/out"; }
js() { python3 -c "import sys,json; d=json.load(open('$LOG/out')); print($1)"; }

IND=$(q "select id from public.industries where slug = 'dental'")
mod() { q "select id from public.industry_modules where industry_id = '$IND' and slug = '$1'"; }
CAL=$(mod calendar); FUP=$(mod ai-follow-up); AUTO=$(mod automations)
on_count() { q "select count(*) from public.businesses b where b.industry_id = '$IND' and public.zella_module_on(b.id, '$1')"; }
audits() { q "select count(*) from public.audit_logs where entity_id = '$IND' and action = '$1'"; }
save() { # $1 = token, $2 = json of modules, $3 = extra fields
  call "$1" "{\"action\":\"industry_save\",\"industryId\":\"$IND\",\"terminology\":{},\"modules\":$2${3:-}}"; }
mods() { # every module as it is, except the ones named in $1 (comma list of ids) which are switched off
  q "select json_agg(json_build_object('id', id, 'name', name, 'description', coalesce(description, ''), 'isActive', is_active and not (id::text = any(string_to_array('$1', ','))))) from public.industry_modules where industry_id = '$IND'"; }

# --- counts -----------------------------------------------------------------------------------------------------
[ "$(on_count calendar)" = "1101" ] && ok "fixture: 1,101 Dental businesses have Calendar on (zella_module_on), past one 1,000 row page" || bad "fixture $(on_count calendar)"
s=$(call "$ADMIN" "{\"action\":\"industry_module_usage\",\"industryId\":\"$IND\"}")
[ "$s" = 200 ] && [ "$(js "d['modules']['$CAL']")" = 1101 ] && [ "$(js "d['modules']['$FUP']")" = 2 ] && [ "$(js "d['modules']['$AUTO']")" = 0 ] \
  && ok "usage counts match zella_module_on (1101, 2, 0) with reads capped at 1,000 rows; the other industry's row isn't counted" || bad "usage $s $(body)"
s=$(call "$ADMIN" '{"action":"industries_list"}')
[ "$(js "[i['businessCount'] for i in d['industries'] if i['id']=='$IND'][0]")" = 1203 ] && ok "the industry list counts all 1,203 Dental businesses (it stopped at the 1,000 row cap before)" || bad "list count $(js "[i['businessCount'] for i in d['industries'] if i['id']=='$IND'][0]")"
s=$(call "$RO" "{\"action\":\"industry_module_usage\",\"industryId\":\"$IND\"}"); [ "$s" = 200 ] && ok "a restricted role with businesses.view can read the counts" || bad "read only usage $s"
s=$(call "$OWNER" "{\"action\":\"industry_module_usage\",\"industryId\":\"$IND\"}"); [ "$s" = 403 ] && ok "a business owner (not an admin) is refused" || bad "owner usage $s"
s=$(call "$ANON" "{\"action\":\"industry_module_usage\",\"industryId\":\"$IND\"}"); [ "$s" = 401 ] && ok "anonymous is refused" || bad "anon usage $s"
s=$(call "$ADMIN" "{\"action\":\"industry_module_usage\",\"industryId\":\"00000000-0000-0000-0000-000000000000\"}"); [ "$s" = 404 ] && ok "an unknown industry reads not found" || bad "unknown $s"

# --- switching a used module off --------------------------------------------------------------------------------
s=$(save "$ADMIN" "$(mods "$CAL")" ',"confirmOff":[]')
[ "$s" = 409 ] && [[ "$(body)" == *"1101 businesses lose Calendar"* ]] && ok "switching Calendar off without confirming it is refused with '1101 businesses lose Calendar'" || bad "unconfirmed $s $(body)"
[ "$(on_count calendar)" = "1101" ] && [ "$(q "select is_active from public.industry_modules where id = '$CAL'")" = t ] && ok "the refused save changed nothing" || bad "refused save wrote"
s=$(save "$ADMIN" "$(mods "$CAL")" ",\"confirmOff\":[\"$FUP\"]"); [ "$s" = 409 ] && ok "confirming a different module doesn't count" || bad "wrong confirm $s"
s=$(save "$RO" "$(mods "$CAL")" ",\"confirmOff\":[\"$CAL\"],\"reason\":\"test\""); [ "$s" = 403 ] && ok "a role without platform.configure can't save" || bad "read only save $s"
s=$(save "$ADMIN" "$(mods "$CAL")" ",\"confirmOff\":[\"$CAL\"]"); [ "$s" = 400 ] && [ "$(q "select is_active from public.industry_modules where id = '$CAL'")" = t ] && ok "a confirmed switch off without a reason is refused and changes nothing" || bad "no reason $s"
s=$(save "$ADMIN" "$(mods "$CAL")" ",\"confirmOff\":[\"$CAL\"],\"reason\":\"Calendar retired for Dental\"")
[ "$s" = 200 ] && [ "$(on_count calendar)" = 0 ] && ok "confirmed: Calendar is off for all 1,101 businesses at once (what the page now says)" || bad "confirmed $s $(body) $(on_count calendar)"
a=$(q "select new_data -> 'modules_switched_off' -> 0 ->> 'businesses' || '|' || (new_data ->> 'reason') from public.audit_logs where entity_id = '$IND' and action = 'industry.updated' order by created_at desc limit 1")
[ "$a" = "1101|Calendar retired for Dental" ] && ok "the audit row names the module switched off, its 1,101 businesses and the reason" || bad "audit $a"
s=$(save "$ADMIN" "$(mods "$AUTO")" ',"confirmOff":[]'); [ "$s" = 200 ] && ok "a module no business uses switches off without a confirmation" || bad "unused $s $(body)"
s=$(save "$ADMIN" "$(mods "$FUP")")
[ "$s" = 200 ] && [ "$(on_count ai-follow-up)" = 0 ] && ok "an older app that sends no confirmation still works during the deploy window" || bad "legacy $s $(body)"
a=$(q "select new_data ->> 'switched_off_without_confirmation' from public.audit_logs where entity_id = '$IND' and action = 'industry.updated' order by created_at desc limit 1")
[ "$a" = true ] && ok "and its audit row says it was switched off without the confirmation" || bad "legacy audit $a"

# --- deactivate and reactivate ----------------------------------------------------------------------------------
q "update public.industry_modules set is_active = true where id = '$CAL'" > /dev/null
before=$(on_count calendar)
active() { call "$1" "{\"action\":\"industry_set_active\",\"industryId\":\"$IND\",\"active\":$2,\"reason\":\"$3\"}"; }
s=$(active "$RO" false "testing"); [ "$s" = 403 ] && ok "a role without platform.configure can't deactivate" || bad "read only deactivate $s"
s=$(active "$OWNER" false "testing"); [ "$s" = 403 ] && ok "a business owner can't deactivate" || bad "owner deactivate $s"
s=$(active "$ANON" false "testing"); [ "$s" = 401 ] && ok "anonymous can't deactivate" || bad "anon deactivate $s"
s=$(active "$ADMIN" false "x"); [ "$s" = 400 ] && ok "a reason is required" || bad "no reason $s"
s=$(call "$ADMIN" "{\"action\":\"industry_set_active\",\"industryId\":\"$IND\",\"active\":\"no\",\"reason\":\"testing\"}"); [ "$s" = 400 ] && ok "active must be true or false" || bad "bad active $s"
[ "$(q "select is_active from public.industries where id = '$IND'")" = t ] && [ "$(audits industry.deactivated)" = 0 ] && ok "refused calls changed nothing" || bad "refused calls wrote"
s=$(active "$ADMIN" false "No longer sold")
[ "$s" = 200 ] && [ "$(q "select is_active from public.industries where id = '$IND'")" = f ] && [ "$(js "d['businesses']")" = 1203 ] && ok "deactivated, and the answer counts its 1,203 businesses" || bad "deactivate $s $(body)"
[ "$(audits industry.deactivated)" = 1 ] && ok "deactivation is audited" || bad "deactivate audit $(audits industry.deactivated)"
s=$(active "$ADMIN" false "No longer sold"); [ "$s" = 200 ] && [ "$(audits industry.deactivated)" = 1 ] && ok "a repeat writes no second audit row" || bad "repeat $s"
[ "$(on_count calendar)" = "$before" ] && ok "businesses already in the industry keep their modules" || bad "modules changed $(on_count calendar)"
v=$("${P[@]}" -d $DB -c "select public.zella_create_business_draft(jsonb_build_object('name', 'Test New Dental', 'industry_id', '$IND'))" 2>&1)
[[ "$v" == *"INDUSTRY_NOT_FOUND"* || "$v" == *"ndustry"* ]] && ok "a new business can't be created in an inactive industry" || bad "create in inactive: $v"
s=$(call "$ADMIN" '{"action":"industries_list"}'); [ "$(js "[i['is_active'] for i in d['industries'] if i['id']=='$IND'][0]")" = False ] && ok "the industry list still shows it, marked inactive" || bad "list $s"
s=$(active "$ADMIN" true "Selling again"); [ "$s" = 200 ] && [ "$(audits industry.reactivated)" = 1 ] && [ "$(q "select is_active from public.industries where id = '$IND'")" = t ] && ok "reactivated and audited" || bad "reactivate $s"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
