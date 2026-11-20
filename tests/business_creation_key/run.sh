#!/usr/bin/env bash
# sql/zella_business_creation_key.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, two creates of the same draft make two businesses (the bug); applies, and applies again; the same
# creation key twice, and twice at once, gives one business; a new key makes a new one; duplicates by name, phone or web
# domain are reported, cancelled businesses and the business itself are not; only the server may call either function;
# the rollback (twice) removes both functions and the column and leaves the one argument function exactly as it was;
# applies again; a changed function stops the file (VERSION_MISMATCH) and the rollback (ROLLBACK_DRIFT).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_creation_key}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_business_creation_key.sql"; RB="$REPO/sql/rollback/zella_business_creation_key_rollback.sql"
one=$(q "select md5(pg_get_functiondef('public.zella_create_business_draft(jsonb)'::regprocedure))")
IND=$(q "select id from public.industries where is_active order by name limit 1")
F="{\"name\": \"Key Test Dental\", \"industry_id\": \"$IND\", \"timezone\": \"America/Chicago\"}"
count() { q "select count(*) from public.businesses where name = '$1'"; }

# before: a retry of the same create makes a second draft
q "select public.zella_create_business_draft('$F'::jsonb); select public.zella_create_business_draft('$F'::jsonb)" > /dev/null
[ "$(count 'Key Test Dental')" = "2" ] && ok "before: a retry makes a second business (the bug)" || bad "before: $(count 'Key Test Dental')"
q "update public.businesses set name = 'Before Fix Dental' where name = 'Key Test Dental'" > /dev/null   # (a business can't be deleted here: BIZ-13a)

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(q "select md5(pg_get_functiondef('public.zella_create_business_draft(jsonb)'::regprocedure))")" = "$one" ] && ok "the one argument function is unchanged" || bad "one argument function changed"

K1=c1000000-0000-0000-0000-000000000001; K2=c1000000-0000-0000-0000-000000000002; K3=c1000000-0000-0000-0000-000000000003
a=$(q "select public.zella_create_business_draft('$F'::jsonb, '$K1') ->> 'business_id'")
r=$(q "select public.zella_create_business_draft('$F'::jsonb, '$K1')")
b=$(q "select '$r'::jsonb ->> 'business_id'"); e=$(q "select '$r'::jsonb ->> 'existing'")
[ "$a" = "$b" ] && [ "$e" = "true" ] && [ "$(count 'Key Test Dental')" = "1" ] && ok "the same key twice gives one business, marked existing" || bad "same key: $a $b $e $(count 'Key Test Dental')"
m=$(q "select count(*) from public.ai_agents where business_id = '$a'")
[ "$m" = "1" ] && ok "and one receptionist" || bad "receptionists: $m"
q "select public.zella_create_business_draft('$F'::jsonb, '$K2')" > /dev/null
[ "$(count 'Key Test Dental')" = "2" ] && ok "a new key makes a new business (Create anyway)" || bad "new key: $(count 'Key Test Dental')"
# twice at once: the first holds its lock (pg_sleep) while the second starts
PGAPPNAME=zlb_key_first "${P[@]}" -d $DB -c "begin; select public.zella_create_business_draft('$F'::jsonb, '$K3'); select pg_sleep(2); commit;" > /dev/null 2>&1 & bg=$!
for i in $(seq 1 100); do [ "$(q "select count(*) from pg_stat_activity where application_name = 'zlb_key_first' and wait_event = 'PgSleep'")" = "1" ] && break; sleep 0.1; done
r=$(q "select public.zella_create_business_draft('$F'::jsonb, '$K3') ->> 'existing'"); wait $bg
[ "$r" = "true" ] && [ "$(q "select count(*) from public.businesses where creation_key = '$K3'")" = "1" ] && [ "$(count 'Key Test Dental')" = "3" ] && ok "the same key twice at once gives one business" || bad "concurrent: $r $(count 'Key Test Dental')"
out=$(q "select public.zella_create_business_draft('$F'::jsonb, null)" 2>&1)
[[ "$out" == *CREATION_KEY_REQUIRED* ]] && ok "a missing key is refused" || bad "null key: $out"

