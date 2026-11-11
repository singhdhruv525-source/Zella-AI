#!/usr/bin/env bash
# Seating data survives sql/rollback/zella_tables_rollback.sql, a re-apply of sql/zella_tables.sql and
# sql/rollback/zella_tables_restore.sql, on an ISOLATED copy of production filled by tests/tables/seating_test.sql.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=ztables_restore
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
APPLIED=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables)
"$REPO/tests/lib/build_full.sh" $DB $(for m in "${APPLIED[@]}"; do echo "$REPO/sql/$m.sql"; done) || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
out=$($P -d $DB -f "$HERE/seating_test.sql" 2>&1) || { echo "FAIL seating fixture: $(echo "$out" | grep -m2 ERROR)"; exit 1; }
# a needs-clearing state, the 'tables' capability, a table assignment and waitlist details, so every archived kind is covered
$P -d $DB -c "set session_replication_role = replica;
  insert into table_states (table_id, business_id, state, since) select id, business_id, 'needs_clearing', '2026-11-05 20:00+00' from restaurant_tables
   where business_id = '5f000000-0000-0000-0000-0000000000c1' order by name limit 1 on conflict (table_id) do nothing;
  insert into business_capabilities (business_id, capability, enabled, updated_at) values ('5f000000-0000-0000-0000-0000000000c1', 'tables', true, '2026-11-05 12:00+00')
   on conflict (business_id, capability) do update set enabled = true;" > /dev/null || { echo "FAIL extra fixture"; exit 1; }
SNAP="select md5(string_agg(x, '|' order by x)) from (
  select 'rt:' || to_jsonb(t)::text x from restaurant_tables t
  union all select 'tc:' || to_jsonb(t)::text from table_combinations t
  union all select 'tb:' || to_jsonb(t)::text from table_blocks t
  union all select 'te:' || to_jsonb(t)::text from table_events t
  union all select 'ts:' || to_jsonb(t)::text from table_states t
  union all select 'cap:' || to_jsonb(c)::text from business_capabilities c where capability = 'tables'
  union all select 'ap:' || id || ':' || table_ids::text from appointments where table_ids is not null
  union all select 'wl:' || id || ':' || concat_ws(',', party_size, preferences, contact_ok) from waitlist_entries where party_size is not null or preferences is not null or contact_ok is not null) s"
COUNTS="select (select count(*) from restaurant_tables) || ' tables, ' || (select count(*) from table_combinations) || ' combinations, ' || (select count(*) from table_blocks) || ' blocks, '
  || (select count(*) from table_events) || ' events, ' || (select count(*) from table_states) || ' states, ' || (select count(*) from appointments where table_ids is not null) || ' assignments, '
  || (select count(*) from waitlist_entries where party_size is not null) || ' waitlist details'"
hash() { [[ "$1" =~ ^[0-9a-f]{32}$ ]]; }
before=$($P -d $DB -c "$SNAP" 2>&1); counts=$($P -d $DB -c "$COUNTS")
hash "$before" || { echo "FAIL snapshot before the rollback is not a hash: $before"; exit 1; }
echo "$counts" | grep -qE '^[1-9][0-9]* tables, [1-9][0-9]* combinations, [1-9][0-9]* blocks, [1-9][0-9]* events, [1-9][0-9]* states, [1-9][0-9]* assignments, [1-9][0-9]* waitlist' \
  && ok "fixture covers every kind of seating data ($counts)" || bad "fixture is missing a kind of seating data ($counts)"
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_rollback.sql" 2>&1) && ok "rollback" || bad "rollback: $(echo "$out" | grep -m1 ERROR)"
# A retry must preserve the generation and all archived data before reapplication.
archive_snapshot() { $P -d $DB -c "select md5(string_agg(to_jsonb(a)::text, '|' order by id)) from table_data_rolled_back a"; }
archive_before=$(archive_snapshot)
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_rollback.sql" 2>&1) || { bad "populated rollback retry: $out"; exit 1; }
[ "$(archive_snapshot)" = "$archive_before" ] && ok "populated rollback retry preserves the archive and generation" || bad "populated rollback retry changed the archive"
out=$($P -d $DB -f "$REPO/sql/zella_tables.sql" 2>&1) && ok "re-apply sql/zella_tables.sql" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"
[ "$($P -d $DB -c "select count(*) from restaurant_tables")" = 0 ] && ok "control: after the re-apply alone the seating data is not back" || bad "control: re-apply already restored data"
# Reapplication before restore must not replace the populated generation or rotate its tables.
archive_before=$(archive_snapshot)
seating_archive_before=$($P -d $DB -c "select md5(string_agg(to_jsonb(t)::text, '|' order by id)) from restaurant_tables_rolled_back t")
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_rollback.sql" 2>&1) \
  && bad "rollback allowed while restore pending" \
  || { echo "$out" | grep -q TABLES_RESTORE_PENDING && ok "rollback refuses to replace a pending generation" || bad "unexpected pending rollback error: $out"; }
