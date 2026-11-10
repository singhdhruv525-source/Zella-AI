#!/usr/bin/env bash
# Builds an ISOLATED database (baseline + live fixes + 28 industries + the 17 pending migrations + setup enforcement),
# serves the real voice-rules function behind the local Supabase stand-in, and runs contrast_matrix.mjs.
# Never point this at production.   Usage: tests/calls/run.sh [--keep]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433} ZDB=${ZDB:-zcalls}
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
SEVENTEEN=(zella_viewer_read_only zella_staff_add_lead zella_call_content_privacy zella_capabilities zella_record_links_secrets zella_money
  zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules zella_readiness zella_appointment_records zella_record_files
  zella_ai_caller_fixes zella_message_courtesy zella_google_leads zella_calendar_providers zella_store_orders)
"$REPO/sql/baseline/restore.sh" "$ZDB" "$REPO/sql/zella_invitation_hardening.sql" "$REPO/sql/zella_billing_hardening.sql" "$REPO/sql/zella_mfa_enforcement.sql" \
  "$REPO/sql/zella_platform_alerts_policy_fix.sql" "$REPO/sql/zella_platform_roles_fix.sql" > /dev/null 2>&1 || { echo "restore failed"; exit 1; }
$P -d "$ZDB" -f "$REPO/sql/zella_industries_seed.sql" > /dev/null && $P -d "$ZDB" -f "$HERE/industries_28.sql" > /dev/null || { echo "industries failed"; exit 1; }
EXTRA=(zella_setup_enforcement); [ "${WITHOUT_FIX:-}" = 1 ] && EXTRA=()
for m in "${SEVENTEEN[@]}" "${EXTRA[@]}"; do out=$($P -d "$ZDB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "migration $m failed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
echo "database: $($P -d "$ZDB" -c "select count(*) from industries") industries"

pkill -f "local-backend.mjs" 2>/dev/null; pkill -f "run-function.ts voice-rules" 2>/dev/null; sleep 1
ZFUNCTIONS='{"voice-rules":54406}' node "$REPO/tests/browser/local-backend.mjs" > "$HERE/out-backend.log" 2>&1 &
SUPABASE_URL=http://localhost:54321 SUPABASE_ANON_KEY=sb_publishable_local_test_only ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only \
  SUPABASE_SERVICE_ROLE_KEY=sb_secret_local_test_only deno run -A --no-lock --config "$REPO/web/supabase/functions/voice-rules/deno.json" \
  "$REPO/tests/browser/run-function.ts" voice-rules 54406 > "$HERE/out-voice-rules.log" 2>&1 &
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:54321/ && grep -q "voice-rules on" "$HERE/out-voice-rules.log" && break; sleep 1; done
node "$HERE/contrast_matrix.mjs"; code=$?
[ "${1:-}" = "--keep" ] || { pkill -f "local-backend.mjs"; pkill -f "run-function.ts voice-rules"; }
exit $code
