#!/usr/bin/env bash
# sql/zella_owner_onboarding.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: the file refuses a different activation function; applies, and applies again; who may call (the owner of
# another business, a team member, a business admin, a Zella Voice admin, anonymous: all refused); row security on the
# progress tables; the seven steps in order (STEP_LOCKED, idempotent answers, every write audited with before and after);
# two step sign in checked from the auth records, never from the caller; Looks right and Change (the note reaches the
# admin as an alert; changed details need a new answer); identity: needed, checking, try again, in review (retry then
# manual review) and verified by an admin in Verification; the plan comes from business_plans and must be the current
# version; payment waits; finish later and resume; the provider event is off by default and, when on, processed once;
# the go live gate (identity and a confirmed payment) in both activation functions; the rollback restores both
# functions exactly (run twice), keeps every onboarding row in an archive, and the file applies again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zonb_test}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
[[ "$DB" == zonb_* ]] || { echo "REFUSED: this suite only builds zonb_* databases" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null 2>&1 || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1" 2>&1; }
MIG="$REPO/sql/zella_owner_onboarding.sql"; RB="$REPO/sql/rollback/zella_owner_onboarding_rollback.sql"

# as <user id or anon> <aal> <sql returning one value>: runs it through the API roles with those token claims and prints the
# value, or ERR:<message>|<detail>. Writes that succeed are kept.
as() {
  local claims role
  if [ "$1" = anon ]; then claims="json_build_object('role', 'anon')"; role=anon
  else claims="json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')"; role=authenticated; fi
  q "do \$\$ declare v text; d text; begin perform set_config('request.jwt.claims', ($claims)::text, true);
    set local role $role; begin execute \$q\$$3\$q\$ into v; exception when others then get stacked diagnostics d = pg_exception_detail;
    v := 'ERR:' || sqlerrm || coalesce('|' || nullif(d, ''), ''); end; reset role; raise notice 'V=%', v; end \$\$" | sed -n 's/.*V=//p'
}
expect() { # name, got, want
  [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', want '$3'"
}

# ---- fixtures: synthetic people and businesses only ----
OWNER=a0b00000-0000-4000-8000-000000000001; OWNER2=a0b00000-0000-4000-8000-000000000002; STAFF=a0b00000-0000-4000-8000-000000000003
BADMIN=a0b00000-0000-4000-8000-000000000004; ZADMIN=a0b00000-0000-4000-8000-000000000005; SUPPORT=a0b00000-0000-4000-8000-000000000006
NOPASS=a0b00000-0000-4000-8000-000000000007
BIZ=a0b10000-0000-4000-8000-000000000001; BIZ2=a0b10000-0000-4000-8000-000000000002
q "insert into auth.users (id, email, email_confirmed_at, encrypted_password) values
   ('$OWNER', 'owner@onboarding.test', now(), 'x'), ('$OWNER2', 'owner2@onboarding.test', now(), 'x'),
   ('$STAFF', 'staff@onboarding.test', now(), 'x'), ('$BADMIN', 'badmin@onboarding.test', now(), 'x'),
   ('$ZADMIN', 'zadmin@onboarding.test', now(), 'x'), ('$SUPPORT', 'support@onboarding.test', now(), 'x'),
   ('$NOPASS', 'nopass@onboarding.test', now(), null);
 insert into public.businesses (id, name, industry_id, timezone, phone, email, onboarding_status)
   select v.id::uuid, v.name, i.id, 'America/Chicago', '+15555550100', 'hello@glow.test', 'testing'
     from (values ('$BIZ', 'Glow Test Studio'), ('$BIZ2', 'Other Test Shop')) v(id, name), (select id from public.industries order by slug limit 1) i;
 insert into public.business_members (business_id, user_id, role, status) values
   ('$BIZ', '$OWNER', 'owner', 'active'), ('$BIZ2', '$OWNER2', 'owner', 'active'), ('$BIZ', '$STAFF', 'staff', 'active'),
   ('$BIZ', '$BADMIN', 'admin', 'active'), ('$BIZ2', '$NOPASS', 'owner', 'active');
 insert into public.platform_admins (user_id, role, is_active) values ('$ZADMIN', 'zella_owner', true), ('$SUPPORT', 'support_admin', true);
 insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at) values
   (gen_random_uuid(), '$ZADMIN', 'totp', 'verified', now(), now()), (gen_random_uuid(), '$SUPPORT', 'totp', 'verified', now(), now());
 insert into public.business_hours (business_id, weekday, opens, closes) values ('$BIZ', 1, '09:00', '17:00');
 insert into public.staff_members (business_id, name, title, email, phone) values ('$BIZ', 'Sam Test', 'Stylist', 'sam@glow.test', '+15555550111');" > "$HERE/.fixtures.log" \
  || { echo "fixtures failed: $(cat "$HERE/.fixtures.log")"; exit 1; }
rm -f "$HERE/.fixtures.log"
# go live prerequisites that already existed before this file (REQ-LC-14), so the new gate is the only thing missing
FIX=$(q "with ag as (insert into public.ai_agents (business_id, name, agent_type, is_default) values ('$BIZ', 'Ava', 'receptionist', true) returning id)
 insert into public.ai_agent_configs (agent_id, business_id, system_prompt, escalation_rules, voice_config, knowledge_base)
   select id, '$BIZ', 'You are the receptionist for a test studio.', '{\"transfer_to\": {\"type\": \"owner\"}}', '{\"greeting\": \"Thanks for calling.\"}',
          '{\"services\": [{\"name\": \"Haircut\", \"duration\": \"45 min\", \"price\": \"\$40\"}]}' from ag;
 insert into public.integrations (business_id, provider, integration_type, status) values ('$BIZ', 'telnyx', 'phone', 'active'), ('$BIZ', 'vapi', 'voice', 'active');
 insert into public.knowledge_items (business_id, title, answer, status) values ('$BIZ', 'Parking', 'Free parking behind the studio.', 'ready');
 insert into public.automations (business_id, name, trigger_type, status) values ('$BIZ', 'Missed call text', 'missed_call', 'paused');
 insert into public.activation_tests (business_id, ok) values ('$BIZ', true);")
[[ "$FIX" == *ERROR* ]] && { echo "go live fixtures failed: $FIX"; exit 1; }
before=$(q "select public.zella_activation_report('$BIZ') ->> 'ready'")
expect "before: the existing go live checks all pass for the test business" "$before" "true"

# ---- version guard ----
q "create table public.zonb_saved as select pg_get_functiondef('public.zella_request_activation(uuid)'::regprocedure) d" > /dev/null
q "create or replace function public.zella_request_activation(p_business_id uuid) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"*"zella_request_activation"* ]] && ok "a different zella_request_activation stops the file" || bad "not caught: $(echo "$out" | tail -2)"
[ "$(q "select to_regclass('public.owner_onboarding') is null")" = t ] && ok "and nothing was created" || bad "partly applied"
q "do \$\$ begin execute (select d from public.zonb_saved); end \$\$; drop table public.zonb_saved" > /dev/null
[ "$(q "select md5(pg_get_functiondef('public.zella_request_activation(uuid)'::regprocedure))")" = 0db1467ab6c0c6cba7bc300bbb5946f5 ] && ok "production's version restored for the test" || bad "restore"

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | grep -v NOTICE | tail -5; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
expect "both production functions archived once" "$(q "select count(*) || ':' || count(distinct signature) from public.zella_function_archive where migration = 'zella_owner_onboarding'")" "2:2"
expect "the archived copies are production's" "$(q "select string_agg(definition_md5, ',' order by signature) from public.zella_function_archive where migration = 'zella_owner_onboarding'")" "65d1ba6e6671bbfe2fc1b2ea304475d8,0db1467ab6c0c6cba7bc300bbb5946f5"