[ "$(archive_snapshot)" = "$archive_before" ] && ok "pending rollback preserves generation and detail archives" || bad "pending rollback changed detail archives"
[ "$($P -d $DB -c "select md5(string_agg(to_jsonb(t)::text, '|' order by id)) from restaurant_tables_rolled_back t")" = "$seating_archive_before" ] \
  && ok "pending rollback preserves populated seating archive" || bad "pending rollback rotated seating archive"
# an older rollback's archive row for an entry the latest rollback had no details for must not come back
STALE=$($P -d $DB -c "set session_replication_role = replica;
  insert into waitlist_entries select (jsonb_populate_record(null::waitlist_entries, to_jsonb(w) || jsonb_build_object('id', gen_random_uuid()))).* from waitlist_entries w limit 1 returning id" | head -1)
$P -d $DB -c "insert into table_data_rolled_back (source_table, business_id, row_data, archived_at)
  select 'waitlist_entries', business_id, to_jsonb(w) || '{\"party_size\": 9, \"preferences\": \"stale\"}', now() - interval '1 day' from waitlist_entries w where id = '$STALE'" > /dev/null \
  || bad "stale archive fixture"
for i in 1 2; do
  out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1) || { bad "restore run $i: $(echo "$out" | grep -m1 ERROR)"; continue; }
  now=$($P -d $DB -c "$SNAP" 2>&1); hash "$now" || { bad "restore run $i: snapshot is not a hash: $now"; continue; }
  [ "$now" = "$before" ] && ok "restore run $i: tables, combinations, blocks, events, states, capability, assignments and waitlist details identical to before the rollback" \
    || bad "restore run $i: data differs ($($P -d $DB -c "$COUNTS") vs $counts)"
done
[ "$($P -d $DB -c "select party_size is null and preferences is null from waitlist_entries where id = '$STALE'")" = t ] \
  && ok "an older rollback's archive is never restored (only the latest rollback's rows are used)" || bad "a stale archive row was restored"
r=$($P -d $DB -c "begin;
  select set_config('request.jwt.claims', '{\"sub\":\"5f300000-0000-0000-0000-0000000000c1\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true) is not null;
  set local role authenticated;
  select jsonb_array_length(public.zella_table_board('5f000000-0000-0000-0000-0000000000c1', now()) -> 'tables') > 0; rollback;" 2>&1 | tail -1)
[ "$r" = t ] && ok "the seating board works on the restored tables" || bad "seating board after restore: $r"
# Partial restores commit progress while refused and unmatched assignments remain pending.
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_rollback.sql" 2>&1) || { bad "retry fixture rollback: $out"; exit 1; }
out=$($P -d $DB -f "$REPO/sql/zella_tables.sql" 2>&1) || { bad "retry fixture reapply: $out"; exit 1; }
MISSING=$($P -d $DB -c "select row_data ->> 'id' from table_data_rolled_back where source_table = 'appointments' and generation_id = (select max(id) from table_data_rolled_back where source_table = 'rollback_generation') order by id limit 1")
REFUSED=$($P -d $DB -c "select row_data ->> 'id' from table_data_rolled_back where source_table = 'appointments' and generation_id = (select max(id) from table_data_rolled_back where source_table = 'rollback_generation') order by id offset 1 limit 1")
$P -d $DB <<SQL >/dev/null || { bad "partial restore fixture"; exit 1; }
update table_data_rolled_back set row_data = jsonb_set(row_data, '{table_ids}', jsonb_build_array(gen_random_uuid()))
 where source_table = 'appointments' and row_data ->> 'id' = '$MISSING';
insert into table_data_rolled_back (source_table, business_id, row_data, generation_id)
 select source_table, business_id, jsonb_set(row_data, '{id}', to_jsonb(gen_random_uuid())), generation_id
 from table_data_rolled_back where source_table = 'appointments' and row_data ->> 'id' = '$MISSING'
 and generation_id = (select max(id) from table_data_rolled_back where source_table = 'rollback_generation');
create function public.test_restore_refusal() returns trigger language plpgsql as \$\$
begin if new.id = '$REFUSED' then raise exception 'TEST_BOOKING_REFUSAL'; end if; return new; end \$\$;
create trigger test_restore_refusal before update on appointments for each row execute function public.test_restore_refusal();
SQL
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1) || { bad "partial restore: $out"; exit 1; }
[[ "$out" == *"unresolved archived table IDs"* && "$out" == *"TEST_BOOKING_REFUSAL"* ]] && ok "unmatched IDs and booking refusals are reported separately" || bad "missing refusal diagnostics: $out"
[ "$($P -d $DB -c "select count(*) = 2 from table_data_rolled_back where source_table = 'appointments' and not restore_completed")" = t ] \
  && ok "only unmatched and refused assignments remain unresolved" || bad "partial restore progress"
$P -d $DB -c "drop trigger test_restore_refusal on appointments; drop function public.test_restore_refusal();
 set session_replication_role = replica;
 delete from table_events; delete from table_states; delete from business_capabilities where capability = 'tables';
 update waitlist_entries set party_size = null, preferences = null, contact_ok = null;
 update appointments set table_ids = null where id not in ('$MISSING', '$REFUSED');" >/dev/null || { bad "post-restore edits"; exit 1; }
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1) || { bad "partial retry: $out"; exit 1; }
[ "$($P -d $DB -c "select not exists (select 1 from table_events) and not exists (select 1 from table_states)
 and not exists (select 1 from business_capabilities where capability = 'tables')
 and not exists (select 1 from waitlist_entries where party_size is not null or preferences is not null or contact_ok is not null)
 and not exists (select 1 from appointments where id not in ('$MISSING', '$REFUSED') and table_ids is not null)
 and exists (select 1 from appointments where id = '$REFUSED' and table_ids is not null)
 and not exists (select 1 from table_data_rolled_back where source_table = 'rollback_generation' and id = (select max(id) from table_data_rolled_back where source_table = 'rollback_generation') and row_data ->> 'restored' = 'true')")" = t ] \
 && ok "retry restores refused assignment without replaying committed data; unmatched ID keeps generation pending" || bad "retry replayed data or completed prematurely"
