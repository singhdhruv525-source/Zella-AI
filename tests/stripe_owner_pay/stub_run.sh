#!/usr/bin/env bash
# A function level check of sql/zella_stripe_owner_pay.sql on the isolated test server (no production schema template
# needed): minimal stand ins for the tables the functions read (only the columns they use), auth.uid() and auth.jwt()
# from the request claims as in Supabase, zella_onboarding_authorize exactly as sql/zella_owner_onboarding.sql makes it,
# and zella_owner_invoices exactly as sql/zella_stripe_invoices.sql makes it (md5 checked). Then: apply, apply again;
# who may read and start an invoice payment (another business's owner and a team member get NOT_FOUND, an uncoded
# session MFA_REQUIRED, a paid invoice ALREADY_PAID, a void one NOT_PAYABLE, payments off PAYMENTS_NOT_LIVE); a double
# start answers the same invoice and creates nothing; the list carries id, amount due and payable; the server only
# lookup; a declined pack reopened on the same PaymentIntent, once; rollback, rollback again, drift refused both ways.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zownerpay_stub}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d "$DB" -c "$1"; }
code() { "${P[@]}" -d "$DB" -f "$1" 2>&1 | sed -nE 's/^.*ERROR: +([A-Z_]+):.*/\1/p' | head -1; }
# runs SQL as a signed in user: as <user> <aal1|aal2> <sql>; err prints the error code it raised
as() { q "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')::text, false); $3" | tail -n +2; }
err() { "${P[@]}" -d "$DB" -c "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')::text, false); $3" 2>&1 | sed -nE 's/^ERROR: +([A-Z_]+).*/\1/p' | head -1; }
md5of() { q "select md5(pg_get_functiondef('$1'::regprocedure))"; }
fn_from() { local s e; s=$(grep -n "^create or replace function public.$2" "$REPO/sql/$1.sql" | cut -d: -f1); e=$(awk -v s="$s" 'NR > s && /^end \$\$;/ { print NR; exit }' "$REPO/sql/$1.sql"); sed -n "${s},${e}p" "$REPO/sql/$1.sql"; }
MIG="$REPO/sql/zella_stripe_owner_pay.sql"; RB="$REPO/sql/rollback/zella_stripe_owner_pay_rollback.sql"
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB" > /dev/null || exit 1

q "do \$\$ begin
     if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
     if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
     if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if; end \$\$;
   create schema auth; grant usage on schema auth to authenticated, anon, service_role;
   create function auth.uid() returns uuid language sql stable as \$f\$ select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid \$f\$;
   create function auth.jwt() returns jsonb language sql stable as \$f\$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb \$f\$;
   grant execute on all functions in schema auth to authenticated, anon, service_role;
   create table public.zella_function_archive (migration text, signature text, definition text, definition_md5 text, saved_at timestamptz default now(), primary key (migration, signature));
   create table public.businesses (id uuid primary key default gen_random_uuid(), name text, suspended_at timestamptz, cancelled_at timestamptz);
   create table public.business_members (business_id uuid, user_id uuid, role text, status text);
   create table public.audit_logs (id bigserial, business_id uuid, user_id uuid, action text, entity_type text, entity_id uuid, old_data jsonb, new_data jsonb);
   create table public.billing_invoices (id uuid primary key default gen_random_uuid(), business_id uuid, stripe_invoice_id text, kind text default 'renewal', status text, number text,
     currency text default 'usd', total_minor bigint, amount_due_minor bigint, amount_paid_minor bigint default 0, period_start timestamptz, period_end timestamptz,
     hosted_invoice_url text, invoice_pdf text, livemode boolean default false, stripe_created_at timestamptz, paid_at timestamptz, created_at timestamptz default now());
   create table public.pack_purchases (id uuid primary key default gen_random_uuid(), business_id uuid, pack_code text, resource text, quantity int, price_cents bigint,
     status text, source text, failure_reason text, stripe_payment_intent text, settled_at timestamptz);
   create table public.pack_catalog_stub (x int);
   create table public.billing_stripe_links (stripe_id text, business_id uuid, kind text, livemode boolean);
   create table public.subscriptions (business_id uuid, provider text, external_subscription_id text);
   create table public.settings_stub (live boolean);
   insert into public.settings_stub values (true);
   create function public.zella_payments_live() returns boolean language sql stable as \$f\$ select live from public.settings_stub \$f\$;
   create function public.zella_mfa_satisfied() returns boolean language sql stable as \$f\$ select true \$f\$;
   create function public.zella_setting(k text, d jsonb) returns jsonb language sql stable as \$f\$ select '\"https://app.example.test\"'::jsonb \$f\$;
   create function public.zella_owner_pack_buy(uuid, text, text) returns jsonb language sql as \$f\$ select null::jsonb \$f\$;
   grant select on all tables in schema public to authenticated, service_role;
   grant insert, update on public.audit_logs, public.pack_purchases to authenticated, service_role;
   grant usage on all sequences in schema public to authenticated, service_role;" > /dev/null || { bad "stand ins"; exit 1; }
