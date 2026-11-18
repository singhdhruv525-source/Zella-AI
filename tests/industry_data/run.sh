#!/usr/bin/env bash
# sql/zella_industry_data.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Production's zella_sensitive_industry is loaded first, so "before" is production's version.
# Checks: before, a new industry is never sensitive (the gap: sensitivity is a slug list); applies, and applies again
# without seeding twice; zella_sensitive_industry gives the same answer for every business before and after; the
# seven sensitive slugs, the booking models of docs/PRODUCT.md §6, an automation set for all 28 industries; each
# industry's seeded safety lines are exactly the text the receptionist's prompt has for it today (the CASE, through
# this database's own presets); a new industry starts sensitive with no booking model and no defaults, and turning the
# flag off changes the answer; a bad booking model is refused; an edit made after the first apply survives a rerun;
# rollback (twice) restores the function exactly and removes the columns; applies again; the rollback refuses a
# changed function; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlc_industry_data}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
for f in zella_writing_cleanup zella_admin_permissions zella_admin_mfa; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }; done
"${P[@]}" -d $DB -f "$HERE/production_zella_sensitive_industry.sql" > /dev/null && "${P[@]}" -d $DB -f "$HERE/fixtures.sql" > /dev/null || { echo "FAIL fixtures"; exit 1; }
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
fp() { q "select md5(pg_get_functiondef('public.zella_sensitive_industry(uuid)'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_sensitive_industry')"; }
answers() { q "select string_agg(b.id || '=' || public.zella_sensitive_industry(b.id), ',' order by b.id) from public.businesses b"; }
cols() { q "select count(*) from information_schema.columns where table_schema = 'public' and ((table_name = 'industries' and column_name in ('sensitive', 'booking_model')) or (table_name = 'industry_configurations' and column_name in ('automation_defaults', 'safety_rules')))"; }
# an industry added before this migration (today: not sensitive, since it isn't in the slug list); it stays that way
q "insert into public.industries (name, slug) values ('Test Telehealth', 'test-telehealth')" > /dev/null
q "insert into public.businesses (id, name, industry_id, onboarding_status) values ('9d000000-0000-0000-0000-000000000098', 'Test New Medical', (select id from public.industries where slug = 'test-telehealth'), 'active')" > /dev/null
before=$(fp); before_answers=$(answers) || { bad "sensitivity before could not be read"; exit 1; }
[ -n "$before_answers" ] || { bad "sensitivity before is empty"; exit 1; }
[ "$(q "select public.zella_sensitive_industry('9d000000-0000-0000-0000-000000000098')")" = f ] && ok "before: a new medical industry is not sensitive, so staff would read its transcripts (the gap)" || bad "before new industry"

"${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" 2>&1 | tail -3; exit 1; }
after_answers=$(answers) || bad "sensitivity after could not be read"
[ -n "$after_answers" ] && [ "$after_answers" = "$before_answers" ] && ok "zella_sensitive_industry gives the same answer for all $(q "select count(*) from public.businesses") businesses as before" || bad "answers changed"
# production's access check is kept: server code, a member of the business or a top admin; anyone else gets false
q "insert into auth.users (id, email) values ('a0000000-0000-0000-0000-0000000000d1', 'member@dental.test'), ('a0000000-0000-0000-0000-0000000000d2', 'stranger@other.test') on conflict do nothing;
   insert into public.business_members (business_id, user_id, role, status) values ('9d000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-0000000000d1', 'staff', 'active') on conflict do nothing" > /dev/null
