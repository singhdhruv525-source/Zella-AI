#!/usr/bin/env bash
# Billing step 2 (sql/zella_billing_allowances.sql) on an ISOLATED copy of the production state: applied twice, the
# checks in test.sql, then the rollback (compared exactly with the state before) and a second apply. Never production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbilling
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
# what production has on top of the 5 Nov state (tests/deploy/run_all.sh PENDING + LATER, without the unapplied
# zella_workflow_alert_email)
LIVE=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages
  zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables zella_relationships zella_scheduling zella_slots_resource_blocks zella_record_workflows
  zella_batch1_security zella_batch3_pagination zella_brand_name zella_rollback_security zella_n8n_webhook_auth zella_record_files_purge_retry zella_replace_business_hours
  zella_order_lookup_reservations zella_review_sql_fixes zella_seating_handoff)
"$REPO/tests/lib/build_full.sh" $DB "$REPO/tests/channel/fixture.sql" $(for m in "${LIVE[@]}"; do echo "$REPO/sql/$m.sql"; done) || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
STATE="select md5(string_agg(x, ',' order by x)) from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) x from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '') from information_schema.columns where table_schema = 'public' and table_name not like '%_rolled_back'
  union all select 't:' || tgrelid::regclass::text || '.' || tgname from pg_trigger where not tgisinternal and tgrelid::regclass::text not like '%_rolled_back'
  union all select 'p:' || tablename || '.' || policyname || ':' || coalesce(qual, '') from pg_policies where schemaname = 'public'
  union all select 'g:' || table_name || ':' || grantee || ':' || privilege_type from information_schema.role_table_grants where table_schema = 'public' and table_name not like '%_rolled_back') s"
# the functions this file patches must be the versions production runs (hashes read from production, 13 Nov 2026)
WANT="zella_call_allowance(uuid):e9caedba965b340087dbaecafa3f2cfa,zella_check_usage_thresholds():0a0b9ee06fd726dba2a2128de13e8564,zella_entitlement_allows(uuid,text,numeric):98e44e3f03ebc5bdc3568219efe8ea6f,zella_entitlements(uuid):54600ffe083ac534eb4b5be20129586e,zella_evaluate_call_usage_thresholds(uuid):b9bfd17c814666e9a3e971374e179285,zella_language_allowance(uuid):98785c44af0b483c038ba9b6425da693,zella_save_usage_preferences(uuid,integer[],text,bigint,text):152e9fdc7f5ad0a65416ba682d0cffc6,zella_usage_preferences(uuid):808efaa459d19b2fb84a1524dcf3fb6e"
HAVE=$("${P[@]}" -d $DB -c "select string_agg(regexp_replace(p.oid::regprocedure::text, '^public\.', '') || ':' || md5(prosrc), ',' order by regexp_replace(p.oid::regprocedure::text, '^public\.', '') collate \"C\") from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.oid::regprocedure::text ~ '^(public\.)?zella_(call_allowance|check_usage_thresholds|entitlement_allows|entitlements|evaluate_call_usage_thresholds|language_allowance|save_usage_preferences|usage_preferences)\('")
[ "$HAVE" = "$WANT" ] && ok "the 8 patched functions match production's versions" || bad "patched functions differ from production: $HAVE"
before=$("${P[@]}" -d $DB -c "$STATE")
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_billing_allowances.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice (safe to re-run)"
out=$("${P[@]}" -d $DB -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*' ; [ $code -ne 0 ] && bad "test.sql: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT|DETAIL' | tr '\n' ' ')"
# concurrency: 20 sessions at once, each subtracting 30 minutes from one business (500 minutes), and 10 sessions sending
# the same key: the period lock serialises them, nothing is subtracted twice and no balance is overdrawn
X=b1000000-0000-4000-8000-0000000000ff
before_used=$("${P[@]}" -d $DB -c "select coalesce(sum(quantity), 0) from public.usage_charges where business_id = '$X' and resource = 'minutes'")
for i in $(seq 1 20); do "${P[@]}" -d $DB -c "select public.zella_usage_consume('$X', 'minutes', 30, 'race-distinct-$i', 'admin', null)" > /dev/null 2>&1 & done
for i in $(seq 1 10); do "${P[@]}" -d $DB -c "select public.zella_usage_consume('$X', 'minutes', 7, 'race-same-key', 'admin', null)" > /dev/null 2>&1 & done
wait
r=$("${P[@]}" -d $DB -c "select (select count(*) from public.usage_charges where idempotency_key like 'race-%') || '/' ||
  (select coalesce(sum(quantity), 0) from public.usage_charges where business_id = '$X' and resource = 'minutes') - $before_used || '/' ||
  (select sum(used) from public.allowance_buckets where business_id = '$X' and resource = 'minutes') || '/' ||
  (select coalesce(sum(over_quantity), 0) from public.usage_charges where business_id = '$X' and resource = 'minutes') || '/' ||
  (select count(*) from public.allowance_buckets where business_id = '$X' and used > granted)")
[ "$r" = "21/607.0000/500.0000/112.0000/0" ] && ok "concurrency: 20 + 10 sessions at once: 21 charges (one for the shared key), 607 minutes recorded, 500 used, 112 over, no balance overdrawn" || bad "concurrency: $r"
# a rollback needs every subscription on a shared plan again (it refuses otherwise): give the test ones a test plan
"${P[@]}" -d $DB -c "insert into public.plans (id, name, slug) values ('b1900000-0000-4000-8000-000000000001', 'TEST rollback plan', 'test-rollback') on conflict do nothing" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_billing_allowances_rollback.sql" 2>&1) && bad "rollback ran with subscriptions on no shared plan" || ok "rollback refuses while a subscription has no shared plan (nothing changed)"
"${P[@]}" -d $DB -c "update public.subscriptions set plan_id = 'b1900000-0000-4000-8000-000000000001' where plan_id is null" > /dev/null
# rollback: back exactly to the state before (the billing history is kept, renamed), then a second apply works
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_billing_allowances_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 ERROR)"; break; }; done
after=$("${P[@]}" -d $DB -c "$STATE")
[ "$after" = "$before" ] && ok "rollback (run twice) returns functions, columns, triggers, policies and grants exactly to the state before" || bad "rollback differs from the state before"
"${P[@]}" -d $DB -c "select count(*) from public.business_plans_rolled_back" > /dev/null 2>&1 && ok "rollback keeps the billing history (renamed)" || bad "billing history not kept"
"${P[@]}" -d $DB -c "do \$\$ declare t text; begin foreach t in array array['usage_charges','allowance_buckets','pack_purchases','auto_reload_settings','billing_periods','billing_pack_catalog','business_plans'] loop execute format('drop table public.%I cascade', t || '_rolled_back'); end loop; end \$\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_billing_allowances.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply after rollback: $(echo "$out" | grep -m1 ERROR)"
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
