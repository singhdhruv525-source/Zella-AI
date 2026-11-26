#!/usr/bin/env bash
# sql/zella_business_email_caps.sql on an ISOLATED copy of the schema baseline (never production), after the rest of
# the business email stack. Test data, fake addresses and a fake token only; no provider is called.
# Checks: refused before its prerequisites, on a foreign version of a function it replaces and on a caps value it wasn't
# written for; applies twice; the new caps (80% of each provider's limit) and 20 a minute; a type that can't be
# determined gets the provider's lowest cap; the mailbox type from the sign in (free domains always personal); server
# only grants, and the old five argument function is gone; the daily cap sends the rest of the day from the fallback
# (the business's name at Zella Voice's address, Reply-To the business email); pacing at 20 a minute answers
# pace_until (the next email waits; nothing goes from the fallback because of it, and dry runs don't count), also
# through zella_prepare_email; zella_business_email_paced puts a reminder or follow up back with its try; the status
# read shows the type and caps; the rollback refuses on drift, then runs twice and restores every function and the
# setting exactly; applies again.
#   tests/business_email_caps/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the database)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizemcaps; DB2=zbizemcaps_x
. "$REPO/tests/lib/isolated_guard.sh"
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB2" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_business_email_caps.sql"; RB="$REPO/sql/rollback/zella_business_email_caps_rollback.sql"
STACK=(sql/zella_platform_emails.sql tests/business_email/prod_prepare_email.sql sql/zella_oauth_states.sql sql/zella_business_email.sql
       sql/zella_business_email_send.sql sql/zella_email_action_buttons.sql sql/zella_business_email_mailbox.sql)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" != 1 ]; then
  "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
