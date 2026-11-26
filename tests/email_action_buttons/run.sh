#!/usr/bin/env bash
# sql/zella_email_action_buttons.sql on an ISOLATED copy of the schema baseline (never production), after production's
# zella_prepare_email (tests/business_email/prod_prepare_email.sql), sql/zella_business_email.sql and
# sql/zella_business_email_send.sql. Test data and fake addresses only; nothing is sent.
# Checks: refused on a zella_prepare_email it wasn't written for; applies twice; server only; an email that asks for
# them and carries a reschedule link gets the three buttons (HTML) and the three addresses (text), and the HTML's
# "Need a new time?" sentence gives way to them while the confirmation code stays; no buttons without the request, without
# a link (no app address), or for a link that isn't one of ours; the link's page: Confirm confirms (a second time says
# so), Cancel cancels (reminders withdrawn, the team told), and nothing works on an unknown code, another action, a
# past or cancelled appointment, or a missed visit's rebook link; another business's appointment is never touched;
# the rollback (twice) restores zella_prepare_email exactly and keeps what customers did; applies again.
#   tests/email_action_buttons/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the database)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zemailbuttons
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_email_action_buttons.sql"; RB="$REPO/sql/rollback/zella_email_action_buttons_rollback.sql"
PREP=public.zella_prepare_email\(uuid,uuid,text,jsonb,text\)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" != 1 ]; then
  "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template zbase" > /dev/null || exit 1
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -f "$1" 2>&1; }
md5of() { q "select md5(pg_get_functiondef('$1'::regprocedure))"; }
for f in tests/business_email/prod_prepare_email.sql sql/zella_business_email.sql; do apply "$REPO/$f" > /dev/null || { bad "prerequisite $f"; exit 1; }; done
out=$(apply "$MIG"); echo "$out" | grep -q VERSION_MISMATCH && [ "$(q "select to_regprocedure('public.zella_reschedule_attend(text,text)') is null")" = t ] \
  && ok "refused before sql/zella_business_email_send.sql (production's zella_prepare_email); nothing created" || bad "applied on the wrong version: $out"
apply "$REPO/sql/zella_business_email_send.sql" > /dev/null || { bad "prerequisite send"; exit 1; }
for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(md5of "$PREP")" = 80a0d034234f64a6384a6dd729d9681e ] && ok "applies twice; zella_prepare_email is this file's version" || bad "unexpected version"
[ "$(q "select bool_or(has_function_privilege(r, f, 'execute')) from unnest(array['anon','authenticated']) r,
        unnest(array['public.zella_reschedule_attend(text,text)', 'public.zella_email_action_buttons(jsonb,text,text)']) f")" = f ] \
  && ok "both new functions are server only" || bad "callable from the browser"

# test data only
A=b3000000-0000-4000-8000-000000000001; B=b3000000-0000-4000-8000-000000000002
CA=c3000000-0000-4000-8000-000000000001; CB=c3000000-0000-4000-8000-000000000002
AP=d3000000-0000-4000-8000-000000000001; AP2=d3000000-0000-4000-8000-000000000002; APB=d3000000-0000-4000-8000-000000000003; APP=d3000000-0000-4000-8000-000000000004
out=$(q "insert into businesses (id, name, email, timezone) values ('$A', 'Test Salon', 'front@salon.example.test', 'America/New_York'), ('$B', 'Test Clinic', 'desk@clinic.example.test', 'America/New_York');
  insert into customers (id, business_id, first_name, email) values ('$CA', '$A', 'Ana', 'ana@example.test'), ('$CB', '$B', 'Ben', 'ben@example.test');
  insert into appointments (id, business_id, customer_id, title, status, start_time, end_time) values
    ('$AP', '$A', '$CA', 'Cut', 'scheduled', now() + interval '2 days', now() + interval '2 days 1 hour'),
    ('$AP2', '$A', '$CA', 'Color', 'scheduled', now() + interval '3 days', now() + interval '3 days 1 hour'),
    ('$APB', '$B', '$CB', 'Checkup', 'scheduled', now() + interval '2 days', now() + interval '2 days 1 hour'),
    ('$APP', '$A', '$CA', 'Past', 'scheduled', now() + interval '1 hour', now() + interval '2 hours');
  insert into appointment_reminders (business_id, appointment_id, customer_id, kind, channel, due_at, status) values ('$A', '$AP2', '$CA', 'reminder', 'email', now() + interval '1 day', 'pending');
  insert into message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status) values
    (null, null, 'appointment_reminder', 'email', 'transactional', 'en-US', 'Reminder: {{appointment}}', E'Hi {{first_name}},\n\nSee you at {{business}}.', 1, 'active'),
    ('$A', null, 'appointment_reminder', 'email', 'transactional', 'en-US', 'Reminder: {{appointment}}', E'Hi {{first_name}},\n\nSee you soon.{{reschedule_line}}', 1, 'active');
  insert into platform_settings (key, value) values ('app_base_url', '\"https://app.example.test\"'), ('email_from_address', '\"no-reply@zv.example.test\"')
    on conflict (key) do update set value = excluded.value;" 2>&1) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
