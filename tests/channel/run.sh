#!/usr/bin/env bash
# sql/zella_channel_review.sql on an ISOLATED copy of the production state, with settings saved before it (fixture.sql).
# WITHOUT_FIX=1 runs the checks without it (they should fail).   Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zchannel
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
FIX=("$REPO/sql/zella_channel_review.sql" "$REPO/sql/zella_channel_review.sql"); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
"$REPO/tests/lib/build_full.sh" $DB "$HERE/fixture.sql" "${FIX[@]}" || exit 1
out=$($P -d $DB -f "$HERE/channel_review_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
echo "ALL PASSED"
