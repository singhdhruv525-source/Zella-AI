#!/usr/bin/env bash
# sql/zella_brain_safety_rules.sql on an ISOLATED copy of the production schema (never production). Test data only;
# nothing is sent and no provider is called: the prompt is only rendered in the database.
# Checks: before, a new industry can't get safety lines (the CASE is keyed on the code's list: the gap); it refuses to
# run before sql/zella_industry_data.sql; applies, and applies again; the rendered prompt is BYTE IDENTICAL (md5 per
# business) for one business in each of the 28 industries plus one with no industry; changing an industry's
# safety_rules changes only that industry's prompts, and a new industry gets its own lines; the marker comments other
# migrations patch on are kept; lines saved without a final new line stay on their own line; a signed in caller who
# is not a member is refused; both files refuse while an industry has no configuration row; rollback (twice) restores
# the function exactly and the prompts with it; applies again;
# the rollback refuses a changed function; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_brain_safety_rules}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$REPO/tests/industry_data/production_zella_sensitive_industry.sql" > /dev/null && "${P[@]}" -d $DB -f "$REPO/tests/industry_data/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
fp() { q "select md5(pg_get_functiondef('public.zella_brain_prompt_base(uuid)'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_brain_prompt_base')"; }
# every business is listed, also one whose prompt comes back null ("null"), so none is left out of the comparison
prompts() { q "select string_agg(b.id || ':' || coalesce(md5(public.zella_brain_prompt_base(b.id)), 'null'), ',' order by b.id) from public.businesses b"; }
before=$(fp); before_prompts=$(prompts)
n=$(q "select count(*) from public.businesses"); [ "$n" -ge 33 ] && ok "fixtures: $n businesses, one in each of the 28 industries and one with none" || bad "fixtures $n"
[ "$(echo "$before_prompts" | tr ',' '\n' | grep -c ':null$')" = 0 ] && [ "$(echo "$before_prompts" | tr ',' '\n' | wc -l)" = "$n" ] && ok "every fixture business renders a prompt" || bad "null prompts: $before_prompts"

out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" 2>&1); [[ "$out" == *"apply sql/zella_industry_data.sql first"* ]] && [ "$(fp)" = "$before" ] && ok "refuses to run before the industry data migration" || bad "order: $out"
# an industry with no configuration row, and a business in it (covered by the byte identical comparison below)
q "insert into public.industries (name, slug) values ('Test Unconfigured', 'test-no-configuration-2'); insert into public.businesses (id, name, industry_id, onboarding_status) values ('9d000000-0000-0000-0000-000000000097', 'Test Unconfigured Co', (select id from public.industries where slug = 'test-no-configuration-2'), 'active')" > /dev/null
"${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" > /dev/null 2>&1 || { bad "industry data"; exit 1; }
[ "$(q "select count(*) from public.industries i where not exists (select 1 from public.industry_configurations c where c.industry_id = i.id)")" = 0 ] \
  && ok "the industry data file gives an industry without a configuration row an empty one, so no industry loses its lines" || bad "missing rows"
q "insert into public.industries (name, slug) values ('Test No Configuration', 'test-no-configuration')" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" 2>&1); [[ "$out" == *"no industry_configurations row"* ]] && [ "$(fp)" = "$before" ] && ok "this file refuses too while an industry has no configuration row, and changes nothing" || bad "no row brain: $out"
q "delete from public.industries where slug = 'test-no-configuration'" > /dev/null
q "insert into public.industries (name, slug) values ('Test Telehealth', 'test-telehealth'); insert into public.industry_configurations (industry_id) select id from public.industries where slug = 'test-telehealth'" > /dev/null
q "insert into public.businesses (id, name, industry_id, onboarding_status) values ('9d000000-0000-0000-0000-000000000098', 'Test Telehealth Clinic', (select id from public.industries where slug = 'test-telehealth'), 'active')" > /dev/null
q "update public.industry_configurations set safety_rules = E'- Test line: never give medical advice.\n' where industry_id = (select id from public.industries where slug = 'test-telehealth')" > /dev/null
v=$(q "select position('Test line' in public.zella_brain_prompt_base('9d000000-0000-0000-0000-000000000098'))"); [ "$v" = 0 ] && ok "before: a new industry's own safety lines are ignored (the gap)" || bad "before new $v"
before_prompts=$(prompts)

