#!/usr/bin/env bash
# Security regression tests on an ISOLATED Postgres: restores sql/baseline (the live schema, no data), applies the
# migrations under test, then runs each *_test.sql and the concurrency checks. Never point this at production.
# Usage: [ZPG_HOST=... ZPG_PORT=...] tests/security/run.sh        Exits 1 on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
PSQL="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -X -q -v ON_ERROR_STOP=1"
FAILS=0; fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
MIGRATIONS=(${MIGRATIONS:-zella_invitation_hardening zella_billing_hardening zella_mfa_enforcement zella_platform_roles_fix zella_platform_alerts_policy_fix zella_viewer_read_only zella_staff_add_lead zella_call_content_privacy zella_capabilities zella_record_links_secrets zella_money zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules})

for t in "$HERE"/*_test.sql; do
  name=$(basename "$t" _test.sql); db="zsec_$name"
  extra=(); for m in "${MIGRATIONS[@]}"; do [ -f "$REPO/sql/$m.sql" ] && extra+=("$REPO/sql/$m.sql"); done
  out=$("$REPO/sql/baseline/restore.sh" "$db" "${extra[@]}" 2>&1) || { fail "restore for $name: $(echo "$out" | grep -m2 -E 'ERROR|FAILED')"; continue; }
  # each migration must also be safe to run twice
  for m in "${extra[@]}"; do out=$({ echo "set check_function_bodies = off;"; cat "$m"; } | $PSQL -d "$db" -f - 2>&1) || fail "second run of $(basename "$m"): $(echo "$out" | grep -m1 ERROR)"; done
  out=$($PSQL -d "$db" -f "$t" 2>&1); code=$?
  echo "$out" | grep -o 'PASS .*'
  [ $code -ne 0 ] && fail "$name: $(echo "$out" | grep -m1 -A2 -E 'ERROR|Assert')"
  [ -x "$HERE/${name}_concurrency.sh" ] && { "$HERE/${name}_concurrency.sh" "$db" || fail "$name concurrency"; }
done
echo; [ $FAILS = 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
