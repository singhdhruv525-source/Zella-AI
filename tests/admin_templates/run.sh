#!/usr/bin/env bash
# sql/zella_admin_templates_manage.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, <SCRIPT> in upper case gets through a save (COM-27) and nothing can create or retire a template
# (UI-20); applies, and applies again; script tags are refused in any case and in the subject; create makes an industry
# version and a Spanish version of a key with a platform version, audited, and refuses a key without one, a second
# copy, the platform version itself, an unknown variable, a marketing text without STOP and a bad language; the
# industry version is what a business of that industry gets; retire archives an override (the business falls back to
# the platform version), audited, and refuses the English platform version and a business copy; a role without
# comms.manage and a business owner are refused; the rollback (twice) restores the save exactly and drops the two;
# applies again; drift stops the file (VERSION_MISMATCH) and the rollback (ROLLBACK_DRIFT).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_admin_templates}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_admin_templates_manage.sql"; RB="$REPO/sql/rollback/zella_admin_templates_manage_rollback.sql"
fp() { q "select md5(pg_get_functiondef('public.zella_admin_template_save(uuid,text,text,text)'::regprocedure))"; }
before=$(fp)
OWN=e3000000-0000-0000-0000-000000000001; RO=e3000000-0000-0000-0000-000000000002; BO=e3000000-0000-0000-0000-000000000003
IND=$(q "select id from public.industries where is_active order by name limit 1")
q "insert into auth.users (id, email) values ('$OWN', 'owner@zella.test'), ('$RO', 'readonly@zella.test'), ('$BO', 'owner@glow.test');
   insert into public.platform_admins (user_id, role, is_active) values ('$OWN', 'zella_owner', true), ('$RO', 'read_only_admin', true);
   insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing" > /dev/null || exit 1
BIZ=$(q "insert into public.businesses (name, industry_id) values ('Glow Test Studio', '$IND') returning id" | head -1)
SMS=$(q "insert into public.message_templates (key, channel, purpose, locale, body) values ('appointment_reminder', 'sms', 'transactional', 'en-US', 'Hi {{first_name}}, see you soon at {{business}}.') returning id" | head -1)
q "insert into public.message_templates (key, channel, purpose, locale, body) values ('win_back', 'sms', 'marketing', 'en-US', 'We miss you at {{business}}. Reply STOP to opt out.');
   insert into public.message_templates (business_id, key, channel, purpose, locale, body) values ('$BIZ', 'appointment_reminder', 'sms', 'transactional', 'en-US', 'Our own copy, {{first_name}}.')" > /dev/null
as() { printf '%s\n' "begin; set local role authenticated;" \
    "select set_config('request.jwt.claims', '{\"sub\": \"$1\", \"role\": \"authenticated\", \"aal\": \"aal2\"}', true) \\g /dev/null" \
    "$2;" "commit;" | "${P[@]}" -d $DB 2>&1; }
out=$(as $OWN "select public.zella_admin_template_save('$SMS', null, 'Hi <SCRIPT>x</SCRIPT> {{first_name}}', 'test')"); save_rc=$?
# the save must really succeed (psql's exit status too), and store the body, for this to show the gap
[ "$save_rc" = "0" ] && [[ "$out" != *ERROR* && "$out" != *BODY_TEXT* ]] && [ "$(q "select count(*) from public.message_templates where key = 'appointment_reminder' and business_id is null and status = 'active' and body = 'Hi <SCRIPT>x</SCRIPT> {{first_name}}'")" = "1" ] \
  && ok "before: <SCRIPT> in upper case gets through a save (COM-27)" || bad "before: $out"
SMS=$(q "select id from public.message_templates where key = 'appointment_reminder' and business_id is null and status = 'active'")
q "update public.message_templates set body = 'Hi {{first_name}}, see you soon at {{business}}.' where id = '$SMS'" > /dev/null
[ -z "$(q "select to_regprocedure('public.zella_admin_template_create(text,text,uuid,text,text,text,text)')")" ] && ok "before: nothing can create or retire a template (UI-20)" || bad "before create"

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | grep -v NOTICE | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
for body in "Hi <SCRIPT>x</SCRIPT>" "Hi <ScRiPt src=x>" "JavaScript:alert(1)"; do
  out=$(as $OWN "select public.zella_admin_template_save('$SMS', null, '$body {{first_name}}', 'test')"); [[ "$out" == *BODY_TEXT* ]] || bad "save let through: $body"
