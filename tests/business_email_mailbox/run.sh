#!/usr/bin/env bash
# sql/zella_business_email_mailbox.sql on an ISOLATED copy of the schema baseline (never production), after
# sql/zella_oauth_states.sql, production's zella_prepare_email (tests/business_email/prod_prepare_email.sql),
# sql/zella_business_email.sql and sql/zella_business_email_send.sql. Test data, fake addresses and a fake token only;
# no provider is called.
# Checks: refused before its prerequisites and on a zella_oauth_state_issue it wasn't written for; applies twice; mailbox
# sign ins ("gmail", "outlook_mail") are stored and used up once, calendar ones still work, and the two never stand in for
# each other; any other provider is refused; then the whole mailbox path in the database, as n8n drives it: the owner
# connects Gmail, a reminder is prepared from the mailbox, logged, its token handed out once, Gmail refuses for its daily
# limit, the reminder is due again with its try back, the next prepare uses the fallback, the same key is logged again
# with the fallback sender, and today's mailbox count no longer includes it; the rollback (twice) restores the function
# and the constraint exactly, removing mailbox sign ins in progress; applies again.
#   tests/business_email_mailbox/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the database)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizemailbox
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_business_email_mailbox.sql"; RB="$REPO/sql/rollback/zella_business_email_mailbox_rollback.sql"
ISSUE=public.zella_oauth_state_issue\(text,uuid,uuid,text,integer\)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" != 1 ]; then
  "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template zbase" > /dev/null || exit 1
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -f "$1" 2>&1; }
out=$(apply "$MIG"); echo "$out" | grep -q "apply sql/zella_oauth_states.sql first" && ok "refused before sql/zella_oauth_states.sql" || bad "applied without oauth states: $out"
apply "$REPO/sql/zella_oauth_states.sql" > /dev/null || { bad "prerequisite oauth states"; exit 1; }
out=$(apply "$MIG"); echo "$out" | grep -q "apply sql/zella_business_email.sql" && [ "$(q "select md5(pg_get_functiondef('$ISSUE'::regprocedure))")" = 26d8f9711f20f6cef0b889c5848cac16 ] \
  && ok "refused before sql/zella_business_email.sql; nothing changed" || bad "applied without the data model: $out"
for f in tests/business_email/prod_prepare_email.sql sql/zella_business_email.sql sql/zella_business_email_send.sql; do apply "$REPO/$f" > /dev/null || { bad "prerequisite $f"; exit 1; }; done
# a version of zella_oauth_state_issue it wasn't written for
q "select public.zella_patch_function('$ISSUE', '/* other */', 'keep the table small', 'keep the table small /* other */')" > /dev/null
out=$(apply "$MIG"); echo "$out" | grep -q VERSION_MISMATCH && [ "$(q "select pg_get_constraintdef(oid) from pg_constraint where conname = 'oauth_states_provider_check'")" = "CHECK ((provider = ANY (ARRAY['google'::text, 'outlook'::text])))" ] \
  && ok "a zella_oauth_state_issue it wasn't written for is refused; the constraint is left as it was" || bad "foreign version not refused: $out"
q "select public.zella_patch_function('$ISSUE', 'zzz_never', 'keep the table small /* other */', 'keep the table small')" > /dev/null
[ "$(q "select md5(pg_get_functiondef('$ISSUE'::regprocedure))")" = 26d8f9711f20f6cef0b889c5848cac16 ] || { bad "could not restore the issue function for the test"; exit 1; }
for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(q "select md5(pg_get_functiondef('$ISSUE'::regprocedure))")" = 3c293bb1bf7ccf7dcd378e079467d1f0 ] && ok "applies twice; the function is this file's version" || bad "unexpected version"

