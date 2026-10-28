#!/bin/bash
# Spam protection (sql/zella_spam_protection.sql) together with voice reliability (sql/zella_voice_reliability.sql,
# sql/zella_vapi_auth.sql), applied in BOTH orders on isolated staging databases (zsv: spam first, zvs: spam last), each
# applied twice. Then: the booking race, the rules/lifecycle/transfer tests, a blocked-caller check and the voice-rules
# HTTP tests on the spam-last database. Staging only; never production. Exits 1 on any failure.
set -u
cd "$(dirname "$0")"; REPO=$(cd ../.. && pwd)
export ZPSQL=${ZPSQL:-"psql -q -At -v ON_ERROR_STOP=1 -h /var/tmp/zella-pg -p 54329 -U postgres"}
DENO=${DENO:-deno}
FAILS=0; fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }; pass() { echo "PASS $*"; }
run() { su nobody -s /bin/bash -c "$ZPSQL -d $1"; }
q() { echo "$2" | run "$1"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zella-spam.XXXX"); chmod 755 "$WORK"
python3 -I build_functions.py prod_md5.txt "$REPO/sql" "$WORK/functions.sql" > /dev/null
python3 -I rebuild_ai_voice.py "$REPO/sql" prod_md5.txt "$WORK/ai_voice.sql" || exit 1
python3 -I build_functions.py spam_md5.txt "$REPO/sql" "$WORK/spamfns.sql" > /dev/null
python3 -I build_phase4.py "$REPO/sql" "$WORK/phase4.sql" > /dev/null || exit 1
{ cat tables.sql "$WORK/functions.sql" live_two.sql "$WORK/ai_voice.sql"
  echo "create unique index callbacks_one_live_idx on public.callbacks (business_id, public.zella_digits(contact_number), reason) where contact_number is not null and status <> all (array['completed','cancelled','needs_review']);"
  cat spam_tables.sql "$WORK/spamfns.sql" "$WORK/phase4.sql"; } > "$WORK/staging.sql"
chmod 644 "$WORK"/*.sql
VR="$REPO/sql/zella_voice_reliability.sql"; AU="$REPO/sql/zella_vapi_auth.sql"; SP="$REPO/sql/zella_spam_protection.sql"
apply() { run "$1" < "$2" > "$WORK/apply.log" 2>&1 || { fail "$1: $(basename "$2"): $(grep -m1 ERROR "$WORK/apply.log")"; return 1; }; }
for DB in zsv zvs; do
  echo "drop database if exists $DB; create database $DB;" | su nobody -s /bin/bash -c "${ZPSQL/-v ON_ERROR_STOP=1/} -d postgres" >/dev/null 2>&1
  run $DB < "$WORK/staging.sql" > /dev/null || { echo "staging build failed"; exit 1; }
  if [ $DB = zsv ]; then order="$SP $VR $AU"; else order="$VR $AU $SP"; fi
  ok=1; for i in 1 2; do for f in $order; do apply $DB "$f" || ok=0; done; done
  [ $ok = 1 ] && pass "$DB: $(for f in $order; do basename "$f" .sql; done | tr '\n' ' ')applied twice in this order without errors"
done
for DB in zsv zvs; do
  echo "== $DB"
  run $DB < fixture.sql
  ./race.sh $DB 20 "select 'booked' from public.zella_book_appointment('aaaaaaaa-0000-4000-8000-000000000001', null, 'C%i', '2026-11-02 10:00 America/New_York', 30, null, null, null);" > "$WORK/race.out" 2>&1
  [ "$(q $DB "select count(*) from appointments where start_time = '2026-11-02 10:00 America/New_York'")" = 1 ] && pass "$DB: 20 simultaneous bookings -> 1 appointment" || fail "$DB booking race"
  run $DB < fixture.sql
  ./race.sh $DB 10 "select public.zella_ai_voice('vc-777', 'aaaaaaaa-0000-4000-8000-000000000001', 'rules', '{}'::jsonb) is not null;" > "$WORK/race.out" 2>&1
  [ "$(q $DB "select count(*) from calls where external_call_id = 'vc-777'")" = 1 ] && pass "$DB: 10 parallel first tool calls -> 1 call row (spam's call trigger in place)" || fail "$DB call rows"
  for t in rules_test lifecycle_test transfer_test auth_test spam_compat; do
    run $DB < fixture.sql
    [ $t = spam_compat ] && q $DB "insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'pn-A')" > /dev/null
    out=$(run $DB < $t.sql 2>&1); n=$(echo "$out" | grep -c 'PASS')
    if echo "$out" | grep -q 'ERROR'; then fail "$DB $t: $(echo "$out" | grep ERROR | head -1)"; else pass "$DB $t: $n checks"; fi
    [ $t = spam_compat ] && echo "$out" | grep -o 'PASS.*' | sed 's/^/   /'
  done
done
for DB in zsv zvs; do
echo "== voice-rules over HTTP on $DB"
run $DB < fixture.sql
q $DB "insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'pn-A'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'pn-B');
  insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'R', 'receptionist', true), ('b0000000-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-000000000002', 'R', 'receptionist', true);
  insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{\"transfer_number\": \"+15550101111\", \"transfer_open_hours_only\": false}'), ('b0000000-0000-4000-8000-00000000000b', '{\"transfer_enabled\": false}')" > /dev/null
export ZDB=$DB TEST_HMAC_SECRET="test-only-$(date +%s%N)-hmac" MOCK_CONTROL="$WORK/mock.ctl"
q $DB "delete from vault.decrypted_secrets where name like 'zella_vapi_%'; delete from platform_settings where key = 'vapi_auth_mode'; insert into vault.decrypted_secrets values ('zella_vapi_hmac_secret', '$TEST_HMAC_SECRET')" > /dev/null
: > "$MOCK_CONTROL"; chmod 666 "$MOCK_CONTROL"
node mock-rest.mjs > "$WORK/mock.log" 2>&1 & MOCK=$!
( cd "$REPO/web/supabase/functions/voice-rules" && exec env SUPABASE_URL=http://127.0.0.1:54400 ZELLA_SERVER_SECRET_KEY=test-key ZELLA_VOICE_RPC_MS=1500 ZELLA_VOICE_BUDGET_MS=4000 NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
  "$DENO" run --allow-net --allow-env --allow-read --allow-sys index.ts > "$WORK/fn.log" 2>&1 ) & FN=$!
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:8000 && break; sleep 1; done
NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 node edge-e2e.mjs > "$WORK/edge.out"; echo "   edge: $(tail -1 "$WORK/edge.out")"; grep '^FAIL' "$WORK/edge.out" && FAILS=$((FAILS + 1))
NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 node brain-e2e.mjs > "$WORK/brain.out" 2>&1; echo "   brain tools: $(tail -1 "$WORK/brain.out")"; grep '^FAIL\|Error' "$WORK/brain.out" && FAILS=$((FAILS + 1))
grep 'spam-screened' "$WORK/brain.out" | sed 's/^/   /'
kill $FN $MOCK 2>/dev/null; wait $FN $MOCK 2>/dev/null
done
rm -rf "$WORK"
echo; [ $FAILS = 0 ] && echo "ALL PASSED" || echo "$FAILS FAILED"; exit $([ $FAILS = 0 ] && echo 0 || echo 1)
