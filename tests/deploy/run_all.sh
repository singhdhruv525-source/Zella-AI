#!/usr/bin/env bash
# The whole pending sequence of docs/DEPLOYMENT_MANIFEST_2026-11-05.md on a fresh ISOLATED copy of the production state
# (tests/lib/build_full.sh: the schema baseline + every migration production has, function-for-function identical to
# production as of 5 Nov), then every suite's checks on that one database, the runtime call handler (current and the
# older deployed-era voice-rules) against it, the edge function and web checks, the full rollback in reverse order
# (compared exactly with the state before), and a second apply after the rollback. Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zdeploy; export ZDB=$DB
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
SCR=${SCRATCH:-/tmp/zella-deploy}; mkdir -p "$SCR"
PENDING=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages
  zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables zella_relationships zella_scheduling zella_slots_resource_blocks zella_record_workflows)
ROLLBACK=(zella_record_workflows_rollback zella_slots_resource_blocks_rollback zella_scheduling_rollback zella_relationships_rollback zella_tables_rollback zella_arrival_windows_rollback zella_delivery_evidence_rollback zella_holiday_availability_rollback zella_plan_languages_rollback zella_assistant_delivery_rollback zella_knowledge_learning_rollback zella_report_schedules_rollback zella_config_migration_rollback zella_order_lookup_v2_rollback zella_knowledge_live_rollback zella_escalation_rules_rollback zella_channel_review_rollback
  zella_booking_buffers_rollback zella_platform_roles_fix_rollback)
# Files applied after the pending list, in production's order (DB-14). Kept apart from PENDING because other suites read
# PENDING and apply some of these themselves (tests/review_sql, tests/rollback_security, tests/batch3, ...).
# zella_brand_name goes before zella_review_sql_fixes: that file's version guards expect the branded wording.
LATER=(zella_batch1_security zella_batch3_pagination zella_brand_name zella_rollback_security zella_n8n_webhook_auth zella_record_files_purge_retry zella_replace_business_hours zella_order_lookup_reservations zella_review_sql_fixes zella_seating_handoff)
LATER_ROLLBACK=(zella_seating_handoff_rollback zella_review_sql_fixes_rollback zella_order_lookup_reservations_rollback zella_replace_business_hours_rollback zella_record_files_purge_retry_rollback zella_n8n_webhook_auth_rollback zella_rollback_security_rollback zella_brand_name_rollback zella_batch3_pagination_rollback zella_batch1_security_rollback)
ALL=("${PENDING[@]}" "${LATER[@]}"); ALL_ROLLBACK=("${LATER_ROLLBACK[@]}" "${ROLLBACK[@]}")
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
ITEMS="select x from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(regexp_replace(regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g'), '\s+', '', 'g')) x
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type from information_schema.columns where table_schema = 'public'
  union all select 't:' || tgrelid::regclass::text || '.' || tgname from pg_trigger where not tgisinternal and tgrelid::regclass::text not like 'pg_%'
  union all select 'p:' || tablename || '.' || policyname from pg_policies where schemaname in ('public', 'storage')) s
  where x not like '%_rolled_back%'
    and x not in ('c:appointments.resource_ids:ARRAY', 'c:appointments.crew_staff_ids:ARRAY', 'c:blocked_times.resource_id:uuid', 'c:crm_record_types.workflow:jsonb', 'c:calls.transfer_approved_at:timestamp with time zone')
    and x not like 'c:store_lookup_guards.%'
    and x not like 'f:zella_receive_inbound_email(text,jsonb):%'"   # checked on its own below (INBOUND)   # what a rollback keeps on purpose: order-lookup guard rows (an unresolved lookup must survive a re-apply), the inbound-email receiver once any business has a 32-character address (zella_rollback_security_rollback), and also renamed tables, the Release 2 columns with their values, each record type's Release 3 workflow setting, and when a transfer was approved (CodeRabbit #44 finding 11: never delete customer data)
STATE="select md5(string_agg(x, ',' order by x)) from ($ITEMS) y"
INBOUND="select md5(pg_get_functiondef('public.zella_receive_inbound_email(text,jsonb)'::regprocedure))"
LONG_TOKENS="select exists (select 1 from public.businesses where inbound_email_token ~ '^[a-f0-9]{32}\$')"