# ---- grants and who may call ----
v=$(q "select bool_and(not has_function_privilege('anon', p.oid, 'EXECUTE')) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and (p.proname like 'zella_owner_onboarding%' or p.proname like 'zella_onboarding%' or p.proname like 'zella_admin_onboarding%'
          or p.proname in ('zella_owner_identity_upload_check', 'zella_owner_identity_document_add', 'zella_identity_provider_event', 'zella_activation_checks'))")
expect "anonymous can execute none of the new functions" "$v" "t"
v=$(q "select bool_and(not has_function_privilege('authenticated', p.oid, 'EXECUTE')) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and (p.proname like 'zella_onboarding%' or p.proname in ('zella_owner_identity_document_add', 'zella_identity_provider_event', 'zella_activation_checks'))")
expect "signed in people can't call the internal helpers, the document recorder or the provider event" "$v" "t"
expect "no one but the server can write the tables" "$(q "select bool_and(not has_table_privilege(r, t, p)) from unnest(array['anon','authenticated']) r,
   unnest(array['public.owner_onboarding','public.owner_onboarding_steps','public.owner_onboarding_sections','public.identity_verification_events']) t,
   unnest(array['INSERT','UPDATE','DELETE']) p")" "t"
expect "the identity reference is never readable by signed in people" "$(q "select has_column_privilege('authenticated', 'public.owner_onboarding', 'identity_reference', 'SELECT')")" "f"

