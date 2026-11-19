#!/usr/bin/env bash
# CFG-14 and CFG-21: business_plans_list on an ISOLATED copy of the production schema (never production). Test data
# only. Runs the real owner-provision-business under Deno against the local stand in (reads capped at 1,000 rows).
# Checks: before, plans_list names every subscription "Unknown plan" (the gap); the new list pages 25 at a time over
# every business, each with its latest plan version, how many versions, price, interval and allowances, and its
# subscription status; businesses without a plan say so; search narrows the list; the limit stays between 1 and 100;
# billing.view is needed (a role without it, a business owner and anonymous are refused).
#   tests/plans_list/run.sh        (env: BPORT=54333 FPORT=54432)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_plans_list}; TEMPLATE=${TEMPLATE:-zprod3}
BPORT=${BPORT:-54333}; FPORT=${FPORT:-54432}; B=http://localhost:$BPORT
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
for port in $BPORT $FPORT; do curl -s -o /dev/null --max-time 2 "http://localhost:$port/" && { echo "FAIL port $port is already in use"; exit 1; }; done
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
js() { python3 -c "import json; d=json.load(open('$LOG/out')); print($1)"; }

s=$(call "$ADMIN" '{"action":"plans_list"}')
[ "$s" = 200 ] && [ "$(js "sum(1 for x in d['subscriptions'] if x['plan_name']=='Unknown plan')")" = 20 ] && ok "before: the old list calls all 20 subscriptions \"Unknown plan\" (the gap)" || bad "old list $s"

s=$(call "$ADMIN" '{"action":"business_plans_list"}')
[ "$s" = 200 ] && [ "$(js "(d['total'], d['withPlan'], d['limit'], len(d['businesses']))")" = "(34, 20, 25, 25)" ] && ok "page 1: 25 of 34 businesses, 20 with a plan" || bad "page 1 $s $(head -c 300 $LOG/out)"
v=$(js "[(b['plan']['version'], b['plan']['versions'], b['plan']['tier'], b['plan']['billingInterval'], b['plan']['priceCents'], b['plan']['minutes'], b['subscription']['status']) for b in d['businesses'] if b['businessName']=='Test Plans 01'][0]")
[ "$v" = "(3, 3, 'pro', 'yearly', 39900, 900, 'active')" ] && ok "a business with three versions shows the latest (Pro yearly, version 3 of 3), its allowances and subscription" || bad "latest $v"
v=$(js "[(b['plan']['version'], b['plan']['versions']) for b in d['businesses'] if b['businessName']=='Test Plans 02'][0]"); [ "$v" = "(2, 2)" ] && ok "two versions: version 2 of 2" || bad "two $v"
v=$(js "sum(1 for b in d['businesses'] if b['businessName'].startswith('Test Plans') and int(b['businessName'][-2:])<=20 and not b['plan'])"); [ "$v" = 0 ] && ok "every business with a plan on the page shows it (no Unknown plan)" || bad "missing plans $v"
s=$(call "$ADMIN" '{"action":"business_plans_list","offset":25}')
[ "$(js "(len(d['businesses']), d['offset'])")" = "(9, 25)" ] && ok "page 2 has the other 9" || bad "page 2 $(js "len(d['businesses'])")"
v=$(js "sum(1 for b in d['businesses'] if b['plan'] is None and b['subscription'] is None)"); [ "$v" -ge 9 ] 2>/dev/null && ok "businesses without a plan say no plan and no subscription" || bad "no plan $v"
s=$(call "$ADMIN" '{"action":"business_plans_list","search":"Plans 0"}'); [ "$(js "d['total'], d['withPlan']")" = "9 None" ] && ok "search narrows the list (9 match), and the count of plans saved, which is for every business, is left out" || bad "search $(js "d['total']")"
s=$(call "$ADMIN" '{"action":"business_plans_list","search":"%"}'); [ "$s" = 200 ] && [ "$(js "d['search']")" = None ] && ok "wildcards in the search are taken as text" || bad "wildcard $s $(js "d.get('search')")"
s=$(call "$ADMIN" '{"action":"business_plans_list","limit":500}'); [ "$(js "d['limit']")" = 100 ] && ok "at most 100 a page" || bad "limit $(js "d['limit']")"
s=$(call "$ADMIN" '{"action":"business_plans_list","limit":0}'); [ "$(js "d['limit']")" = 1 ] && ok "at least 1 a page" || bad "min $(js "d['limit']")"

s=$(call "$RO" '{"action":"business_plans_list"}'); [ "$s" = 403 ] && [ "$(js "d['permission']")" = billing.view ] && ok "a role without billing.view is refused" || bad "read only $s"
"${P[@]}" -d $DB -c "insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'billing.view') on conflict do nothing" > /dev/null
s=$(call "$RO" '{"action":"business_plans_list"}'); [ "$s" = 200 ] && ok "with billing.view granted it may" || bad "granted $s"
s=$(call "$OWNER" '{"action":"business_plans_list"}'); [ "$s" = 403 ] && ok "a business owner is refused" || bad "owner $s"
s=$(call "$ANON" '{"action":"business_plans_list"}'); [ "$s" = 401 ] && ok "anonymous is refused" || bad "anon $s"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