link() { q "select public.zella_reschedule_line('$1')"; }
tok() { echo "$1" | grep -o '[0-9a-f]\{64\}'; }
L1=$(link $AP); T1=$(tok "$L1"); L2=$(link $AP2); T2=$(tok "$L2"); LB=$(link $APB); TB=$(tok "$LB"); LP=$(link $APP); TP=$(tok "$LP")
[ ${#T1} = 64 ] && [ ${#TB} = 64 ] || { bad "could not make links"; exit 1; }
prep() { q "select public.zella_prepare_email('$1', '$2', 'appointment_reminder', jsonb_build_object('appointment', 'Cut', 'reschedule_line', 'Your confirmation code is K7Q2MP.' || '$3', 'action_buttons', '$4'), 'transactional') ->> '$5'"; }

html=$(prep $B $CB "$LB" true body_html)
[ "$(echo "$html" | grep -o 'href="https://app.example.test/r/'"$TB"'?do=confirm"' | wc -l)$(echo "$html" | grep -o 'href="https://app.example.test/r/'"$TB"'"' | wc -l)$(echo "$html" | grep -o 'href="https://app.example.test/r/'"$TB"'?do=cancel"' | wc -l)" = 111 ] \
  && echo "$html" | grep -q '>Confirm</a>' && echo "$html" | grep -q '>Reschedule</a>' && echo "$html" | grep -q '>Cancel</a>' \
  && ok "HTML: Confirm, Reschedule and Cancel buttons on the email's own link" || bad "HTML buttons: $html"
txt=$(prep $B $CB "$LB" true body_text)
echo "$txt" | grep -q "^Confirm: https://app.example.test/r/$TB?do=confirm$" && echo "$txt" | grep -q "^Reschedule: https://app.example.test/r/$TB$" \
  && echo "$txt" | grep -q "^Cancel: https://app.example.test/r/$TB?do=cancel$" && ok "text: the three addresses" || bad "text buttons: $txt"
html=$(prep $A $CA "$L1" true body_html)
echo "$html" | grep -q "Your confirmation code is K7Q2MP." && ! echo "$html" | grep -q "Need a new time" && echo "$html" | grep -q '>Confirm</a>' \
  && ok "a template with the reschedule sentence: the buttons replace it in the HTML, the confirmation code stays" || bad "sentence handling: $html"
echo "$(prep $A $CA "$L1" true body_text)" | grep -q "Need a new time" && ok "the plain text keeps the sentence (it is the text link)" || bad "text lost the sentence"
[ "$(prep $B $CB "$LB" false body_html | grep -c 'do=confirm')" = 0 ] && ok "no buttons unless the email asks for them (follow ups, owner emails)" || bad "buttons without asking"
[ "$(prep $B $CB "" true body_html | grep -c 'do=confirm')" = 0 ] && ok "no buttons without a link (no app address): never a dead button" || bad "buttons without a link"
[ "$(prep $B $CB " Need a new time? https://evil.example.test/x/r/$(printf 'a%.0s' {1..63})" true body_html | grep -c 'do=confirm')" = 0 ] \
  && [ "$(prep $B $CB " Need a new time? javascript:alert(1)/r/$TB" true body_html | grep -c 'do=confirm')" = 0 ] \
  && [ "$(prep $B $CB " Need a new time? https://evil.example.test/r/$TB" true body_html | grep -c 'do=confirm')" = 0 ] \
  && ok "no buttons for a link that isn't an https reschedule link with a full code on Zella Voice's own app address" || bad "buttons for a bad link"
[ "$(prep $B $CB "$LB" true sender_route)" = fallback ] && ok "the sender still comes with it" || bad "sender lost"

# the link's page
att() { q "select public.zella_reschedule_attend('$1', '$2') ->> '$3'"; }
[ "$(att "$T1" confirm result)" = confirmed ] && [ "$(q "select status from appointments where id = '$AP'")" = confirmed ] && ok "Confirm: the appointment is confirmed in the CRM" || bad "confirm"
[ "$(att "$T1" confirm result)" = already_confirmed ] && ok "Confirm again: says so, changes nothing" || bad "confirm twice"
[ "$(q "select uses from appointment_reschedule_links where token_hash = encode(sha256(convert_to('$T1', 'utf8')), 'hex')")" = 2 ] && ok "each use is counted on the link" || bad "uses not counted"
before=$(q "select count(*) from staff_notifications where business_id = '$A' and kind = 'appointment_cancelled'")
[ "$(att "$T2" cancel result)" = cancelled ] && [ "$(q "select status || ' ' || cancel_reason from appointments where id = '$AP2'")" = "cancelled Canceled by the customer from the email link" ] \
  && [ "$(q "select status from appointment_reminders where appointment_id = '$AP2'")" = cancelled ] \
  && [ "$(q "select count(*) from staff_notifications where business_id = '$A' and kind = 'appointment_cancelled'")" = $((before + 1)) ] \
  && ok "Cancel: cancelled with the reason, its reminder withdrawn, the team told" || bad "cancel"
[ "$(att "$T2" cancel ok) $(att "$T2" cancel reason)" = "false not_available" ] && [ "$(att "$T2" confirm reason)" = not_available ] \
  && ok "a cancelled appointment can't be cancelled or confirmed again" || bad "cancelled appointment changed"
[ "$(att "$(printf 'f%.0s' {1..64})" confirm reason)" = invalid ] && [ "$(att "bad" cancel reason)" = invalid ] && ok "an unknown or malformed code does nothing" || bad "unknown code"
[ "$(att "$TB" delete reason)" = invalid ] && [ "$(att "$TB" '' reason)" = invalid ] && [ "$(q "select status from appointments where id = '$APB'")" = scheduled ] \
  && ok "only confirm and cancel" || bad "other action accepted"
q "update appointments set start_time = now() - interval '1 hour', end_time = now() where id = '$APP'" > /dev/null
[ "$(att "$TP" cancel reason)" = past ] && [ "$(q "select status from appointments where id = '$APP'")" = scheduled ] && ok "a past appointment can't be changed" || bad "past appointment changed"
[ "$(q "select status from appointments where id = '$APB'")" = scheduled ] && ok "another business's appointment was never touched (each code is one appointment)" || bad "cross business change"
if [ "$(q "select to_regprocedure('public.zella_rebook_line(uuid)') is not null")" = t ]; then
  q "update appointments set status = 'no_show', start_time = now() - interval '1 day', end_time = now() - interval '23 hours' where id = '$APB'" > /dev/null
  TR=$(tok "$(q "select public.zella_rebook_line('$APB')")")
  [ "$(att "$TR" cancel ok)" = false ] && [ "$(q "select status from appointments where id = '$APB'")" = no_show ] && ok "a missed visit's rebook link can't confirm or cancel" || bad "rebook link acted"
fi

# the rollback
for i in 1 2; do out=$("$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1) || bad "rollback (run $i): $out"; done
[ "$(md5of "$PREP")" = 5477af97583514bab9f3c3d6cffa98be ] && [ "$(q "select to_regprocedure('public.zella_reschedule_attend(text,text)') is null and to_regprocedure('public.zella_email_action_buttons(jsonb,text,text)') is null")" = t ] \
  && ok "rollback (twice): zella_prepare_email is exactly the send file's version; the new functions are gone" || bad "rollback"
[ "$(q "select string_agg(status, ',' order by start_time) from appointments where id in ('$AP', '$AP2')")" = "confirmed,cancelled" ] && ok "rollback keeps what customers did" || bad "rollback changed appointments"
out=$(apply "$MIG") && [ "$(md5of "$PREP")" = 80a0d034234f64a6384a6dd729d9681e ] && ok "applies again after the rollback" || bad "re-apply: $out"
out=$("$REPO/sql/rollback/run.sh" "$REPO/sql/rollback/zella_business_email_send_rollback.sql" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1)
echo "$out" | grep -q IN_USE && ok "the send file's rollback refuses while the buttons are applied" || bad "send rollback did not refuse: $out"

# on caller verification's version of zella_prepare_email (sql/zella_caller_verification.sql) too
DB2=${DB}_cv; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB2" || exit 1
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB2" -c "create database $DB2 template zbase" > /dev/null || exit 1
q2() { "${P[@]}" -d "$DB2" -c "set client_min_messages = warning" "$@"; }
q2 -f "$REPO/tests/business_email/prod_prepare_email.sql" > /dev/null
awk '/^CREATE OR REPLACE FUNCTION public.zella_prepare_email\(/{f=1} f{print} f&&/^end \$function\$/{print ";"; exit}' "$REPO/sql/zella_caller_verification.sql" | "${P[@]}" -d "$DB2" > /dev/null
for f in sql/zella_business_email.sql sql/zella_business_email_send.sql sql/zella_email_action_buttons.sql sql/zella_email_action_buttons.sql; do q2 -f "$REPO/$f" > /dev/null 2>&1 || bad "caller base: $f"; done
[ "$(q2 -c "select md5(pg_get_functiondef('$PREP'::regprocedure))")" = 48f63edd50fd20e6dfb921cc22c1b3ca ] && ok "applies twice on caller verification's version too" || bad "caller base version"
for i in 1 2; do "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB2" -q > /dev/null 2>&1 || bad "caller base rollback $i"; done
[ "$(q2 -c "select md5(pg_get_functiondef('$PREP'::regprocedure))")" = f6804f2eb7e698454e56669b0e5e31a4 ] && ok "and its rollback gives that base back exactly" || bad "caller base rollback version"
[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB2" > /dev/null

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