done
ok "a save refuses script tags in any case"
c() { as $OWN "select public.zella_admin_template_create($1)"; }
r=$(c "'appointment_reminder', 'sms', '$IND', 'en-US', null, 'Hello {{first_name}}, your visit at {{business}} is soon.', 'Industry wording'")
[[ "$r" == *'"locale": "en-US"'* ]] && ok "create makes an industry version" || bad "industry create: $r"
r=$(c "'appointment_reminder', 'sms', null, 'es-US', null, 'Hola {{first_name}}, le esperamos en {{business}}.', 'Spanish'")
[[ "$r" == *es-US* ]] && ok "create makes a Spanish version" || bad "spanish create: $r"
[ "$(q "select count(*) from public.audit_logs where action = 'comms.template_created' and user_id = '$OWN' and new_data ->> 'reason' is not null")" = "2" ] && ok "each create is audited with the reason" || bad "create audit"
for args in "'no_such_key', 'sms', null, 'es-US', null, 'Hi', 'x reason'|NO_PLATFORM_VERSION" \
            "'appointment_reminder', 'sms', '$IND', 'en-US', null, 'Again {{first_name}}', 'x reason'|ALREADY_EXISTS" \
            "'appointment_reminder', 'sms', null, 'en-US', null, 'Base again', 'x reason'|ALREADY_EXISTS" \
            "'appointment_reminder', 'sms', null, 'fr-FR', null, 'Bonjour', 'x reason'|LOCALE" \
            "'win_back', 'sms', '$IND', 'en-US', null, 'Come back to {{business}}', 'x reason'|SMS_NEEDS_STOP" \
            "'win_back', 'sms', null, 'es-US', null, 'Vuelva {{card_number}} STOP', 'x reason'|UNKNOWN_VARIABLES" \
            "'win_back', 'sms', null, 'es-US', null, 'Vuelva <Script> STOP', 'x reason'|BODY_TEXT" \
            "'win_back', 'sms', null, 'es-US', null, 'Vuelva STOP', ' '|REASON_REQUIRED"; do
  IFS='|' read -r a want <<< "$args"; out=$(c "$a"); [[ "$out" == *"$want"* ]] || bad "create should refuse $want: $out"
done
ok "create refuses a key without a platform version, a second copy, the platform version itself, a bad language, a marketing text without STOP, unknown variables, script and a missing reason"
B2=$(q "insert into public.businesses (name, industry_id) values ('Same Industry Co', '$IND') returning id" | head -1)
[[ "$(q "select (public.zella_resolve_template('$B2', 'appointment_reminder', 'sms')).body")" == "Hello {{first_name}}, your visit"* ]] && ok "a business of that industry now gets the industry version" || bad "resolve industry"
IV=$(q "select id from public.message_templates where industry_id = '$IND' and key = 'appointment_reminder' and status = 'active'")
for who in "$RO" "$BO"; do out=$(as $who "select public.zella_admin_template_retire('$IV', 'test reason')"); [[ "$out" == *NOT_ALLOWED* ]] || bad "retire allowed for $who: $out"
  out=$(as $who "select public.zella_admin_template_create('win_back', 'sms', null, 'es-US', null, 'Vuelva STOP', 'test reason')"); [[ "$out" == *NOT_ALLOWED* ]] || bad "create allowed for $who: $out"; done
ok "a role without comms.manage and a business owner are refused"
r=$(as $OWN "select public.zella_admin_template_retire('$IV', 'Back to the platform wording') ->> 'status'")
[ "$r" = "archived" ] && [[ "$(q "select (public.zella_resolve_template('$B2', 'appointment_reminder', 'sms')).body")" == "Hi {{first_name}}, see you soon"* ]] && ok "retire archives the override and the business falls back to the platform version" || bad "retire: $r"
[ "$(q "select count(*) from public.audit_logs where action = 'comms.template_retired' and entity_id = '$IV'")" = "1" ] && ok "retire is audited" || bad "retire audit"
out=$(as $OWN "select public.zella_admin_template_retire('$SMS', 'test reason')"); [[ "$out" == *PLATFORM_BASE* ]] && ok "the English platform version can't be retired" || bad "base: $out"
BC=$(q "select id from public.message_templates where business_id = '$BIZ'")
out=$(as $OWN "select public.zella_admin_template_retire('$BC', 'test reason')"); [[ "$out" == *BUSINESS_TEMPLATE* ]] && ok "a business's own copy can't be retired here" || bad "business copy: $out"

"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && [ "$(q "select count(*) from pg_proc where proname in ('zella_admin_template_create', 'zella_admin_template_retire')")" = "0" ] && ok "rollback restores the save exactly and drops create and retire" || bad "after rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_template_retire(p_id uuid, p_reason text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