"${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
after_prompts=$(prompts)
diffs=$(python3 -c "
a=dict(x.split(':') for x in '''$before_prompts'''.split(',')); b=dict(x.split(':') for x in '''$after_prompts'''.split(','))
print(sum(1 for k in a if a[k]!=b.get(k)), [k for k in a if a[k]!=b.get(k)])")
[ "$diffs" = "1 ['9d000000-0000-0000-0000-000000000098']" ] && ok "every existing business's prompt is byte identical (md5 per business); only the new industry's changed" || bad "prompts differ: $diffs"
v=$(q "select position('Test line: never give medical advice.' in public.zella_brain_prompt_base('9d000000-0000-0000-0000-000000000098')) > 0"); [ "$v" = t ] && ok "a new industry now gets its own safety lines" || bad "new lines $v"
q "update public.industry_configurations set safety_rules = safety_rules || E'- Test extra plumbing line.\n' where industry_id = (select id from public.industries where slug = 'plumbing')" > /dev/null
v=$(q "select count(*) filter (where i.slug = 'plumbing' and m) || '|' || count(*) filter (where i.slug = 'plumbing' and not m) || '|' || count(*) filter (where i.slug is distinct from 'plumbing' and m)
        from (select b.*, position('Test extra plumbing line' in public.zella_brain_prompt_base(b.id)) > 0 m from public.businesses b) b left join public.industries i on i.id = b.industry_id")
[ "$v" = "1|0|0" ] && ok "editing one industry's lines changes only that industry's prompts" || bad "edit $v"
q "update public.industry_configurations set safety_rules = replace(safety_rules, E'- Test extra plumbing line.\n', '') where industry_id = (select id from public.industries where slug = 'plumbing')" > /dev/null
q "update public.industry_configurations set safety_rules = '- Test line without an ending.' where industry_id = (select id from public.industries where slug = 'test-telehealth')" > /dev/null
v=$(q "select position(E'- Test line without an ending.\n- Never read out access codes' in public.zella_brain_prompt_base('9d000000-0000-0000-0000-000000000098')) > 0"); [ "$v" = t ] && ok "saved lines without a final new line still end their line before the fixed privacy rule" || bad "newline $v"
q "update public.industry_configurations set safety_rules = E'- Test line: never give medical advice.\n' where industry_id = (select id from public.industries where slug = 'test-telehealth')" > /dev/null
v=$("${P[@]}" -d $DB -c "begin; set local request.jwt.claims = '{\"sub\":\"9d000000-0000-0000-0000-0000000000ff\",\"role\":\"authenticated\"}'; select public.zella_brain_prompt_base('9d000000-0000-0000-0000-000000000098'); commit;" 2>&1)
[[ "$v" == *NOT_ALLOWED* ]] && ok "a signed in caller who doesn't belong to the business is refused (server code, with no user, is not)" || bad "caller check $v"
v=$(q "select (position('zella_industry_rules_v2' in d) > 0 and position('zella_prompt_v4_rules' in d) > 0 and position('zella_escalation_rules' in d) > 0) from (select pg_get_functiondef('public.zella_brain_prompt_base(uuid)'::regprocedure) d) x")
[ "$v" = t ] && ok "the marker comments other migrations patch on are kept" || bad "markers"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_brain_safety_rules_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_brain_safety_rules_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && [ "$(prompts)" = "$before_prompts" ] && ok "rollback restores the function, its grants and every prompt exactly" || bad "after rollback: $(fp)"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_industry_data_rollback.sql" 2>&1); [ $? -eq 0 ] && ok "then the industry data can be rolled back too" || bad "industry rollback: $out"
"${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" > /dev/null 2>&1 && ok "both apply again after the rollback" || bad "reapply"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_industry_data_rollback.sql" 2>&1); [[ "$out" == *"roll back zella_brain_safety_rules.sql first"* ]] && ok "the industry data rollback refuses while the prompt reads safety_rules" || bad "order rollback: $out"
q "select public.zella_patch_function('public.zella_brain_prompt_base(uuid)', 'You speak with callers on the phone.', 'You speak with callers.')" > /dev/null 2>&1 \
  || q "do \$x\$ begin execute replace(pg_get_functiondef('public.zella_brain_prompt_base(uuid)'::regprocedure), 'You speak with callers on the phone.', 'You speak with callers.'); end \$x\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_brain_safety_rules_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_brain_safety_rules.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
