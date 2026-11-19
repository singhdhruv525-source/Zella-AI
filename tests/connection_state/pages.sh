#!/usr/bin/env bash
# The four admin answers agree (COM-01, OPS-07, UI-02): AI agents, Integrations, Overview and the operations health
# count read the same definition (sql/zella_connection_state.sql) for the same businesses. Runs the real
# owner-provision-business under Deno against the local stand in, on an ISOLATED database (never production); test
# data only. Also: before the migration is applied the pages say the state isn't available instead of guessing.
#   tests/connection_state/pages.sh        (env: BPORT=54333 FPORT=54432)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_connection_pages}; TEMPLATE=${TEMPLATE:-zprod3}
BPORT=${BPORT:-54333}; FPORT=${FPORT:-54432}; B=http://localhost:$BPORT
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
for port in $BPORT $FPORT; do curl -s -o /dev/null --max-time 2 "http://localhost:$port/" && { echo "FAIL port $port is already in use"; exit 1; }; done
LOG=$(mktemp -d)
backend() {   # the stand in reads the function list once, so it is restarted after the migration
  ZDB=$DB PORT=$BPORT ZMAX_ROWS=1000 ZTEST_PASSWORD_AAL2=1 ZFUNCTIONS="{\"owner-provision-business\":$FPORT}" node "$REPO/tests/browser/local-backend.mjs" > "$LOG/backend.log" 2>&1 &
  BPID=$!
  for _ in $(seq 40); do grep -q "stand-in" "$LOG/backend.log" 2>/dev/null && break; sleep 0.25; done
}
backend
SUPABASE_URL=$B SUPABASE_ANON_KEY=sb_publishable_local_test_only ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only ZELLA_APP_URL=http://localhost:5160 \
  deno run -A --no-lock --config "$REPO/web/supabase/functions/owner-provision-business/deno.json" "$REPO/tests/browser/run-function.ts" owner-provision-business $FPORT > "$LOG/fn.log" 2>&1 &
FPID=$!
trap 'kill $BPID $FPID 2>/dev/null; rm -rf "$LOG"' EXIT
for _ in $(seq 60); do grep -q "on $FPORT" "$LOG/fn.log" 2>/dev/null && grep -q "stand-in" "$LOG/backend.log" 2>/dev/null && break; sleep 0.5; done
TOK=$(curl -s "$B/auth/v1/token?grant_type=password" -H 'content-type: application/json' -d '{"email":"admin@zella.test","password":"Test-pass-1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
call() { curl -s "$B/functions/v1/owner-provision-business" -H "authorization: Bearer $TOK" -H "apikey: sb_publishable_local_test_only" -H 'content-type: application/json' -d "{\"action\":\"$1\"}" > "$LOG/$1.json"; }
fetch() { for a in agents_list integrations_overview overview_data platform_status; do call $a; done; }
py() { python3 - "$LOG" <<PY
import json, sys, os
L = sys.argv[1]
j = lambda n: json.load(open(os.path.join(L, n + ".json")))
$1
PY
}

# --- before the migration: honest "not available", never a guess ---------------------------------------------------
fetch
v=$(py 'a=j("agents_list"); i=j("integrations_overview"); o=j("overview_data"); print(a["connectionsAvailable"], i["connectionsAvailable"], o["stats"]["receptionistsLive"], o["stats"]["receptionistsSwitchedOn"])')
[ "$v" = "False False None 7" ] && ok "before the migration the pages say live isn't available (not 0 and not the switched on count)" || bad "before: $v"

"${P[@]}" -d $DB -f "$REPO/sql/zella_connection_state.sql" > /dev/null 2>&1 || { bad "apply"; exit 1; }
kill $BPID; wait $BPID 2>/dev/null; backend
SQL=$("${P[@]}" -d $DB -c "begin; set local request.jwt.claims = '{\"role\":\"service_role\"}'; set local role service_role;
  select json_object_agg(business_id, json_build_object('phone', phone, 'voice', vapi_linked, 'answering', answering, 'live', live, 'calendar', calendar, 'leads', lead_sources))
    from public.zella_business_connections(array(select id from public.businesses)); commit;")
echo "$SQL" > "$LOG/sql.json"
fetch

v=$(py '
s=j("sql"); a=j("agents_list"); bad=[]
for g in a["agents"]:
  e=s[g["businessId"]]
  if (g["checks"]["phone"], g["checks"]["voice"], g["answering"], g["live"]) != (e["phone"], e["voice"], e["answering"], e["live"]): bad.append(g["businessName"])
print(len(a["agents"]), bad)')
[ "$v" = "8 []" ] && ok "AI agents: phone, Vapi link, answering and live match the SQL definition for all 8 receptionists" || bad "agents: $v"
v=$(py 'a=j("agents_list"); print(a["stats"]["live"], a["stats"]["answering"])')
[ "$v" = "2 1" ] && ok "AI agents: Live 2 and Answering 1 (one live receptionist hasn't served a call this week)" || bad "agent stats: $v"
v=$(py '
s=j("sql"); i=j("integrations_overview"); bad=[]
for r in i["requests"]:
  e=s[r["businessId"]]
  if (r["phone"]["connected"], r["voice"]["connected"], r["voice"]["answering"], r["calendar"]["connected"], sorted(r["leads"]["connected"]), r["live"]) != (e["phone"], e["voice"], e["answering"], e["calendar"], sorted(e["leads"]), e["live"]): bad.append(r["businessName"])
  if r["email"]["connected"] is not None or r["email"]["tracked"] is not False: bad.append("email " + r["businessName"])
print(len(i["requests"]), bad)')
[ "$v" = "12 []" ] && ok "Integrations: every business's phone, voice, answering, calendar, leads and live match; email is not tracked" || bad "integrations: $v"
v=$(py '
s=j("sql"); o=j("overview_data"); i=j("integrations_overview"); p=j("platform_status")
live=sum(1 for e in s.values() if e["live"]); ans=sum(1 for e in s.values() if e["answering"])
print(o["stats"]["receptionistsLive"]==live==i["counts"]["live"], o["stats"]["receptionistsAnswering"]==ans, p["health"]["brokenIntegrations"]==i["counts"]["problems"], live, ans, p["health"]["brokenIntegrations"])')
[ "$v" = "True True True 2 1 3" ] && ok "Overview and the operations health count agree: 2 live, 1 answering, 3 connections need attention" || bad "overview/status: $v"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
