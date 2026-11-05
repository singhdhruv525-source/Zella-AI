#!/usr/bin/env bash
# Staging test of the ten industry migrations (4 Nov 2026), on an ISOLATED Postgres only. Never point at production.
#   1. build: production schema (sql/baseline + the hardening already live in production) + production reference data
#      (industries, presets, automation templates: $REF, exported read-only, no customer data) + synthetic businesses
#      (seed.sql: four shaped like production, one per industry with records)
#   2. snapshot "before"; take the pre-deploy backups exactly as the deployment notes say
#   3. apply the ten migrations in order, print each report, then apply all of them again (must change nothing)
#   4. checks.sql: nothing lost, every record still valid, roles, privacy, capabilities, presets, receptionist
#   5. generate the rollback from before/after, run it on a copy, and require schema and data to match "before"
#   6. re-apply the migrations after the rollback (a second deploy must work)
# Usage: REF=/path/to/reference_fixtures.sql tests/staging/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
H=${ZPG_HOST:-/var/lib/postgresql/zella-sec}; PT=${ZPG_PORT:-55433}
PSQL="psql -h $H -p $PT -U postgres -qtAX -v ON_ERROR_STOP=1"
REF=${REF:?set REF to the reference data export}
OUT=${OUT:-$HERE/out}; mkdir -p "$OUT"
FAILS=0; fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }; pass() { echo "PASS $*"; }
LIVE=(zella_invitation_hardening zella_billing_hardening zella_mfa_enforcement zella_platform_alerts_policy_fix)
TEN=(zella_viewer_read_only zella_staff_add_lead zella_call_content_privacy zella_capabilities zella_record_links_secrets zella_money
     zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules zella_readiness zella_appointment_records zella_record_files zella_ai_caller_fixes zella_message_courtesy zella_google_leads zella_calendar_providers zella_store_orders)

# 1. build
extra=(); for m in "${LIVE[@]}"; do extra+=("$REPO/sql/$m.sql"); done
"$REPO/sql/baseline/restore.sh" zstg "${extra[@]}" > "$OUT/build.log" 2>&1 || { echo "build failed"; tail -3 "$OUT/build.log"; exit 1; }
$PSQL -d zstg -c "set session_replication_role = replica" -f "$REF" > /dev/null 2>&1 || { echo "reference data failed"; exit 1; }
$PSQL -d zstg -f "$HERE/seed.sql" > "$OUT/seed.log" 2>&1 || { echo "seed failed"; grep -m3 ERROR "$OUT/seed.log"; exit 1; }
pass "staging built: production schema, production reference data, synthetic businesses ($(grep -o 'staging seed.*' "$OUT/seed.log"))"

# 2. before
# a frozen copy is "before"; the rollback must bring the database back to exactly this
psql -h $H -p $PT -U postgres -qX -c "drop database if exists zstg_before" -c "create database zstg_before template zstg" > /dev/null 2>&1
$PSQL -d zstg_before -f "$HERE/snapshot.sql" > "$OUT/before.json"
$PSQL -d zstg -c "create table public.backup_20261104_presets as select * from public.industry_crm_presets;
                  create table public.backup_20261104_types as select * from public.crm_record_types;
                  create table public.backup_20261104_records as select id, data from public.crm_records;" > /dev/null
pass "pre-deploy backups taken (presets, record types, record data)"

# 3. the ten migrations, in order, each report printed; then all again
for m in "${TEN[@]}"; do
  out=$($PSQL -d zstg -f "$REPO/sql/$m.sql" 2>&1) || { fail "$m: $(echo "$out" | grep -m1 ERROR)"; continue; }
  rep=$(echo "$out" | grep -oE "NOTICE:  (zella_|capability|sensitive|presets).*" | grep -v "does not exist, skipping" | sed 's/NOTICE:  //' | paste -sd';' -)
  pass "applied $m${rep:+ ($rep)}"
done
for m in "${TEN[@]}"; do
  out=$($PSQL -d zstg -f "$REPO/sql/$m.sql" 2>&1) || fail "second run of $m: $(echo "$out" | grep -m1 ERROR)"
done
rep=$($PSQL -d zstg -f "$REPO/sql/zella_presets_v2.sql" 2>&1 | grep -o "presets v2:.*")
[[ "$rep" == *"0 presets changed, 0 title labels renamed"*"0 types added or upgraded, 0 private values moved"* ]] && pass "second run of all of them changes nothing ($rep)" || fail "second run not idle: $rep"

# 4. checks
$PSQL -d zstg -f "$HERE/snapshot.sql" > "$OUT/after.json"
# on a copy, because the checks write (a test save, a test invoice, the timers) and the rollback must start clean
psql -h $H -p $PT -U postgres -qX -c "drop database if exists zstg_chk" -c "create database zstg_chk template zstg" > /dev/null
counts=$(python3 -I -c "import json,sys; print(json.dumps({'counts': json.load(open(sys.argv[1]))['counts']}))" "$OUT/before.json")
out=$($PSQL -d zstg_chk -v before="$counts" -f "$HERE/checks.sql" 2>&1); code=$?
echo "$out" | grep -oE "(PASS|INFO) .*"; [ $code -ne 0 ] && fail "checks: $(echo "$out" | grep -m1 -A2 -E 'ERROR|Assert')"

