#!/usr/bin/env bash
# sql/zella_call_routing_conflict.sql on an ISOLATED copy of the production schema (never production). Test data only:
# fake businesses and +1555 numbers; no provider is called and nothing is sent.
# Checks: before, a number and a Vapi phone ID of two different businesses route to the ID's business (the gap); a
# changed function stops the file (VERSION_MISMATCH, nothing changes); applies, and applies again, to the recorded
# fingerprint, with grants unchanged (server only); every input that isn't a conflict gives exactly what production's
# function gave (the number alone, the ID alone, matching pairs, two rows of one business, paused numbers, stopped
# businesses, unregistered values, the call settings fallback); every conflict gives no business, whatever the
# fallback, also when one side is paused or its business stopped; one urgent call_routing_conflict alert per pair of
# rows, no business on it, both rows and businesses in meta, only the last 4 digits of the number, repeats counted;
# a read only transaction still refuses (no alert, no error); every path of a conflicting call refuses and writes
# nothing for either business (assistant request, status update, voice rules, Brain tools, unanswered question,
# transfer, end of call report) while a matching pair still records its call; the rollback (twice, through
# sql/rollback/run.sh) restores production's function exactly and keeps the alerts; it refuses a changed function;
# the file applies again after it.
#   tests/call_routing_conflict/run.sh      (env ZPG_HOST ZPG_PORT DB TEMPLATE; TEMPLATE defaults to zprod3, else zbase)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlr_routing_conflict}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "${DB}_x" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_call_routing_conflict.sql"; RB="$REPO/sql/rollback/zella_call_routing_conflict_rollback.sql"
SIG="public.zella_business_for_number(text,text,uuid)"
PROD_MD5=051170698159c7b440ebb7ca62a3a0eb; PROD_SRC_MD5=eaa05f56f3d943768066e5b48ab780f3; NEW_MD5=5f066cb575f536698873724a6e4b65ef
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# the template: zprod3 (the isolated copy of production) when there is one, else the schema baseline (sql/baseline)
TEMPLATE=${TEMPLATE:-zprod3}
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = '$TEMPLATE'")" != 1 ]; then
  TEMPLATE=zbase
  [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" = 1 ] \
    || "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$TEMPLATE" || exit 1
echo "template: $TEMPLATE"
mkdb() { "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $1" -c "create database $1 template $TEMPLATE" > /dev/null || exit 1
  # the assistant request (sql/zella_assistant_delivery.sql) when the template predates it (the 4 Nov baseline)
  if [ "$("${P[@]}" -d "$1" -c "select to_regprocedure('public.zella_assistant_for_call(text,text,text)') is null")" = t ]; then
    "${P[@]}" -d "$1" -f "$REPO/sql/zella_assistant_delivery.sql" > /dev/null 2>&1 || { echo "FAIL could not add zella_assistant_for_call to the copy"; exit 1; }
  fi
}
mkdb "$DB"
q() { "${P[@]}" -d "${2:-$DB}" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "${2:-$DB}" -c "set client_min_messages = warning" -f "$1" 2>&1; }
rollback() { "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "${1:-$DB}" -q 2>&1; }
fp() { q "select md5(pg_get_functiondef('$SIG'::regprocedure))" "${1:-$DB}"; }
[ "$(fp)" = "$PROD_MD5" ] && [ "$(q "select md5(prosrc) from pg_proc where oid = '$SIG'::regprocedure")" = "$PROD_SRC_MD5" ] \
  && ok "the copy has production's function (body md5 $PROD_SRC_MD5, as recorded from production)" || { bad "the copy's function is not production's: $(fp)"; exit 1; }

# test data only: businesses A and B (active), D (suspended); A has two numbers and a paused one, B one, D one
A=c7000000-0000-0000-0000-00000000000a; B=c7000000-0000-0000-0000-00000000000b; D=c7000000-0000-0000-0000-00000000000d
NA=+15555550171; NA2=+15555550174; NB=+15555550172; NC=+15555550173; ND=+15555550175; NX=+15555550179
q "insert into public.businesses (id, name) values ('$A', 'Routing Test A'), ('$B', 'Routing Test B'), ('$D', 'Routing Test D');
   insert into public.business_phone_numbers (business_id, e164, vapi_phone_number_id, label) values
     ('$A', '$NA', 'test-vapi-a', 'main'), ('$A', '$NA2', 'test-vapi-a2', 'second'), ('$A', '$NC', 'test-vapi-c', 'paused'),
     ('$B', '$NB', 'test-vapi-b', 'main'), ('$D', '$ND', 'test-vapi-d', 'main');
   update public.business_phone_numbers set status = 'paused' where e164 = '$NC';
   update public.businesses set suspended_at = now() where id = '$D'" > /dev/null || { bad "test data"; exit 1; }

# every lookup case: number | Vapi phone ID | fallback (literal SQL); "same" cases must not change, "conflict" ones must
SAME=(
  "'$NA'|null|null" "'(555) 555-0171'|null|null" "'5555550172'|null|null" "null|'test-vapi-a'|null" "null|'test-vapi-b'|null"
  "'$NA'|'test-vapi-a'|null" "'$NB'|'test-vapi-b'|'$A'" "'$NA'|'test-vapi-a2'|null" "'$NA2'|'test-vapi-a'|'$B'"
  "'$NX'|'test-vapi-a'|null" "'$NA'|'test-vapi-unknown'|null" "'$NX'|'test-vapi-unknown'|'$B'" "'$NA'|''|null"
  "'$NC'|null|'$B'" "'$NC'|'test-vapi-a'|null" "'$NC'|'test-vapi-c'|null" "null|'test-vapi-c'|null" "'$ND'|null|'$A'" "null|'test-vapi-d'|null"
  "'$NX'|null|'$A'" "'$NX'|null|'$D'" "null|null|'$B'" "null|null|null" "'not a number'|null|'$A'" "'$NX'|'test-vapi-a2'|'$B'"
)
CONFLICT=(
  "'$NA'|'test-vapi-b'|null" "'$NA'|'test-vapi-b'|'$A'" "'$NB'|'test-vapi-a'|'$B'" "'(555) 555-0172'|'test-vapi-a2'|null"
  "'$NC'|'test-vapi-b'|null" "'$NB'|'test-vapi-c'|null" "'$ND'|'test-vapi-a'|'$A'" "'$NA'|'test-vapi-d'|null"
)
look() { IFS='|' read -r n v f <<< "$1"; q "select coalesce(public.zella_business_for_number($n, $v, $f)::text, 'none')"; }
declare -A was
for c in "${SAME[@]}" "${CONFLICT[@]}"; do was[$c]=$(look "$c"); done
[ "${was["'$NA'|'test-vapi-b'|null"]}" = "$B" ] && ok "before: number of A with the Vapi phone ID of B is routed to B (the gap)" || bad "before gap: ${was["'$NA'|'test-vapi-b'|null"]}"
[ "$(q "select count(*) from public.platform_alerts where kind = 'call_routing_conflict'")" = 0 ] && ok "before: no alert" || bad "before alert"

# a changed function stops the file, and nothing changes
mkdb "${DB}_x"
q "create or replace function public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text default null, p_fallback uuid default null) returns uuid language sql stable security definer set search_path = public as \$f\$ select null::uuid \$f\$" "${DB}_x" > /dev/null
d=$(fp "${DB}_x"); out=$(apply "$MIG" "${DB}_x")
[[ "$out" == *VERSION_MISMATCH* ]] && [ "$(fp "${DB}_x")" = "$d" ] && ok "a changed function stops the file (VERSION_MISMATCH) and nothing changes" || bad "drift: $out"
"${P[@]}" -d postgres -c "drop database if exists ${DB}_x" > /dev/null
mkdb "${DB}_x"; q "drop function public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)" "${DB}_x" > /dev/null
out=$(apply "$MIG" "${DB}_x"); [[ "$out" == *"zella_platform_alert is missing"* ]] && [ "$(fp "${DB}_x")" = "$PROD_MD5" ] && ok "without the admin alert function the file stops and nothing changes" || bad "no alert fn: $out"
"${P[@]}" -d postgres -c "drop database if exists ${DB}_x" > /dev/null

grants() { q "select has_function_privilege('anon', '$SIG', 'execute')::text || has_function_privilege('authenticated', '$SIG', 'execute')::text || has_function_privilege('service_role', '$SIG', 'execute')::text || has_function_privilege('public', '$SIG', 'execute')::text"; }
g_before=$(grants)
out=$(apply "$MIG") && ok "applies" || { bad "applies: $out"; exit 1; }
out=$(apply "$MIG") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "$NEW_MD5" ] && ok "the new fingerprint is the recorded one ($NEW_MD5)" || bad "fingerprint $(fp)"
[ "$(grants)" = "falsefalsetruefalse" ] && [ "$(grants)" = "$g_before" ] && ok "server only, as before: anon, authenticated and public can't run it, service_role can" || bad "grants $(grants) (before $g_before)"

n=0; for c in "${SAME[@]}"; do now=$(look "$c"); [ "$now" = "${was[$c]}" ] || { bad "changed: $c was ${was[$c]}, now $now"; n=$((n + 1)); }; done
[ $n = 0 ] && ok "${#SAME[@]} lookups that are not conflicts give exactly what production's function gave (number alone, ID alone, matching pairs, paused, stopped, fallback)" || true
[ "$(look "'$NA'|null|null")$(look "null|'test-vapi-b'|null")$(look "'$NA'|'test-vapi-a'|null")$(look "'$NA'|'test-vapi-a2'|null")" = "$A$B$A$A" ] \
  && ok "the number alone, the ID alone, a matching pair and two rows of one business resolve (A, B, A, A)" || bad "resolve"
n=0; for c in "${CONFLICT[@]}"; do now=$(look "$c"); [ "$now" = none ] || { bad "conflict $c gave $now"; n=$((n + 1)); }; done
[ $n = 0 ] && ok "${#CONFLICT[@]} conflicting pairs give no business, whatever the fallback, also with a paused number or a stopped business" || true

al() { q "select count(*) || ':' || coalesce(sum(occurrences), 0) || ':' || coalesce(string_agg(distinct severity, ','), '') || ':' || bool_and(business_id is null) || ':' || bool_and(status = 'open') from public.platform_alerts where kind = 'call_routing_conflict'"; }
# 8 conflicts over 4 pairs of rows, whichever side each value came from: (a, b) three times, (b, a2), (c, b) twice,
# (d, a) twice
[ "$(al)" = "4:8:urgent:true:true" ] && ok "one urgent alert per pair of rows (4 pairs, 8 calls counted), no business on the alert, open" || bad "alerts $(al)"
ROW_A=$(q "select id from public.business_phone_numbers where e164 = '$NA'"); ROW_B=$(q "select id from public.business_phone_numbers where e164 = '$NB'")
m=$(q "select occurrences || ':' || (array[meta ->> 'number_business_id', meta ->> 'vapi_business_id'] @> array['$A', '$B'])::text || ':'
          || (array[meta ->> 'number_row_id', meta ->> 'vapi_row_id'] @> array['$ROW_A', '$ROW_B'])::text || ':' || (meta ->> 'number_ending')
        from public.platform_alerts where kind = 'call_routing_conflict' and dedupe_key = 'call_routing_conflict:' || least('$ROW_A', '$ROW_B') || ':' || greatest('$ROW_A', '$ROW_B')")
# the last of the three calls for this pair was B's number with A's ID, so the meta shows that call's number ending
[ "$m" = "3:true:true:0172" ] && ok "the alert names both phone number rows and both businesses, counts repeats, last 4 digits only" || bad "meta: $m"
[ "$(q "select count(*) from public.platform_alerts where kind = 'call_routing_conflict' and (detail || title || meta::text) ~ '\\+?1?555555017'")" = 0 ] \
  && ok "no alert carries a full phone number (last 4 digits only)" || bad "full number in an alert"
[ "$(q "select count(*) from public.platform_alerts where kind = 'call_routing_conflict' and (title || detail) ~ '[-–—]'")" = 0 ] && ok "the alert's words have no dashes or hyphens" || bad "dash in alert"
before_occ=$(al)
out=$("${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "begin transaction read only" -c "select coalesce(public.zella_business_for_number('$NA', 'test-vapi-b', '$A')::text, 'none')" -c "commit" 2> "${TMPDIR:-/tmp}/zrc.$$.err")
err=$(cat "${TMPDIR:-/tmp}/zrc.$$.err"); rm -f "${TMPDIR:-/tmp}/zrc.$$.err"
[ "$out" = none ] && [ "$(al)" = "$before_occ" ] && [[ "$err" == *"routing conflict alert not raised (25006)"* ]] \
  && ok "in a read only transaction a conflict is still refused, without an error (a warning with the SQLSTATE only)" || bad "read only: $out / $err"

# every path of a conflicting call (called number of A, Vapi phone ID of B); voice-rules and n8n pass the lookup's null
CALL=test-call-conflict-0001; FROM=+15555550199
r=$(q "select (r ->> 'outcome') || ':' || coalesce(r ->> 'assistant', 'no assistant') from public.zella_assistant_for_call('$NA', 'test-vapi-b', '$CALL') r")
[ "$r" = "unknown_number:no assistant" ] \
  && [ "$(q "select count(*) from public.assistant_deliveries where provider_call_id = '$CALL' and business_id is null and outcome = 'unknown_number'")" = 1 ] \
  && ok "assistant request: unknown number, no business configuration returned (voice-rules says the neutral line)" || bad "assistant: $r"
[ "$(q "select public.zella_record_call_status('$CALL', 'ringing', '$NA', 'test-vapi-b', '$FROM', 'inbound', now(), null)")" = unknown_business ] && ok "status update: unknown business, no call row" || bad "status"
BIZ=$(q "select coalesce(public.zella_business_for_number('$NA', 'test-vapi-b', '$A')::text, 'null')")
out=$(q "select public.zella_ai_voice('$CALL', $( [ "$BIZ" = null ] && echo null || echo "'$BIZ'" ), 'rules', '{\"caller_number\": \"$FROM\"}')" 2>&1)
[[ "$out" == *UNKNOWN_BUSINESS* ]] && ok "voice rules (call_rules): refused, UNKNOWN_BUSINESS" || bad "ai_voice: $out"
n=0; for t in search_knowledge check_open_hours lookup_caller check_availability take_message request_follow_up report_emergency; do
  s=$(q "select public.zella_ai_tool('$CALL', null, '$t', '{\"caller_number\": \"$FROM\", \"message\": \"test\", \"query\": \"hours\"}', null) ->> 'status'")
  [ "$s" = unknown_business ] || { bad "brain tool $t: $s"; n=$((n + 1)); }
done; [ $n = 0 ] && ok "Brain tools (7 of them, take_message and report_emergency included): unknown business" || true
out=$(q "select public.zella_report_unanswered('$CALL', null, 'What time do you open?')" 2>&1); [[ "$out" == *UNKNOWN_BUSINESS* ]] && ok "unanswered question: refused" || bad "unanswered: $out"
r=$(q "select (r ->> 'ok') || ':' || (r ->> 'reason') || ':' || coalesce(r ->> 'number', 'no number') from public.zella_transfer_destination('$CALL', '$NA', 'test-vapi-b', '$FROM') r")
[ "$r" = "false:unknown_business:no number" ] && ok "transfer: refused, no number given" || bad "transfer: $r"
[ "$(q "select public.zella_record_inbound_call('$CALL', '$NA', 'test-vapi-b', '$FROM', now() - interval '2 minutes', now(), 120, 'customer-ended-call', 'Caller wanted to book.', null, 'Caller: I want to book.', true)")" = unknown_business ] \
  && ok "end of call report: unknown business" || bad "inbound report"
w=$(q "select (select count(*) from public.calls where external_call_id = '$CALL' or business_id in ('$A', '$B'))
           + (select count(*) from public.callbacks where business_id in ('$A', '$B')) + (select count(*) from public.customers where business_id in ('$A', '$B'))
           + (select count(*) from public.ai_tool_calls where business_id in ('$A', '$B')) + (select count(*) from public.knowledge_gaps where business_id in ('$A', '$B'))
           + (select count(*) from public.assistant_deliveries where business_id in ('$A', '$B'))")
[ "$w" = 0 ] && ok "nothing was written for either business (calls, callbacks, customers, tool calls, questions, deliveries)" || bad "rows written: $w"
# a matching pair still reaches its business through the same path (the refusal above is the conflict, not the path)
[ "$(q "select public.zella_record_call_status('test-call-match-0001', 'ringing', '$NA', 'test-vapi-a', '$FROM', 'inbound', now(), null)")" = recorded ] \
  && [ "$(q "select business_id from public.calls where external_call_id = 'test-call-match-0001'")" = "$A" ] && ok "a matching pair still records its call for A" || bad "matching call"

# rollback: production's function exactly, the alerts kept; twice; refuses a changed function; the file applies again
n_alerts=$(q "select count(*) from public.platform_alerts where kind = 'call_routing_conflict'")
out=$(rollback) && [ "$(fp)" = "$PROD_MD5" ] && [ "$(q "select md5(prosrc) || provolatile::text from pg_proc where oid = '$SIG'::regprocedure")" = "${PROD_SRC_MD5}s" ] \
  && ok "rollback restores production's function exactly (md5, body, STABLE)" || bad "rollback: $out $(fp)"
out=$(rollback) && [ "$(fp)" = "$PROD_MD5" ] && ok "rollback runs twice" || bad "rollback twice: $out"
[ "$(grants)" = "falsefalsetruefalse" ] && ok "rollback keeps the grants" || bad "grants after rollback $(grants)"
[ "$(q "select count(*) from public.platform_alerts where kind = 'call_routing_conflict'")" = "$n_alerts" ] && ok "rollback keeps every alert" || bad "alerts lost"
[ "$(look "'$NA'|'test-vapi-b'|null")" = "$B" ] && ok "after the rollback the old behaviour is back (routed by the ID)" || bad "rolled back behaviour"
out=$(apply "$MIG") && [ "$(fp)" = "$NEW_MD5" ] && ok "applies again after the rollback" || bad "reapply: $out"
q "create or replace function public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text default null, p_fallback uuid default null) returns uuid language plpgsql volatile security definer set search_path = public as \$f\$ begin return null; end \$f\$" > /dev/null
d=$(fp); out=$(rollback); [[ "$out" == *ROLLBACK_DRIFT* ]] && [ "$(fp)" = "$d" ] && ok "the rollback refuses a changed function (ROLLBACK_DRIFT) and changes nothing" || bad "rollback drift: $out"

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