expect "anonymous: get refused" "$(as anon aal1 "select public.zella_owner_onboarding_get('$BIZ')::text")" "ERR:permission denied for function zella_owner_onboarding_get"
expect "no session: NOT_SIGNED_IN" "$(q "select public.zella_owner_onboarding_get('$BIZ')" | grep -o 'NOT_SIGNED_IN' | head -1)" "NOT_SIGNED_IN"
expect "the owner of another business is refused" "$(as $OWNER2 aal2 "select public.zella_owner_onboarding_get('$BIZ')::text")" "ERR:NOT_ALLOWED"
expect "a staff member is refused" "$(as $STAFF aal2 "select public.zella_owner_onboarding_get('$BIZ')::text")" "ERR:NOT_ALLOWED"
expect "a business admin is refused" "$(as $BADMIN aal2 "select public.zella_owner_onboarding_get('$BIZ')::text")" "ERR:NOT_ALLOWED"
expect "a Zella Voice admin is refused on the owner calls" "$(as $ZADMIN aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'welcome')::text")" "ERR:NOT_ALLOWED"
expect "an unknown business looks the same as another's (no oracle)" "$(as $OWNER aal1 "select public.zella_owner_onboarding_get('a0b1ffff-0000-4000-8000-000000000000')::text")" "ERR:NOT_ALLOWED"
expect "staff can't write either" "$(as $STAFF aal2 "select public.zella_owner_onboarding_section('$BIZ', 'team', 'change', 'x')::text")" "ERR:NOT_ALLOWED"
expect "the other owner can't finish later on this business" "$(as $OWNER2 aal2 "select public.zella_owner_onboarding_finish_later('$BIZ')::text")" "ERR:NOT_ALLOWED"
expect "list: the owner sees only their business" "$(as $OWNER aal1 "select string_agg(x ->> 'business_name', ',') from jsonb_array_elements(public.zella_owner_onboarding_list() -> 'businesses') x")" "Glow Test Studio"
expect "list: staff own nothing" "$(as $STAFF aal1 "select public.zella_owner_onboarding_list()::text")" '{"businesses": []}'

# ---- step 1, and the state before anything ----
expect "a new journey starts at welcome, not started" "$(as $OWNER aal1 "select concat_ws(',', g ->> 'current_step', g ->> 'current_step_number', g ->> 'steps_total', g ->> 'started') from public.zella_owner_onboarding_get('$BIZ') g")" "welcome,1,7,false"
expect "rules carry the four defaults" "$(as $OWNER aal1 "select concat_ws(',', r ->> 'identity_provider', r ->> 'plan_choice', r ->> 'first_payment', r ->> 'failed_check', r ->> 'identity_attempts', r ->> 'payments_connected') from (select public.zella_owner_onboarding_get('$BIZ') -> 'rules' r) x")" "none,accept_only,pay_before_live,retry_then_review,2,false"
expect "a later step is locked" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'details')::text")" "ERR:STEP_LOCKED"
expect "an unknown step is invalid" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'nope')::text")" "ERR:INVALID_INPUT"
expect "welcome completes" "$(as $OWNER aal1 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}') from public.zella_owner_onboarding_complete_step('$BIZ', 'welcome') r")" "true,security"
expect "welcome again changes nothing" "$(as $OWNER aal1 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}') from public.zella_owner_onboarding_complete_step('$BIZ', 'welcome') r")" "false,security"
expect "the step is audited with before and after" "$(q "select concat_ws(',', count(*), max(old_data ->> 'current_step'), max(new_data ->> 'current_step')) from public.audit_logs where business_id = '$BIZ' and action = 'onboarding.step_completed'")" "1,welcome,security"

# ---- row security on the progress tables ----
expect "the owner reads their progress row" "$(as $OWNER aal1 "select count(*)::text from public.owner_onboarding")" "1"
expect "staff read no progress rows" "$(as $STAFF aal1 "select count(*)::text from public.owner_onboarding")" "0"
expect "a business admin reads no progress rows" "$(as $BADMIN aal1 "select count(*)::text from public.owner_onboarding_steps")" "0"
expect "the other owner reads none" "$(as $OWNER2 aal1 "select count(*)::text from public.owner_onboarding_steps")" "0"
expect "a Zella Voice admin with businesses.view reads them" "$(as $ZADMIN aal2 "select count(*)::text from public.owner_onboarding_steps")" "2"
expect "an admin without the permission reads none" "$(as $SUPPORT aal2 "select count(*)::text from public.owner_onboarding")" "0"
expect "the owner can't write the progress directly" "$(as $OWNER aal2 "update public.owner_onboarding set current_step = 'done' returning current_step")" "ERR:permission denied for table owner_onboarding"
expect "anonymous reads nothing" "$(as anon aal1 "select count(*)::text from public.owner_onboarding")" "ERR:permission denied for table owner_onboarding"

# ---- step 2: checked from the auth records, never from the caller ----
expect "no authenticator and no code: refused with what is missing" "$(as $OWNER aal1 "select public.zella_owner_onboarding_complete_step('$BIZ', 'security')::text")" "ERR:SECURITY_INCOMPLETE|authenticator,code"
expect "claiming aal2 without a verified authenticator is not enough" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'security')::text")" "ERR:SECURITY_INCOMPLETE|authenticator"
q "insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at) values (gen_random_uuid(), '$OWNER', 'totp', 'unverified', now(), now())" > /dev/null
expect "an unverified authenticator doesn't count" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'security')::text")" "ERR:SECURITY_INCOMPLETE|authenticator"
q "update auth.mfa_factors set status = 'verified' where user_id = '$OWNER'" > /dev/null
expect "a verified authenticator but a password only session: MFA_REQUIRED" "$(as $OWNER aal1 "select public.zella_owner_onboarding_complete_step('$BIZ', 'security')::text")" "ERR:MFA_REQUIRED"
expect "an owner without a password is told so" "$(q "insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at) values (gen_random_uuid(), '$NOPASS', 'totp', 'verified', now(), now())" > /dev/null;
   as $NOPASS aal2 "select public.zella_owner_onboarding_complete_step('$BIZ2', 'welcome') ->> 'changed'" > /dev/null;
   as $NOPASS aal2 "select public.zella_owner_onboarding_complete_step('$BIZ2', 'security')::text")" "ERR:SECURITY_INCOMPLETE|password"
