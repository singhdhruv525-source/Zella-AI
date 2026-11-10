#!/usr/bin/env bash
# Checks zella_require_isolated with psql replaced by a shell function, so no database is contacted. The stub answers
# the guard's one query with STUB_DATA_DIR and records each call; a refusal that happened before the query (bad host or
# port) leaves no call behind, so each case shows which check refused it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/isolated_guard.sh"
CALLS_FILE=$(mktemp); trap 'rm -f "$CALLS_FILE"' EXIT
psql() { echo call >> "$CALLS_FILE"; printf '%s\n' "$STUB_DATA_DIR"; }   # runs in $(...), so it counts in a file
fails=0
expect() {   # expect <accept|refuse> <calls expected> <label> <host> <port> <db>
  local want=$1 calls=$2 label=$3; shift 3
  : > "$CALLS_FILE"
  if zella_require_isolated "$@" 2>/dev/null; then got=accept; else got=refuse; fi
  CALLS=$(wc -l < "$CALLS_FILE" | tr -d " ")
  if [ "$got" = "$want" ] && [ "$CALLS" = "$calls" ]; then echo "PASS guard: $label"; else echo "FAIL guard: $label (got $got after $CALLS server calls)"; fails=$((fails + 1)); fi
}
OK=/var/lib/postgresql/zella-sec
STUB_DATA_DIR=$OK/data
expect accept 1 "the isolated test cluster is accepted"                         "$OK" 55433 zrel
expect refuse 0 "a host with a space and a second -h is refused before connecting" "$OK -h elsewhere" 55433 zrel
expect refuse 0 "a port that isn't a number is refused before connecting"        "$OK" "55433 -h elsewhere" zrel
expect refuse 0 "a network host is refused before connecting"                    localhost 55433 zrel
expect refuse 0 "a database that isn't a test database is refused"               "$OK" 55433 postgres_prod
ZELLA_ISOLATED_DIR=/var/lib/postgresql STUB_DATA_DIR=/var/lib/postgresql/15/main \
  expect refuse 1 "another cluster is refused, even with the old directory setting widened" "$OK" 55433 zrel
STUB_DATA_DIR='' expect refuse 1 "a connection that isn't over a socket (no data directory returned) is refused" "$OK" 55433 zrel
[ "$fails" = 0 ]
