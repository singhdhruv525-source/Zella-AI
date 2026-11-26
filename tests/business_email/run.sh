#!/usr/bin/env bash
# sql/zella_business_email.sql on an ISOLATED copy of the schema baseline (sql/baseline, never production). Test people
# and fake values only (example.test addresses, a fake token); no provider is ever called.
# Checks: applies twice; a foreign version of a function is refused; server only functions can't be called by anon or
# signed in people; the table is read only and row security keeps each business to its own row (owners, admins and
# managers; not staff, viewers or another business); who may set it up (owner, admin, Zella Voice admin with
# businesses.manage; not staff, another business's owner, an inactive admin or one without the permission); the domain
# rules (bad address, free mailbox, Zella Voice's own domain, a domain another business has, records kept to safe
# fields); Resend's verification answer; who sends (fallback with Reply-To the business email; each route's switch;
# domain verified; mailbox connected; the daily cap counted in the business's day, or reached by a refusal); the
# mailbox token lives only in Vault and is handed out only for one queued mailbox email of that business; a refusal
# (daily cap or sign in) fails the email, gives the reminder or follow up its try back due now, and tells the business
# once a day; disconnect deletes the token; the status read; every change audited without a token; the rollback
# refuses while something is set up, then runs twice and the file applies again.
#   tests/business_email/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the database)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizemail; DB2=zbizemail_x
. "$REPO/tests/lib/isolated_guard.sh"
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB2" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_business_email.sql"; RB="$REPO/sql/rollback/zella_business_email_rollback.sql"
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" != 1 ]; then
  "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
for d in "$DB" "$DB2"; do "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $d" -c "create database $d template zbase" > /dev/null || exit 1; done
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "${2:-$DB}" -c "set client_min_messages = warning" -f "$1" 2>&1; }
rollback() { "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1; }
# as <user> <sql>: runs <sql> as that signed in person and prints the answer (or ERR:<message>)
as() { q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '$1', true); set local role authenticated; begin $2 exception when others then r := 'ERR:' || sqlerrm; end; reset role;
  raise warning 'R=%', r; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1; }

# a foreign function with one of this file's names is refused, and nothing is created
"${P[@]}" -d "$DB2" -c "create function public.zella_business_email_sender(uuid) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$(apply "$MIG" "$DB2"); echo "$out" | grep -q "VERSION_MISMATCH" && [ "$("${P[@]}" -d "$DB2" -c "select to_regclass('public.business_email_senders') is null")" = t ] \
  && ok "a foreign version of a function is refused and nothing is created" || bad "foreign version not refused: $out"
"${P[@]}" -d postgres -c "drop database if exists $DB2" > /dev/null

for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
ok "applies twice"
[ "$(q "select value::text from platform_settings where key = 'business_email_routes'")" = '{"domain": false, "mailbox": false}' ] \
  && ok "both routes start switched off (business_email_routes)" || bad "routes switch not off"
[ "$(q "select count(*) from zella_migration_settings where migration = 'zella_business_email'")" = 2 ] && ok "the two settings are recorded for the rollback" || bad "settings not recorded"

# who may call what
srv=(zella_business_email_actor_can zella_business_email_mailbox_can_connect zella_business_email_domain_begin zella_business_email_domain_saved zella_business_email_domain_checked
     zella_business_email_mailbox_saved zella_business_email_disconnect zella_business_email_sender zella_business_email_mailbox_credentials
     zella_business_email_mailbox_refused zella_business_email_local_day zella_business_email_records)