# 5. rollback: generated from before/after, run on a copy, compared with before
python3 -I "$HERE/make_rollback.py" zstg_before zstg "$REPO/sql/rollback/industry_2026_11_04_rollback.sql" > /dev/null || fail "rollback generation"
psql -h $H -p $PT -U postgres -qX -c "drop database if exists zstg_rb" -c "create database zstg_rb template zstg" > /dev/null
out=$($PSQL -d zstg_rb -f "$REPO/sql/rollback/industry_2026_11_04_rollback.sql" 2>&1) || fail "rollback: $(echo "$out" | grep -m2 ERROR)"
$PSQL -d zstg_rb -c "drop table public.backup_20261104_presets, public.backup_20261104_types, public.backup_20261104_records" > /dev/null
$PSQL -d zstg_rb -f "$HERE/snapshot.sql" > "$OUT/rolled_back.json"
python3 -I - "$OUT/before.json" "$OUT/rolled_back.json" <<'EOF' && pass "rollback returns schema and data exactly to before (functions, grants, policies, triggers, views, tables, columns, every row)" || fail "rollback differs from before (see above)"
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
bad = []
for part in ("schema", "data"):
    for k in sorted(set(a[part]) | set(b[part])):
        if a[part].get(k) != b[part].get(k): bad.append(f"{part}.{k}")
if bad: print("  differs:", ", ".join(bad[:40])); sys.exit(1)
EOF
# rollback after customers used the new features: nothing they recorded may be lost
psql -h $H -p $PT -U postgres -qX -c "drop database if exists zstg_used" -c "create database zstg_used template zstg" > /dev/null 2>&1
out=$($PSQL -d zstg_used 2>&1 <<'SQL'
select set_config('request.jwt.claims', json_build_object('sub', md5('stg-s-plumbing-owner')::uuid, 'role', 'authenticated', 'aal', 'aal1')::text, false);
select public.zella_set_capability(md5('stg-s-plumbing')::uuid, 'access_vault', false);
select public.zella_create_charge(md5('stg-s-plumbing')::uuid, 'invoice', 12345, 'after deploy');
select public.zella_save_record(md5('stg-s-plumbing')::uuid, 'properties', id, title, status, customer_id, assigned_to, due_at, data || '{"access": "New code 9876"}')
  from public.crm_records where business_id = md5('stg-s-plumbing')::uuid and type_key = 'properties' and title = 'Property 1';
reset role;
select public.zella_calendar_connect_provider(md5('stg-s-plumbing')::uuid, 'outlook', md5('stg-s-plumbing-owner')::uuid, 'owner@plumbing.test', 'rt-staging-outlook');
SQL
) || fail "using the new features: $(echo "$out" | grep -m1 ERROR)"
out=$($PSQL -d zstg_used -f "$REPO/sql/rollback/industry_2026_11_04_rollback.sql" 2>&1) || fail "rollback after use: $(echo "$out" | grep -m1 ERROR)"
r=$($PSQL -d zstg_used -c "select (select data ->> 'access' from public.crm_records where business_id = md5('stg-s-plumbing')::uuid and type_key = 'properties' and title = 'Property 1')
  || '|' || (select count(*) from public.customer_charges_rolled_back_20261104) || '|' || (select count(*) from public.business_capabilities_rolled_back_20261104)
  || '|' || (to_regclass('public.crm_record_secrets') is null)
  || '|' || (select count(*) from public.calendar_connections_outlook_rolled_back_20261104) || '|' || (select count(*) from vault.secrets where name = 'zella_cal_outlook_' || md5('stg-s-plumbing')::uuid)
  || '|' || (select pg_get_constraintdef(oid) from pg_constraint where conname = 'calendar_connections_provider_check')")
[ "$r" = "New code 9876|1|1|true|1|1|CHECK ((provider = 'google'::text))" ] && pass "rollback after use keeps what customers recorded: the new access code back in the record, invoice, capability choice and Outlook calendar connection (with its key) kept" || fail "rollback after use: $r"

# rollback without backups is refused
out=$($PSQL -d zstg_before -f "$REPO/sql/rollback/industry_2026_11_04_rollback.sql" 2>&1) && fail "rollback ran without backups" || { echo "$out" | grep -q ROLLBACK_NEEDS_BACKUPS && pass "rollback refuses to run without the pre-deploy backups" || fail "rollback without backups: $(echo "$out" | grep -m1 ERROR)"; }

# 6. deploy again after the rollback
$PSQL -d zstg_rb -c "create table public.backup_20261104_presets as select * from public.industry_crm_presets;
                     create table public.backup_20261104_types as select * from public.crm_record_types;" > /dev/null
ok=1; for m in "${TEN[@]}"; do out=$($PSQL -d zstg_rb -f "$REPO/sql/$m.sql" 2>&1) || { ok=0; fail "re-deploy $m: $(echo "$out" | grep -m1 ERROR)"; }; done
[ $ok = 1 ] && pass "the migrations apply again after a rollback"

echo; [ $FAILS = 0 ] && echo "STAGING: ALL PASSED" || { echo "STAGING: $FAILS FAILED"; exit 1; }
