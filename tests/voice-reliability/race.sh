#!/bin/bash
# race.sh <db> <n> <sql-per-session-with-%i>  : n sessions start the same statement at the same instant.
DB=$1; N=$2; SQL=$3; P="${ZPSQL/-v ON_ERROR_STOP=1/} -d $DB"
OUT=$(mktemp -d ${TMPDIR:-/tmp}/zella-race.XXXX); chmod 777 "$OUT"
# controller holds the barrier; every session waits for it, then runs the statement
( echo "select pg_advisory_lock(424242); select pg_sleep(3); select pg_advisory_unlock(424242);" | su nobody -s /bin/bash -c "$P" >/dev/null ) &
sleep 0.5
for i in $(seq 1 $N); do
  S=${SQL//%i/$i}
  ( printf "%s\n" "select pg_advisory_lock_shared(424242); select pg_advisory_unlock_shared(424242);" "$S" | su nobody -s /bin/bash -c "$P" > "$OUT/$i.out" 2> "$OUT/$i.err" ) &
done
wait
cat "$OUT"/*.out | grep -v '^$' | sort | uniq -c | sed 's/^/   ok: /'
cat "$OUT"/*.err | sed -E 's/^.*ERROR: +//' | grep -v '^$' | sort | uniq -c | sed 's/^/  err: /'
rm -rf "$OUT"
