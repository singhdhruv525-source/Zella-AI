#!/usr/bin/env bash
# Booking buffer and overlap guard (sql/zella_booking_buffers.sql) on an ISOLATED copy of the production state.
# WITHOUT_FIX=1 runs the same checks without the fix (they should fail).   Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbooking
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
FIX=("$REPO/sql/zella_booking_buffers.sql" "$REPO/sql/zella_booking_buffers.sql"); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
"$REPO/tests/lib/build_full.sh" $DB "${FIX[@]}" || exit 1
out=$($P -d $DB -f "$HERE/buffers_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }

# concurrency: two writers for overlapping times at the same moment, on different paths (the AI's booking function and a
# direct table write as the CRM does); the second must wait for the first and then be refused
D=$($P -d $DB -c "select (date_trunc('day', now()) + interval '3 days')::timestamptz")
$P -d $DB -c "begin; select public.zella_book_appointment('eb000000-0000-0000-0000-00000000000a', null, 'Race 1', '$D'::timestamptz + interval '13 hours', 30); select pg_sleep(2); commit;" > /tmp/zb_race1.txt 2>&1 &
sleep 0.7
$P -d $DB -c "insert into appointments (business_id, title, start_time, end_time, timezone, status) values ('eb000000-0000-0000-0000-00000000000a', 'Race 2', '$D'::timestamptz + interval '13 hours 20 minutes', '$D'::timestamptz + interval '13 hours 50 minutes', 'UTC', 'scheduled')" > /tmp/zb_race2.txt 2>&1
wait
n=$($P -d $DB -c "select count(*) from appointments where title like 'Race %' and status = 'scheduled'")
if [ "$n" = 1 ] && grep -q SLOT_TAKEN /tmp/zb_race2.txt; then echo "PASS concurrency: two overlapping bookings at the same moment (AI path and direct write): one is kept, the other is refused"
else echo "FAIL concurrency: $n kept; second writer said: $(head -c 200 /tmp/zb_race2.txt)"; exit 1; fi
echo "ALL PASSED"
