#!/usr/bin/env bash
# Before-and-after scenarios through the real voice-rules on an ISOLATED copy of production (all applied files, plus
# any pending ones listed in PENDING). Never point this at production.   WITHOUT_FIX=1 leaves the pending files out.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433} ZDB=${ZDB:-ze2e}
APPLIED=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages zella_holiday_availability zella_delivery_evidence)
PENDING=(zella_arrival_windows); [ "${WITHOUT_FIX:-}" = 1 ] && PENDING=()
"$REPO/tests/lib/build_full.sh" "$ZDB" $(for m in "${APPLIED[@]}" "${PENDING[@]}"; do echo "$REPO/sql/$m.sql"; done) > /dev/null || { echo "build failed"; exit 1; }
pkill -f "local-backend.mjs" 2>/dev/null; pkill -f "run-function.ts voice-rules" 2>/dev/null; sleep 1
mkdir -p "$HERE/out"
ZFUNCTIONS='{"voice-rules":54406}' node "$REPO/tests/browser/local-backend.mjs" > "$HERE/out/backend.log" 2>&1 &
SUPABASE_URL=http://localhost:54321 SUPABASE_ANON_KEY=sb_publishable_local_test_only ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only \
  SUPABASE_SERVICE_ROLE_KEY=sb_secret_local_test_only deno run -A --no-lock --config "$REPO/web/supabase/functions/voice-rules/deno.json" \
  "$REPO/tests/browser/run-function.ts" voice-rules 54406 > "$HERE/out/voice-rules.log" 2>&1 &
for i in $(seq 1 40); do curl -s -o /dev/null http://localhost:54321/ && grep -q "voice-rules on" "$HERE/out/voice-rules.log" && break; sleep 1; done
node "$HERE/scenarios.mjs"; code=$?
pkill -f "local-backend.mjs"; pkill -f "run-function.ts voice-rules"
exit $code
