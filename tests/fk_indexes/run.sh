#!/usr/bin/env bash
# sql/zella_fk_indexes.sql on an ISOLATED copy of the production state (never production): 38 unindexed foreign keys
# before, none after, applied twice, an index that already exists under another name is kept and not duplicated, the
# rollback drops only what the file created and leaves every other index exactly as it was, and it applies again.
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
"$REPO/tests/lib/build_full.sh" $DB "$REPO/tests/channel/fixture.sql" $(for m in "${LIVE[@]}"; do echo "$REPO/sql/$m.sql"; done) > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
# foreign keys in public with no index whose leading columns are exactly the key's columns
UNINDEXED="select count(*) from pg_constraint c join pg_namespace n on n.oid = c.connamespace where c.contype = 'f' and n.nspname = 'public'
  and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] = c.conkey)"
LIST="select md5(string_agg(c.conrelid::regclass::text || ':' || c.conname, ',' order by 1)) from pg_constraint c join pg_namespace n on n.oid = c.connamespace
  where c.contype = 'f' and n.nspname = 'public' and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] = c.conkey)"
# every index in public except the ones this file creates, with its full definition
OTHERS="select md5(string_agg(indexdef, ',' order by indexdef)) from pg_indexes where schemaname = 'public' and indexname not like 'zella\_fk\_%'"
OURS="select count(*) from pg_indexes where schemaname = 'public' and indexname like 'zella\_fk\_%'"

[ "$(q "$UNINDEXED")" = 38 ] && ok "before: 38 foreign keys without an index (as in production)" || bad "before: $(q "$UNINDEXED") unindexed, expected 38"
list_before=$(q "$LIST")
# an index that already exists under another name must be kept and not duplicated
q "create index keep_me_customer_consents_business on public.customer_consents (business_id)" > /dev/null
others_before=$(q "$OTHERS")

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_fk_indexes.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
[ "$(q "$UNINDEXED")" = 0 ] && ok "after: every foreign key has an index" || bad "after: $(q "$UNINDEXED") still unindexed"
[ "$(q "$OURS")" = 37 ] && ok "37 indexes created; the one that already existed is not duplicated" || bad "created $(q "$OURS"), expected 37"
[ "$(q "select count(*) from pg_indexes where tablename = 'customer_consents' and indexdef like '%(business_id)'")" = 1 ] \
  && ok "the existing index on customer_consents(business_id) is the only one" || bad "duplicate index on customer_consents(business_id)"
[ "$(q "select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid where c.relname like 'zella\_fk\_%' and not i.indisvalid")" = 0 ] \
  && ok "every new index is valid" || bad "an invalid index"
[ "$(q "$OTHERS")" = "$others_before" ] && ok "no other index changed" || bad "other indexes changed"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_fk_index_list()', 'execute') or has_function_privilege('anon', 'public.zella_fk_index_list()', 'execute')")" = f ] \
  && ok "the index list helper is server only" || bad "the helper is callable by signed-in or anonymous users"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_fk_indexes_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
[ "$(q "$OURS")" = 0 ] && [ "$(q "$OTHERS")" = "$others_before" ] && ok "the rollback (run twice) drops only the new indexes; the existing one is kept" || bad "rollback: ours=$(q "$OURS")"
q "drop index public.keep_me_customer_consents_business" > /dev/null
[ "$(q "$LIST")" = "$list_before" ] && ok "after the rollback the same 38 foreign keys are unindexed as before" || bad "rollback left a different set"
[ "$(q "select to_regprocedure('public.zella_fk_index_list()') is null")" = t ] && ok "the rollback removes the helper" || bad "helper left behind"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_fk_indexes.sql" 2>&1) && [ "$(q "$UNINDEXED")" = 0 ] && [ "$(q "$OURS")" = 38 ] && ok "applies again after the rollback (38 indexes)" \
  || bad "re-apply: $(echo "$out" | grep -m2 ERROR | tr '\n' ' ')"

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
