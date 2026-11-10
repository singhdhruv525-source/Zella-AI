#!/usr/bin/env bash
# Setup-enforcement tests on an ISOLATED Postgres: baseline + the live fixes + industry seed + the 17 pending migrations
# (in deployment order) + sql/zella_setup_enforcement.sql (twice), then the tests, then the rollback (and a re-deploy).
# Never point this at production.   Usage: [ZPG_HOST=... ZPG_PORT=...] tests/setup/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
. "$REPO/tests/lib/isolated_guard.sh"
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "zsetup" || exit 1
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
FAILS=0; fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
SEVENTEEN=(zella_viewer_read_only zella_staff_add_lead zella_call_content_privacy zella_capabilities zella_record_links_secrets zella_money
  zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules zella_readiness zella_appointment_records zella_record_files
  zella_ai_caller_fixes zella_message_courtesy zella_google_leads zella_calendar_providers zella_store_orders)
build() {
  "$REPO/sql/baseline/restore.sh" "$1" "$REPO/sql/zella_invitation_hardening.sql" "$REPO/sql/zella_billing_hardening.sql" "$REPO/sql/zella_mfa_enforcement.sql" \
    "$REPO/sql/zella_platform_alerts_policy_fix.sql" "$REPO/sql/zella_platform_roles_fix.sql" > /dev/null 2>&1 || { fail "restore $1"; return 1; }
  $P -d "$1" -f "$REPO/sql/zella_industries_seed.sql" > /dev/null 2>&1 || fail "seed"
  for m in "${SEVENTEEN[@]}"; do out=$($P -d "$1" -f "$REPO/sql/$m.sql" 2>&1) || fail "$m: $(echo "$out" | grep -m1 ERROR)"; done
}
fn_defs() { $P -d "$1" -c "select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('zella_brain_context','zella_ai_tool','zella_ai_booking','zella_ai_manage_booking')"; }

build zsetup || exit 1
before=$(fn_defs zsetup)
for i in 1 2; do out=$($P -d zsetup -f "$REPO/sql/zella_setup_enforcement.sql" 2>&1) || fail "apply run $i: $(echo "$out" | grep -m1 ERROR)"; done
out=$($P -d zsetup -f "$HERE/setup_enforcement_test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && fail "tests: $(echo "$out" | grep -m2 -E 'ERROR|assert')"

python3 -I "$HERE/make_rollback.py" > /dev/null || fail "rollback generation"
out=$($P -d zsetup -f "$REPO/sql/rollback/zella_setup_enforcement_rollback.sql" 2>&1) || fail "rollback: $(echo "$out" | grep -m2 ERROR)"
[ "$(fn_defs zsetup)" = "$before" ] && echo "PASS rollback puts the four patched functions back exactly as they were" || fail "rollback left the functions changed"
[ "$($P -d zsetup -c "select count(*) from knowledge_items where source_key like 'setup:%' and status <> 'archived'")" = "0" ] && echo "PASS rollback archives the knowledge made from setup answers" || fail "setup knowledge still live after rollback"
out=$($P -d zsetup -f "$REPO/sql/zella_setup_enforcement.sql" 2>&1) && echo "PASS re-deploy after rollback works" || fail "re-deploy: $(echo "$out" | grep -m1 ERROR)"

# the patches also apply without the 17 (order independence: they anchor on text both versions keep)
"$REPO/sql/baseline/restore.sh" zsetup_alone "$REPO/sql/zella_invitation_hardening.sql" > /dev/null 2>&1
$P -d zsetup_alone -f "$REPO/sql/zella_industries_seed.sql" > /dev/null 2>&1
out=$($P -d zsetup_alone -f "$REPO/sql/zella_setup_enforcement.sql" 2>&1) && echo "PASS applies on the current production schema too (before the 17)" || fail "alone: $(echo "$out" | grep -m1 ERROR)"
echo; [ $FAILS = 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