expect "password, verified authenticator and a code verified session: done" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}', r #>> '{state,security,ready}') from public.zella_owner_onboarding_complete_step('$BIZ', 'security') r")" "true,details,true"
expect "from step 3 on, a password only session can't write" "$(as $OWNER aal1 "select public.zella_owner_onboarding_section('$BIZ', 'business', 'looks_right')::text")" "ERR:MFA_REQUIRED"

# ---- step 3: check your details ----
expect "the details snapshot shows what Zella Voice entered" "$(as $OWNER aal2 "select concat_ws(',', s #>> '{0,data,name}', s #>> '{1,data,services,0,name}', s #>> '{1,data,hours,0,opens}', s #>> '{2,data,members,0,email}', s #>> '{3,data,greeting}') from (select public.zella_owner_onboarding_get('$BIZ') #> '{details,sections}' s) x")" "Glow Test Studio,Haircut,09:00,sam@glow.test,Thanks for calling."
expect "every section starts to review" "$(as $OWNER aal2 "select string_agg(x ->> 'status', ',') from jsonb_array_elements(public.zella_owner_onboarding_get('$BIZ') #> '{details,sections}') x")" "to_review,to_review,to_review,to_review"
expect "finishing step 3 early lists the sections left" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'details')::text")" "ERR:SECTIONS_NOT_CONFIRMED|business,hours_services,team,receptionist_phone"
expect "an unknown section is invalid" "$(as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'billing', 'looks_right')::text")" "ERR:INVALID_INPUT"
expect "Change without a note is refused" "$(as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'team', 'change', '   ')::text")" "ERR:NOTE_REQUIRED"
LONG=$(printf 'a%.0s' $(seq 1 1001))
expect "a note over 1000 characters is refused" "$(as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'team', 'change', '$LONG')::text")" "ERR:NOTE_REQUIRED|too_long"
for s in business hours_services receptionist_phone; do as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', '$s', 'looks_right') ->> 'changed'" > /dev/null; done
expect "Looks right again changes nothing" "$(as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'business', 'looks_right') ->> 'changed'")" "false"
expect "Change with a note" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,details,sections,2,status}', r #>> '{state,details,sections,2,note}') from public.zella_owner_onboarding_section('$BIZ', 'team', 'change', 'Add Maya, she started this week.') r")" "true,change_requested,Add Maya, she started this week."
expect "the same note again changes nothing" "$(as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'team', 'change', 'Add Maya, she started this week.') ->> 'changed'")" "false"
expect "the note reaches Zella Voice as one open alert" "$(q "select count(*) || ',' || max(detail) from public.platform_alerts where kind = 'onboarding_change_requested' and business_id = '$BIZ' and status <> 'resolved'")" "1,Team: Add Maya, she started this week."
expect "the change request is audited with before and after" "$(q "select concat_ws(',', old_data ->> 'status', new_data ->> 'status', new_data ->> 'note') from public.audit_logs where business_id = '$BIZ' and action = 'onboarding.change_requested'")" "to_review,change_requested,Add Maya, she started this week."
expect "admin overview counts the open request" "$(as $ZADMIN aal2 "select concat_ws(',', x ->> 'business_name', x ->> 'current_step_number', x ->> 'change_requests') from jsonb_array_elements(public.zella_admin_onboarding_overview() -> 'businesses') x where x ->> 'business_id' = '$BIZ'")" "Glow Test Studio,3,1"
expect "an admin without businesses.view is refused" "$(as $SUPPORT aal2 "select public.zella_admin_onboarding_overview()::text")" "ERR:NOT_PERMITTED"
expect "an owner can't use the admin calls" "$(as $OWNER aal2 "select public.zella_admin_onboarding_progress('$BIZ')::text")" "ERR:NOT_PERMITTED"
expect "admin progress leaves out team phone and email" "$(as $ZADMIN aal2 "select (s #> '{2,data,members,0}')::text from (select public.zella_admin_onboarding_progress('$BIZ') #> '{details,sections}' s) x")" '{"name": "Sam Test", "title": "Stylist"}'
expect "admin progress for a business not started" "$(as $ZADMIN aal2 "select concat_ws(',', g ->> 'started', g ->> 'current_step') from public.zella_admin_onboarding_progress('$BIZ2') g where true")" "true,security"
expect "admin change done needs businesses.manage" "$(as $SUPPORT aal2 "select public.zella_admin_onboarding_change_done('$BIZ', 'team', 'Added Maya')::text")" "ERR:NOT_PERMITTED"
q "insert into public.staff_members (business_id, name, title) values ('$BIZ', 'Maya Test', 'Stylist')" > /dev/null
expect "admin marks the change done" "$(as $ZADMIN aal2 "select public.zella_admin_onboarding_change_done('$BIZ', 'team', 'Added Maya')::text")" '{"changed": true}'
expect "and again changes nothing" "$(as $ZADMIN aal2 "select public.zella_admin_onboarding_change_done('$BIZ', 'team', 'Added Maya')::text")" '{"changed": false}'
expect "the owner sees it updated, with the admin's note, and the alert is resolved" "$(as $OWNER aal2 "select concat_ws(',', s #>> '{2,status}', s #>> '{2,admin_note}') from (select public.zella_owner_onboarding_get('$BIZ') #> '{details,sections}' s) x")$(q "select ',' || count(*) from public.platform_alerts where kind = 'onboarding_change_requested' and business_id = '$BIZ' and status <> 'resolved'")" "updated,Added Maya,0"
as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'team', 'looks_right') ->> 'changed'" > /dev/null
q "update public.businesses set website = 'https://glow.test' where id = '$BIZ'" > /dev/null
expect "details changed after Looks right: the section asks again" "$(as $OWNER aal2 "select concat_ws(',', g #>> '{details,sections,0,status}', g #>> '{details,all_looks_right}') from public.zella_owner_onboarding_get('$BIZ') g")" "updated,false"
expect "and step 3 can't finish on stale answers" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'details')::text")" "ERR:SECTIONS_NOT_CONFIRMED|business"
as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'business', 'looks_right') ->> 'changed'" > /dev/null
expect "step 3 completes once every section looks right" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}') from public.zella_owner_onboarding_complete_step('$BIZ', 'details') r")" "true,identity"
expect "answers after step 3 are closed" "$(as $OWNER aal2 "select public.zella_owner_onboarding_section('$BIZ', 'team', 'change', 'late')::text")" "ERR:STEP_CLOSED"

