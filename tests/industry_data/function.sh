#!/usr/bin/env bash
# CFG-05 part 1 through the real owner-provision-business (Deno, local stand in, ISOLATED database, test data only).
# Checks: before the migration the industry list says industry data is off and saving still works; after it the list
# carries sensitive, booking model and default automations; only a Zella Voice owner may change sensitive (a super
# admin, a read only admin, a business owner and anonymous are refused), with a reason, and turning it off needs a
# confirmation; each change is audited once; the booking model and default automations save, bad ones are refused;
# a copied industry takes the booking model, defaults and safety lines and still starts sensitive; the wizard's
# defaults read back from the server.
#   tests/industry_data/function.sh        (env: BPORT=54333 FPORT=54432)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_industry_data_fn}; TEMPLATE=${TEMPLATE:-zprod3}
BPORT=${BPORT:-54333}; FPORT=${FPORT:-54432}; B=http://localhost:$BPORT
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$HERE/production_zella_sensitive_industry.sql" > /dev/null && "${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null && "${P[@]}" -d $DB -f "$REPO/tests/industry_modules/seed.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
"${P[@]}" -d $DB -c "insert into auth.users (id, email, email_confirmed_at) values ('a0000000-0000-0000-0000-0000000000c5', 'super@zella.test', now());
  insert into public.platform_admins (user_id, role) values ('a0000000-0000-0000-0000-0000000000c5', 'super_admin');
  insert into auth.mfa_factors (id, user_id, factor_type, status) values (gen_random_uuid(), 'a0000000-0000-0000-0000-0000000000c5', 'totp', 'verified');
  insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
for port in $BPORT $FPORT; do curl -s -o /dev/null --max-time 2 "http://localhost:$port/" && { echo "FAIL port $port is already in use"; exit 1; }; done
LOG=$(mktemp -d)
backend() {   # the stand in reads the table list once, so it is restarted after the migration
  : > "$LOG/backend.log"   # empty it first, so a restart can't read the previous stand in's ready line
  ZDB=$DB PORT=$BPORT ZMAX_ROWS=1000 ZTEST_PASSWORD_AAL2=1 ZFUNCTIONS="{\"owner-provision-business\":$FPORT}" node "$REPO/tests/browser/local-backend.mjs" > "$LOG/backend.log" 2>&1 &
  BPID=$!
  for _ in $(seq 40); do grep -q "stand-in" "$LOG/backend.log" 2>/dev/null && break; sleep 0.25; done
}
backend
SUPABASE_URL=$B SUPABASE_ANON_KEY=sb_publishable_local_test_only ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only ZELLA_APP_URL=http://localhost:5160 \
  deno run -A --no-lock --config "$REPO/web/supabase/functions/owner-provision-business/deno.json" "$REPO/tests/browser/run-function.ts" owner-provision-business $FPORT > "$LOG/fn.log" 2>&1 &
FPID=$!
trap 'kill $BPID $FPID 2>/dev/null; rm -rf "$LOG"' EXIT
for _ in $(seq 60); do grep -q "on $FPORT" "$LOG/fn.log" 2>/dev/null && break; sleep 0.5; done
token() { curl -s "$B/auth/v1/token?grant_type=password" -H 'content-type: application/json' -d "{\"email\":\"$1\",\"password\":\"Test-pass-1\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
call() { curl -s -o "$LOG/out" -w '%{http_code}' "$B/functions/v1/owner-provision-business" -H "authorization: Bearer $1" -H "apikey: sb_publishable_local_test_only" -H 'content-type: application/json' -d "$2"; }
js() { python3 -c "import json; d=json.load(open('$LOG/out')); print($1)"; }
tokens() { ADMIN=$(token admin@zella.test); SUPER=$(token super@zella.test); RO=$(token readonly@zella.test); OWNER=$(token owner@glow.test); }
tokens; ANON=sb_publishable_local_test_only
DENTAL=$(q "select id from public.industries where slug = 'dental'")

# --- before the migration ---------------------------------------------------------------------------------------------
s=$(call "$ADMIN" '{"action":"industries_list"}'); [ "$s" = 200 ] && [ "$(js "d['industryData'], d['industries'][0]['sensitive']")" = "False None" ] && ok "before the migration the list says industry data is off (not 'not sensitive')" || bad "before list $s"
s=$(call "$ADMIN" "{\"action\":\"industry_save\",\"industryId\":\"$DENTAL\",\"terminology\":{},\"modules\":[]}"); [ "$s" = 200 ] && ok "and an older page's save still works" || bad "before save $s $(cat $LOG/out)"
s=$(call "$ADMIN" "{\"action\":\"industry_automation_defaults\",\"industryId\":\"$DENTAL\"}"); [ "$(js "d['available'], d['defaults']")" = "False None" ] && ok "the wizard's defaults read 'not available', so it keeps its own" || bad "before defaults $(cat $LOG/out)"

"${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" > /dev/null 2>&1 || { bad "apply"; exit 1; }
kill $BPID; wait $BPID 2>/dev/null; backend; tokens

s=$(call "$ADMIN" '{"action":"industries_list"}')
v=$(js "[(i['sensitive'], i['bookingModel'], i['automationDefaults']['appointment_reminder']['enabled']) for i in d['industries'] if i['slug']=='dental'][0], d['industryData']")
[ "$v" = "(True, 'staff_appointment', True) True" ] && ok "after: the list carries sensitive, booking model and default automations" || bad "after list $v"
sens() { call "$1" "{\"action\":\"industry_set_sensitive\",\"industryId\":\"$DENTAL\",\"sensitive\":$2,\"reason\":\"$3\"$4}"; }
s=$(sens "$SUPER" false "testing" ',"confirm":true'); [ "$s" = 403 ] && ok "a super admin can't change sensitive (Zella Voice owner only)" || bad "super $s"
s=$(sens "$RO" false "testing" ',"confirm":true'); [ "$s" = 403 ] && ok "a read only admin can't" || bad "ro $s"
s=$(sens "$OWNER" false "testing" ',"confirm":true'); [ "$s" = 403 ] && ok "a business owner can't" || bad "owner $s"
s=$(sens "$ANON" false "testing" ',"confirm":true'); [ "$s" = 401 ] && ok "anonymous can't" || bad "anon $s"
s=$(sens "$ADMIN" false "x" ',"confirm":true'); [ "$s" = 400 ] && ok "a reason is required" || bad "reason $s"
s=$(sens "$ADMIN" false "Reviewed with legal" ""); [ "$s" = 409 ] && [[ "$(cat $LOG/out)" == *"read call transcripts"* ]] && ok "turning it off without confirming is refused and says staff may then read transcripts" || bad "confirm $s"
[ "$(q "select sensitive from public.industries where id = '$DENTAL'")" = t ] && [ "$(q "select count(*) from public.audit_logs where entity_id = '$DENTAL' and action like 'industry.sensitive%'")" = 0 ] && ok "refused calls changed nothing and wrote no audit row" || bad "refused wrote"
s=$(sens "$ADMIN" false "Reviewed with legal" ',"confirm":true'); [ "$s" = 200 ] && [ "$(q "select sensitive from public.industries where id = '$DENTAL'")" = f ] && ok "a Zella Voice owner turns it off with a reason and a confirmation" || bad "off $s"
[ "$(q "select public.zella_sensitive_industry('9d000000-0000-0000-0000-000000000005')")" = f ] && ok "and the server's transcript rule follows it" || bad "rule"
s=$(sens "$ADMIN" false "Reviewed with legal" ',"confirm":true'); a=$(q "select count(*) || '|' || max(new_data ->> 'reason') from public.audit_logs where entity_id = '$DENTAL' and action = 'industry.sensitive_off'")
[ "$a" = "1|Reviewed with legal" ] && ok "audited once with the reason; a repeat writes no second row" || bad "audit $a"
s=$(sens "$ADMIN" true "Back on" ""); [ "$s" = 200 ] && [ "$(q "select count(*) from public.audit_logs where entity_id = '$DENTAL' and action = 'industry.sensitive_on'")" = 1 ] && ok "turning it back on needs no confirmation and is audited" || bad "on $s"

AUTO=$(q "select automation_defaults from public.industry_configurations where industry_id = '$DENTAL'" | python3 -c 'import sys,json; d=json.load(sys.stdin); d["waitlist_offer"]["enabled"]=False; print(json.dumps(d))')
s=$(call "$ADMIN" "{\"action\":\"industry_save\",\"industryId\":\"$DENTAL\",\"terminology\":{},\"modules\":[],\"bookingModel\":\"consultation\",\"automationDefaults\":$AUTO}")
[ "$s" = 200 ] && [ "$(q "select i.booking_model || '|' || (ic.automation_defaults #>> '{waitlist_offer,enabled}') from public.industries i join public.industry_configurations ic on ic.industry_id = i.id where i.id = '$DENTAL'")" = "consultation|false" ] && ok "the booking model and default automations save" || bad "save data $s $(cat $LOG/out)"
s=$(call "$ADMIN" "{\"action\":\"industry_save\",\"industryId\":\"$DENTAL\",\"terminology\":{},\"modules\":[],\"bookingModel\":\"teleport\"}"); [ "$s" = 400 ] && ok "a booking model outside the list is refused" || bad "bad model $s"
s=$(call "$ADMIN" "{\"action\":\"industry_save\",\"industryId\":\"$DENTAL\",\"terminology\":{},\"modules\":[],\"automationDefaults\":{\"x\":{\"enabled\":\"yes\"}}}"); [ "$s" = 400 ] && ok "malformed default automations are refused" || bad "bad defaults $s"
s=$(call "$RO" "{\"action\":\"industry_save\",\"industryId\":\"$DENTAL\",\"terminology\":{},\"modules\":[],\"bookingModel\":\"class\"}"); [ "$s" = 403 ] && ok "a read only admin can't save them" || bad "ro save $s"
s=$(call "$ADMIN" "{\"action\":\"industry_automation_defaults\",\"industryId\":\"$DENTAL\"}"); [ "$(js "d['available'], d['defaults']['waitlist_offer']['enabled']")" = "True False" ] && ok "the wizard reads the saved defaults back from the server" || bad "defaults $(cat $LOG/out)"
s=$(call "$RO" "{\"action\":\"industry_automation_defaults\",\"industryId\":\"$DENTAL\"}"); [ "$s" = 200 ] && ok "a role with businesses.view may read them" || bad "ro defaults $s"

s=$(call "$ADMIN" "{\"action\":\"industry_create\",\"name\":\"Test Orthodontics\",\"copyFromId\":\"$DENTAL\"}")
NEW=$(js "d['industryId']")
v=$(q "select i.sensitive || '|' || i.booking_model || '|' || (ic.automation_defaults #>> '{waitlist_offer,enabled}') || '|' || (ic.safety_rules = (select safety_rules from public.industry_configurations where industry_id = '$DENTAL')) from public.industries i join public.industry_configurations ic on ic.industry_id = i.id where i.id = '$NEW'")
[ "$v" = "true|consultation|false|true" ] && ok "a copied industry takes the booking model, defaults and safety lines, and starts sensitive" || bad "copy $s $v"
s=$(call "$ADMIN" '{"action":"industry_create","name":"Test Empty Industry"}'); NEW2=$(js "d['industryId']")
v=$(q "select i.sensitive || '|' || coalesce(i.booking_model, '-') || '|' || coalesce(ic.automation_defaults::text, '-') from public.industries i join public.industry_configurations ic on ic.industry_id = i.id where i.id = '$NEW2'")
[ "$v" = "true|-|-" ] && ok "a new empty industry starts sensitive with no booking model and the base automations" || bad "empty $v"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
