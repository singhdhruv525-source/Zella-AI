#!/usr/bin/env bash
# sql/zella_tenant_business_id.sql on an ISOLATED copy of the production state (never production): existing rows are
# backfilled; new rows get their parent's business; a wrong business, or a missing parent, is refused; a parent moved
# to another business carries its rows; policies and other tables are unchanged; an orphan stops the file and leaves
# nothing behind; the rollback restores the schema exactly without touching rows; it applies again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=ztenantbiz
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" ztenantbizorphan || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
LIVE=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages
  zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables zella_relationships zella_scheduling zella_slots_resource_blocks zella_record_workflows
  zella_batch1_security zella_batch3_pagination zella_brand_name zella_rollback_security zella_n8n_webhook_auth zella_record_files_purge_retry zella_replace_business_hours
  zella_order_lookup_reservations zella_review_sql_fixes zella_seating_handoff)
"$REPO/tests/lib/build_full.sh" $DB "$REPO/tests/channel/fixture.sql" $(for m in "${LIVE[@]}"; do echo "$REPO/sql/$m.sql"; done) > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
A=ec000000-0000-0000-0000-00000000000a; B=ec000000-0000-0000-0000-00000000000b
# rows that exist before the migration (test data), one per table
q "insert into ai_agents (id, business_id, name, agent_type) values ('a1000000-0000-4000-8000-000000000001', '$A', 'R', 'receptionist');
   insert into ai_agent_configs (agent_id) values ('a1000000-0000-4000-8000-000000000001');
   insert into conversations (id, business_id, channel) values ('c1000000-0000-4000-8000-000000000001', '$A', 'sms');
   insert into conversation_messages (conversation_id, sender_type, content) values ('c1000000-0000-4000-8000-000000000001', 'customer', 'hello');
   insert into business_report_schedules (id, business_id, local_hour) values ('d1000000-0000-4000-8000-000000000001', '$A', 8);
   insert into business_report_runs (schedule_id, local_date, status) values ('d1000000-0000-4000-8000-000000000001', current_date, 'sent');
   insert into integrations (id, business_id, provider, integration_type) values ('e1000000-0000-4000-8000-000000000001', '$A', 'test', 'test');
   insert into integration_secrets (integration_id) values ('e1000000-0000-4000-8000-000000000001');
   insert into automations (id, business_id, name, trigger_type) values ('f1000000-0000-4000-8000-000000000001', '$A', 'T', 'test');
   insert into industry_automation_runs (automation_id, record_id, step) values ('f1000000-0000-4000-8000-000000000001', gen_random_uuid(), 'first');" > /dev/null \
  || { bad "could not seed the test rows"; exit 1; }
q "insert into staff_members (id, business_id, name) values ('b1000000-0000-4000-8000-000000000001', '$A', 'Test staff')" > /dev/null
SHIFT=$(q "insert into on_call_shifts (business_id, staff_id, kind, starts_at, ends_at) values ('$A', 'b1000000-0000-4000-8000-000000000001', 'cover', now(), now() + interval '1 day') returning id") \
  && q "insert into on_call_reminders_sent (shift_id, starts_at) values ('$SHIFT', now())" > /dev/null || { bad "could not seed an on-call reminder"; exit 1; }
TABLES="'ai_agent_configs','conversation_messages','business_report_runs','integration_secrets','on_call_reminders_sent','industry_automation_runs'"
# everything except the six tables' new parts: columns, constraints, indexes, policies, triggers, function bodies
SCHEMA="select md5(string_agg(x, ',' order by x)) from (
  select 'c:' || table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '') x from information_schema.columns where table_schema = 'public'
  union all select 'k:' || conrelid::regclass::text || ':' || conname || ':' || pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'i:' || indexdef from pg_indexes where schemaname = 'public'
  union all select 'p:' || tablename || '.' || policyname || ':' || coalesce(qual, '') || ':' || coalesce(with_check, '') from pg_policies where schemaname = 'public'
  union all select 't:' || tgrelid::regclass::text || '.' || tgname from pg_trigger where not tgisinternal
  union all select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f') s"
POLICIES="select md5(string_agg(tablename || policyname || coalesce(qual, '') || coalesce(with_check, ''), ',' order by 1)) from pg_policies where schemaname = 'public'"
ROWS="select md5(string_agg(t || ':' || n, ',' order by t)) from (select 'ai_agent_configs' t, count(*) n from ai_agent_configs union all select 'conversation_messages', count(*) from conversation_messages
  union all select 'business_report_runs', count(*) from business_report_runs union all select 'integration_secrets', count(*) from integration_secrets
  union all select 'on_call_reminders_sent', count(*) from on_call_reminders_sent union all select 'industry_automation_runs', count(*) from industry_automation_runs) s"
schema_before=$(q "$SCHEMA"); policies_before=$(q "$POLICIES"); rows_before=$(q "$ROWS")

# an orphan stops the file and leaves nothing behind (a copy, so the main test database stays clean)
"${P[@]}" -d postgres -c "drop database if exists ztenantbizorphan" -c "create database ztenantbizorphan template $DB" > /dev/null
"${P[@]}" -d ztenantbizorphan -c "insert into industry_automation_runs (automation_id, record_id, step) values (gen_random_uuid(), gen_random_uuid(), 'orphan')" > /dev/null
o_before=$("${P[@]}" -d ztenantbizorphan -c "$SCHEMA")
out=$("${P[@]}" -d ztenantbizorphan -f "$REPO/sql/zella_tenant_business_id.sql" 2>&1) && bad "an orphan did not stop the file" || {
  echo "$out" | grep -q ORPHANS && [ "$("${P[@]}" -d ztenantbizorphan -c "$SCHEMA")" = "$o_before" ] && [ "$("${P[@]}" -d ztenantbizorphan -c "select count(*) from industry_automation_runs where step = 'orphan'")" = 1 ] \
    && ok "an orphan row stops the file (ORPHANS), nothing is changed and the row is kept" || bad "orphan run: $(echo "$out" | grep -m1 ERROR)"; }
