#!/usr/bin/env bash
# All 28 industries, after the batch 4 migrations, on a copy of the local reference database (isolated Postgres only;
# never point this at production). Applies presets v2, automation presets v2 and receptionist rules twice, checks the
# invariants below, and prints the capability / workflow matrix as Markdown.
#   * every industry has capability defaults and an industry key; insurance and cleaning have their own presets
#   * no record type's title repeats one of its field labels; every link points at a type in the same preset
#   * every industry except "other" gets at least one industry-specific receptionist safety line
#   * private fields hold no plain values in record data
# Usage: tests/industry/presets_v2_check.sh [source db, default zella_ui]
set -euo pipefail
SRC=${1:-zella_ui}; DB=zsec_presets_check
H="-h ${ZPG_HOST:-/var/lib/postgresql/zella-sec} -p ${ZPG_PORT:-55433} -U postgres"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
psql $H -qX -c "drop database if exists $DB" -c "create database $DB" >/dev/null
pg_dump $H -d "$SRC" | psql $H -qX -d $DB >/dev/null 2>&1
P="psql $H -qtAX -d $DB -v ON_ERROR_STOP=1"
for m in zella_capabilities zella_record_links_secrets zella_money zella_presets_v2 zella_automation_presets_v2 zella_receptionist_industry_rules; do
  for run in 1 2; do $P -f "$REPO/sql/$m.sql" >/dev/null 2>&1 || { echo "FAIL $m run $run"; $P -f "$REPO/sql/$m.sql" 2>&1 | grep -m2 ERROR; exit 1; }; done
done
fail=0
check() { local n; n=$($P -c "$2"); if [ "$n" != "0" ]; then echo "FAIL $1: $n"; fail=1; else echo "PASS $1"; fi; }
check "every industry has capability defaults" "select count(*) from industries i left join industry_configurations c on c.industry_id = i.id where not coalesce(c.features ? 'capabilities', false)"
check "insurance and cleaning have their own presets" "select 2 - count(*) from industry_crm_presets where key in ('insurance', 'cleaning')"
check "no title repeats a field label (presets)" "select count(*) from industry_crm_presets p, jsonb_array_elements(p.config -> 'types') t, jsonb_array_elements(t -> 'fields') f where lower(f ->> 'label') = lower(coalesce(t ->> 'title_label', 'Name'))"
check "every link targets a type in the same preset" "select count(*) from industry_crm_presets p, jsonb_array_elements(p.config -> 'types') t, jsonb_array_elements(t -> 'fields') f where f ->> 'type' = 'record' and not exists (select 1 from jsonb_array_elements(p.config -> 'types') x where x ->> 'key' = f ->> 'target')"
check "private fields hold no plain values" "select count(*) from crm_record_types t join crm_records r on r.business_id = t.business_id and r.type_key = t.key, jsonb_array_elements(t.fields) f where coalesce((f ->> 'sensitive')::boolean, false) and r.data ? (f ->> 'key')"
check "industry safety line for every test business but other" "select count(*) from businesses b join industries i on i.id = b.industry_id where b.id::text like 'c0%' and i.slug <> 'other' and (select count(*) from regexp_split_to_table(substring(public.zella_brain_prompt_base(b.id) from 'SAFETY\n(.*?)(\nBUSINESS-SPECIFIC|\nUpcoming|$)'), '\n') l where l like '- %') < 3"
echo
echo "| Industry | Preset | On by default | Optional | Record types (new ones in italics) | Private fields | Links | Receptionist lines |"
echo "|---|---|---|---|---|---|---|---|"
$P -F'|' -c "
select i.name, public.zella_industry_key_for(b.id),
  (select string_agg(x, ', ') from jsonb_array_elements_text(c.features #> '{capabilities,on}') x),
  coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(c.features #> '{capabilities,optional}') x), '—'),
  (select string_agg(case when t.enabled then t.plural else '*' || t.plural || '*' end, ', ' order by t.position, t.key) from crm_record_types t where t.business_id = b.id and (t.enabled or t.preset_key = public.zella_industry_key_for(b.id))),
  (select count(*) from crm_record_types t, jsonb_array_elements(t.fields) f where t.business_id = b.id and coalesce((f ->> 'sensitive')::boolean, false)),
  (select count(*) from crm_record_types t, jsonb_array_elements(t.fields) f where t.business_id = b.id and f ->> 'type' = 'record'),
  (select count(*) from regexp_split_to_table(substring(public.zella_brain_prompt_base(b.id) from 'SAFETY\n(.*?)(\nBUSINESS-SPECIFIC|\nUpcoming|$)'), '\n') l where l like '- %')
from businesses b join industries i on i.id = b.industry_id left join industry_configurations c on c.industry_id = i.id
where b.id::text like 'c0%' order by i.name" | sed 's/^/| /; s/$/ |/'
exit $fail