# duplicates
q "insert into public.businesses (name, industry_id, phone, website) values ('Bright Smile Dental', '$IND', '+1 (555) 201-3344', 'https://www.brightsmile.example/contact');
   insert into public.businesses (name, industry_id, phone, website, cancelled_at) values ('Gone Dental', '$IND', '555-777-8888', 'gone.example', now())" > /dev/null
d() { q "select coalesce(string_agg(e ->> 'name' || ':' || (select string_agg(x, '+' order by x) from jsonb_array_elements_text(e -> 'matched') x), ',' order by e ->> 'name'), '') from jsonb_array_elements(public.zella_business_duplicates($1, null)) e"; }
[ "$(d "'bright smile, dental!', null, null, null")" = "Bright Smile Dental:name" ] && ok "a duplicate by name (case and punctuation ignored)" || bad "name: $(d "'bright smile, dental!', null, null, null")"
[ "$(d "'Other', '555.201.3344', null, null")" = "Bright Smile Dental:phone" ] && ok "a duplicate by phone (last 10 digits)" || bad "phone: $(d "'Other', '555.201.3344', null, null")"
[ "$(d "'Other', null, 'brightsmile.example', null")" = "Bright Smile Dental:website" ] && ok "a duplicate by web domain" || bad "domain: $(d "'Other', null, 'brightsmile.example', null")"
[ "$(d "'Bright Smile Dental', '5552013344', 'http://brightsmile.example', null")" = "Bright Smile Dental:name+phone+website" ] && ok "every match is named" || bad "all"
[ -z "$(d "'Gone Dental', '5557778888', 'gone.example', null")" ] && ok "cancelled businesses are not duplicates" || bad "cancelled: $(d "'Gone Dental', '5557778888', 'gone.example', null")"
self=$(q "select id from public.businesses where name = 'Bright Smile Dental'")
[ -z "$(d "'Bright Smile Dental', null, null, '$self'")" ] && ok "the business itself is left out" || bad "exclude"
own=$(q "select count(*) from jsonb_array_elements(public.zella_business_duplicates('Key Test Dental', null, null, null, '$K1'))")
all=$(q "select count(*) from jsonb_array_elements(public.zella_business_duplicates('Key Test Dental', null, null, null, null))")
[ "$own" = "$((all - 1))" ] && ok "a retry doesn't warn about the business its own first try made" || bad "own key: $own of $all"
[ -z "$(d "'', '12', 'localhost', null")" ] && ok "blank, short or dotless values match nothing" || bad "blank: $(d "'', '12', 'localhost', null")"
g=$(q "select has_function_privilege('authenticated', 'public.zella_create_business_draft(jsonb,uuid)', 'execute')::text || has_function_privilege('anon', 'public.zella_business_duplicates(text,text,text,uuid,uuid)', 'execute')::text || has_function_privilege('authenticated', 'public.zella_business_duplicates(text,text,text,uuid,uuid)', 'execute')::text || has_function_privilege('service_role', 'public.zella_business_duplicates(text,text,text,uuid,uuid)', 'execute')::text")
[ "$g" = "falsefalsefalsetrue" ] && ok "only the server may call either function" || bad "grants: $g"

"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
s=$(q "select (to_regprocedure('public.zella_create_business_draft(jsonb,uuid)') is null)::text || (to_regprocedure('public.zella_business_duplicates(text,text,text,uuid,uuid)') is null)::text || (select count(*) from information_schema.columns where table_name = 'businesses' and column_name = 'creation_key')")
[ "$s" = "truetrue0" ] && ok "rollback removes both functions and the column" || bad "rollback state: $s"
[ "$(q "select md5(pg_get_functiondef('public.zella_create_business_draft(jsonb)'::regprocedure))")" = "$one" ] && ok "the one argument function is exactly as before" || bad "fingerprint after rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_business_duplicates(p_name text, p_phone text, p_website text, p_exclude uuid, p_creation_key uuid) returns jsonb language sql as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift not caught: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