# ---- finish later and resume ----
expect "finish later" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}', (r #>> '{state,paused_at}') is not null) from public.zella_owner_onboarding_finish_later('$BIZ') r")" "true,identity,t"
expect "finish later again changes nothing" "$(as $OWNER aal2 "select public.zella_owner_onboarding_finish_later('$BIZ') ->> 'changed'")" "false"
expect "the admin sees where it was left" "$(as $ZADMIN aal2 "select (x ->> 'paused_at' is not null)::text from jsonb_array_elements(public.zella_admin_onboarding_overview() -> 'businesses') x where x ->> 'business_id' = '$BIZ'")" "true"
expect "resume comes back at the same step" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}', (r #>> '{state,paused_at}') is null) from public.zella_owner_onboarding_resume('$BIZ') r")" "true,identity,t"
expect "resume again changes nothing" "$(as $OWNER aal2 "select public.zella_owner_onboarding_resume('$BIZ') ->> 'changed'")" "false"
expect "both are audited" "$(q "select count(*) from public.audit_logs where business_id = '$BIZ' and action in ('onboarding.finish_later', 'onboarding.resumed') and old_data is not null and new_data is not null")" "2"

# ---- step 4: identity (manual upload, checked in Verification) ----
expect "no documents yet: needed, both kinds may be uploaded" "$(as $OWNER aal2 "select concat_ws(',', i ->> 'status', i ->> 'can_upload', i -> 'upload_kinds') from public.zella_owner_onboarding_identity_status('$BIZ') i")" 'needed,true,["owner_identity", "business_registration"]'
expect "payment is locked until identity is verified" "$(as $OWNER aal2 "select concat_ws(',', p ->> 'status', p ->> 'reason', p ->> 'checkout_available') from public.zella_owner_onboarding_payment_status('$BIZ') p")" "locked,identity_first,false"
expect "identity can't be finished yet" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'identity')::text")" "ERR:IDENTITY_NOT_VERIFIED"
expect "the upload check: owner only" "$(as $STAFF aal2 "select public.zella_owner_identity_upload_check('$BIZ', 'owner_identity')::text")" "ERR:NOT_ALLOWED"
expect "the upload check: a code verified session" "$(as $OWNER aal1 "select public.zella_owner_identity_upload_check('$BIZ', 'owner_identity')::text")" "ERR:MFA_REQUIRED"
expect "the upload check: a known kind" "$(as $OWNER aal2 "select public.zella_owner_identity_upload_check('$BIZ', 'tax_registration')::text")" "ERR:INVALID_INPUT"
expect "the upload check passes for the owner" "$(as $OWNER aal2 "select public.zella_owner_identity_upload_check('$BIZ', 'owner_identity')::text")" '{"ok": true}'
expect "the upload check refuses another business's step" "$(as $OWNER2 aal2 "select public.zella_owner_identity_upload_check('$BIZ', 'owner_identity')::text")" "ERR:NOT_ALLOWED"
add() { # kind, user, path suffix
  q "set role service_role; select public.zella_owner_identity_document_add('$BIZ', '$2', '$1', '$BIZ/$1/$3.jpg', 'id.jpg', 'image/jpeg', 2048) #>> '{identity,status}'" | tail -1; }
