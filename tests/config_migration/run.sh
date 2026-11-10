#!/usr/bin/env bash
# sql/zella_config_migration.sql on an ISOLATED copy of the production state (with sql/zella_channel_review.sql).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zconfigmig
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
"$REPO/tests/lib/build_full.sh" $DB "$REPO/sql/zella_channel_review.sql" "$REPO/sql/zella_config_migration.sql" "$REPO/sql/zella_config_migration.sql" || exit 1
out=$($P -d $DB -f "$HERE/migration_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
echo "ALL PASSED"