# 1. production state, plus settings that existed before the pending files (they must find them)
"$REPO/tests/lib/build_full.sh" $DB "$REPO/tests/channel/fixture.sql" || exit 1
before=$($P -d $DB -c "$STATE"); inbound_before=$($P -d $DB -c "$INBOUND")
# 2. the pending files, in order, each twice
for m in "${ALL[@]}"; do for i in 1 2; do
  out=$($P -d $DB -f "$REPO/sql/$m.sql" 2>&1) || { bad "apply $m (run $i): $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done; done; ok "the ${#ALL[@]} pending and later files apply in order, each twice (safe to re-run)"
after=$($P -d $DB -c "$STATE")

# 3. every suite's checks on the one database (each fixture uses its own ids)
for t in tests/setup/setup_enforcement_test.sql tests/booking/buffers_test.sql tests/channel/channel_review_test.sql tests/escalation/escalation_test.sql \
         tests/orders/v2_test.sql tests/crm_updates/updates_test.sql tests/config_migration/migration_test.sql tests/reports/report_test.sql tests/knowledge/learning_test.sql \
         tests/assistant/delivery_test.sql tests/plans/languages_test.sql tests/windows/windows_test.sql tests/tables/tables_test.sql tests/tables/seating_test.sql \
         tests/relationships/test.sql tests/scheduling/test.sql tests/slotblocks/test.sql tests/workflows/test.sql; do
  out=$($P -d $DB -f "$REPO/$t" 2>&1) && ok "$t: $(echo "$out" | grep -c 'PASS ') checks" || bad "$t: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"
done
# tests/messaging M3 checks the channel review's behaviour when that file is applied (AI-call reminders held, not texted)
out=$($P -d $DB -f "$REPO/tests/messaging/settings_fix_test.sql" 2>&1) && ok "tests/messaging/settings_fix_test.sql: $(echo "$out" | grep -c 'PASS ') checks (M3 in its channel-review form)" || bad "messaging: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

# 4. the call handler at runtime against the new database: today's voice-rules, and the older one (before order lookup)
run_matrix() {  # $1 = functions dir root, $2 = label
  pkill -f "local-backend.mjs" 2>/dev/null; pkill -f "run-function.ts voice-rules" 2>/dev/null; sleep 1
  ZFUNCTIONS='{"voice-rules":54406}' node "$REPO/tests/browser/local-backend.mjs" > "$SCR/backend.log" 2>&1 &
  SUPABASE_URL=http://localhost:54321 SUPABASE_ANON_KEY=sb_publishable_local_test_only ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only \
    SUPABASE_SERVICE_ROLE_KEY=sb_secret_local_test_only deno run -A --no-lock --config "$1/web/supabase/functions/voice-rules/deno.json" \
    "$1/tests/browser/run-function.ts" voice-rules 54406 > "$SCR/vr.log" 2>&1 &
  for i in $(seq 1 40); do curl -s -o /dev/null http://localhost:54321/ && grep -q "voice-rules on" "$SCR/vr.log" && break; sleep 1; done
  out=$(ZMATRIX_ASSISTANT=${3:-0} node "$REPO/tests/calls/contrast_matrix.mjs" 2>&1); code=$?
  [ $code -eq 0 ] && ok "$2: $(echo "$out" | tail -1)" || bad "$2: $(echo "$out" | grep -m3 FAIL | tr '\n' ' ')"
  pkill -f "local-backend.mjs"; pkill -f "run-function.ts voice-rules"
}
run_matrix "$REPO" "28 industries x 2 businesses through the current voice-rules (incl. assistant-request)" 1
OLD=98f120a^
rm -rf "$SCR/old" && git -C "$REPO" worktree add -f --detach "$SCR/old" $OLD > /dev/null 2>&1 && cp "$REPO/tests/browser/run-function.ts" "$SCR/old/tests/browser/run-function.ts"
[ -d "$SCR/old/web" ] && run_matrix "$SCR/old" "the same through the voice-rules before order lookup ($(git -C "$REPO" rev-parse --short $OLD), the deployed-era code)" || bad "old voice-rules checkout"
git -C "$REPO" worktree remove --force "$SCR/old" > /dev/null 2>&1

# 5. edge functions and web of this commit
(cd "$REPO/web/supabase/functions/voice-rules" && deno test --no-lock -A > "$SCR/vr-test.log" 2>&1) && ok "voice-rules: $(grep -E 'passed' "$SCR/vr-test.log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')" || bad "voice-rules tests"
(cd "$REPO/web/supabase/functions/owner-provision-business" && deno test --no-lock -A > "$SCR/op-test.log" 2>&1) && ok "owner-provision-business: $(grep -E 'passed' "$SCR/op-test.log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')" || bad "owner-provision-business tests"
for f in voice-rules owner-provision-business; do (cd "$REPO/web/supabase/functions/$f" && deno check --no-lock index.ts > /dev/null 2>&1) && ok "deno check $f" || bad "deno check $f"; done
(cd "$REPO/web" && npm run build > "$SCR/web.log" 2>&1) && ok "web build" || bad "web build: $(tail -3 "$SCR/web.log")"

# Seed an approval independently of the schema comparison's intentional column exclusion.
APPROVAL_ID=97000000-0000-0000-0000-000000000001
out=$($P -d $DB -c "set session_replication_role = replica; insert into public.calls (id, business_id, direction, transfer_approved_at) values ('$APPROVAL_ID', '97000000-0000-0000-0000-000000000002', 'inbound', '2026-11-05 12:34:56+00');" 2>&1) || { bad "seed transfer approval: $out"; exit 1; }
check_approval() {
  out=$($P -d $DB -c "do \$\$ begin assert exists (select 1 from information_schema.columns where table_schema='public' and table_name='calls' and column_name='transfer_approved_at'); assert (select transfer_approved_at = timestamptz '2026-11-05 12:34:56+00' from public.calls where id='$APPROVAL_ID'); end \$\$;" 2>&1) && ok "transfer approval timestamp retained $1" || bad "transfer approval $1: $out"
}

# 6. roll the whole sequence back, newest first, and compare with the state before
SEATING="select md5(string_agg(x, '|' order by x)) from (
  select 'rt:' || to_jsonb(t)::text x from restaurant_tables t union all select 'tc:' || to_jsonb(t)::text from table_combinations t
  union all select 'tb:' || to_jsonb(t)::text from table_blocks t union all select 'ts:' || to_jsonb(t)::text from table_states t
  union all select 'te:' || to_jsonb(t)::text from table_events t
  union all select 'cap:' || to_jsonb(c)::text from business_capabilities c where capability = 'tables'
  union all select 'ap:' || id || ':' || table_ids::text from appointments where table_ids is not null
  union all select 'wl:' || id || ':' || concat_ws(',', party_size, preferences, contact_ok) from waitlist_entries where party_size is not null or preferences is not null or contact_ok is not null) s"
out=$($P -d $DB -c "set session_replication_role = replica;
  insert into table_states (table_id, business_id, state, since) select id, business_id, 'needs_clearing', '2026-11-05 20:00+00' from restaurant_tables
   where business_id = '5f000000-0000-0000-0000-0000000000c1' order by name limit 1
   on conflict (table_id) do update set state = 'needs_clearing', since = excluded.since;
  insert into business_capabilities (business_id, capability, enabled, updated_at) values ('5f000000-0000-0000-0000-0000000000c1', 'tables', true, '2026-11-05 12:00+00')
   on conflict (business_id, capability) do update set enabled = true;
  do \$\$ begin
    assert exists (select 1 from table_states where business_id = '5f000000-0000-0000-0000-0000000000c1' and state = 'needs_clearing' and since = timestamptz '2026-11-05 20:00+00');
    assert exists (select 1 from business_capabilities where business_id = '5f000000-0000-0000-0000-0000000000c1' and capability = 'tables' and enabled);
  end \$\$;" 2>&1) || { bad "seed seating snapshot: $out"; exit 1; }
seating_before=$($P -d $DB -c "$SEATING")
for r in "${ALL_ROLLBACK[@]}"; do out=$($P -d $DB -f "$REPO/sql/rollback/$r.sql" 2>&1) || { bad "rollback $r: $(echo "$out" | grep -m1 ERROR)"; break; }; done
check_approval "after rollback"
# the inbound-email receiver goes back exactly, unless a business already has a 32-character address (then it is kept on purpose)
if [ "$($P -d $DB -c "$INBOUND")" = "$inbound_before" ]; then ok "inbound-email receiver restored exactly"
elif [ "$($P -d $DB -c "$LONG_TOKENS")" = t ]; then ok "inbound-email receiver kept on purpose: 32-character addresses are in use"
else bad "inbound-email receiver neither restored nor justified"; fi
now=$($P -d $DB -c "$STATE")
kept=$($P -d $DB -c "select string_agg(table_name, ', ') from information_schema.tables where table_schema = 'public' and table_name like '%_rolled_back'")
if [ "$now" = "$before" ]; then ok "full rollback, newest first: every function, column, trigger and policy identical to before (kept on purpose, renamed: $kept)"
else
  $P -d $DB -c "$ITEMS order by 1" > "$SCR/after_rollback.txt"
  tests_db=zdeploy_ref; "$REPO/tests/lib/build_full.sh" $tests_db "$REPO/tests/channel/fixture.sql" > /dev/null; $P -d $tests_db -c "$ITEMS order by 1" > "$SCR/before.txt"
  bad "full rollback differs: $(diff "$SCR/before.txt" "$SCR/after_rollback.txt" | grep '^[<>]' | head -8 | tr '\n' ' ')"
fi
# 7. and the sequence applies again after a rollback
for m in "${ALL[@]}"; do out=$($P -d $DB -f "$REPO/sql/$m.sql" 2>&1) || { bad "re-apply $m after rollback: $(echo "$out" | grep -m1 ERROR)"; break; }; done
check_approval "after reapply"
if out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1); then
  seating_after=$($P -d $DB -c "$SEATING")
  [[ "$seating_before" =~ ^[0-9a-f]{32}$ ]] && [ "$seating_after" = "$seating_before" ] \
    && ok "seating data (tables, combinations, blocks, events, states, capability, assignments, waitlist details) identical after rollback, re-apply and restore" \
    || bad "seating data differs after restore ($seating_before vs $seating_after)"
else bad "seating restore: $(echo "$out" | grep -m1 ERROR)"; fi
[ "$($P -d $DB -c "$STATE")" = "$after" ] && ok "re-apply after the rollback" || bad "re-apply differs from the first apply"
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