for d in "$DB" "$DB2"; do "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $d" -c "create database $d template zbase" > /dev/null || exit 1; done
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
q2() { "${P[@]}" -d "$DB2" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "${2:-$DB}" -c "set client_min_messages = warning" -f "$1" 2>&1; }
rollback() { "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1; }
md5of() { q "select md5(pg_get_functiondef('$1'::regprocedure))"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(str(d.get(k)) for k in sys.argv[1:]))' "$@"; }
SND=public.zella_business_email_sender\(uuid\); STA=public.zella_business_email_status\(uuid\)
SAV5=public.zella_business_email_mailbox_saved\(uuid,uuid,text,text,text\); SAV6=public.zella_business_email_mailbox_saved\(uuid,uuid,text,text,text,text\)
OLD_CAPS='{"gmail": 500, "outlook": 300, "microsoft_365": 2000, "google_workspace": 2000}'
NEW_CAPS='{"gmail": 400, "outlook": 240, "per_minute": 20, "microsoft_365": 8000, "google_workspace": 1600}'

# before its prerequisites, and on foreign versions
out=$(apply "$MIG" "$DB2"); echo "$out" | grep -q "apply sql/zella_business_email.sql" && ok "refused before the business email data model" || bad "applied without prerequisites: $out"
for f in "${STACK[@]}"; do apply "$REPO/$f" "$DB2" > /dev/null || { bad "prerequisite $f"; exit 1; }; done
q2 "select public.zella_patch_function('$SND', '/* other */', 'v_from text :=', '/* other */ v_from text :=')" > /dev/null
out=$(apply "$MIG" "$DB2"); echo "$out" | grep -q VERSION_MISMATCH && [ "$(q2 "select value::text from platform_settings where key = 'business_email_mailbox_caps'")" = "$OLD_CAPS" ] \
  && [ "$(q2 "select to_regprocedure('public.zella_business_email_mailbox_cap(text,text)') is null")" = t ] \
  && ok "a sender it wasn't written for is refused; nothing changes" || bad "foreign sender not refused: $out"
q2 "select public.zella_patch_function('$SND', 'zzz_never', '/* other */ v_from text :=', 'v_from text :=')" > /dev/null
q2 "update platform_settings set value = '{\"gmail\": 450}' where key = 'business_email_mailbox_caps'" > /dev/null
out=$(apply "$MIG" "$DB2"); echo "$out" | grep -q "business_email_mailbox_caps is not the value" && [ "$(q2 "select to_regprocedure('$SAV5') is not null")" = t ] \
  && ok "a caps value it wasn't written for is refused; nothing changes" || bad "foreign caps not refused: $out"
"${P[@]}" -d postgres -c "drop database if exists $DB2" > /dev/null

for f in "${STACK[@]}"; do apply "$REPO/$f" > /dev/null || { bad "prerequisite $f"; exit 1; }; done
B_SND=$(md5of "$SND"); B_STA=$(md5of "$STA"); B_SAV=$(md5of "$SAV5")
for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(md5of "$SND") $(md5of "$STA") $(md5of "$SAV6")" = "4869cab9ec6319740667de295508c884 59e30c139362c44863045142ee98aa43 0b43ade45c628f71091efbbcdf71b73d" ] \
  && [ "$(q "select to_regprocedure('$SAV5') is null")" = t ] && ok "applies twice; the functions are this file's versions; the five argument mailbox_saved is gone" || bad "versions after apply"
[ "$(q "select value::text from platform_settings where key = 'business_email_mailbox_caps'")" = "$NEW_CAPS" ] \
  && ok "caps: free Gmail 400, Google Workspace 1,600, Outlook.com 240, Microsoft 365 8,000, 20 a minute" || bad "caps: $(q "select value from platform_settings where key = 'business_email_mailbox_caps'")"
n=$(q "select count(*) from unnest(array['public.zella_business_email_mailbox_cap(text,text)', 'public.zella_business_email_paced(text,uuid,timestamptz)', '$SAV6']) f,
        unnest(array['anon', 'authenticated']) r where has_function_privilege(r, f::regprocedure, 'execute')")
[ "$n" = 0 ] && [ "$(q "select has_function_privilege('service_role', '$SAV6', 'execute')")" = t ] && ok "the new functions are server only" || bad "$n browser grants"

# the cap of each type; not known = the provider's lowest
cap() { q "select public.zella_business_email_mailbox_cap($1)"; }
[ "$(cap "'gmail', 'gmail'") $(cap "'gmail', 'google_workspace'") $(cap "'outlook', 'outlook'") $(cap "'outlook', 'microsoft_365'") $(cap "'gmail', 'per_minute'")" = "400 1600 240 8000 20" ] \
  && ok "cap: each type's daily cap and the per minute cap" || bad "caps per type"
[ "$(cap "'gmail', null") $(cap "'outlook', null") $(cap "'gmail', 'microsoft_365'")" = "400 240 400" ] \
  && ok "cap: a type not known (or not the provider's) gets the provider's lowest" || bad "lowest cap"
q "update platform_settings set value = '{\"gmail\": 1700, \"google_workspace\": 1600, \"outlook\": 240, \"microsoft_365\": 8000, \"per_minute\": 20}' where key = 'business_email_mailbox_caps'" > /dev/null
[ "$(cap "'gmail', null")" = 1600 ] && ok "cap: the lowest is read from the setting, whichever type it is" || bad "lowest not from the setting"
q "update platform_settings set value = '$NEW_CAPS' where key = 'business_email_mailbox_caps'" > /dev/null

# test data only
A=b6000000-0000-4000-8000-000000000001; OWN=a6000000-0000-4000-8000-000000000001; CUS=c6000000-0000-4000-8000-000000000001
APT=d6000000-0000-4000-8000-000000000001; REM=e6000000-0000-4000-8000-000000000001; TSK=f6000000-0000-4000-8000-000000000001
out=$(q "insert into auth.users (id, email) values ('$OWN', 'owner@example.test');
  insert into businesses (id, name, email, timezone) values ('$A', 'Test Salon', 'front@salon.example.test', 'America/Denver');
  insert into business_members (business_id, user_id, role, status) values ('$A', '$OWN', 'owner', 'active');
  insert into customers (id, business_id, first_name, email) values ('$CUS', '$A', 'Ana', 'ana@example.test');
  insert into appointments (id, business_id, customer_id, title, start_time, end_time) values ('$APT', '$A', '$CUS', 'Cut', now() + interval '1 day', now() + interval '1 day 1 hour');
  insert into appointment_reminders (id, business_id, appointment_id, customer_id, kind, channel, due_at, status, attempts) values ('$REM', '$A', '$APT', '$CUS', 'reminder', 'email', now(), 'sending', 1);
  insert into followup_tasks (id, business_id, kind, due_at, status, attempts) values ('$TSK', '$A', 'call_followup', now(), 'in_progress', 2);
  insert into message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
    values (null, null, 'appointment_reminder', 'email', 'transactional', 'en-US', 'Reminder: {{appointment}}', E'Hi {{first_name}},\n\nSee you at {{business}}.', 1, 'active');
  insert into platform_settings (key, value) values ('email_from_address', '\"no-reply@zv.example.test\"'), ('email_live', 'true') on conflict (key) do update set value = excluded.value;
  update platform_settings set value = '{\"domain\": true, \"mailbox\": true}' where key = 'business_email_routes';" 2>&1) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
TOKEN=fake-refresh-token-for-tests-only
connect() { q "select public.zella_business_email_mailbox_saved('$A', '$OWN', '$1', '$2', '$TOKEN', $3) ->> 'mailbox_type'"; }
[ "$(connect gmail salon@gmail.com "'work'") $(connect gmail hello@salon.example.test "'work'") $(connect gmail hello@salon.example.test "'personal'") $(connect gmail hello@salon.example.test null)" \
  = "gmail google_workspace gmail unknown" ] && ok "type: gmail.com is free Gmail whatever the sign in says; Workspace from the sign in; otherwise not known" || bad "gmail types"
[ "$(connect outlook salon@hotmail.com "'work'") $(connect outlook hello@salon.example.test "'work'") $(connect outlook hello@salon.example.test "'personal'") $(connect outlook hello@salon.example.test "'other'")" \
  = "outlook microsoft_365 outlook unknown" ] && ok "type: Outlook.com domains are personal; Microsoft 365 from the sign in; anything else not known" || bad "outlook types"
[ "$(q "select count(*) from audit_logs where business_id = '$A' and action = 'business_email.mailbox_connected' and new_data ->> 'mailbox_type' = 'unknown'")" = 2 ] \
  && [ "$(q "select count(*) from audit_logs where row_to_json(audit_logs)::text like '%$TOKEN%'")" = 0 ] && ok "audited with the type, never the token" || bad "audit"
[ "$(q "select mailbox_cap_key is null from business_email_senders where business_id = '$A'")" = t ] && ok "a type not known is stored as not known" || bad "unknown stored"

snd() { q "select public.zella_business_email_sender('$A')"; }
as_owner() { q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$OWN', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '$OWN', true); set local role authenticated; r := $1; reset role; raise warning 'R=%', r; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1; }
st=$(as_owner "public.zella_business_email_status('$A')::text")
[ "$(echo "$st" | j mailbox_type mailbox_daily_cap mailbox_per_minute mailbox_sent_today)" = "unknown 240 20 0" ] && ok "status: the type, the lowest Outlook cap, 20 a minute, none sent today" || bad "status: $st"

# the daily cap: a Workspace mailbox whose type is known
connect gmail hello@salon.example.test "'work'" > /dev/null
MID=$(q "select (public.zella_business_email_local_day('$A')::timestamp at time zone 'America/Denver') + interval '30 seconds'")
mk() { q "insert into email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, metadata, created_at)
          select '$A', '$CUS', 'outbound', '$2', 'hello@salon.example.test', 'ana@example.test', 's', '{\"transport\": \"gmail\"}', $3 from generate_series(1, $1)" > /dev/null; }
mk 1599 sent "'$MID'::timestamptz"
[ "$(snd | j sender_route transport)" = "mailbox gmail" ] && ok "daily cap: Workspace under 1,600 today still sends from the mailbox" || bad "under cap: $(snd)"
mk 1 queued "'$MID'::timestamptz"
[ "$(snd | j sender_route transport from from_name reply_to sender_note)" = "fallback resend no-reply@zv.example.test Test Salon front@salon.example.test mailbox_daily_cap" ] \
  && ok "daily cap: at 1,600 (queued count) the rest of the day goes from Zella Voice's address with the business's name, Reply-To the business email" || bad "at cap: $(snd)"
connect gmail hello@salon.example.test null > /dev/null
q "delete from email_messages where business_id = '$A'" > /dev/null; mk 400 sent "'$MID'::timestamptz"
[ "$(snd | j sender_route sender_note)" = "fallback mailbox_daily_cap" ] && ok "daily cap: a Google mailbox whose type isn't known stops at free Gmail's 400" || bad "unknown at 400: $(snd)"
connect outlook hello@salon.example.test "'work'" > /dev/null
q "update email_messages set metadata = '{\"transport\": \"outlook\"}' where business_id = '$A'" > /dev/null
[ "$(snd | j sender_route transport)" = "mailbox outlook" ] && ok "daily cap: Microsoft 365 goes on past 400" || bad "365: $(snd)"
q "delete from email_messages where business_id = '$A'" > /dev/null

# pacing: 20 in the last 60 seconds
mk 19 sent "now() - interval '30 seconds'"
r=$(snd); [ "$(echo "$r" | j sender_route pace_until)" = "mailbox None" ] && ok "pacing: 19 in the last minute, the next one goes now" || bad "19: $r"
mk 5 dry_run "now() - interval '10 seconds'"
r=$(snd); [ "$(echo "$r" | j pace_until)" = "None" ] && ok "pacing: dry runs don't count" || bad "dry runs counted: $r"
mk 1 queued "now() - interval '5 seconds'"
r=$(snd); [ "$(echo "$r" | j sender_route transport sender_note)" = "mailbox outlook mailbox_paced" ] \
  && [ "$(q "select ('$(echo "$r" | j pace_until)'::timestamptz - (now() + interval '30 seconds')) between interval '-2 seconds' and interval '2 seconds'")" = t ] \
  && ok "pacing: at 20 the next one waits until the oldest is a minute old; it never goes from the fallback" || bad "20: $r"
p=$(q "select public.zella_prepare_email('$A', '$CUS', 'appointment_reminder', '{\"appointment\": \"Cut\"}', 'transactional')")
[ "$(echo "$p" | j allowed transport sender_note)" = "True outlook mailbox_paced" ] && [ "$(echo "$p" | j pace_until)" != None ] \
  && ok "pacing: zella_prepare_email's answer carries pace_until to the email workflows" || bad "prepare: $p"
until=$(echo "$p" | j pace_until)
r=$(q "select public.zella_business_email_paced('reminder', '$REM', '$until')")
[ "$(q "select status || ' ' || attempts || ' ' || (abs(extract(epoch from due_at - '$until'::timestamptz)) < 1) from appointment_reminders where id = '$REM'")" = "pending 0 true" ] \
  && ok "paced: the reminder waits until then, with its try given back" || bad "paced reminder: $r"
r=$(q "select public.zella_business_email_paced('task', '$TSK', now() + interval '1 hour')")
[ "$(q "select status || ' ' || attempts || ' ' || (due_at <= now() + interval '2 minutes 1 second') from followup_tasks where id = '$TSK'")" = "pending 1 true" ] \
  && ok "paced: a follow up the same way, never more than two minutes away" || bad "paced task: $r"
[ "$(q "select public.zella_business_email_paced('reminder', '$REM', now()) ->> 'ok'")" = false ] && ok "paced: only an item still being sent" || bad "paced a pending reminder"
out=$(q "select public.zella_business_email_paced('call', '$REM', now())" 2>&1); echo "$out" | grep -q BAD_ITEM && ok "paced: an unknown item is refused" || bad "unknown item: $out"
q "delete from email_messages where business_id = '$A'" > /dev/null

# the rollback
q "select public.zella_patch_function('$STA', '/* drift */', '-- the route set up', '/* drift */ -- the route set up')" > /dev/null
out=$(rollback); echo "$out" | grep -q ROLLBACK_DRIFT && [ "$(q "select to_regprocedure('$SAV6') is not null")" = t ] && ok "rollback: refused on a status read that changed since; nothing changes" || bad "drift not refused: $out"
q "select public.zella_patch_function('$STA', 'zzz_never', '/* drift */ -- the route set up', '-- the route set up')" > /dev/null
for i in 1 2; do out=$(rollback) || bad "rollback (run $i): $out"; done
[ "$(md5of "$SND") $(md5of "$STA") $(md5of "$SAV5")" = "$B_SND $B_STA $B_SAV" ] && [ "$(q "select to_regprocedure('$SAV6') is null and to_regprocedure('public.zella_business_email_mailbox_cap(text,text)') is null")" = t ] \
  && [ "$(q "select value::text from platform_settings where key = 'business_email_mailbox_caps'")" = "$OLD_CAPS" ] \
  && [ "$(q "select has_function_privilege('service_role', '$SAV5', 'execute') and not has_function_privilege('authenticated', '$SAV5', 'execute')")" = t ] \
  && ok "rollback (twice): every function, its grants and the caps come back exactly" || bad "rollback state"
out=$(apply "$MIG") && [ "$(md5of "$SND")" = 4869cab9ec6319740667de295508c884 ] && ok "applies again after the rollback" || bad "re-apply: $out"

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