as_user() { "${P[@]}" -d $DB -c "begin; set local request.jwt.claims = '{\"role\":\"authenticated\",\"sub\":\"$1\",\"aal\":\"aal2\"}'; set local role authenticated; select public.zella_sensitive_industry('9d000000-0000-0000-0000-000000000005'); commit;" 2>&1; }
[ "$(as_user a0000000-0000-0000-0000-0000000000d1)" = t ] && [ "$(as_user a0000000-0000-0000-0000-0000000000d2)" = f ] && ok "production's access check is kept: a member of the dental business gets true, a stranger false" || bad "access $(as_user a0000000-0000-0000-0000-0000000000d1) $(as_user a0000000-0000-0000-0000-0000000000d2)"
v=$(q "select string_agg(slug, ',' order by slug) from public.industries where sensitive"); [ "$v" = "childcare,dental,financial-services,healthcare,insurance,legal,pet-care-veterinary" ] && ok "the seven sensitive industries, exactly today's list" || bad "sensitive $v"
v=$(q "select count(*) filter (where booking_model is not null) || '|' || (select booking_model from public.industries where slug = 'restaurant') || '|' || (select booking_model from public.industries where slug = 'ecommerce') from public.industries")
[ "$v" = "28|table|none" ] && ok "every industry has its booking model (restaurant table, ecommerce none)" || bad "booking $v"
v=$(q "select count(*) from public.industry_configurations where jsonb_typeof(automation_defaults) = 'object' and automation_defaults ? 'appointment_reminder'"); [ "$v" = 28 ] && ok "all 28 industries have their default automations" || bad "automations $v"
v=$(q "select automation_defaults #>> '{new_lead_callback,settings,contact_within_minutes}' || '|' || (automation_defaults #>> '{quote_follow_up,enabled}') from public.industry_configurations ic join public.industries i on i.id = ic.industry_id where i.slug = 'plumbing'")
[ "$v" = "5|true" ] && ok "plumbing has the trades defaults (contact within 5 minutes, quote follow up on)" || bad "plumbing $v"
v=$(q "select count(*) || '|' || count(*) filter (where position(ic.safety_rules in public.zella_brain_prompt_base(b.id)) > 0)
         from public.businesses b join public.industry_configurations ic on ic.industry_id = b.industry_id where b.id::text like '9d%' and ic.safety_rules is not null")
[ "$v" = "26|26" ] && ok "26 industries have safety lines and each is exactly in the receptionist's prompt today" || bad "safety lines $v"
v=$(q "select count(*) from public.industry_configurations ic join public.industries i on i.id = ic.industry_id where i.slug in ('other', 'ecommerce', 'professional-services') and ic.safety_rules is null")
[ "$v" = 2 ] && ok "other and professional services have none, as today; ecommerce has its order lines" || bad "none $v"
q "update public.industries set sensitive = false where slug = 'dental'" > /dev/null
"${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(q "select sensitive from public.industries where slug = 'dental'")" = f ] && ok "a change made after the first apply survives the rerun (nothing is seeded twice)" || bad "reseeded"
[ "$(q "select public.zella_sensitive_industry('9d000000-0000-0000-0000-000000000005')")" = f ] && ok "turning the flag off changes the answer: the server reads the column" || bad "flag not read"
q "update public.industries set sensitive = true where slug = 'dental'" > /dev/null
q "insert into public.industries (name, slug) values ('Test Clinic', 'test-clinic')" > /dev/null
v=$(q "select sensitive || '|' || coalesce(booking_model, '-') from public.industries where slug = 'test-clinic'"); [ "$v" = "true|-" ] && ok "a new industry starts sensitive, with no booking model" || bad "new $v"
q "insert into public.businesses (id, name, industry_id, onboarding_status) values ('9d000000-0000-0000-0000-000000000097', 'Test New Clinic', (select id from public.industries where slug = 'test-clinic'), 'active')" > /dev/null
[ "$(q "select public.zella_sensitive_industry('9d000000-0000-0000-0000-000000000097')")" = t ] && ok "so its businesses' transcripts are closed to staff from the start" || bad "new business"
[ "$(q "select public.zella_sensitive_industry('9d000000-0000-0000-0000-000000000098')")" = f ] && ok "an industry that existed before the migration keeps today's answer" || bad "old industry"
v=$(q "update public.industries set booking_model = 'teleport' where slug = 'test-clinic'" 2>&1); [[ "$v" == *industries_booking_model_check* ]] && ok "a booking model outside the list is refused" || bad "bad booking $v"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_industry_data_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_industry_data_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && [ "$(cols)" = 0 ] && ok "rollback restores the function and its grants exactly and removes the four columns" || bad "after rollback: $(fp) cols $(cols)"
v=$(q "select string_agg(b.id || '=' || public.zella_sensitive_industry(b.id), ',' order by b.id) from public.businesses b where b.id <> '9d000000-0000-0000-0000-000000000097'")
[ "$v" = "$before_answers" ] && ok "and the answers are today's again" || bad "answers after rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" > /dev/null 2>&1 && [ "$(cols)" = 4 ] && ok "applies again after the rollback (and seeds again)" || bad "reapply"
q "create or replace function public.zella_sensitive_industry(p_business_id uuid) returns boolean language sql stable as \$f\$ select true \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_industry_data_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && [ "$(cols)" = 4 ] && ok "the rollback refuses a changed function and changes nothing" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_industry_data.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
