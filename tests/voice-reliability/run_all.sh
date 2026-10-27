#!/bin/bash
# Voice reliability phase 1 tests, on a STAGING copy of the live database functions (never production).
# Needs a local Postgres (ZPSQL, default: the session's local cluster), node, python3 and deno (DENO).
# Builds: zbase = live functions as they are; zvoice = live functions + sql/zella_voice_reliability.sql. Exits 1 on any failure.
set -u
cd "$(dirname "$0")"; HERE=$(pwd); REPO=$(cd ../.. && pwd)
export ZPSQL=${ZPSQL:-"psql -q -At -v ON_ERROR_STOP=1 -h /var/tmp/zella-pg -p 54329 -U postgres"}
DENO=${DENO:-deno}
FAILS=0; fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }; pass() { echo "PASS $*"; }
run() { su nobody -s /bin/bash -c "$ZPSQL -d $1"; }
q() { echo "$2" | run "$1"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zella-voice.XXXX"); chmod 755 "$WORK"

echo "== build the staging copy from the repo, checked against the live function checksums (prod_md5.txt)"
python3 -I build_functions.py prod_md5.txt "$REPO/sql" "$WORK/functions.sql" | tail -1
python3 -I rebuild_ai_voice.py "$REPO/sql" prod_md5.txt "$WORK/ai_voice.sql" || exit 1
{ cat tables.sql "$WORK/functions.sql" live_two.sql "$WORK/ai_voice.sql"
  echo "create unique index callbacks_one_live_idx on public.callbacks (business_id, public.zella_digits(contact_number), reason) where contact_number is not null and status <> all (array['completed','cancelled','needs_review']);"; } > "$WORK/staging.sql"
for DB in zbase zvoice; do
  echo "drop database if exists $DB; create database $DB;" | su nobody -s /bin/bash -c "${ZPSQL/-v ON_ERROR_STOP=1/} -d postgres" >/dev/null 2>&1
  run $DB < "$WORK/staging.sql" > /dev/null || { echo "staging build failed"; exit 1; }
done
q zvoice "select string_agg(p.proname || '=' || md5(p.prosrc), ' ' order by p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname like 'zella_%'" | tr ' ' '\n' | sort > "$WORK/l.txt"
tr ' ' '\n' < prod_md5.txt | sort | diff - "$WORK/l.txt" > /dev/null && pass "staging copy reproduces all $(wc -l < "$WORK/l.txt") live function bodies exactly" || { fail "staging copy differs from production"; exit 1; }
for i in 1 2; do run zvoice < "$REPO/sql/zella_voice_reliability.sql" > /dev/null 2>&1 || fail "migration run $i"; done
[ "$(q zvoice "select count(*) from jsonb_each(zella_voice_reliability_status()) where value = 'true'::jsonb")" = 10 ] && pass "migration applied twice; all 10 patches in place" || fail "patch status"

count() { q "$1" "$2"; }
race() { ./race.sh "$1" "$2" "$3" > "$WORK/race.out" 2>&1; }
echo "== booking concurrency (20 at the same instant), before (zbase) and after (zvoice)"
for DB in zbase zvoice; do
  run $DB < fixture.sql
  race $DB 20 "select 'booked' from public.zella_book_appointment('aaaaaaaa-0000-4000-8000-000000000001', null, 'C%i', '2026-11-02 10:00 America/New_York', 30, null, null, null);"
  n=$(count $DB "select count(*) from appointments where start_time = '2026-11-02 10:00 America/New_York'")
  if [ $DB = zbase ]; then echo "   before: $n appointments for one slot"; else [ "$n" = 1 ] && pass "20 simultaneous bookings -> 1 appointment" || fail "after fix: $n appointments"; fi
done
run zvoice < fixture.sql
q zvoice "insert into appointments (id, business_id, title, start_time, end_time) select ('dddddddd-0000-4000-8000-0000000000' || lpad(g::text, 2, '0'))::uuid, 'aaaaaaaa-0000-4000-8000-000000000001', 'm', '2026-11-03 09:00 America/New_York'::timestamptz + g * interval '30 minutes', '2026-11-03 09:30 America/New_York'::timestamptz + g * interval '30 minutes' from generate_series(1, 6) g" > /dev/null
race zvoice 20 "select case when %i <= 8 then (select 'b' from public.zella_book_appointment('aaaaaaaa-0000-4000-8000-000000000001', null, 'B', '2026-11-02 11:00 America/New_York', 30, null, null, null)) when %i <= 14 then (select 'h' from public.zella_hold_slot('aaaaaaaa-0000-4000-8000-000000000001', null, 'H', '2026-11-02 11:00 America/New_York', 30, null, 15)) else (select 'm' from public.zella_reschedule_appointment(('dddddddd-0000-4000-8000-0000000000' || lpad((%i - 14)::text, 2, '0'))::uuid, '2026-11-02 11:00 America/New_York', null, 'staff')) end;"
[ "$(count zvoice "select count(*) from appointments where start_time = '2026-11-02 11:00 America/New_York'")" = 1 ] && pass "mixed book/hold/reschedule race -> 1" || fail "mixed race"
run zvoice < fixture.sql
q zvoice "insert into staff_members (business_id, name, working_hours) select 'aaaaaaaa-0000-4000-8000-000000000001', n, '{\"mon\":{\"on\":true,\"start\":\"09:00\",\"end\":\"17:00\"}}' from unnest(array['A','B']) n" > /dev/null
race zvoice 20 "select 'b' from public.zella_book_appointment('aaaaaaaa-0000-4000-8000-000000000001', null, 'S', '2026-11-02 10:00 America/New_York', 30, null, null, null);"
[ "$(count zvoice "select count(distinct staff_id) || '/' || count(*) from appointments where start_time = '2026-11-02 10:00 America/New_York'")" = 2/2 ] && pass "two free staff -> exactly 2 bookings, one each" || fail "staff race"
for DB in zbase zvoice; do
  run $DB < fixture.sql
  race $DB 20 "select (r ->> 'status') || coalesce('-' || (r ->> 'repeated'), '') from (select public.zella_ai_tool('dup-1', 'aaaaaaaa-0000-4000-8000-000000000001', 'book_appointment', '{\"confirmed\": true, \"start\": \"2026-11-02T15:00:00Z\", \"first_name\": \"Ana\", \"phone\": \"+15551230001\"}'::jsonb) r) x;"
  okn=$(grep -c "booked" "$WORK/race.out" || true); oks=$(grep -o '[0-9]* booked' "$WORK/race.out" | awk '{s+=$1} END {print s+0}')
  race $DB 20 "select r ->> 'status' from (select public.zella_ai_tool('d-%i', 'aaaaaaaa-0000-4000-8000-000000000001', 'book_appointment', ('{\"confirmed\": true, \"start\": \"2026-11-02T16:00:00Z\", \"first_name\": \"C%i\", \"phone\": \"+1555777' || lpad('%i', 4, '0') || '\"}')::jsonb) r) x;"
  diffc=$(count $DB "select count(*) from appointments where start_time = '2026-11-02T16:00:00Z' and booking_state = 'confirmed'")
  if [ $DB = zbase ]; then echo "   before: identical retries answered 'booked' $oks/20 times; different callers booked into one slot: $diffc"
  else [ "$oks" = 20 ] && pass "20 identical in-flight retries -> all answered 'booked', one appointment" || fail "retries: $oks/20"
       [ "$diffc" = 1 ] && pass "20 different callers -> 1 booked" || fail "different callers: $diffc"; fi
done
echo "== call rows"
for DB in zbase zvoice; do
  run $DB < fixture.sql
  race $DB 10 "select public.zella_ai_voice('vc-777', 'aaaaaaaa-0000-4000-8000-000000000001', 'rules', '{}'::jsonb) is not null;"
  n=$(count $DB "select count(*) from calls where external_call_id = 'vc-777'")
  if [ $DB = zbase ]; then echo "   before: 10 parallel first tool calls -> $n call rows"; else [ "$n" = 1 ] && pass "10 parallel first tool calls -> 1 call row" || fail "call rows $n"; fi
done
echo "== rules, lifecycle, transfer (assertions inside)"
for t in rules_test lifecycle_test transfer_test; do
  run zvoice < fixture.sql
  out=$(run zvoice < $t.sql 2>&1); echo "$out" | grep -o 'PASS.*' ; echo "$out" | grep -q 'ERROR' && fail "$t: $(echo "$out" | grep ERROR | head -1)"
done
echo "== Brain Tools code nodes against the patched functions"
run zvoice < fixture.sql
q zvoice "insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'pn-A'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'pn-B')" > /dev/null
node brain-flow.mjs || FAILS=$((FAILS + 1))
echo "== voice-rules edge function end to end (HTTP -> function -> staging database)"
run zvoice < fixture.sql
q zvoice "insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'pn-A'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'pn-B');
  insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'R', 'receptionist', true), ('b0000000-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-000000000002', 'R', 'receptionist', true);
  insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{\"transfer_number\": \"+15550101111\", \"transfer_open_hours_only\": false}'), ('b0000000-0000-4000-8000-00000000000b', '{\"transfer_enabled\": false}')" > /dev/null
node mock-rest.mjs > "$WORK/mock.log" 2>&1 & MOCK=$!
( cd "$REPO/web/supabase/functions/voice-rules" && exec env SUPABASE_URL=http://127.0.0.1:54400 ZELLA_SERVER_SECRET_KEY=test-key ZELLA_VAPI_SECRET=s3cret-test NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
  "$DENO" run --allow-net --allow-env --allow-read --allow-sys index.ts > "$WORK/fn.log" 2>&1 ) & FN=$!
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:8000 && break; sleep 1; done
NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 node edge-e2e.mjs | tee "$WORK/edge.out"; grep -q '^FAIL' "$WORK/edge.out" && FAILS=$((FAILS + 1))
kill $FN $MOCK 2>/dev/null; wait $FN $MOCK 2>/dev/null
rm -rf "$WORK"
echo; [ $FAILS = 0 ] && echo "ALL PASSED" || echo "$FAILS FAILED"; exit $([ $FAILS = 0 ] && echo 0 || echo 1)
