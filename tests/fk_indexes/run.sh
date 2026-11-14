#!/usr/bin/env bash
# sql/zella_fk_indexes.sql on an ISOLATED copy of the production state (never production): 38 unindexed foreign keys
# before, none after, applied twice, an index that already exists (under another name, or under ours) is kept and not
# duplicated, a partial index is not counted, a colliding name stops the file, the rollback drops only what the file created and leaves every other index exactly as it was, and it applies again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zfkindexes
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
# what production has (as in tests/billing/run.sh)
LIVE=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages
  zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables zella_relationships zella_scheduling zella_slots_resource_blocks zella_record_workflows
  zella_batch1_security zella_batch3_pagination zella_brand_name zella_rollback_security zella_n8n_webhook_auth zella_record_files_purge_retry zella_replace_business_hours
  zella_order_lookup_reservations zella_review_sql_fixes zella_seating_handoff)
LIVE_FILES=(); for m in "${LIVE[@]}"; do LIVE_FILES+=("$REPO/sql/$m.sql"); done
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" "${LIVE_FILES[@]}" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
# foreign keys in public with no usable index (valid, ready, not partial) whose leading columns are exactly the key's
COVER="i.indisvalid and i.indisready and i.indislive and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] = c.conkey
  and (i.indpred is null or (array_length(c.conkey, 1) = 1 and pg_get_expr(i.indpred, i.indrelid)
       = format('(%s IS NOT NULL)', quote_ident((select attname from pg_attribute where attrelid = c.conrelid and attnum = c.conkey[1])))))"
# foreign keys outside this file's 38 whose only index is limited to a status (follow-up, docs/MEMORY.md): not counted here
OUT_OF_SCOPE="(c.conrelid::regclass::text, (select string_agg(attname, ',' order by attnum) from pg_attribute where attrelid = c.conrelid and attnum = any(c.conkey)))
  not in (('automation_channel_reviews','business_id'),('calendar_sync_queue','appointment_id'),('crm_records','business_id'),('crm_records','business_id,type_key'),
          ('crm_records','customer_id'),('customer_charge_payments','business_id'),('data_rights_requests','business_id'),('followup_tasks','appointment_id'),
          ('live_notices','business_id'),('message_drafts','business_id'),('record_approvals','business_id'),('record_milestones','business_id'))"
UNINDEXED="select count(*) from pg_constraint c join pg_namespace n on n.oid = c.connamespace where c.contype = 'f' and n.nspname = 'public' and $OUT_OF_SCOPE
  and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and $COVER)"
LIST="select md5(string_agg(c.conrelid::regclass::text || ':' || c.conname, ',' order by 1)) from pg_constraint c join pg_namespace n on n.oid = c.connamespace
  where c.contype = 'f' and n.nspname = 'public' and $OUT_OF_SCOPE and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and $COVER)"
# every index in public except the ones this file creates, with its full definition
OTHERS="select md5(string_agg(indexdef, ',' order by indexdef)) from pg_indexes where schemaname = 'public' and indexname not like 'zella\_fk\_%'"
OURS="select count(*) from pg_indexes where schemaname = 'public' and indexname like 'zella\_fk\_%'"

[ "$(q "$UNINDEXED")" = 38 ] && ok "before: 38 foreign keys without an index (as in production)" || bad "before: $(q "$UNINDEXED") unindexed, expected 38"
list_before=$(q "$LIST")
# a name collision: our name taken by an index on other columns stops the file and changes nothing
q "create index zella_fk_customer_consents_business_id_idx on public.customer_consents (given_by_customer_id)" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_fk_indexes.sql" 2>&1) && bad "a colliding index name was accepted" || {
  echo "$out" | grep -q VERSION_MISMATCH && ok "an index under our name that does not cover the key stops the file" || bad "collision failed for another reason: $(echo "$out" | grep -m1 ERROR)"; }
q "drop index public.zella_fk_customer_consents_business_id_idx; drop function if exists public.zella_fk_index_list()" > /dev/null
[ "$(q "$UNINDEXED")" = 38 ] && ok "the stopped run left nothing behind" || bad "the stopped run changed something"
# a partial index does not count as coverage
q "create index partial_consents_business on public.customer_consents (business_id) where false" > /dev/null
# an index that already exists under another name must be kept and not duplicated
q "create index keep_me_customer_consents_given_by on public.customer_consents (given_by_customer_id)" > /dev/null
# an index that already exists under our exact name and covers the key is kept, and the rollback leaves it
q "create index zella_fk_table_states_business_id_idx on public.table_states (business_id)" > /dev/null
others_before=$(q "$OTHERS")
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_fk_indexes.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
[ "$(q "$UNINDEXED")" = 0 ] && ok "after: every foreign key in scope has a usable index (12 status-limited ones are a recorded follow-up)" || bad "after: $(q "$UNINDEXED") still unindexed"
MARKED="select count(*) from pg_class where relname like 'zella\_fk\_%' and obj_description(oid, 'pg_class') = 'created by sql/zella_fk_indexes.sql'"
[ "$(q "$MARKED")" = 36 ] && ok "36 indexes created and marked; the two that already existed are not duplicated or marked" || bad "marked $(q "$MARKED"), expected 36"
[ "$(q "select count(*) from pg_indexes where tablename = 'customer_consents' and indexdef like '%(given_by_customer_id)'")" = 1 ] \
  && ok "the existing index on customer_consents(given_by_customer_id) is the only one" || bad "duplicate index on customer_consents(given_by_customer_id)"
[ "$(q "select count(*) from pg_indexes where indexname = 'zella_fk_customer_consents_business_id_idx'")" = 1 ] \
  && ok "a partial index is not taken as coverage: the real index is created" || bad "the partial index was taken as coverage"
[ "$(q "select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid where c.relname like 'zella\_fk\_%' and not i.indisvalid")" = 0 ] \
  && ok "every new index is valid" || bad "an invalid index"
[ "$(q "$OTHERS")" = "$others_before" ] && ok "no other index changed" || bad "other indexes changed"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_fk_index_list()', 'execute') or has_function_privilege('anon', 'public.zella_fk_index_list()', 'execute')")" = f ] \
  && ok "the index list helper is server only" || bad "the helper is callable by signed-in or anonymous users"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_fk_indexes_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
[ "$(q "$MARKED")" = 0 ] && [ "$(q "$OTHERS")" = "$others_before" ] && [ "$(q "$OURS")" = 1 ] \
  && ok "the rollback (run twice) drops only what the file created; the pre-existing index under our name is kept" || bad "rollback: ours=$(q "$OURS") marked=$(q "$MARKED")"
q "drop index public.keep_me_customer_consents_given_by; drop index public.partial_consents_business; drop index public.zella_fk_table_states_business_id_idx" > /dev/null
[ "$(q "$LIST")" = "$list_before" ] && ok "after the rollback the same 38 foreign keys are unindexed as before" || bad "rollback left a different set"
[ "$(q "select to_regprocedure('public.zella_fk_index_list()') is null")" = t ] && ok "the rollback removes the helper" || bad "helper left behind"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_fk_indexes.sql" 2>&1) && [ "$(q "$UNINDEXED")" = 0 ] && [ "$(q "$OURS")" = 38 ] && ok "applies again after the rollback (38 indexes)" \
  || bad "re-apply: $(echo "$out" | grep -m2 ERROR | tr '\n' ' ')"

[ -n "${KEEP_DB:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