# test data only
A=b5000000-0000-4000-8000-000000000001; OWN=a5000000-0000-4000-8000-000000000001; CUS=c5000000-0000-4000-8000-000000000001
APT=d5000000-0000-4000-8000-000000000001; REM=e5000000-0000-4000-8000-000000000001
out=$(q "insert into auth.users (id, email) values ('$OWN', 'owner@example.test');
  insert into businesses (id, name, email, timezone) values ('$A', 'Test Salon', 'front@salon.example.test', 'America/Denver');
  insert into business_members (business_id, user_id, role, status) values ('$A', '$OWN', 'owner', 'active');
  insert into customers (id, business_id, first_name, email) values ('$CUS', '$A', 'Ana', 'ana@example.test');
  insert into appointments (id, business_id, customer_id, title, start_time, end_time) values ('$APT', '$A', '$CUS', 'Cut', now() + interval '1 day', now() + interval '1 day 1 hour');
  insert into appointment_reminders (id, business_id, appointment_id, customer_id, kind, channel, due_at, status, attempts) values ('$REM', '$A', '$APT', '$CUS', 'reminder', 'email', now(), 'sending', 1);
  insert into message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
    values (null, null, 'appointment_reminder', 'email', 'transactional', 'en-US', 'Reminder: {{appointment}}', E'Hi {{first_name}},\n\nSee you at {{business}}.', 1, 'active');
  insert into platform_settings (key, value) values ('email_from_address', '\"no-reply@zv.example.test\"'), ('email_live', 'true') on conflict (key) do update set value = excluded.value;
  update platform_settings set value = '{\"domain\": true, \"mailbox\": true}' where key = 'business_email_routes';" 2>&1) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }

# the sign in states
H1=$(printf '1%.0s' {1..64}); H2=$(printf '2%.0s' {1..64}); H3=$(printf '3%.0s' {1..64})
issue() { q "select public.zella_oauth_state_issue('$1', '$OWN', '$A', '$2', 300)" 2>&1; }
consume() { q "select public.zella_oauth_state_consume('$1', '$OWN', '$A', '$2')"; }
[ "$(issue $H1 gmail)$(issue $H2 outlook_mail)$(issue $H3 google)" = ttt ] && ok "mailbox sign ins (gmail, outlook_mail) are stored; calendar ones still are" || bad "issue"
out=$(issue "$(printf '4%.0s' {1..64})" yahoo); echo "$out" | grep -q BAD_REQUEST && ok "any other provider is refused" || bad "other provider stored"
[ "$(consume $H2 outlook)$(consume $H3 gmail)" = ff ] && ok "a mailbox sign in can't finish as a calendar one, nor the other way round" || bad "cross use"
[ "$(consume $H1 gmail)$(consume $H1 gmail)$(consume $H2 outlook_mail)" = tft ] && ok "a mailbox sign in is used up once" || bad "consume"
[ "$(q "select has_function_privilege('authenticated', '$ISSUE', 'execute') or has_function_privilege('anon', '$ISSUE', 'execute')")" = f ] && ok "still server only" || bad "issue callable from the browser"

# the mailbox path in the database, as n8n drives it
TOKEN=fake-refresh-token-for-tests-only
[ "$(q "select public.zella_business_email_mailbox_saved('$A', '$OWN', 'gmail', 'salon@gmail.com', '$TOKEN') ->> 'ok'")" = true ] || { bad "connect"; exit 1; }
p=$(q "select public.zella_prepare_email('$A', '$CUS', 'appointment_reminder', '{\"appointment\": \"Cut\"}', 'transactional')")
[ "$(echo "$p" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["transport"], d["from"], d["reply_to"])')" = "gmail salon@gmail.com salon@gmail.com" ] && ok "prepare: from the connected Gmail" || bad "prepare: $p"
MID=$(q "select public.zella_log_outbound_email('$A', '$CUS', 'ana@example.test', 'salon@gmail.com', 'Reminder: Cut', 't', 'h', 'reminder:$REM', 'queued', '{\"transport\": \"gmail\", \"sender_route\": \"mailbox\", \"reminder_id\": \"$REM\"}') ->> 'id'")
[ "$(q "select public.zella_business_email_mailbox_credentials('$MID') ->> 'refresh_token'")" = "$TOKEN" ] && ok "the token is handed out for this queued email" || bad "credentials"
q "select public.zella_update_outbound_email('$MID', 'failed', null, 'Gmail refused: its daily sending limit.')" > /dev/null
[ "$(q "select public.zella_business_email_mailbox_credentials('$MID') ->> 'ok'")" = false ] && ok "once the send is over, the token is no longer handed out" || bad "credentials after send"
r=$(q "select public.zella_business_email_mailbox_refused('$MID', 'quota')")
[ "$(q "select status || ' ' || attempts from appointment_reminders where id = '$REM'")" = "pending 0" ] && ok "Gmail's daily limit: the reminder is due again at once, with its try back" || bad "requeue: $r"
p=$(q "select public.zella_prepare_email('$A', '$CUS', 'appointment_reminder', '{\"appointment\": \"Cut\"}', 'transactional')")
[ "$(echo "$p" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["transport"], d["from"], d["reply_to"], d["sender_note"])')" = "resend no-reply@zv.example.test front@salon.example.test mailbox_daily_cap" ] \
  && ok "the next prepare uses the fallback (Reply-To the business email) for the rest of the day" || bad "fallback after cap: $p"
r=$(q "select public.zella_log_outbound_email('$A', '$CUS', 'ana@example.test', 'no-reply@zv.example.test', 'Reminder: Cut', 't', 'h', 'reminder:$REM', 'queued', '{\"transport\": \"resend\", \"sender_route\": \"fallback\", \"reminder_id\": \"$REM\"}')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["id"] == "'"$MID"'", d["duplicate"])')" = "True False" ] \
  && [ "$(q "select from_email || ' ' || (metadata ->> 'transport') from email_messages where id = '$MID'")" = "no-reply@zv.example.test resend" ] \
  && ok "the same key is sent again through the fallback, and the record says so" || bad "relog: $r"
[ "$(q "select count(*) from email_messages where business_id = '$A' and metadata ->> 'transport' in ('gmail', 'outlook') and status in ('queued', 'sent', 'delivered')")" = 0 ] \
  && ok "today's mailbox count no longer includes it" || bad "mailbox count still includes the fallback send"

# the rollback
issue "$(printf '5%.0s' {1..64})" gmail > /dev/null
for i in 1 2; do out=$("$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1) || bad "rollback (run $i): $out"; done
[ "$(q "select md5(pg_get_functiondef('$ISSUE'::regprocedure))")" = 26d8f9711f20f6cef0b889c5848cac16 ] \
  && [ "$(q "select pg_get_constraintdef(oid) from pg_constraint where conname = 'oauth_states_provider_check'")" = "CHECK ((provider = ANY (ARRAY['google'::text, 'outlook'::text])))" ] \
  && [ "$(q "select count(*) from oauth_states where provider in ('gmail', 'outlook_mail')")" = 0 ] && [ "$(q "select count(*) from oauth_states where provider = 'google'")" = 1 ] \
  && ok "rollback (twice): the function and the constraint come back exactly; mailbox sign ins in progress go, calendar ones stay" || bad "rollback"
[ "$(q "select mailbox_status from business_email_senders where business_id = '$A'")" = connected ] && ok "rollback leaves a connected mailbox connected" || bad "rollback changed the mailbox"
out=$(apply "$MIG") && ok "applies again after the rollback" || bad "re-apply: $out"

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