# A user replacement resolves an unmatched assignment without overwriting their choice.
$P -d $DB -c "set session_replication_role = replica; update appointments set table_ids = '{}' where id = '$MISSING';" >/dev/null || exit 1
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1) || { bad "resolve missing assignment: $out"; exit 1; }
[ "$($P -d $DB -c "select row_data ->> 'restored' = 'true' from table_data_rolled_back where source_table = 'rollback_generation' order by id desc limit 1")" = t ] \
 && ok "user replacement resolves unmatched assignment and completes generation" || bad "resolved generation remains pending"

# A second, empty archive generation must not recover details from the populated first one.
out=$($P -d $DB -c "set session_replication_role = replica;
  delete from table_states;
  delete from business_capabilities where capability = 'tables';
  update appointments set table_ids = null;
  update waitlist_entries set party_size = null, preferences = null, contact_ok = null;" 2>&1) \
  || { bad "empty generation fixture: $out"; exit 1; }
previous_generation=$($P -d $DB -c "select max(id) from table_data_rolled_back where source_table = 'rollback_generation'")
# Archive timestamps do not determine the current generation (even with clock skew).
$P -d $DB -c "update table_data_rolled_back set archived_at = now() + interval '1 day' where generation_id = $previous_generation" > /dev/null \
  || { bad "older generation timestamp fixture"; exit 1; }
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_rollback.sql" 2>&1) || { bad "empty generation rollback: $out"; exit 1; }
[ "$($P -d $DB -c "select max(id) > $previous_generation and not exists (
  select 1 from table_data_rolled_back where generation_id = (select max(id) from table_data_rolled_back where source_table = 'rollback_generation'))
  from table_data_rolled_back where source_table = 'rollback_generation'")" = t ] \
  && ok "an empty rollback records a distinct generation without archived data rows" || bad "empty rollback generation marker"
archive_before=$(archive_snapshot)
out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_rollback.sql" 2>&1) || { bad "empty rollback retry: $out"; exit 1; }
[ "$(archive_snapshot)" = "$archive_before" ] && ok "empty rollback retry preserves the archive and generation" || bad "empty rollback retry changed the archive"
out=$($P -d $DB -f "$REPO/sql/zella_tables.sql" 2>&1) || { bad "empty generation re-apply: $out"; exit 1; }
for i in 1 2; do
  out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1) || { bad "empty generation restore $i: $out"; continue; }
  [ "$($P -d $DB -c "select not exists (select 1 from table_states)
    and not exists (select 1 from business_capabilities where capability = 'tables')
    and not exists (select 1 from appointments where table_ids is not null)
    and not exists (select 1 from waitlist_entries where party_size is not null or preferences is not null or contact_ok is not null)
    and exists (select 1 from table_data_rolled_back where generation_id = $previous_generation)")" = t ] \
    && ok "empty generation restore $i leaves old states, capability, assignments and waitlist details archived" \
    || bad "empty generation restore $i recovered older values"
done
out=$($P -d $DB -c "drop table public.restaurant_tables cascade" 2>&1); out=$($P -d $DB -f "$REPO/sql/rollback/zella_tables_restore.sql" 2>&1) \
  && bad "restore ran without the re-apply" || { echo "$out" | grep -q TABLES_NOT_APPLIED && ok "restore refuses to run before sql/zella_tables.sql is re-applied" || bad "restore without re-apply: $(echo "$out" | grep -m1 ERROR)"; }
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
