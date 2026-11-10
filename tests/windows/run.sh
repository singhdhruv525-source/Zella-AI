#!/usr/bin/env bash
# BM1 arrival windows (sql/zella_arrival_windows.sql) on an ISOLATED copy of production. WITHOUT_FIX=1 runs without it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zwindows
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
APPLIED=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages zella_holiday_availability zella_delivery_evidence)
FIX=("$REPO/sql/zella_arrival_windows.sql" "$REPO/sql/zella_arrival_windows.sql"); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
"$REPO/tests/lib/build_full.sh" $DB $(for m in "${APPLIED[@]}"; do echo "$REPO/sql/$m.sql"; done) "${FIX[@]}" || exit 1
out=$($P -d $DB -f "$HERE/windows_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
echo "ALL PASSED"
