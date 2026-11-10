#!/usr/bin/env bash
# Builds an ISOLATED copy (as tests/calls/run.sh, without the call stack) + sql/zella_message_settings_fix.sql (twice)
# and runs settings_fix_test.sql. Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zmsg
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
SEVENTEEN=(zella_viewer_read_only zella_staff_add_lead zella_call_content_privacy zella_capabilities zella_record_links_secrets zella_money
  zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules zella_readiness zella_appointment_records zella_record_files
  zella_ai_caller_fixes zella_message_courtesy zella_google_leads zella_calendar_providers zella_store_orders)
"$REPO/sql/baseline/restore.sh" $DB "$REPO/sql/zella_invitation_hardening.sql" "$REPO/sql/zella_billing_hardening.sql" "$REPO/sql/zella_mfa_enforcement.sql" \
  "$REPO/sql/zella_platform_alerts_policy_fix.sql" "$REPO/sql/zella_platform_roles_fix.sql" > /dev/null 2>&1 || { echo restore failed; exit 1; }
$P -d $DB -f "$REPO/sql/zella_industries_seed.sql" > /dev/null && $P -d $DB -f "$REPO/tests/calls/industries_28.sql" > /dev/null
FIX=(zella_message_settings_fix zella_message_settings_fix); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
FNS="select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('zella_issue_quote', 'zella_queue_quote_followups', 'zella_appointment_after', 'zella_replace_reminders', 'zella_claim_reminders')"
for m in "${SEVENTEEN[@]}" zella_setup_enforcement; do
  out=$($P -d $DB -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
before=$($P -d $DB -c "$FNS")
for m in "${FIX[@]}"; do out=$($P -d $DB -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
out=$($P -d $DB -f "$HERE/settings_fix_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|assert|CONTEXT')"; exit 1; }
if [ "${WITHOUT_FIX:-}" != 1 ]; then
  $P -d $DB -f "$REPO/sql/rollback/zella_message_settings_fix_rollback.sql" > /dev/null 2>&1 || { echo "FAIL rollback did not run"; exit 1; }
  [ "$($P -d $DB -c "$FNS")" = "$before" ] && [ "$($P -d $DB -c "select count(*) from pg_proc where proname in ('zella_resync_reminders', 'zella_reminder_settings_trg')")" = 0 ] \
    || { echo "FAIL the rollback does not restore the five functions exactly"; exit 1; }
  $P -d $DB -f "$REPO/sql/zella_message_settings_fix.sql" > /dev/null 2>&1 || { echo "FAIL re-applying after the rollback"; exit 1; }
  echo "PASS rollback restores the five functions exactly and removes what the fix added; the fix applies again after it"
fi
echo "ALL PASSED"