expect "recording a document: the owner of this business only" "$(q "set role service_role; select public.zella_owner_identity_document_add('$BIZ', '$OWNER2', 'owner_identity', '$BIZ/owner_identity/00000000-0000-4000-8000-000000000001.jpg', 'id.jpg', 'image/jpeg', 2048)" | grep -o NOT_ALLOWED)" "NOT_ALLOWED"
expect "recording a document: a path this business was given" "$(q "set role service_role; select public.zella_owner_identity_document_add('$BIZ', '$OWNER', 'owner_identity', '$BIZ2/owner_identity/00000000-0000-4000-8000-000000000001.jpg', 'id.jpg', 'image/jpeg', 2048)" | grep -o INVALID_INPUT)" "INVALID_INPUT"
expect "the owner can't call the recorder directly" "$(as $OWNER aal2 "select public.zella_owner_identity_document_add('$BIZ', '$OWNER', 'owner_identity', '$BIZ/owner_identity/00000000-0000-4000-8000-000000000001.jpg', 'id.jpg', 'image/jpeg', 2048)::text")" "ERR:permission denied for function zella_owner_identity_document_add"
expect "one document uploaded: still needed (the other is missing)" "$(add owner_identity $OWNER 00000000-0000-4000-8000-000000000001)" "needed"
expect "both uploaded: checking, no more uploads" "$(add business_registration $OWNER 00000000-0000-4000-8000-000000000002)" "checking"
expect "uploading while checking is refused" "$(as $OWNER aal2 "select public.zella_owner_identity_upload_check('$BIZ', 'owner_identity')::text")" "ERR:UPLOAD_NOT_ALLOWED"
expect "the upload is audited" "$(q "select count(*) from public.audit_logs where business_id = '$BIZ' and action = 'onboarding.document_uploaded' and old_data ? 'identity_status' and new_data ? 'document_id'")" "2"
# Zella Voice rejects the identity document in Verification (the same update the admin's document_review makes)
review() { q "update public.business_verification_documents set status = '$2', review_note = nullif('$3', ''), reviewed_at = now(), updated_at = now()
               where business_id = '$BIZ' and kind = '$1' and status <> 'replaced'" > /dev/null; }
review owner_identity rejected "The photo is blurred."
expect "a rejected document: try again, one attempt used, that kind may be uploaded" "$(as $OWNER aal2 "select concat_ws(',', i ->> 'status', i ->> 'attempts_used', i -> 'upload_kinds', i #>> '{documents,1,review_note}') from public.zella_owner_onboarding_identity_status('$BIZ') i")" 'try_again,1,["owner_identity"],The photo is blurred.'
expect "no manual review alert yet" "$(q "select count(*) from public.platform_alerts where kind = 'onboarding_identity_review' and business_id = '$BIZ'")" "0"
expect "the new copy replaces the rejected one: checking" "$(add owner_identity $OWNER 00000000-0000-4000-8000-000000000003)" "checking"
review owner_identity rejected "Still blurred."
expect "the second failure goes to manual review, no upload" "$(as $OWNER aal2 "select concat_ws(',', i ->> 'status', i ->> 'attempts_used', i ->> 'can_upload') from public.zella_owner_onboarding_identity_status('$BIZ') i")" "in_review,2,false"
expect "Zella Voice is alerted to review it by hand" "$(q "select count(*) from public.platform_alerts where kind = 'onboarding_identity_review' and business_id = '$BIZ' and status = 'open'")" "1"
expect "uploading in review is refused" "$(as $OWNER aal2 "select public.zella_owner_identity_upload_check('$BIZ', 'owner_identity')::text")" "ERR:UPLOAD_NOT_ALLOWED"
expect "still can't pass step 4" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'identity')::text")" "ERR:IDENTITY_NOT_VERIFIED"
review business_registration verified ""
review owner_identity verified ""
expect "an admin approves both in Verification: verified, alert resolved" "$(as $OWNER aal2 "select public.zella_owner_onboarding_identity_status('$BIZ') ->> 'status'")$(q "select ',' || count(*) from public.platform_alerts where kind = 'onboarding_identity_review' and business_id = '$BIZ' and status <> 'resolved'")" "verified,0"
expect "step 4 completes" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}') from public.zella_owner_onboarding_complete_step('$BIZ', 'identity') r")" "true,plan"
expect "payment now waits (payments aren't connected)" "$(as $OWNER aal2 "select concat_ws(',', p ->> 'status', p ->> 'reason', p ->> 'checkout_available') from public.zella_owner_onboarding_payment_status('$BIZ') p")" "waiting,payments_not_connected,false"

