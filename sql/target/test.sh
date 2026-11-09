#!/usr/bin/env bash
# Loads the Zella Voice target schema into a fresh ISOLATED local test database and runs the three-business isolation
# suite, plus a concurrent double-booking check. Never points at production: the shared guard refuses anything except
# the throwaway local test cluster. Usage: sql/target/test.sh   (exits 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
H=${ZPG_HOST:-/var/lib/postgresql/zella-sec}; P=${ZPG_PORT:-55433}; DB=ztarget
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$H" "$P" "$DB" || exit 1
PSQL=(psql -h "$H" -p "$P" -U postgres -X -q)

"${PSQL[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null || exit 1
sed "s/current_database_placeholder/$DB/" "$REPO/sql/baseline/00_supabase_stubs.sql" | "${PSQL[@]}" -v ON_ERROR_STOP=1 -d "$DB" -f - >/dev/null || { echo "FAILED loading stubs"; exit 1; }
"${PSQL[@]}" -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/zella_voice_schema.sql" >/dev/null || { echo "FAILED loading schema"; exit 1; }
"${PSQL[@]}" -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/industries_seed.sql" >/dev/null || { echo "FAILED loading industries"; exit 1; }
echo "schema loaded: $("${PSQL[@]}" -d "$DB" -tAc "select count(*) from pg_tables where schemaname='public'") tables, $("${PSQL[@]}" -d "$DB" -tAc "select count(*) from pg_policies where schemaname in ('public','storage')") policies"

OUT=$("${PSQL[@]}" -d "$DB" -f "$HERE/test_isolation.sql" 2>&1)
echo "$OUT" | grep -oE "(PASS|FAIL) .*"
ERR=$(echo "$OUT" | grep -E "ERROR|FAIL" | grep -v "^psql.*NOTICE" | head -5)

# Concurrency: two transactions race for the same resource and time; exactly one may win.
"${PSQL[@]}" -d "$DB" -c "insert into appointments (id, business_id, location_id, customer_id, starts_at, ends_at, source) values
  ('aa200000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000000','a1000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','2026-12-02 15:00+00','2026-12-02 16:00+00','staff'),
  ('aa200000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000000','a1000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','2026-12-02 15:00+00','2026-12-02 16:00+00','staff')" >/dev/null
race() { "${PSQL[@]}" -d "$DB" -c "begin; insert into resource_reservations (business_id, resource_id, appointment_id, kind, period) values ('aaaaaaaa-0000-0000-0000-000000000000','a4000000-0000-0000-0000-000000000001','$1','booking','[2026-12-02 15:00+00,2026-12-02 16:00+00)'); select pg_sleep(1); commit;" >/dev/null 2>&1 && echo ok || echo refused; }
race aa200000-0000-0000-0000-000000000001 & P1=$!
race aa200000-0000-0000-0000-000000000002 & P2=$!
wait $P1 $P2
WON=$("${PSQL[@]}" -d "$DB" -tAc "select count(*) from resource_reservations where period && '[2026-12-02 15:00+00,2026-12-02 16:00+00)' and active")
if [ "$WON" = "1" ]; then echo "PASS concurrent double booking: exactly one of two simultaneous requests won"; else echo "FAIL concurrent double booking: $WON reservations"; ERR="${ERR}race"; fi

PASSES=$(echo "$OUT" | grep -c "PASS"); [ "$WON" = "1" ] && PASSES=$((PASSES + 1))
echo; if [ -z "$ERR" ]; then echo "ALL PASSED ($PASSES checks)"; else echo "FAILED:"; echo "$ERR"; exit 1; fi