fn_from zella_owner_onboarding zella_onboarding_authorize | "${P[@]}" -d "$DB" > /dev/null || { bad "authorize"; exit 1; }
fn_from zella_stripe_invoices zella_owner_invoices | "${P[@]}" -d "$DB" > /dev/null || { bad "owner invoices"; exit 1; }
[ "$(md5of 'public.zella_owner_invoices(uuid)')" = "60c0659f065c58b03dc279ffb007825c" ] && ok "zella_owner_invoices is zella_stripe_invoices.sql's version" || bad "original md5"
fn_from zella_stripe_emails zella_billing_email_invoice_trg | "${P[@]}" -d "$DB" > /dev/null || { bad "email trigger"; exit 1; }
[ "$(md5of 'public.zella_billing_email_invoice_trg()')" = "cc75a8987f19e2ae96c066395b79af45" ] && ok "zella_billing_email_invoice_trg is zella_stripe_emails.sql's version" || bad "trigger md5"

"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies: $("${P[@]}" -d "$DB" -f "$MIG" 2>&1 | grep -m2 ERROR)"; exit 1; }
made=$(md5of 'public.zella_owner_invoices(uuid)')
[ "$(md5of 'public.zella_billing_email_invoice_trg()')" = "e71bf72e22f1e906f1022c5e94f44f5e" ] && [ "$(q "select position('''invoiceId'', new.id' in pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure)) > 0")" = "t" ] \
  && ok "invoice emails now carry our invoice id (for the /pay/invoice/<id> link), one exact change" || bad "trigger change"
"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && [ "$(md5of 'public.zella_owner_invoices(uuid)')" = "$made" ] && ok "applies again, unchanged" || bad "second apply"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_billing_stripe_refs(uuid,boolean)', 'execute')::text || has_function_privilege('anon', 'public.zella_owner_invoice_pay_start(uuid)', 'execute')::text || has_function_privilege('authenticated', 'public.zella_owner_invoice_pay_start(uuid)', 'execute')::text")" = "falsefalsetrue" ] \
  && ok "the Stripe lookup is server only; the owner functions are for signed in people, never anonymous" || bad "grants"

b=$(q "insert into public.businesses (name) values ('Pay One') returning id"); b2=$(q "insert into public.businesses (name) values ('Pay Two') returning id")
u=$(q "select gen_random_uuid()"); u2=$(q "select gen_random_uuid()"); staff=$(q "select gen_random_uuid()")
q "insert into public.business_members values ('$b', '$u', 'owner', 'active'), ('$b2', '$u2', 'owner', 'active'), ('$b', '$staff', 'staff', 'active')" > /dev/null
open=$(q "insert into public.billing_invoices (business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor) values ('$b', 'in_open', 'open', 'ZV-0001', 24900, 24900) returning id")
paid=$(q "insert into public.billing_invoices (business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor, amount_paid_minor, paid_at) values ('$b', 'in_paid', 'paid', 'ZV-0002', 24900, 0, 24900, now()) returning id")
void=$(q "insert into public.billing_invoices (business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor) values ('$b', 'in_void', 'void', 'ZV-0003', 24900, 24900) returning id")
draft=$(q "insert into public.billing_invoices (business_id, stripe_invoice_id, status, total_minor, amount_due_minor) values ('$b', 'in_draft', 'draft', 100, 100) returning id")

[ "$(as "$u" aal1 "select (x ->> 'id') || ',' || (x ->> 'amount_due_minor') || ',' || (x ->> 'payable') from jsonb_array_elements(public.zella_owner_invoices('$b')) x where x ->> 'number' = 'ZV-0001'")" = "$open,24900,true" ] && ok "the list carries our id, the amount due and Pay now" || bad "list"
[ "$(as "$u" aal1 "select string_agg((x ->> 'number') || '=' || (x ->> 'payable'), ',' order by x ->> 'number') from jsonb_array_elements(public.zella_owner_invoices('$b')) x")" = "ZV-0001=true,ZV-0002=false,ZV-0003=false" ] && ok "paid and void invoices aren't payable; drafts aren't listed" || bad "payable flags"
[ "$(err "$u2" aal2 "select public.zella_owner_invoices('$b')")" = "NOT_ALLOWED" ] && ok "another business's owner can't list them" || bad "list other owner"
[ "$(as "$u" aal1 "select public.zella_owner_invoice_pay_status('$open') ->> 'status'")" = "open" ] && ok "the owner reads the invoice by its id" || bad "status read"
for who in "$u2:another business's owner" "$staff:a team member who isn't the owner"; do
  [ "$(err "${who%%:*}" aal2 "select public.zella_owner_invoice_pay_status('$open')")" = "NOT_FOUND" ] && ok "the id alone grants nothing: ${who#*:} gets NOT_FOUND" || bad "status ${who#*:}"
  [ "$(err "${who%%:*}" aal2 "select public.zella_owner_invoice_pay_start('$open')")" = "NOT_FOUND" ] && ok "and can't start paying it" || bad "start ${who#*:}"
done
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_status(gen_random_uuid())")" = "NOT_FOUND" ] && ok "a made up id answers the same NOT_FOUND" || bad "made up id"
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_status('$draft')")" = "NOT_FOUND" ] && ok "a draft isn't shown" || bad "draft"
[ "$(q "set role anon; select public.zella_owner_invoice_pay_status('$open')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "anonymous can't ask at all" || bad "anon"
[ "$(err "$u" aal1 "select public.zella_owner_invoice_pay_start('$open')")" = "MFA_REQUIRED" ] && ok "paying needs a code verified session" || bad "aal1"
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$paid')")" = "ALREADY_PAID" ] && ok "a paid invoice can't be paid again" || bad "paid"
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$void')")" = "NOT_PAYABLE" ] && ok "a void invoice can't be paid" || bad "void"
q "update public.settings_stub set live = false" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$open')")" = "PAYMENTS_NOT_LIVE" ] && ok "nothing starts while payments are off" || bad "off"
[ "$(as "$u" aal1 "select public.zella_owner_invoice_pay_status('$open') ->> 'payable'")" = "false" ] && ok "and Pay now isn't offered then" || bad "off payable"
q "update public.settings_stub set live = true" > /dev/null
r1=$(as "$u" aal2 "select public.zella_owner_invoice_pay_start('$open') ->> 'stripe_invoice_id'"); r2=$(as "$u" aal2 "select public.zella_owner_invoice_pay_start('$open') ->> 'stripe_invoice_id'")
[ "$r1" = "in_open" ] && [ "$r2" = "in_open" ] && ok "a double start answers the same invoice (its one PaymentIntent)" || bad "double start: $r1 $r2"
[ "$(as "$u" aal2 "select public.zella_owner_invoice_pay_start('$open') ->> 'amount_due_minor'")" = "24900" ] && ok "the amount is ours, from the invoice" || bad "amount"
[ "$(q "select count(*) from public.audit_logs where action = 'billing.invoice_pay_started'")" = "3" ] && ok "each start is audited; nothing else is written" || bad "audit"
q "insert into public.billing_stripe_links values ('cus_P1', '$b', 'customer', false), ('cus_P1live', '$b', 'customer', true); insert into public.subscriptions values ('$b', 'stripe', 'sub_P1')" > /dev/null
[ "$(q "set role service_role; select public.zella_billing_stripe_refs('$b', false)::text")" = '{"customer": "cus_P1", "subscription": "sub_P1"}' ] && ok "the server finds the customer in the key's mode and the subscription" || bad "refs"
[ "$(err "$u2" aal2 "select public.zella_owner_billing_access('$b', true)")" = "NOT_ALLOWED" ] && ok "card actions: another owner is refused" || bad "access other"
[ "$(as "$u" aal2 "select public.zella_owner_billing_access('$b', true) ->> 'app_base_url'")" = "https://app.example.test" ] && ok "card actions: the owner, with the address Stripe returns to" || bad "access"

pk=$(q "insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, failure_reason, stripe_payment_intent) values ('$b', 'minutes_100', 'minutes', 100, 2900, 'failed', 'owner_purchase', 'authentication_required', 'pi_P1') returning id")
auto=$(q "insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, failure_reason, stripe_payment_intent) values ('$b', 'minutes_100', 'minutes', 100, 2900, 'failed', 'auto_reload', 'card_declined', 'pi_P2') returning id")
[ "$(as "$u" aal1 "select public.zella_owner_pack_status('$b', '$pk') ->> 'can_act'")" = "true" ] && ok "a pack the bank wants confirmed can be finished by the owner" || bad "can act"
[ "$(err "$u" aal2 "select public.zella_owner_pack_status('$b', '$auto')")" = "NOT_FOUND" ] && ok "an automatic reload isn't the owner's purchase to finish" || bad "auto reload"
[ "$(err "$u2" aal2 "select public.zella_owner_pack_act_start('$b', '$pk')")" = "NOT_ALLOWED" ] && ok "another owner can't finish it" || bad "pack other owner"
a1=$(as "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$pk') ->> 'payment_intent'"); a2=$(as "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$pk') ->> 'payment_intent'")
[ "$a1" = "pi_P1" ] && [ "$a2" = "pi_P1" ] && ok "finishing reuses the same PaymentIntent, and repeating it answers the same" || bad "act: $a1 $a2"
[ "$(q "select status || ',' || coalesce(failure_reason, 'none') from public.pack_purchases where id = '$pk'")" = "pending,none" ] && ok "the purchase is pending again; nothing is granted until Stripe says succeeded" || bad "pending"
[ "$(q "select count(*) from public.audit_logs where action = 'billing.pack_owner_action'")" = "1" ] && ok "reopened once, audited once" || bad "pack audit"
q "update public.pack_purchases set status = 'granted' where id = '$pk'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$pk')")" = "ALREADY_PAID" ] && ok "a granted pack can't be paid again" || bad "granted"

"${P[@]}" -d "$DB" -f "$RB" > /dev/null 2>&1 && [ "$(md5of 'public.zella_owner_invoices(uuid)')" = "60c0659f065c58b03dc279ffb007825c" ] \
  && [ "$(q "select count(*) from pg_proc where proname in ('zella_owner_invoice_pay_status', 'zella_owner_invoice_pay_start', 'zella_owner_billing_access', 'zella_billing_stripe_refs', 'zella_owner_pack_status', 'zella_owner_pack_act_start')")" = "0" ] \
  && [ "$(md5of 'public.zella_billing_email_invoice_trg()')" = "cc75a8987f19e2ae96c066395b79af45" ] \
  && ok "rollback restores zella_owner_invoices and the email trigger exactly and drops the rest" || bad "rollback: $("${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -m1 ERROR)"
"${P[@]}" -d "$DB" -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "second rollback"
"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && [ "$(md5of 'public.zella_owner_invoices(uuid)')" = "$made" ] && ok "applies again after the rollback" || bad "reapply"
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_owner_pack_status(uuid,uuid)'::regprocedure), 'processing_error', 'processing_errors'); end \$\$" > /dev/null
[ "$(code "$RB")" = "ROLLBACK_DRIFT" ] && ok "rollback refuses a changed function" || bad "drift rollback"
[ "$(code "$MIG")" = "VERSION_MISMATCH" ] && ok "the file refuses a version it didn't make" || bad "drift apply"
"${P[@]}" -d postgres -c "drop database $DB" > /dev/null
echo; [ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