# ---- step 5: the plan from business_plans, accept only ----
expect "no plan saved yet" "$(as $OWNER aal2 "select public.zella_owner_onboarding_plan_accept('$BIZ', 1)::text")" "ERR:PLAN_MISSING"
plan() { q "insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, minutes, texts, emails, team_seats, phone_numbers, locations, languages, idempotency_key, values_hash)
           values ('$BIZ', $1, 'base', 'monthly', $2, 300, 200, 200, 3, 1, 1, array['en'], 'onboarding-test-$1', md5('$1'))" > /dev/null; }
plan 1 9900; plan 2 12900
expect "the owner sees the current plan, never the estimate" "$(as $OWNER aal2 "select concat_ws(',', p ->> 'available', p #>> '{current,version}', p #>> '{current,price_cents}', p #>> '{current,minutes}', p -> 'current' ? 'estimate') from (select public.zella_owner_onboarding_get('$BIZ') -> 'plan' p) x")" "true,2,12900,300,f"
expect "accepting an old version is refused" "$(as $OWNER aal2 "select public.zella_owner_onboarding_plan_accept('$BIZ', 1)::text")" "ERR:PLAN_CHANGED"
expect "staff can't accept the plan" "$(as $STAFF aal2 "select public.zella_owner_onboarding_plan_accept('$BIZ', 2)::text")" "ERR:NOT_ALLOWED"
expect "accepting the current version completes step 5" "$(as $OWNER aal2 "select concat_ws(',', r ->> 'changed', r #>> '{state,current_step}', r #>> '{state,plan,accepted_version}') from public.zella_owner_onboarding_plan_accept('$BIZ', 2) r")" "true,payment,2"
expect "accepting it again changes nothing" "$(as $OWNER aal2 "select public.zella_owner_onboarding_plan_accept('$BIZ', 2) ->> 'changed'")" "false"
expect "the acceptance is audited with the price" "$(q "select concat_ws(',', coalesce(old_data ->> 'accepted_version', 'none'), new_data ->> 'accepted_version', new_data ->> 'price_cents') from public.audit_logs where business_id = '$BIZ' and action = 'onboarding.plan_accepted'")" "none,2,12900"

# ---- step 6 and the go live gate ----
expect "step 6 waits for a confirmed payment" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'payment')::text")" "ERR:PAYMENT_NOT_CONFIRMED"
gate() { as $OWNER aal2 "select concat_ws(',', r ->> 'ready', (select string_agg(c ->> 'key', '+') from jsonb_array_elements(r -> 'checks') c where not (c ->> 'ok')::boolean)) from public.zella_activation_report('$BIZ') r"; }
expect "the report now shows the payment check failing (identity passed)" "$(gate)" "false,payment"
expect "go live is refused without a payment" "$(as $OWNER aal2 "select public.zella_request_activation('$BIZ') ->> 'ready'")$(q "select ',' || onboarding_status from public.businesses where id = '$BIZ'")" "false,testing"
q "insert into public.payments (business_id, amount, currency, status, provider, paid_at) values ('$BIZ', 129, 'usd', 'pending', 'stripe', null),
     ('$BIZ', 129, 'usd', 'succeeded', null, now())" > /dev/null
expect "a pending payment, or one with no provider, doesn't count" "$(gate)" "false,payment"
q "insert into public.payments (business_id, amount, currency, status, provider, paid_at) values ('$BIZ', 129, 'usd', 'succeeded', 'stripe', now())" > /dev/null
expect "a confirmed payment: every check passes" "$(gate)" "true"
expect "step 6 completes, then step 7" "$(as $OWNER aal2 "select public.zella_owner_onboarding_complete_step('$BIZ', 'payment') #>> '{state,current_step}'"),$(as $OWNER aal2 "select concat_ws(',', r #>> '{state,current_step}', (r #>> '{state,completed_at}') is not null) from public.zella_owner_onboarding_complete_step('$BIZ', 'done') r")" "done,done,t"
expect "every step is done" "$(as $OWNER aal2 "select string_agg(s ->> 'state', ',') from jsonb_array_elements(public.zella_owner_onboarding_get('$BIZ') -> 'steps') s")" "done,done,done,done,done,done,done"
expect "staff can't switch it live" "$(as $STAFF aal2 "select public.zella_request_activation('$BIZ')::text")" "ERR:NOT_ALLOWED"
expect "the owner goes live once everything passes" "$(as $OWNER aal2 "select public.zella_request_activation('$BIZ') ->> 'ready'")$(q "select ',' || onboarding_status from public.businesses where id = '$BIZ'")" "true,active"
expect "the other business stays gated (no identity, no payment)" "$(as $OWNER2 aal2 "select (select string_agg(c ->> 'key', '+') from jsonb_array_elements(r -> 'checks') c where c ->> 'key' in ('identity', 'payment') and not (c ->> 'ok')::boolean) from public.zella_activation_report('$BIZ2') r")" "identity+payment"
expect "a suspended business can't write onboarding" "$(q "update public.businesses set suspended_at = now() where id = '$BIZ2'" > /dev/null; as $OWNER2 aal2 "select public.zella_owner_onboarding_complete_step('$BIZ2', 'welcome')::text"; q "update public.businesses set suspended_at = null where id = '$BIZ2'" > /dev/null)" "ERR:BUSINESS_NOT_AVAILABLE"

# ---- the identity provider event: off by default, once per event when on ----
REF=$(q "select identity_reference from public.owner_onboarding where business_id = '$BIZ'")
expect "off while identity_provider is none" "$(q "set role service_role; select public.zella_identity_provider_event('persona', 'evt_1', '$REF', 'approved', now()) ->> 'result'" | tail -1)" "off"
expect "nothing recorded while off" "$(q "select count(*) from public.identity_verification_events")" "0"
# switch the provider on for this test only (the one constant), then put it back
q "create or replace function public.zella_onboarding_rules() returns jsonb language sql immutable set search_path = '' as \$f\$
   select jsonb_build_object('identity_provider', 'persona', 'plan_choice', 'accept_only', 'first_payment', 'pay_before_live',
     'failed_check', 'retry_then_review', 'identity_attempts', 2, 'payments_connected', false) \$f\$" > /dev/null
ev() { q "set role service_role; select public.zella_identity_provider_event('persona', '$1', '$2', '$3', now()) ->> 'result'" | tail -1; }
expect "another provider's name is off" "$(q "set role service_role; select public.zella_identity_provider_event('stripe_identity', 'e', '$REF', 'approved', now()) ->> 'result'" | tail -1)" "off"
expect "an event for this business is applied" "$(ev evt_1 "$REF" approved)" "applied"
expect "the same event again is a duplicate" "$(ev evt_1 "$REF" approved)" "duplicate"
expect "an unknown reference is kept as unmapped and alerted, never guessed" "$(ev evt_2 ffffffffffffffffffffffffffffffff approved),$(q "select count(*) from public.platform_alerts where kind = 'identity_event_unmapped' and business_id is null")" "unmapped,1"
expect "a pending event is recorded but ignored" "$(ev evt_3 "$REF" pending)" "ignored"
expect "a bad outcome is invalid" "$(q "set role service_role; select public.zella_identity_provider_event('persona', 'evt_4', '$REF', 'maybe', now())" | grep -o INVALID_INPUT)" "INVALID_INPUT"
expect "each event stored once" "$(q "select string_agg(event_id || ':' || result, ',' order by event_id) from public.identity_verification_events")" "evt_1:applied,evt_2:unmapped,evt_3:ignored"
expect "the result is audited" "$(q "select count(*) from public.audit_logs where business_id = '$BIZ' and action = 'onboarding.identity_provider_result'")" "1"
expect "signed in people can't read the provider events" "$(as $OWNER aal2 "select count(*)::text from public.identity_verification_events")" "ERR:permission denied for table identity_verification_events"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "reapplying the file puts the rules back" || bad "reapply after rules change"
expect "the provider is off again" "$(q "select public.zella_onboarding_rules() ->> 'identity_provider'")" "none"

# ---- rollback ----
"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback: $("${P[@]}" -d $DB -f "$RB" 2>&1 | tail -2)"
expect "both activation functions are production's again" "$(q "select md5(pg_get_functiondef('public.zella_activation_report(uuid)'::regprocedure)) || ',' || md5(pg_get_functiondef('public.zella_request_activation(uuid)'::regprocedure))")" "65d1ba6e6671bbfe2fc1b2ea304475d8,0db1467ab6c0c6cba7bc300bbb5946f5"
expect "tables, functions and the trigger are gone" "$(q "select to_regclass('public.owner_onboarding') is null and to_regclass('public.identity_verification_events') is null
   and not exists (select 1 from pg_proc where proname like 'zella_owner_onboarding%' or proname like 'zella_onboarding%' or proname like 'zella_admin_onboarding%'
                     or proname in ('zella_owner_identity_upload_check', 'zella_owner_identity_document_add', 'zella_identity_provider_event'))
   and to_regprocedure('public.zella_activation_checks(uuid)') is null
   and not exists (select 1 from pg_trigger where tgname = 'zella_onboarding_document_rejected')")" "t"
expect "every onboarding row is kept in the archive" "$(q "select string_agg(table_name || ':' || n, ',' order by table_name) from (select table_name, count(*) n from public.zella_owner_onboarding_archive group by 1) x")" "identity_verification_events:3,owner_onboarding:2,owner_onboarding_sections:4,owner_onboarding_steps:9"
expect "the archive is server only" "$(q "select has_table_privilege('authenticated', 'public.zella_owner_onboarding_archive', 'SELECT')")" "f"
expect "documents and payments are untouched" "$(q "select (select count(*) from public.business_verification_documents where business_id = '$BIZ') || ',' || (select count(*) from public.payments where business_id = '$BIZ')")" "3,3"
expect "grants on the restored functions are kept" "$(q "select has_function_privilege('authenticated', 'public.zella_request_activation(uuid)', 'EXECUTE')")" "t"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply after rollback"
q "create or replace function public.zella_request_activation(p_business_id uuid) returns jsonb language plpgsql security definer set search_path = public as \$f\$ begin return '{}'::jsonb; end \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "a changed function stops the rollback (nothing undone)" || bad "drift not caught: $(echo "$out" | tail -2)"
expect "and the tables are still there" "$(q "select to_regclass('public.owner_onboarding') is not null")" "t"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
