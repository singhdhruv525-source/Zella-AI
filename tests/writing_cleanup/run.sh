#!/usr/bin/env bash
# sql/zella_writing_cleanup.sql on an ISOLATED copy of the production schema (never production): applied twice; the
# 33 phrases in database functions are gone and their new wording is there; stored names, descriptions and display
# text in JSON lose their hyphens (E-commerce becomes Ecommerce) while matching values (a service an automation matches,
# option values, statuses) stay; the rollback (run twice) restores every function and every value exactly. Test data only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zwritingcleanup
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template zdocs" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
for f in zella_fk_indexes zella_model_defaults zella_unsubscribe_limit zella_tenant_business_id zella_billing_allowances; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "prerequisite $f"; exit 1; }
done
out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
insert into industries (name, slug) values ('E-commerce', 'ecommerce'), ('Dental', 'dental') on conflict do nothing;
insert into industry_modules (id, industry_id, name, slug, description) values ('1e000000-0000-4000-8000-000000000001', (select id from industries where slug = 'dental'), 'Walk-in waitlist', 'walkins', 'AI-powered check-in for walk-ins on 2026-11-15');
insert into businesses (id, name) values ('b0000000-0000-4000-8000-0000000000c1', 'Test Clinic');
insert into automations (id, business_id, name, trigger_type, description, trigger_config) values ('1f000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-0000000000c1',
  'Six-month check-up', 'schedule', 'A 10-class follow-up', '{"service": "check-up", "rules": [{"message": "Your check-up is due.", "task": {"title": "Book follow-up visit: {title}"}}]}');
insert into industry_automation_presets (id, industry_key, name, trigger_type, trigger_config) values ('1f100000-0000-4000-8000-000000000001', 'dental', 'Post-purchase check-in', 'schedule',
  '{"service": "check-up", "rule": {"notify": {"title": "Walk-in waiting over an hour: {title}"}}}');
insert into industry_message_policy (industry_key, policy, reason) values ('dental', '{}', 'They already had an after-visit check-in.')
  on conflict (industry_key) do update set reason = excluded.reason;
insert into industry_crm_presets (key, match, config) values ('dental_forms', array['dental'],
  '{"types": [{"singular": "New-patient form", "plural": "New-patient forms", "notice": "Never store log-in details.", "fields": [{"label": "Visit type", "options": ["Check-up", "Clean-up"]}], "statuses": [{"value": "follow_up", "label": "Follow-up"}]}]}');
