#!/usr/bin/env bash
# sql/zella_business_email_send.sql on an ISOLATED copy of the schema baseline (never production), with production's
# zella_prepare_email (169dc4af..., tests/business_email/prod_prepare_email.sql) and sql/zella_business_email.sql.
# Test data and fake addresses only; nothing is sent.
# Checks: refused before sql/zella_business_email.sql, and on a zella_prepare_email it wasn't written for; applies twice
# on production's version, and on caller verification's (d0d67a38..., from sql/zella_caller_verification.sql); the
# fallback (business name, Zella Voice's sender, Reply-To the business email, even with an inbound address set up);
# a verified domain (switch on) sends from the business address through Resend; a mailbox from its account; the cap
# sends the rest of the day through the fallback; a refusal (no consent, unknown customer) is unchanged and names no
# sender; another business is unaffected; a failed email tried again under the same key records what is sent this
# time; sql/zella_business_email.sql's rollback refuses while this file is applied; the rollback (twice) restores both
# functions exactly, on both bases, and the file applies again.
#   tests/business_email_send/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the databases)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizemailsend; DB2=zbizemailsend_cv
. "$REPO/tests/lib/isolated_guard.sh"
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB2" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_business_email_send.sql"; RB="$REPO/sql/rollback/zella_business_email_send_rollback.sql"
PREP=public.zella_prepare_email\(uuid,uuid,text,jsonb,text\); LOG=public.zella_log_outbound_email\(uuid,uuid,text,text,text,text,text,text,text,jsonb\)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" != 1 ]; then
  "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
mk() { "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $1" -c "create database $1 template zbase" > /dev/null || exit 1
  "${P[@]}" -d "$1" -f "$REPO/tests/business_email/prod_prepare_email.sql" > /dev/null || exit 1; }
md5of() { "${P[@]}" -d "${2:-$DB}" -c "select md5(pg_get_functiondef('$1'::regprocedure))"; }
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "${2:-$DB}" -c "set client_min_messages = warning" -f "$1" 2>&1; }
rollback() { "$REPO/sql/rollback/run.sh" "$1" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "${2:-$DB}" -q 2>&1; }
mk "$DB"
[ "$(md5of "$PREP")" = 169dc4af51e2bff9f527bcb3fd9e7d84 ] && ok "the copy's zella_prepare_email is production's version" || { bad "the copy is not production's version"; exit 1; }
LOG_BASE=$(md5of "$LOG"); [ "$LOG_BASE" = d524ef783e77b316130bc169d036f18c ] || { bad "zella_log_outbound_email is not production's version"; exit 1; }

out=$(apply "$MIG"); echo "$out" | grep -q "apply sql/zella_business_email.sql first" && [ "$(md5of "$PREP")" = 169dc4af51e2bff9f527bcb3fd9e7d84 ] \
  && ok "refused before sql/zella_business_email.sql; nothing changed" || bad "applied without its prerequisite: $out"
apply "$REPO/sql/zella_business_email.sql" > /dev/null || { bad "prerequisite"; exit 1; }
# a version it wasn't written for
q "select public.zella_patch_function('$PREP', '/* someone else */', 'v_subject := left(trim(v_subject), 200);', 'v_subject := left(trim(v_subject), 199); /* someone else */')" > /dev/null
out=$(apply "$MIG"); echo "$out" | grep -q VERSION_MISMATCH && [ "$(md5of "$LOG")" = "$LOG_BASE" ] \
  && ok "a zella_prepare_email it wasn't written for is refused, and nothing changes" || bad "foreign version not refused: $out"
mk "$DB"; apply "$REPO/sql/zella_business_email.sql" > /dev/null
for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(md5of "$PREP") $(md5of "$LOG")" = "5477af97583514bab9f3c3d6cffa98be 3f878d87e3a4c13ee234b912b12f9e87" ] && ok "applies twice; both functions are this file's version" || bad "unexpected versions"
[ "$(q "select count(*) from zella_function_archive where migration = 'zella_business_email_send'")" = 2 ] && ok "both originals archived for the exact rollback" || bad "archive"
out=$("$REPO/sql/rollback/run.sh" "$REPO/sql/rollback/zella_business_email_rollback.sql" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1)
echo "$out" | grep -q IN_USE && ok "the data model's rollback refuses while sending uses it" || bad "data model rollback did not refuse: $out"