n=$(q "select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace, unnest(array['anon','authenticated','public']) r
        where s.nspname = 'public' and p.proname = any (array['$(IFS=,; echo "${srv[*]}" | sed "s/,/','/g")']) and r <> 'public' and has_function_privilege(r, p.oid, 'execute')")
[ "$n" = 0 ] && ok "the twelve server only functions can't be called by anon or signed in people" || bad "$n server only grants to anon or authenticated"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_business_email_status(uuid)', 'execute') and not has_function_privilege('anon', 'public.zella_business_email_status(uuid)', 'execute')")" = t ] \
  && ok "the status read is for signed in people only" || bad "status grants wrong"
[ "$(q "select bool_or(has_table_privilege(r, 'public.business_email_senders', p)) from unnest(array['anon','authenticated']) r, unnest(array['insert','update','delete']) p")" = f ] \
  && [ "$(q "select has_column_privilege('authenticated', 'public.business_email_senders', 'mailbox_secret_name', 'select')")" = f ] \
  && [ "$(q "select relrowsecurity from pg_class where oid = 'public.business_email_senders'::regclass")" = t ] \
  && ok "the table: row security on, nobody writes it directly, the Vault secret's name isn't readable" || bad "table access wrong"
[ "$(q "select count(*) from pg_proc where proname like 'zella_business_email%' and prosecdef and not (proconfig @> array['search_path=\"\"'])")" = 0 ] \
  && ok "every privileged function pins an empty search path" || bad "a function without a pinned search path"

# test data only: two businesses, their people, two Zella Voice admins, a customer, a booking, a reminder and a follow up
A=b1000000-0000-4000-8000-000000000001; B=b1000000-0000-4000-8000-000000000002; S=b1000000-0000-4000-8000-000000000003
OWN=a1000000-0000-4000-8000-000000000001; ADM=a1000000-0000-4000-8000-000000000002; STF=a1000000-0000-4000-8000-000000000003
VIE=a1000000-0000-4000-8000-000000000004; MGR=a1000000-0000-4000-8000-000000000005; OWNB=a1000000-0000-4000-8000-000000000006
ZOPS=a1000000-0000-4000-8000-000000000007; ZRO=a1000000-0000-4000-8000-000000000008; ZOFF=a1000000-0000-4000-8000-000000000009; OWNS=a1000000-0000-4000-8000-00000000000a
CUS=c1000000-0000-4000-8000-000000000001; APT=d1000000-0000-4000-8000-000000000001; REM=e1000000-0000-4000-8000-000000000001; TSK=f1000000-0000-4000-8000-000000000001
out=$(q "insert into auth.users (id, email) select u::uuid, 'person' || n || '@example.test' from unnest(array['$OWN','$ADM','$STF','$VIE','$MGR','$OWNB','$ZOPS','$ZRO','$ZOFF','$OWNS']) with ordinality x(u, n);
  insert into businesses (id, name, email, timezone) values ('$A', 'Test Salon \"A\"', 'Hello@Salon-A.example.test', 'America/Los_Angeles'),
    ('$B', 'Test Clinic B', 'front@clinic-b.example.test', 'America/New_York'), ('$S', 'Paused Studio', 'hi@paused.example.test', 'America/New_York');
  update businesses set suspended_at = now() where id = '$S';
  insert into business_members (business_id, user_id, role, status) values ('$A', '$OWN', 'owner', 'active'), ('$A', '$ADM', 'admin', 'active'),
    ('$A', '$STF', 'staff', 'active'), ('$A', '$VIE', 'viewer', 'active'), ('$A', '$MGR', 'manager', 'active'), ('$B', '$OWNB', 'owner', 'active'), ('$S', '$OWNS', 'owner', 'active');
  -- the 4 Nov baseline still limits platform roles to two (production has the granular ones): its trigger is skipped here
  set session_replication_role = replica;
  insert into platform_admins (user_id, role, is_active) values ('$ZOPS', 'platform_operations', true), ('$ZRO', 'read_only_admin', true), ('$ZOFF', 'platform_operations', false);
  insert into platform_role_permissions (role, permission) values ('platform_operations', 'businesses.manage'), ('platform_operations', 'businesses.view'), ('read_only_admin', 'businesses.view');
  set session_replication_role = origin;
  insert into platform_settings (key, value) values ('email_from_address', '\"no-reply@zellavoice.example.test\"') on conflict (key) do update set value = excluded.value;
  insert into customers (id, business_id, first_name, email) values ('$CUS', '$A', 'Ana', 'ana@example.test');
  insert into appointments (id, business_id, customer_id, title, start_time, end_time) values ('$APT', '$A', '$CUS', 'Cut', now() + interval '1 day', now() + interval '1 day 1 hour');
  insert into appointment_reminders (id, business_id, appointment_id, customer_id, kind, channel, due_at, status, attempts) values ('$REM', '$A', '$APT', '$CUS', 'reminder', 'email', now(), 'sending', 1);
  insert into followup_tasks (id, business_id, customer_id, kind, channel, due_at, status, attempts) values ('$TSK', '$A', '$CUS', 'post_appointment_follow_up', 'email', now(), 'in_progress', 1);" 2>&1) \
  || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }

# who may set it up
can() { q "select public.zella_business_email_actor_can('$1', '$2')"; }
[ "$(can $A $OWN)$(can $A $ADM)$(can $A $ZOPS)" = ttt ] && ok "the owner, an admin and a Zella Voice admin with businesses.manage may set it up" || bad "allowed people refused"
[ "$(can $A $STF)$(can $A $MGR)$(can $A $VIE)$(can $A $OWNB)$(can $A $ZRO)$(can $A $ZOFF)$(can $S $OWNS)" = fffffff ] \
  && ok "staff, managers, viewers, another business's owner, an admin without businesses.manage, an inactive admin and a paused business's owner may not" \
  || bad "someone not allowed may set it up"

# the domain rules
begin() { q "select public.zella_business_email_domain_begin('$1', '$2', '$3') ->> 'reason'"; }
[ "$(begin $A $STF hello@salon-a.example.test)" = NOT_ALLOWED ] && ok "domain: staff refused" || bad "domain: staff not refused"
[ "$(begin $A $OWN 'not an address')" = BAD_ADDRESS ] && [ "$(begin $A $OWN 'a\"b@salon-a.example.test')" = BAD_ADDRESS ] && [ "$(begin $A $OWN 'x@-bad.test')" = BAD_ADDRESS ] \
  && ok "domain: an address that isn't safe for an email header is refused" || bad "domain: bad address accepted"
[ "$(begin $A $OWN salon@gmail.com)" = FREE_MAILBOX_DOMAIN ] && [ "$(begin $A $OWN salon@Outlook.com)" = FREE_MAILBOX_DOMAIN ] \
  && ok "domain: a free mailbox's domain (Gmail, Outlook) is refused: those connect the mailbox instead" || bad "domain: free mailbox accepted"
[ "$(begin $A $OWN hi@zellavoice.com)" = PLATFORM_DOMAIN ] && [ "$(begin $A $OWN hi@mail.zellavoice.com)" = PLATFORM_DOMAIN ] \
  && ok "domain: Zella Voice's own domain is refused" || bad "domain: platform domain accepted"
r=$(q "select public.zella_business_email_domain_begin('$A', '$ZOPS', ' Hello@Salon-A.example.test ')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["address"], d["domain"])')" = "True hello@salon-a.example.test salon-a.example.test" ] \
  && ok "domain: a Zella Voice admin may begin; the address is trimmed and lower cased" || bad "domain begin: $r"

RECS='[{"record":"SPF","name":"send","type":"MX","ttl":"Auto","status":"not_started","value":"feedback-smtp.us-east-1.amazonses.com","priority":10,"secret":"x"},
       {"record":"DKIM","name":"resend._domainkey","type":"TXT","ttl":"Auto","status":"not_started","value":"p=MIGfMA0GCSqGSIb3DQEB"},
       {"record":"bad","name":"x","type":"A","value":"1.2.3.4"}, "junk"]'
r=$(q "select public.zella_business_email_domain_saved('$A', '$OWN', 'hello@salon-a.example.test', 'd_abc123', '$RECS'::jsonb, 'not_started')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["domain_status"])')" = "True pending" ] \
  && [ "$(q "select route || ' ' || domain_status || ' ' || jsonb_array_length(dns_records) || ' ' || (dns_records::text like '%secret%') from business_email_senders where business_id = '$A'")" = "domain pending 2 false" ] \
  && ok "domain saved: pending, with only the MX, TXT and CNAME records and only the fields the page shows" || bad "domain saved: $r"
[ "$(begin $B $OWNB info@salon-a.example.test)" = DOMAIN_TAKEN ] && ok "domain: another business can't take a domain this business set up (cross business)" || bad "domain taken by another business"
out=$(q "insert into business_email_senders (business_id, route, address, domain) values ('$B', 'domain', 'x@salon-a.example.test', 'salon-a.example.test')" 2>&1)
echo "$out" | grep -q "business_email_senders_domain_key" && ok "the database itself keeps one business per domain" || bad "two businesses on one domain: $out"
[ "$(q "select public.zella_business_email_domain_checked('$A', '$OWN', 'd_other', 'verified', '[]') ->> 'reason'")" = NOT_SET_UP ] \
  && ok "verify: an answer about another domain is ignored" || bad "verify: wrong domain id accepted"
[ "$(q "select public.zella_business_email_domain_checked('$A', '$STF', 'd_abc123', 'verified', '[]') ->> 'reason'")" = NOT_ALLOWED ] \
  && ok "verify: staff refused" || bad "verify: staff not refused"

# who sends: the fallback, then the domain
snd() { local k=$2; [ "$k" = route ] && k=sender_route; [ "$k" = note ] && k=sender_note; q "select public.zella_business_email_sender('$1') ->> '$k'"; }
[ "$(snd $A route)|$(snd $A from)|$(snd $A from_name)|$(snd $A reply_to)|$(snd $A note)" = "fallback|no-reply@zellavoice.example.test|Test Salon  A|hello@salon-a.example.test|domain_not_verified" ] \
  && ok "sender: until verified, the fallback (business name at no reply, Reply-To the business email)" || bad "sender fallback: $(q "select public.zella_business_email_sender('$A')")"
q "select public.zella_business_email_domain_checked('$A', '$OWN', 'd_abc123', 'verified', '[]')" > /dev/null
[ "$(q "select domain_status || ' ' || (domain_verified_at is not null) || ' ' || jsonb_array_length(dns_records) from business_email_senders where business_id = '$A'")" = "verified true 2" ] \
  && ok "verify: Verified, with the time; the records stay when the answer has none" || bad "verify: not verified"
[ "$(snd $A route) $(snd $A note)" = "fallback domain_route_off" ] && ok "sender: a verified domain still uses the fallback while its switch is off (ARC-8)" || bad "domain used with switch off"
q "update platform_settings set value = '{\"domain\": true, \"mailbox\": false}' where key = 'business_email_routes'" > /dev/null
[ "$(snd $A route)|$(snd $A transport)|$(snd $A from)|$(snd $A reply_to)" = "domain|resend|hello@salon-a.example.test|hello@salon-a.example.test" ] \
  && ok "sender: switch on, the business's own address through Resend" || bad "domain route: $(q "select public.zella_business_email_sender('$A')")"
[ "$(snd $B route)" = fallback ] && ok "sender: another business is unaffected (cross business)" || bad "another business changed"
q "update businesses set email = 'not an email' where id = '$B'" > /dev/null
[ "$(q "select public.zella_business_email_sender('$B') ? 'reply_to'")" = f ] && ok "sender: no Reply-To key when the business has no valid email (prepare keeps its own)" || bad "bad reply to passed on"

# the mailbox
TOKEN="fake-refresh-token-for-tests-only"
[ "$(q "select public.zella_business_email_mailbox_saved('$A', '$STF', 'gmail', 'salon@gmail.com', '$TOKEN') ->> 'reason'")" = NOT_ALLOWED ] && ok "mailbox: staff refused" || bad "mailbox: staff not refused"
[ "$(q "select public.zella_business_email_mailbox_saved('$A', '$ZOPS', 'gmail', 'salon@gmail.com', '$TOKEN') ->> 'reason'")" = NOT_ALLOWED ] \
  && [ "$(q "select public.zella_business_email_mailbox_can_connect('$A', '$ZOPS')")$(q "select public.zella_business_email_mailbox_can_connect('$A', '$OWN')")$(q "select public.zella_business_email_mailbox_can_connect('$A', '$ADM')")$(q "select public.zella_business_email_mailbox_can_connect('$A', '$MGR')")$(q "select public.zella_business_email_mailbox_can_connect('$S', '$OWNS')")" = fttff ] \
  && ok "mailbox: only the business's own owner or admin connects it; never a Zella Voice admin (the team never holds a business's logins)" || bad "mailbox: wrong people may connect"
[ "$(q "select public.zella_business_email_mailbox_saved('$A', '$OWN', 'yahoo', 'salon@yahoo.com', '$TOKEN') ->> 'reason'")" = BAD_PROVIDER ] && ok "mailbox: only Gmail and Outlook" || bad "mailbox: other provider accepted"
[ "$(q "select public.zella_business_email_mailbox_saved('$A', '$OWN', 'gmail', null, '$TOKEN') ->> 'reason'")" = NO_ACCOUNT_EMAIL ] && ok "mailbox: refused without the account's own address" || bad "mailbox without account"
r=$(q "select public.zella_business_email_mailbox_saved('$A', '$OWN', 'gmail', 'Salon@Gmail.com', '$TOKEN')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["removed_domain_id"])')" = "True d_abc123" ] \
  && [ "$(q "select route || ' ' || mailbox_status || ' ' || mailbox_account || ' ' || mailbox_cap_key || ' ' || coalesce(domain, 'none') from business_email_senders where business_id = '$A'")" = "mailbox connected salon@gmail.com gmail none" ] \
  && ok "mailbox: connected; the domain set up before is dropped and its Resend id answered for removal" || bad "mailbox saved: $r"
[ "$(q "select count(*) from vault.secrets where name = 'zella_mail_gmail_$A' and secret = '$TOKEN'")" = 1 ] \
  && [ "$(q "select count(*) from business_email_senders where row_to_json(business_email_senders)::text like '%$TOKEN%'")" = 0 ] \
  && [ "$(q "select count(*) from audit_logs where row_to_json(audit_logs)::text like '%$TOKEN%'")" = 0 ] \
  && ok "mailbox: the token is only in Vault (not in the table, not in the audit log)" || bad "token stored outside Vault"
[ "$(snd $A route) $(snd $A note)" = "fallback mailbox_route_off" ] && ok "sender: a connected mailbox uses the fallback while its switch is off" || bad "mailbox used with switch off"
q "update platform_settings set value = '{\"domain\": true, \"mailbox\": true}' where key = 'business_email_routes'" > /dev/null
[ "$(snd $A route)|$(snd $A transport)|$(snd $A from)" = "mailbox|gmail|salon@gmail.com" ] && ok "sender: switch on, the mailbox sends from its own account" || bad "mailbox route: $(q "select public.zella_business_email_sender('$A')")"

# the daily cap, counted in the business's own day; yesterday's emails don't count
q "update platform_settings set value = '{\"gmail\": 2, \"google_workspace\": 2000, \"outlook\": 300, \"microsoft_365\": 2000}' where key = 'business_email_mailbox_caps'" > /dev/null
q "insert into email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, metadata, created_at) values
   ('$A', '$CUS', 'outbound', 'sent', 'salon@gmail.com', 'ana@example.test', 's', '{\"transport\": \"gmail\"}', now() - interval '2 days'),
   ('$A', '$CUS', 'outbound', 'sent', 'salon@gmail.com', 'ana@example.test', 's', '{\"transport\": \"gmail\"}', now())" > /dev/null
[ "$(snd $A route)" = mailbox ] && ok "cap: under the cap (one today; the one two days ago doesn't count)" || bad "cap counted yesterday"
MSG=$(q "insert into email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, metadata) values
   ('$A', '$CUS', 'outbound', 'queued', 'salon@gmail.com', 'ana@example.test', 's', '{\"transport\": \"gmail\", \"reminder_id\": \"$REM\", \"dedupe_key\": \"reminder:$REM\"}') returning id")
[ "$(snd $A route) $(snd $A note)" = "fallback mailbox_daily_cap" ] && ok "cap: at the cap (queued ones count), the rest go through the fallback" || bad "cap not applied"
q "update platform_settings set value = '{\"gmail\": 500, \"google_workspace\": 2000, \"outlook\": 300, \"microsoft_365\": 2000}' where key = 'business_email_mailbox_caps'" > /dev/null

# the token, only for one queued mailbox email of that business
cred() { q "select public.zella_business_email_mailbox_credentials('$1') ->> '$2'"; }
[ "$(cred "$MSG" ok) $(cred "$MSG" provider) $(cred "$MSG" refresh_token)" = "true gmail $TOKEN" ] && ok "credentials: handed out for a queued mailbox email from the account" || bad "credentials refused"
OTHER=$(q "insert into email_messages (business_id, direction, status, from_email, to_email, subject, metadata) values ('$B', 'outbound', 'queued', 'salon@gmail.com', 'x@example.test', 's', '{\"transport\": \"gmail\"}') returning id")
RES=$(q "insert into email_messages (business_id, direction, status, from_email, to_email, subject, metadata) values ('$A', 'outbound', 'queued', 'no-reply@zellavoice.example.test', 'x@example.test', 's', '{\"transport\": \"resend\"}') returning id")
SENT=$(q "insert into email_messages (business_id, direction, status, from_email, to_email, subject, metadata) values ('$A', 'outbound', 'sent', 'salon@gmail.com', 'x@example.test', 's', '{\"transport\": \"gmail\"}') returning id")
[ "$(cred "$OTHER" ok)$(cred "$RES" ok)$(cred "$SENT" ok)$(cred 00000000-0000-4000-8000-000000000000 ok)" = falsefalsefalsefalse ] \
  && ok "credentials: never for another business's email, a Resend email, a sent email or an unknown one" || bad "credentials handed out wrongly"

# the provider refuses: daily cap
before=$(q "select count(*) from staff_notifications where business_id = '$A' and kind = 'business_email_daily_cap'")
r=$(q "select public.zella_business_email_mailbox_refused('$MSG', 'quota')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["requeued"], d["told_business"])')" = "reminder True" ] \
  && [ "$(q "select status || ' ' || attempts || ' ' || (due_at <= now()) from appointment_reminders where id = '$REM'")" = "pending 0 true" ] \
  && [ "$(q "select status || ' ' || (metadata ->> 'error') from email_messages where id = '$MSG'")" = "failed mailbox_daily_cap" ] \
  && ok "refused (cap): the email failed with the reason; its reminder is due now with its try given back" || bad "refused (cap): $r"
[ "$(snd $A route) $(snd $A note)" = "fallback mailbox_daily_cap" ] && ok "refused (cap): the rest of the business's day uses the fallback" || bad "cap not kept for the day"
TMSG=$(q "insert into email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, metadata) values
   ('$A', '$CUS', 'outbound', 'queued', 'salon@gmail.com', 'ana@example.test', 's', '{\"transport\": \"gmail\", \"task_id\": \"$TSK\"}') returning id")
r=$(q "select public.zella_business_email_mailbox_refused('$TMSG', 'quota')")
[ "$(echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["requeued"], d["told_business"])')" = "task False" ] \
  && [ "$(q "select status || ' ' || attempts from followup_tasks where id = '$TSK'")" = "pending 0" ] \
  && [ "$(q "select count(*) from staff_notifications where business_id = '$A' and kind = 'business_email_daily_cap'")" = $((before + 1)) ] \
  && ok "refused (cap): a follow up goes back the same way; the business is told once that day, not twice" || bad "refused (cap, second): $r"
q "update business_email_senders set cap_reached_on = cap_reached_on - 1 where business_id = '$A'" > /dev/null
[ "$(snd $A route)" = mailbox ] && ok "cap: the next day, the mailbox sends again" || bad "cap not reset the next day"
[ "$(q "select body from staff_notifications where business_id = '$A' and kind = 'business_email_daily_cap' limit 1" | grep -c -- '-')" = 0 ] \
  && ok "the notification has no dashes or hyphens (BRD-6)" || bad "notification text has a dash"
out=$(q "select public.zella_business_email_mailbox_refused('$MSG', 'other')" 2>&1); echo "$out" | grep -q BAD_REASON && ok "refused: an unknown reason is refused" || bad "unknown reason: $out"
out=$(q "select public.zella_business_email_mailbox_refused('$RES', 'quota')" 2>&1); echo "$out" | grep -q NOT_FOUND && ok "refused: not for a Resend email" || bad "refused a resend email: $out"

# the provider refuses: the sign in no longer works
SMSG=$(q "insert into email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, metadata) values
   ('$A', '$CUS', 'outbound', 'queued', 'salon@gmail.com', 'ana@example.test', 's', '{\"transport\": \"gmail\"}') returning id")
q "select public.zella_business_email_mailbox_refused('$SMSG', 'sign_in')" > /dev/null
[ "$(snd $A route) $(snd $A note)" = "fallback mailbox_reconnect_needed" ] && [ "$(cred "$SMSG" ok)" = false ] \
  && [ "$(q "select count(*) from staff_notifications where business_id = '$A' and kind = 'business_email_reconnect'")" = 1 ] \
  && ok "refused (sign in): reconnect needed, the fallback until then, the business told" || bad "refused (sign in) wrong"

# the status read
st() { as "$1" "r := public.zella_business_email_status('$2') ->> '$3';"; }
[ "$(st $OWN $A route)|$(st $OWN $A active_route)|$(st $MGR $A mailbox_account)|$(st $ZRO $A route)" = "mailbox|fallback|salon@gmail.com|mailbox" ] \
  && ok "status: the owner, a manager and a Zella Voice admin with businesses.view read it" || bad "status read: $(st $OWN $A route) $(st $ZRO $A route)"
[ "$(as $OWN "r := public.zella_business_email_status('$A')::text;" | grep -c "$TOKEN\|zella_mail_")" = 0 ] && ok "status: never the token or the secret's name" || bad "status leaks the token"
[ "$(st $STF $A route)$(st $VIE $A route)$(st $OWNB $A route)$(st $ZOFF $A route)" = "ERR:NOT_ALLOWEDERR:NOT_ALLOWEDERR:NOT_ALLOWEDERR:NOT_ALLOWED" ] \
  && ok "status: staff, viewers, another business's owner and an inactive admin are refused" || bad "status: someone not allowed read it"
[ "$(as $OWNB "select count(*)::text into r from public.business_email_senders;")|$(as $OWN "select count(*)::text into r from public.business_email_senders;")|$(as $STF "select count(*)::text into r from public.business_email_senders;")" = "0|1|0" ] \
  && ok "row security: each business's owner reads only its own row; staff read none" || bad "row security wrong"
[ "$(as $OWN "update public.business_email_senders set route = null; r := 'updated';")" != updated ] && ok "row security: a signed in owner can't change the row directly" || bad "owner wrote the row"

# disconnect
r=$(q "select public.zella_business_email_disconnect('$A', '$OWN')")
[ "$(q "select count(*) from vault.secrets where name = 'zella_mail_gmail_$A'")" = 0 ] && [ "$(snd $A route) $(snd $A note)" = "fallback " ] \
  && ok "disconnect: the token is deleted from Vault; back to the fallback" || bad "disconnect: $r"
[ "$(q "select string_agg(action, ',' order by created_at, action) from audit_logs where business_id = '$A' and action like 'business_email.%'")" = "business_email.domain_started,business_email.domain_verified,business_email.mailbox_connected,business_email.disconnected" ] \
  && ok "every change is audited" || bad "audit: $(q "select string_agg(action, ',') from audit_logs where business_id = '$A'")"
[ "$(q "select public.zella_business_email_disconnect('$A', '$OWN') ->> 'changed'")" = false ] && ok "disconnect: twice is harmless" || bad "disconnect twice"

# the rollback
q "select public.zella_business_email_domain_saved('$A', '$OWN', 'hello@salon-a.example.test', 'd_abc123', '[]', 'pending')" > /dev/null
out=$(rollback); echo "$out" | grep -q SENDERS_SET_UP && [ "$(q "select to_regclass('public.business_email_senders') is not null")" = t ] \
  && ok "rollback refuses while a business has its email address set up" || bad "rollback did not refuse: $out"
q "select public.zella_business_email_disconnect('$A', '$OWN')" > /dev/null
for i in 1 2; do out=$(rollback) || { bad "rollback (run $i): $out"; }; done
[ "$(q "select count(*) from pg_proc where proname like 'zella_business_email%'")|$(q "select to_regclass('public.business_email_senders') is null and to_regclass('public.email_messages_mailbox_day_idx') is null")|$(q "select count(*) from platform_settings where key like 'business_email_%'")" = "0|t|0" ] \
  && ok "rollback (twice): the functions, the table, the index and the two settings are gone" || bad "rollback left something"
[ "$(q "select count(*) from email_messages where business_id = '$A'")" -ge 5 ] && ok "rollback deletes no email history" || bad "rollback deleted email history"
out=$(apply "$MIG") && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
