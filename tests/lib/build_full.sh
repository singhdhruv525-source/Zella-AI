#!/usr/bin/env bash
# Builds an ISOLATED database with everything production has after the 5 Nov apply (docs/PRODUCTION_APPLY_2026-11-05.md):
# the schema baseline, the live fix files, 28 industries, the 17 migrations and the 3 fixes. Kept as template "zfull"
# (rebuilt when any input file changes); each caller gets its own copy.
#   tests/lib/build_full.sh <db> [extra.sql ...]      Never point this at production.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
DB="$1"; shift
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# live fix files production has (zella_platform_roles_fix is NOT live: it is pending, see docs/DEPLOYMENT_MANIFEST_2026-11-05.md)
LIVE=(zella_invitation_hardening zella_billing_hardening zella_mfa_enforcement zella_platform_alerts_policy_fix)
APPLIED=(zella_viewer_read_only zella_staff_add_lead zella_call_content_privacy zella_capabilities zella_record_links_secrets zella_money
  zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules zella_readiness zella_appointment_records zella_record_files
  zella_ai_caller_fixes zella_message_courtesy zella_google_leads zella_calendar_providers zella_store_orders
  zella_setup_enforcement zella_message_settings_fix zella_order_lookup_assurance)
inputs=$(cat "$REPO"/sql/baseline/*.sql "$REPO/sql/zella_industries_seed.sql" "$REPO/tests/calls/industries_28.sql" \
  $(for m in "${LIVE[@]}" "${APPLIED[@]}"; do echo "$REPO/sql/$m.sql"; done) 2>/dev/null | md5sum | cut -c1-12)
have=$($P -d postgres -c "select shobj_description(oid, 'pg_database') from pg_database where datname = 'zfull'")
if [ "$have" != "$inputs" ]; then
  $P -d postgres -c "drop database if exists zfull" > /dev/null 2>&1
  "$REPO/sql/baseline/restore.sh" zfull $(for m in "${LIVE[@]}"; do echo "$REPO/sql/$m.sql"; done) > /dev/null 2>&1 || { echo "build: restore failed" >&2; exit 1; }
  $P -d zfull -f "$REPO/sql/zella_industries_seed.sql" > /dev/null && $P -d zfull -f "$REPO/tests/calls/industries_28.sql" > /dev/null || { echo "build: industries failed" >&2; exit 1; }
  for m in "${APPLIED[@]}"; do out=$($P -d zfull -f "$REPO/sql/$m.sql" 2>&1) || { echo "build: $m failed: $(echo "$out" | grep -m1 ERROR)" >&2; exit 1; }; done
  $P -d postgres -c "comment on database zfull is '$inputs'" > /dev/null
fi
$P -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('zfull', '$DB') and pid <> pg_backend_pid()" > /dev/null
$P -d postgres -c "drop database if exists $DB" > /dev/null 2>&1
$P -d postgres -c "create database $DB template zfull" > /dev/null || { echo "build: copy failed" >&2; exit 1; }
for f in "$@"; do out=$($P -d "$DB" -f "$f" 2>&1) || { echo "build: $(basename "$f") failed: $(echo "$out" | grep -m1 ERROR)" >&2; exit 1; }; done