SQL
) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
before_fns=$(q "select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'")
before_data=$(q "select md5(string_agg(x, '|' order by x)) from (select name from industries union all select name || coalesce(description,'') from industry_modules union all select name || coalesce(description,'') || trigger_config::text from automations union all select name || trigger_config::text from industry_automation_presets union all select reason from industry_message_policy union all select config::text from industry_crm_presets) t(x)")

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_writing_cleanup.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare d text; begin
  select string_agg(pg_get_functiondef(signature::regprocedure), ' ') into d from zella_function_archive where migration = 'zella_writing_cleanup';
  assert (select count(*) from zella_function_archive where migration = 'zella_writing_cleanup') = 22, 'all 22 functions archived';
  assert position('Missed-call follow-up' in d) = 0 and position('No-shows and cancellations' in d) = 0 and position('After-hours calls go to' in d) = 0
     and position('"blow-dry"' in d) = 0 and position('Front-desk check-ins' in d) = 0, 'old phrases gone';
  assert position('Missed call follow up' in d) > 0 and position('No shows and cancellations are up' in d) > 0 and position('"blow dry"' in d) > 0
     and position('Front desk check ins' in d) > 0, 'new phrases there';
  raise notice 'PASS the phrases in 22 database functions are rewritten';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "functions: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare a jsonb; c jsonb; begin
  assert public.zella_plain_words('X-ray ray-X X-Y A-B-C 2026-11-15') = 'X ray ray X X Y A B C 2026-11-15', 'single letter compounds and dates';
  assert public.zella_plain_json('{"label":"X-ray","service":"X-ray","options":["X-ray"],"value":"X-ray"}'::jsonb)
    = '{"label":"X ray","service":"X-ray","options":["X-ray"],"value":"X-ray"}'::jsonb, 'single letter matching values protected';
  assert (select name from industries where slug = 'ecommerce') = 'Ecommerce', 'Ecommerce';
  assert (select name || ' / ' || description from industry_modules where id = '1e000000-0000-4000-8000-000000000001') = 'Walk in waitlist / AI powered check in for walk ins on 2026-11-15', 'module: ' || (select name || ' / ' || description from industry_modules where id = '1e000000-0000-4000-8000-000000000001');
  select trigger_config into a from automations where id = '1f000000-0000-4000-8000-000000000001';
  assert (select name || ' / ' || description from automations where id = '1f000000-0000-4000-8000-000000000001') = 'Six month check up / A 10 class follow up', 'automation: ' || (select name || ' / ' || description from automations where id = '1f000000-0000-4000-8000-000000000001');
  assert a ->> 'service' = 'check-up', 'matched service kept';
  assert a #>> '{rules,0,message}' = 'Your check up is due.' and a #>> '{rules,0,task,title}' = 'Book follow up visit: {title}', 'automation text: ' || a::text;
  assert (select name from industry_automation_presets where id = '1f100000-0000-4000-8000-000000000001') = 'After purchase check in', 'preset name';
  assert (select trigger_config #>> '{rule,notify,title}' from industry_automation_presets where id = '1f100000-0000-4000-8000-000000000001') = 'Walk in waiting over an hour: {title}', 'preset text';
  assert (select trigger_config ->> 'service' from industry_automation_presets where id = '1f100000-0000-4000-8000-000000000001') = 'check-up', 'preset service kept';
  assert (select reason from industry_message_policy where industry_key = 'dental') = 'They already had an after visit check in.', 'policy reason';
  select config into c from industry_crm_presets where key = 'dental_forms';
  assert c #>> '{types,0,singular}' = 'New patient form' and c #>> '{types,0,notice}' = 'Never store login details.' and c #>> '{types,0,statuses,0,label}' = 'Follow up', 'crm text: ' || c::text;
  assert c #> '{types,0,fields,0,options}' = '["Check-up", "Clean-up"]'::jsonb and c #>> '{types,0,statuses,0,value}' = 'follow_up', 'option and status values kept';
  assert (select count(*) from zella_text_archive where migration = 'zella_writing_cleanup') > 0, 'archived';
  raise notice 'PASS stored names, descriptions and display text are plain (Ecommerce), matching values (service, options, statuses) unchanged';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "data: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

# A later edit must abort the entire rollback and retain both archives for a retry.
q "update automations set trigger_config = jsonb_set(trigger_config, '{service}', to_jsonb('later-edit'::text)) where id = '1f000000-0000-4000-8000-000000000001'" > /dev/null
conflict_data=$(q "select md5(string_agg(row(t.*)::text, '|' order by row(t.*)::text)) from automations t")
conflict_archive=$(q "select md5(string_agg(row(t.*)::text, '|' order by row(t.*)::text)) from zella_text_archive t")
conflict_functions=$(q "select md5(string_agg(pg_get_functiondef(signature::regprocedure), '|' order by signature)) from zella_function_archive where migration = 'zella_writing_cleanup'")
if out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_writing_cleanup_rollback.sql" 2>&1); then
  bad "rollback accepted a later configuration edit"
elif [[ "$out" != *ROLLBACK_CONFLICT* ]]; then
  bad "rollback did not report the configuration conflict: $out"
else
  [ "$conflict_data" = "$(q "select md5(string_agg(row(t.*)::text, '|' order by row(t.*)::text)) from automations t")" ] &&
  [ "$conflict_archive" = "$(q "select md5(string_agg(row(t.*)::text, '|' order by row(t.*)::text)) from zella_text_archive t")" ] &&
  [ "$conflict_functions" = "$(q "select md5(string_agg(pg_get_functiondef(signature::regprocedure), '|' order by signature)) from zella_function_archive where migration = 'zella_writing_cleanup'")" ] &&
    ok "rollback reports conflict and preserves edits, archives and migrated functions" || bad "conflicting rollback changed data or archives"
fi
q "update automations set trigger_config = public.zella_plain_json((select old_value::jsonb from zella_text_archive where migration = 'zella_writing_cleanup' and tbl = 'automations' and col = 'trigger_config' and row_key = '1f000000-0000-4000-8000-000000000001')) where id = '1f000000-0000-4000-8000-000000000001'" > /dev/null

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_writing_cleanup_rollback.sql" 2>&1) || bad "rollback (run $i): $(echo "$out" | grep -m2 ERROR)"; done
after_fns=$(q "select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'")
after_data=$(q "select md5(string_agg(x, '|' order by x)) from (select name from industries union all select name || coalesce(description,'') from industry_modules union all select name || coalesce(description,'') || trigger_config::text from automations union all select name || trigger_config::text from industry_automation_presets union all select reason from industry_message_policy union all select config::text from industry_crm_presets) t(x)")
[ "$before_fns" = "$after_fns" ] && [ "$before_data" = "$after_data" ] && ok "the rollback (run twice) restores every function and every value exactly" || bad "rollback left a difference"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_writing_cleanup.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

[ -n "${KEEP_DB:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