"${P[@]}" -d postgres -c "drop database if exists ztenantbizorphan" > /dev/null

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_tenant_business_id.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
[ "$(q "select count(*) from information_schema.columns where table_schema = 'public' and table_name in ($TABLES) and column_name = 'business_id' and is_nullable = 'NO' and data_type = 'uuid'")" = 6 ] \
  && ok "all six tables have a required business_id" || bad "business_id columns: $(q "select string_agg(table_name, ',') from information_schema.columns where table_name in ($TABLES) and column_name = 'business_id'")"
[ "$(q "select count(*) from pg_constraint where contype = 'f' and conname in (select t || '_business_id_fkey' from unnest(array[$TABLES]) t) and confdeltype = 'c'")" = 6 ] \
  && [ "$(q "select count(*) from pg_indexes where indexname in (select t || '_business_id_idx' from unnest(array[$TABLES]) t)")" = 6 ] \
  && ok "each has a foreign key to businesses (on delete cascade) and an index" || bad "foreign keys or indexes missing"
[ "$(q "select count(*) from (select business_id from ai_agent_configs union all select business_id from conversation_messages union all select business_id from business_report_runs
      union all select business_id from integration_secrets union all select business_id from industry_automation_runs union all select business_id from on_call_reminders_sent) s where business_id <> '$A'")" = 0 ] \
  && [ "$(q "$ROWS")" = "$rows_before" ] && [ "$(q "select count(*) from on_call_reminders_sent")" = 1 ] && ok "existing rows (one in each of the six tables) are backfilled with their parent's business, and no row is added or lost" || bad "backfill"
[ "$(q "$POLICIES")" = "$policies_before" ] && ok "row security policies are unchanged (expand step only)" || bad "policies changed"

out=$("${P[@]}" -d $DB 2>&1 <<SQL
do \$\$ declare m uuid; v uuid; begin
  -- a new row gets its parent's business without naming it
  insert into conversation_messages (conversation_id, sender_type, content) values ('c1000000-0000-4000-8000-000000000001', 'ai', 'hi') returning id, business_id into m, v;
  assert v = '$A', 'new message got ' || coalesce(v::text, 'nothing');
  -- naming another business is refused
  begin
    insert into conversation_messages (conversation_id, sender_type, content, business_id) values ('c1000000-0000-4000-8000-000000000001', 'ai', 'x', '$B');
    raise exception 'a message was filed under another business';
  exception when check_violation then if sqlerrm not like 'TENANT_MISMATCH%' then raise; end if; end;
  -- moving a row's business by hand is refused
  begin
    update conversation_messages set business_id = '$B' where id = m;
    raise exception 'a message was moved to another business by hand';
  exception when check_violation then if sqlerrm not like 'TENANT_MISMATCH%' then raise; end if; end;
  -- a parent that doesn't exist is refused (these two tables had no foreign key to their parent)
  begin
    insert into industry_automation_runs (automation_id, record_id, step) values (gen_random_uuid(), gen_random_uuid(), 'x');
    raise exception 'a run without an automation was accepted';
  exception when foreign_key_violation then if sqlerrm not like 'TENANT_MISMATCH%' then raise; end if; end;
  -- a parent moved to another business carries its rows
  update conversations set business_id = '$B' where id = 'c1000000-0000-4000-8000-000000000001';
  assert (select bool_and(business_id = '$B') from conversation_messages where conversation_id = 'c1000000-0000-4000-8000-000000000001'), 'messages did not follow their conversation';
  update ai_agents set business_id = '$B' where id = 'a1000000-0000-4000-8000-000000000001';
  assert (select business_id from ai_agent_configs where agent_id = 'a1000000-0000-4000-8000-000000000001') = '$B', 'config did not follow its agent';
  raise notice 'PASS new rows take the parent''s business; another business, a hand move and a missing parent are refused; rows follow a moved parent';
end \$\$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "behaviour: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"
[ "$(q "select bool_or(has_function_privilege(r, 'public.zella_child_business_id_trg()', 'execute') or has_function_privilege(r, 'public.zella_parent_business_id_trg()', 'execute')) from unnest(array['anon','authenticated']) r")" = f ] \
  && ok "the trigger functions are not callable by signed-in or anonymous users" || bad "trigger functions are callable"

# put the test rows back where they were, then the rollback must restore the schema exactly
q "update conversations set business_id = '$A' where id = 'c1000000-0000-4000-8000-000000000001'; update ai_agents set business_id = '$A' where id = 'a1000000-0000-4000-8000-000000000001';
   delete from conversation_messages where sender_type = 'ai'" > /dev/null
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_tenant_business_id_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
[ "$(q "$SCHEMA")" = "$schema_before" ] && [ "$(q "$ROWS")" = "$rows_before" ] && ok "the rollback (run twice) restores the schema exactly and keeps every row" || bad "rollback differs"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_tenant_business_id.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m2 ERROR | tr '\n' ' ')"

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