# test data only
A=b2000000-0000-4000-8000-000000000001; B=b2000000-0000-4000-8000-000000000002; OWN=a2000000-0000-4000-8000-000000000001
CA=c2000000-0000-4000-8000-000000000001; CB=c2000000-0000-4000-8000-000000000002; CX=c2000000-0000-4000-8000-000000000003
out=$(q "insert into auth.users (id, email) values ('$OWN', 'owner@example.test');
  insert into businesses (id, name, email, timezone, inbound_email_token) values ('$A', 'Test Salon', 'Front@Salon.example.test', 'America/New_York', 'tok123'),
    ('$B', 'Test Clinic', 'desk@clinic.example.test', 'America/Chicago', null);
  insert into business_members (business_id, user_id, role, status) values ('$A', '$OWN', 'owner', 'active');
  insert into customers (id, business_id, first_name, email) values ('$CA', '$A', 'Ana', 'ana@example.test'), ('$CB', '$B', 'Ben', 'ben@example.test'),
    ('$CX', '$A', 'Cy', 'cy@example.test');
  update customers set do_not_email = true where id = '$CX';
  insert into message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
    values (null, null, 'appointment_reminder', 'email', 'transactional', 'en-US', 'Reminder: {{appointment}}', E'Hi {{first_name}},\n\nSee you at {{business}}.', 1, 'active');
  insert into platform_settings (key, value) values ('email_from_address', '\"no-reply@zellavoice.example.test\"'), ('inbound_email_domain', '\"in.example.test\"'), ('email_live', 'true')
    on conflict (key) do update set value = excluded.value;" 2>&1) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
prep() { q "select public.zella_prepare_email('$1', '$2', 'appointment_reminder', '{\"appointment\": \"Cut\"}', 'transactional') ->> '$3'"; }
[ "$(prep $A $CA allowed)|$(prep $A $CA from)|$(prep $A $CA from_name)|$(prep $A $CA reply_to)|$(prep $A $CA sender_route)|$(prep $A $CA transport)|$(prep $A $CA sender_note)" \
  = "true|no-reply@zellavoice.example.test|Test Salon|front@salon.example.test|fallback|resend|" ] \
  && ok "fallback: business name at Zella Voice's sender, Reply-To the business email (not the inbound address)" || bad "fallback: $(q "select public.zella_prepare_email('$A', '$CA', 'appointment_reminder', '{\"appointment\": \"Cut\"}', 'transactional')")"
[ "$(prep $A $CA subject)|$(prep $A $CA body_text)" = "Reminder: Cut|Hi Ana,

See you at Test Salon." ] && ok "the email itself is unchanged" || bad "email content changed"
[ "$(prep $A $CX allowed)|$(prep $A $CX reason)|$(q "select public.zella_prepare_email('$A', '$CX', 'appointment_reminder', '{}', 'transactional') ? 'sender_route'")" = "false|no_consent|f" ] \
  && ok "a refusal is unchanged and names no sender" || bad "refusal changed"
[ "$(prep $A $CB reason)" = unknown_customer ] && ok "another business's customer is still refused (cross business)" || bad "cross business customer"

# the verified domain, then the switch
q "select public.zella_business_email_domain_saved('$A', '$OWN', 'hello@salon.example.test', 'd_1', '[]', 'verified')" > /dev/null
[ "$(prep $A $CA sender_route) $(prep $A $CA sender_note) $(prep $A $CA from)" = "fallback domain_route_off no-reply@zellavoice.example.test" ] \
  && ok "a verified domain waits for its switch (ARC-8)" || bad "domain used with its switch off"
q "update platform_settings set value = '{\"domain\": true, \"mailbox\": true}' where key = 'business_email_routes'" > /dev/null
[ "$(prep $A $CA from)|$(prep $A $CA from_name)|$(prep $A $CA reply_to)|$(prep $A $CA transport)|$(prep $A $CA sender_route)" = "hello@salon.example.test|Test Salon|hello@salon.example.test|resend|domain" ] \
  && ok "domain: from the business's own address through Resend" || bad "domain: $(q "select public.zella_prepare_email('$A', '$CA', 'appointment_reminder', '{}', 'transactional')")"
[ "$(prep $B $CB from) $(prep $B $CB reply_to)" = "no-reply@zellavoice.example.test desk@clinic.example.test" ] && ok "another business keeps the fallback (cross business)" || bad "another business changed"

# the mailbox and its cap
q "select public.zella_business_email_mailbox_saved('$A', '$OWN', 'outlook', 'salon@outlook.com', 'fake-token-for-tests')" > /dev/null
[ "$(prep $A $CA from) $(prep $A $CA transport) $(prep $A $CA sender_route)" = "salon@outlook.com outlook mailbox" ] && ok "mailbox: from its account, through the provider" || bad "mailbox route"
q "update business_email_senders set cap_reached_on = public.zella_business_email_local_day('$A') where business_id = '$A'" > /dev/null
[ "$(prep $A $CA from) $(prep $A $CA transport) $(prep $A $CA sender_note) $(prep $A $CA reply_to)" = "no-reply@zellavoice.example.test resend mailbox_daily_cap front@salon.example.test" ] \
  && ok "mailbox at its daily cap: the fallback for the rest of the day" || bad "cap not applied in prepare"

# a failed email tried again records what is sent this time
r=$(q "select public.zella_log_outbound_email('$A', '$CA', 'ana@example.test', 'salon@outlook.com', 'Reminder', 't', 'h', 'reminder:test-0001', 'queued', '{\"transport\": \"outlook\"}')")
MID=$(echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
q "update email_messages set status = 'failed' where id = '$MID'" > /dev/null
r=$(q "select public.zella_log_outbound_email('$A', '$CA', 'ana@example.test', 'no-reply@zellavoice.example.test', 'Reminder 2', 't2', 'h2', 'reminder:test-0001', 'queued', '{\"transport\": \"resend\", \"sender_route\": \"fallback\"}')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["duplicate"], d["status"])')" = "False queued" ] \
  && [ "$(q "select from_email || ' ' || subject || ' ' || (metadata ->> 'transport') || ' ' || (metadata ->> 'dedupe_key') from email_messages where id = '$MID'")" = "no-reply@zellavoice.example.test Reminder 2 resend reminder:test-0001" ] \
  && ok "a retried email records this time's sender, content and transport, under the same key" || bad "retry record: $r"
r=$(q "select public.zella_log_outbound_email('$A', '$CA', 'ana@example.test', 'x@example.test', 'Other', 't', 'h', 'reminder:test-0001', 'queued', '{}')")
[ "$(echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["duplicate"])')" = True ] && [ "$(q "select subject from email_messages where id = '$MID'")" = "Reminder 2" ] \
  && ok "a queued email under the same key is still never sent twice nor changed" || bad "duplicate changed the row"

# the rollback, twice
for i in 1 2; do out=$(rollback "$RB") || bad "rollback (run $i): $out"; done
[ "$(md5of "$PREP") $(md5of "$LOG")" = "169dc4af51e2bff9f527bcb3fd9e7d84 $LOG_BASE" ] && ok "rollback (twice) restores both functions exactly" || bad "rollback did not restore"
out=$(apply "$MIG") && [ "$(md5of "$PREP")" = 5477af97583514bab9f3c3d6cffa98be ] && ok "applies again after the rollback" || bad "re-apply: $out"
q "select public.zella_patch_function('$LOG', '/* drift */', 'returning * into r;', 'returning * into r; /* drift */')" > /dev/null
out=$(rollback "$RB"); echo "$out" | grep -q ROLLBACK_DRIFT && [ "$(md5of "$PREP")" = 5477af97583514bab9f3c3d6cffa98be ] \
  && ok "the rollback refuses a changed function and changes nothing (all or nothing)" || bad "drift not refused: $out"

# caller verification's version of zella_prepare_email
mk "$DB2"; apply "$REPO/sql/zella_business_email.sql" "$DB2" > /dev/null
awk '/^CREATE OR REPLACE FUNCTION public.zella_prepare_email\(/{f=1} f{print} f&&/^end \$function\$/{print ";"; exit}' "$REPO/sql/zella_caller_verification.sql" | "${P[@]}" -d "$DB2" > /dev/null
if [ "$(md5of "$PREP" "$DB2")" = d0d67a384b0e6a3e270e613ca4af923c ]; then
  for i in 1 2; do out=$(apply "$MIG" "$DB2") || bad "caller verification base, apply $i: $(echo "$out" | grep -m1 ERROR)"; done
  [ "$(md5of "$PREP" "$DB2")" = f6804f2eb7e698454e56669b0e5e31a4 ] && ok "applies twice on caller verification's version too" || bad "caller base: wrong version"
  for i in 1 2; do out=$(rollback "$RB" "$DB2") || bad "caller base rollback $i: $out"; done
  [ "$(md5of "$PREP" "$DB2")" = d0d67a384b0e6a3e270e613ca4af923c ] && ok "and its rollback gives caller verification's version back exactly" || bad "caller base rollback wrong"
else bad "could not build caller verification's version"; fi

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" -c "drop database if exists $DB2" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
