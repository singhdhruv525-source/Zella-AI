#!/bin/bash
# Tests for the 2026-10-28 features (on-call rota, languages, review replies, cross-sell, scorecards, status page),
# on a STAGING copy (never production). Needs the voice-reliability staging database zvoice
# (tests/voice-reliability/run_all.sh builds it) and a local Postgres (ZPSQL). Exits 1 on any failure.
set -u
cd "$(dirname "$0")"; HERE=$(pwd); REPO=$(cd ../.. && pwd)
export ZPSQL=${ZPSQL:-"psql -q -At -v ON_ERROR_STOP=1 -h /var/tmp/zella-pg -p 54329 -U postgres"}
FAILS=0; fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }; pass() { echo "PASS $*"; }
run() { su nobody -s /bin/bash -c "$ZPSQL -d $1"; }
q() { echo "$2" | run "$1"; }
DENO=${DENO:-deno}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zella-feat.XXXX"); chmod 755 "$WORK"
DB=zfeat
echo "drop database if exists $DB; create database $DB template zvoice;" | su nobody -s /bin/bash -c "${ZPSQL/-v ON_ERROR_STOP=1/} -d postgres" > /dev/null 2>&1 \
  || { echo "could not copy zvoice (run tests/voice-reliability/run_all.sh first)"; exit 1; }
run $DB < support.sql > /dev/null || exit 1
[ -f extra_tables.sql ] && { run $DB < extra_tables.sql > /dev/null || { echo "extra tables failed"; exit 1; }; }
for f in ${FEATURES:-on_call languages reviews cross_sell scorecards status}; do
  for i in 1 2; do out=$(run $DB < "$REPO/sql/zella_$f.sql" 2>&1) || fail "zella_$f.sql run $i: $(echo "$out" | grep -m1 ERROR)"; done
  [ $FAILS = 0 ] && pass "sql/zella_$f.sql applied twice"
  out=$(run $DB < "${f}_test.sql" 2>&1); echo "$out" | grep -o 'PASS.*'
  echo "$out" | grep -q 'ERROR' && fail "${f}_test: $(echo "$out" | grep -m1 -A2 ERROR)"
  [ -f "${f}_after.sh" ] && { . "./${f}_after.sh"; }
done
echo; [ $FAILS = 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
