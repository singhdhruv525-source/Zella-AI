#!/usr/bin/env bash
# CRM updates reaching the receptionist, on an ISOLATED copy of the production state + sql/zella_knowledge_live.sql.
# WITHOUT_FIX=1 runs without it (the knowledge checks should fail).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zcrmupdates
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
FIX=("$REPO/sql/zella_knowledge_live.sql" "$REPO/sql/zella_knowledge_live.sql"); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
"$REPO/tests/lib/build_full.sh" $DB "${FIX[@]}" || exit 1
out=$($P -d $DB -f "$HERE/updates_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
echo "ALL PASSED"
