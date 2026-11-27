#!/usr/bin/env bash
# A function level check of sql/zella_stripe_owner_pay.sql on the isolated test server (no production schema template
# needed): minimal stand ins for the tables the functions read (only the columns they use), auth.uid() and auth.jwt()
# from the request claims as in Supabase, zella_onboarding_authorize exactly as sql/zella_owner_onboarding.sql makes it,
# and zella_owner_invoices exactly as sql/zella_stripe_invoices.sql makes it (md5 checked). Then: apply, apply again;
# who may read and start an invoice payment (another business's owner and a team member get NOT_FOUND, an uncoded
# session MFA_REQUIRED, a paid invoice ALREADY_PAID, a void one NOT_PAYABLE, payments off PAYMENTS_NOT_LIVE); a double
# start answers the same invoice and creates nothing; the list carries id, amount due and payable; the server only
# lookup; a declined pack reopened on the same PaymentIntent, once; Auto pay (owner only, one versioned Stripe command
# with the stored body, a double submit changes nothing, a card needed to turn it on, our record changed only by
# customer.subscription.updated, a mismatch resent); the review fixes (a reopened pack is linked and granted, a pack
# payment with no link is held, one pending owner purchase per pack, Auto pay keys and held commands, the checkout's Auto
# pay choice kept on the server, the rollback's refusals); rollback, rollback again, drift refused both ways.
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
   create table public.businesses (id uuid primary key default gen_random_uuid(), name text, suspended_at timestamptz, cancelled_at timestamptz,
     address_line_1 text, address_line_2 text, city text, state text, postal_code text, country text);
   create table public.business_members (business_id uuid, user_id uuid, role text, status text);
   create table public.audit_logs (id bigserial, business_id uuid, user_id uuid, action text, entity_type text, entity_id uuid, old_data jsonb, new_data jsonb);
   create table public.billing_invoices (id uuid primary key default gen_random_uuid(), business_id uuid, stripe_invoice_id text, kind text default 'renewal', status text, number text,
     currency text default 'usd', total_minor bigint, amount_due_minor bigint, amount_paid_minor bigint default 0, period_start timestamptz, period_end timestamptz,
     hosted_invoice_url text, invoice_pdf text, livemode boolean default false, stripe_created_at timestamptz, paid_at timestamptz, created_at timestamptz default now());
   create table public.pack_purchases (id uuid primary key default gen_random_uuid(), business_id uuid, pack_code text, resource text, quantity int, price_cents bigint,
     status text, source text, failure_reason text, stripe_payment_intent text, settled_at timestamptz, period_id uuid, reason text, idempotency_key text, created_by uuid, purchased_at timestamptz default clock_timestamp());
   create table public.billing_periods (id uuid primary key default gen_random_uuid(), period_end timestamptz);
   create table public.billing_pack_catalog (code text, resource text, quantity int, price_cents bigint, active boolean);
   create table public.allowance_buckets (business_id uuid, period_id uuid, resource text, kind text, pack_purchase_id uuid, granted int, expires_at timestamptz);
   create table public.payments (business_id uuid, subscription_id uuid, amount numeric, amount_minor bigint, currency text, status text, provider text, external_payment_id text, paid_at timestamptz, metadata jsonb);
   create unique index on public.payments (provider, external_payment_id) where external_payment_id is not null;
   create table public.billing_checkouts (id uuid primary key default gen_random_uuid(), business_id uuid, stripe_subscription_id text, created_by uuid, updated_at timestamptz);
   create function public.zella_stripe_customer(uuid) returns text language sql stable as \$f\$ select 'cus_P1' \$f\$;
   create function public.zella_minor_to_amount(bigint, text) returns numeric language sql as \$f\$ select \$1 / 100.0 \$f\$;
   create function public.zella_ledger_post(uuid, text, jsonb) returns void language sql as \$f\$ select \$f\$;
   create function public.zella_notify_owners(uuid, text, text, text, text, text) returns void language sql as \$f\$ select \$f\$;
   create table public.pack_catalog_stub (x int);
   create table public.billing_stripe_links (stripe_id text primary key, business_id uuid, kind text, livemode boolean, local_kind text, local_id uuid, expected_amount_minor bigint);
   create table public.subscriptions (id uuid primary key default gen_random_uuid(), business_id uuid unique, provider text, external_subscription_id text, status text default 'active',
     metadata jsonb not null default '{}', current_period_end timestamptz, billing_event_at timestamptz, past_due_since timestamptz, updated_at timestamptz);
   create table public.billing_outbox (id uuid primary key default gen_random_uuid(), business_id uuid, kind text, idempotency_key text unique, method text, path text, body jsonb,
     local_kind text, local_id uuid, status text not null default 'pending', response jsonb, created_at timestamptz default clock_timestamp(), updated_at timestamptz);
   create table public.billing_events (id uuid primary key default gen_random_uuid(), event_created_at timestamptz, business_id uuid, subscription_id uuid);
   create table public.billing_plan_changes (subscription_id uuid, status text, to_plan_id uuid, updated_at timestamptz);
   create table public.email_stub (business_id uuid, code text, dedupe_key text unique, data jsonb);
   create function public.zella_billing_email(b uuid, c text, o text, occ text, d jsonb) returns uuid language sql as
     \$f\$ insert into public.email_stub values (b, c, 'email:' || c || ':' || o || ':' || coalesce(occ, '1'), d) on conflict do nothing; select null::uuid \$f\$;
   create function public.zella_stripe_link(text, text) returns public.billing_stripe_links language sql stable as \$f\$ select * from public.billing_stripe_links where stripe_id = \$1 and kind = \$2 limit 1 \$f\$;
   create function public.zella_subscription_transition_ok(text, text) returns boolean language sql as \$f\$ select true \$f\$;
   create function public.zella_stripe_cancel_check(public.billing_events, jsonb) returns text language sql as \$f\$ select 'ignored' \$f\$;
   create table public.settings_stub (live boolean);
   insert into public.settings_stub values (true);
   create function public.zella_payments_live() returns boolean language sql stable as \$f\$ select live from public.settings_stub \$f\$;
   create function public.zella_mfa_satisfied() returns boolean language sql stable as \$f\$ select true \$f\$;
   create function public.zella_setting(k text, d jsonb) returns jsonb language sql stable as \$f\$ select '\"https://app.example.test\"'::jsonb \$f\$;
   grant select on all tables in schema public to authenticated, service_role;
   grant insert, update on public.audit_logs, public.pack_purchases to authenticated, service_role;
   grant usage on all sequences in schema public to authenticated, service_role;" > /dev/null || { bad "stand ins"; exit 1; }
fn_from zella_owner_onboarding zella_onboarding_authorize | "${P[@]}" -d "$DB" > /dev/null || { bad "authorize"; exit 1; }
fn_from zella_stripe_invoices zella_owner_invoices | "${P[@]}" -d "$DB" > /dev/null || { bad "owner invoices"; exit 1; }
[ "$(md5of 'public.zella_owner_invoices(uuid)')" = "60c0659f065c58b03dc279ffb007825c" ] && ok "zella_owner_invoices is zella_stripe_invoices.sql's version" || bad "original md5"
fn_from zella_stripe_emails zella_billing_email_invoice_trg | "${P[@]}" -d "$DB" > /dev/null || { bad "email trigger"; exit 1; }
fn_from zella_stripe_pipeline zella_billing_outbox_add | "${P[@]}" -d "$DB" > /dev/null || { bad "outbox add"; exit 1; }
fn_from zella_stripe_pipeline zella_stripe_link_add | "${P[@]}" -d "$DB" > /dev/null || { bad "link add"; exit 1; }
fn_from zella_stripe_packs zella_owner_pack_buy | "${P[@]}" -d "$DB" > /dev/null || { bad "pack buy"; exit 1; }
fn_from zella_stripe_packs zella_stripe_on_payment_intent_succeeded | "${P[@]}" -d "$DB" > /dev/null || { bad "pack succeeded"; exit 1; }
[ "$(md5of 'public.zella_owner_pack_buy(uuid,text,text)')|$(md5of 'public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)')" = "ce968b09b251a2192c48fefd2de0cb52|e7a39b17547fe5eefda25aa12c7fc0d2" ] \
  && ok "the pack functions are zella_stripe_packs.sql's versions" || bad "pack md5s"
# the regression, before the fix: a pack's payment that has no link is dropped ("ignored") although money was taken (B1)
q "insert into public.billing_events (event_created_at) values (now())" > /dev/null
[ "$(q "select public.zella_stripe_on_payment_intent_succeeded(e, '{\"id\": \"pi_unlinked\", \"status\": \"succeeded\", \"metadata\": {\"purchase_id\": \"00000000-0000-4000-8000-000000000001\"}}'::jsonb) from public.billing_events e limit 1")" = "ignored" ] \
  && ok "before the fix: a pack payment with no link was ignored (the review's B1)" || bad "B1 before"
fn_from zella_stripe_plan_change zella_stripe_on_customer_subscription_updated | "${P[@]}" -d "$DB" > /dev/null || { bad "subscription event"; exit 1; }
[ "$(md5of 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)')" = "c9b70ddd6dfdf324e93d3f2aa79d7ab4" ] && ok "customer.subscription.updated is zella_stripe_plan_change.sql's version" || bad "event md5"
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
q "insert into public.billing_stripe_links values ('cus_P1', '$b', 'customer', false), ('cus_P1live', '$b', 'customer', true); insert into public.subscriptions (business_id, provider, external_subscription_id) values ('$b', 'stripe', 'sub_P1')" > /dev/null
[ "$(q "set role service_role; select public.zella_billing_stripe_refs('$b', false)::text")" = '{"customer": "cus_P1", "subscription": "sub_P1"}' ] && ok "the server finds the customer in the key's mode and the subscription" || bad "refs"
q "update public.businesses set address_line_1 = ' 1 Main St ', address_line_2 = '', city = 'Austin', state = 'TX', postal_code = '78701', country = 'United States' where id = '$b'" > /dev/null
[ "$(q "set role service_role; select public.zella_billing_address_prefill('$b')::text")" = '{"city": "Austin", "line1": "1 Main St", "state": "TX", "country": "US", "postal_code": "78701"}' ] \
  && ok "the billing address prefill is the business's own address, trimmed, empty parts left out" || bad "prefill: $(q "set role service_role; select public.zella_billing_address_prefill('$b')::text")"
q "update public.businesses set city = 'Toronto', state = 'ON', postal_code = 'M5H 3T4', country = 'ca' where id = '$b'" > /dev/null
[ "$(q "set role service_role; select public.zella_billing_address_prefill('$b') ->> 'country'")" = "CA" ] && ok "any country: a two letter code passes through" || bad "prefill CA"
q "update public.businesses set country = 'Atlantis' where id = '$b'" > /dev/null
[ "$(q "set role service_role; select coalesce(public.zella_billing_address_prefill('$b') ->> 'country', 'none')")" = "none" ] && ok "a country it can't read is left out, never guessed" || bad "prefill unknown"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_billing_address_prefill(uuid)', 'execute')::text || has_function_privilege('anon', 'public.zella_billing_address_prefill(uuid)', 'execute')::text")" = "falsefalse" ] \
  && ok "the prefill is server only" || bad "prefill grant"
[ "$(err "$u2" aal2 "select public.zella_owner_billing_access('$b', true)")" = "NOT_ALLOWED" ] && ok "card actions: another owner is refused" || bad "access other"
[ "$(as "$u" aal2 "select public.zella_owner_billing_access('$b', true) ->> 'app_base_url'")" = "https://app.example.test" ] && ok "card actions: the owner, with the address Stripe returns to" || bad "access"

per=$(q "insert into public.billing_periods (period_end) values (now() + interval '20 days') returning id")
pk=$(q "insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, failure_reason, stripe_payment_intent, period_id) values ('$b', 'minutes_100', 'minutes', 100, 2900, 'failed', 'owner_purchase', 'authentication_required', 'pi_P1', '$per') returning id")
auto=$(q "insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, failure_reason, stripe_payment_intent) values ('$b', 'minutes_100', 'minutes', 100, 2900, 'failed', 'auto_reload', 'card_declined', 'pi_P2') returning id")
[ "$(as "$u" aal1 "select public.zella_owner_pack_status('$b', '$pk') ->> 'can_act'")" = "true" ] && ok "a pack the bank wants confirmed can be finished by the owner" || bad "can act"
[ "$(err "$u" aal2 "select public.zella_owner_pack_status('$b', '$auto')")" = "NOT_FOUND" ] && ok "an automatic reload isn't the owner's purchase to finish" || bad "auto reload"
[ "$(err "$u2" aal2 "select public.zella_owner_pack_act_start('$b', '$pk')")" = "NOT_ALLOWED" ] && ok "another owner can't finish it" || bad "pack other owner"
a1=$(as "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$pk') ->> 'payment_intent'")
[ "$a1" = "pi_P1" ] && [ "$(q "select status from public.pack_purchases where id = '$pk'")" = "failed" ] && ok "asking to finish only checks: the same PaymentIntent, and nothing moves before Stripe is checked (review 3)" || bad "act: $a1"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_billing_pack_reopen(uuid,uuid,text,boolean,uuid)', 'execute')::text")" = "false" ] && ok "reopening is server only" || bad "reopen grant"
r1=$(q "set role service_role; select public.zella_billing_pack_reopen('$b', '$pk', 'pi_P1', false, '$u') ->> 'payment_intent'"); r2=$(q "set role service_role; select public.zella_billing_pack_reopen('$b', '$pk', 'pi_P1', false, '$u') ->> 'payment_intent'")
[ "$r1|$r2" = "pi_P1|pi_P1" ] && [ "$(q "select status || ',' || (reopen_expires_at > now())::text from public.pack_purchases where id = '$pk'")" = "pending,true" ] \
  && [ "$(q "select local_kind || ',' || expected_amount_minor from public.billing_stripe_links where stripe_id = 'pi_P1'")" = "pack,2900" ] \
  && [ "$(q "select count(*) from public.audit_logs where action = 'billing.pack_owner_action'")" = "1" ] \
  && ok "after Stripe is checked: pending again on the same PaymentIntent, now LINKED with the price, a day to finish, audited once (B1)" || bad "reopen: $r1 $r2"
[ "$(q "set role service_role; select public.zella_billing_pack_reopen('$b', '$pk', 'pi_other', false, '$u')" 2>&1 | grep -c NOT_PAYABLE)" = "1" ] && ok "another PaymentIntent can't reopen it" || bad "reopen other pi"
ev=$(q "insert into public.billing_events (event_created_at) values (now()) returning id")
res=$(q "select public.zella_stripe_on_payment_intent_succeeded(e, jsonb_build_object('id', 'pi_P1', 'status', 'succeeded', 'amount', 2900, 'currency', 'usd', 'customer', 'cus_P1', 'metadata', jsonb_build_object('purchase_id', '$pk'))) from public.billing_events e where e.id = '$ev'")
[ "$res" = "applied" ] && [ "$(q "select status from public.pack_purchases where id = '$pk'")|$(q "select count(*) from public.allowance_buckets where pack_purchase_id = '$pk'")" = "granted|1" ] \
  && ok "declined, finished by the owner, then payment_intent.succeeded: the pack is GRANTED (B1)" || bad "B1 grant: $res"
[ "$(q "select public.zella_stripe_on_payment_intent_succeeded(e, '{\"id\": \"pi_unlinked\", \"status\": \"succeeded\", \"metadata\": {\"purchase_id\": \"00000000-0000-4000-8000-000000000001\"}}'::jsonb) from public.billing_events e limit 1" 2>&1 | grep -c 'BINDING: pack payment pi_unlinked has no link')" = "1" ] \
  && ok "after the fix: a pack payment with no link is held for a person (quarantine and an urgent alert), never ignored (B1)" || bad "B1 after"
[ "$(err "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$pk')")" = "ALREADY_PAID" ] && ok "a granted pack can't be paid again" || bad "granted"
# a reopened purchase that isn't paid expires after its day (billing-api calls this only once Stripe says it wasn't taken)
pk2=$(q "insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, failure_reason, stripe_payment_intent) values ('$b', 'minutes_100', 'minutes', 100, 2900, 'failed', 'owner_purchase', 'card_declined', 'pi_P4') returning id")
q "set role service_role; select public.zella_billing_pack_reopen('$b', '$pk2', 'pi_P4', false, '$u')" > /dev/null
[ "$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'another-key-0001') ->> 'purchase_id'")" = "$pk2" ] && [ "$(q "select count(*) from public.pack_purchases where pack_code = 'minutes_100' and status = 'pending'")" = "1" ] \
  && ok "a second tab or a retry with a new key while the pack is being paid gets THAT purchase: no second purchase, no second charge (M1, cases 3, 6)" || bad "pack pending"
q "insert into public.billing_pack_catalog values ('minutes_100', 'minutes', 100, 2900, true); insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source) values ('$b', 'minutes_500', 'minutes', 500, 9900, 'pending', 'auto_reload')" > /dev/null
q "update public.pack_purchases set status = 'failed' where id = '$pk2'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'another-key-0002')")" = "PACK_PENDING" ] && ok "an automatic reload of the same resource still being paid refuses the owner's buy (case 12)" || bad "reload pending"
q "delete from public.pack_purchases where source = 'auto_reload' and status = 'pending'; update public.pack_purchases set status = 'pending' where id = '$pk2'" > /dev/null
q "update public.pack_purchases set reopen_expires_at = now() - interval '1 minute' where id = '$pk2'" > /dev/null
[ "$(as "$u" aal1 "select public.zella_owner_pack_status('$b', '$pk2') ->> 'reopen_expired'")" = "true" ] && [ "$(q "set role service_role; select public.zella_billing_pack_reopen_expire('$pk2')")" = "expired" ] \
  && [ "$(q "select status || ',' || failure_reason from public.pack_purchases where id = '$pk2'")" = "failed,reopen_expired" ] && ok "a reopened purchase not paid within its day goes back to failed (review 3)" || bad "reopen expiry"

# ---- Auto pay ----
q "update public.subscriptions set status = 'active', current_period_end = '2026-12-20', metadata = '{}' where business_id = '$b'" > /dev/null
q "insert into public.billing_stripe_links values ('sub_P1', '$b', 'subscription', false)" > /dev/null
ev() { q "insert into public.billing_events (event_created_at) values (clock_timestamp()) returning id" | head -1; }
subevent() { local e; e=$(ev); q "select public.zella_stripe_on_customer_subscription_updated(e, '$1'::jsonb) from public.billing_events e where e.id = '$e'" > /dev/null; }
[ "$(as "$u" aal1 "select (x ->> 'on') || ',' || (x ->> 'pending') || ',' || (x ->> 'email_live') from public.zella_owner_autopay_status('$b') x")" = "true,false,false" ] && ok "Auto pay: on by default, nothing pending" || bad "autopay default"
[ "$(err "$u2" aal2 "select public.zella_owner_autopay_set('$b', false, 'key_other_owner1')")" = "NOT_ALLOWED" ] && ok "Auto pay: another business's owner is refused" || bad "autopay other owner"
[ "$(err "$staff" aal2 "select public.zella_owner_autopay_status('$b')")" = "NOT_ALLOWED" ] && ok "Auto pay: a team member who isn't the owner can't even read it" || bad "autopay staff"
[ "$(err "$u" aal1 "select public.zella_owner_autopay_set('$b', false, 'key_aal1_000001')")" = "MFA_REQUIRED" ] && ok "Auto pay: changing it needs a code verified session" || bad "autopay aal1"
r1=$(as "$u" aal2 "select (x ->> 'on') || ',' || (x ->> 'pending') from public.zella_owner_autopay_set('$b', false, 'key_off_0000001') x")
r2=$(as "$u" aal2 "select (x ->> 'on') || ',' || (x ->> 'pending') from public.zella_owner_autopay_set('$b', false, 'key_off_0000001') x")
r3=$(as "$u" aal2 "select (x ->> 'on') || ',' || (x ->> 'pending') from public.zella_owner_autopay_set('$b', false, 'key_off_0000002') x")
[ "$r1|$r2|$r3" = "true,true|true,true|true,true" ] && ok "Auto pay off: still on until Stripe's event says otherwise (pending); a double submit or the same choice again answers the same" || bad "autopay off: $r1 $r2 $r3"
[ "$(q "select count(*) || ',' || min(idempotency_key) || ',' || min(body::text) || ',' || min(path) from public.billing_outbox where kind = 'autopay'")" = '1,autopay:sub_P1:1:1,{"days_until_due": 3, "collection_method": "send_invoice"},/v1/subscriptions/sub_P1' ] \
  && ok "Auto pay off: one Stripe command, send_invoice due in 3 days, keyed by the choice's version, body stored" || bad "autopay command: $(q "select idempotency_key, body from public.billing_outbox where kind = 'autopay'")"
[ "$(q "select count(*) from public.audit_logs where action = 'billing.autopay_changed'")|$(q "select count(*) || ',' || min(data ->> 'autoPayOn') from public.email_stub where code = 'H1'")" = "1|1,false" ] \
  && ok "Auto pay off: audited once, one confirmation email queued (held while email is off)" || bad "autopay audit/email"
q "update public.billing_outbox set status = 'sent' where kind = 'autopay'" > /dev/null
subevent '{"id": "sub_P1", "status": "active", "collection_method": "send_invoice", "days_until_due": 3}'
[ "$(as "$u" aal1 "select (x ->> 'on') || ',' || (x ->> 'pending') || ',' || (x ->> 'days_until_due') from public.zella_owner_autopay_status('$b') x")" = "false,false,3" ] && ok "Auto pay off only once customer.subscription.updated says so" || bad "autopay event"
[ "$(err "$u" aal2 "select public.zella_owner_autopay_set('$b', true, 'key_off_0000001')")" = "IDEMPOTENCY_CONFLICT" ] && ok "Auto pay: the same key with the other value is refused (review m1)" || bad "key conflict"
[ "$(q "select count(*) || ',' || min(operation) from public.billing_owner_requests")" = "2,autopay" ] && ok "Auto pay keys are kept in their own table, scoped to the operation (review m1)" || bad "keys table"
[ "$(err "$u" aal2 "select public.zella_owner_autopay_set('$b', true, 'key_on_00000001')")" = "NO_SAVED_CARD" ] && ok "Auto pay on: refused without a saved card, by the database itself (review m1)" || bad "no card"
subevent '{"id": "sub_P1", "status": "active", "collection_method": "send_invoice", "days_until_due": 3, "default_payment_method": "pm_P1"}'
[ "$(as "$u" aal2 "select x ->> 'pending' from public.zella_owner_autopay_set('$b', true, 'key_on_00000002') x")" = "true" ] \
  && [ "$(q "select body::text from public.billing_outbox where idempotency_key = 'autopay:sub_P1:2:1'")" = '{"collection_method": "charge_automatically"}' ] && ok "Auto pay on with a saved card: the next version's command" || bad "autopay on"
q "update public.billing_outbox set status = 'sent' where kind = 'autopay'" > /dev/null
subevent '{"id": "sub_P1", "status": "active", "collection_method": "send_invoice", "days_until_due": 3, "default_payment_method": "pm_P1"}'
[ "$(q "select count(*) from public.billing_outbox where idempotency_key = 'autopay:sub_P1:2:2' and status = 'pending'")" = "1" ] && ok "Stripe still differs from the latest choice and nothing is waiting: sent again with the next attempt" || bad "resend"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_stripe_autopay_sync(uuid,integer)', 'execute')::text || has_function_privilege('authenticated', 'public.zella_owner_autopay_set(uuid,boolean,text)', 'execute')::text")" = "falsetrue" ] \
  && ok "Auto pay: the Stripe command is server only; the owner function is for signed in owners" || bad "autopay grants"
# a permanent refusal (held) stops the resends until a new choice (review m2)
q "update public.billing_outbox set status = 'held' where idempotency_key = 'autopay:sub_P1:2:2'" > /dev/null
subevent '{"id": "sub_P1", "status": "active", "collection_method": "send_invoice", "days_until_due": 3, "default_payment_method": "pm_P1"}'
[ "$(q "select count(*) from public.billing_outbox where kind = 'autopay' and status = 'pending'")" = "0" ] && ok "a held Auto pay command blocks further resends until the owner chooses again (review m2)" || bad "held loop"
[ "$(code "$RB")" = "ROLLBACK_AUTOPAY_OFF" ] && ok "rollback refuses while any business has Auto pay off at Stripe (review M5)" || bad "rollback autopay off"
subevent '{"id": "sub_P1", "status": "active", "collection_method": "charge_automatically", "default_payment_method": "pm_P1"}'
q "update public.billing_outbox set status = 'pending' where idempotency_key = 'autopay:sub_P1:2:2'" > /dev/null
[ "$(code "$RB")" = "ROLLBACK_HAS_PENDING" ] && ok "rollback refuses while an Auto pay command is waiting" || bad "rollback pending"
q "update public.billing_outbox set status = 'sent' where kind = 'autopay'" > /dev/null
# the Auto pay choice made in the onboarding checkout is kept on the server and applied once the subscription is linked (M2)
q "insert into public.businesses (id, name) values ('00000000-0000-4000-8000-0000000000c3', 'Pay Three'); insert into public.subscriptions (business_id, provider, external_subscription_id, status) values ('00000000-0000-4000-8000-0000000000c3', 'stripe', 'sub_P3', 'pending_payment')" > /dev/null
co=$(q "insert into public.billing_checkouts (business_id) values ('00000000-0000-4000-8000-0000000000c3') returning id")
q "set role service_role; select public.zella_billing_checkout_autopay('00000000-0000-4000-8000-0000000000c3', '$co', false)" > /dev/null
q "update public.billing_checkouts set stripe_subscription_id = 'sub_P3' where id = '$co'" > /dev/null
[ "$(q "select desired_autopay::text from public.subscriptions where business_id = '00000000-0000-4000-8000-0000000000c3'")|$(q "select body ->> 'collection_method' from public.billing_outbox where idempotency_key = 'autopay:sub_P3:1:1'")" = "false|send_invoice" ] \
  && ok "Auto pay off chosen in the checkout, the tab closed: applied on the server once Stripe's subscription is linked (M2)" || bad "checkout autopay"
q "update public.subscriptions set desired_autopay = null where business_id = '00000000-0000-4000-8000-0000000000c3'; update public.billing_outbox set status = 'sent' where kind = 'autopay'" > /dev/null

"${P[@]}" -d "$DB" -f "$RB" > /dev/null 2>&1 && [ "$(md5of 'public.zella_owner_invoices(uuid)')" = "60c0659f065c58b03dc279ffb007825c" ] \
  && [ "$(q "select count(*) from pg_proc where proname in ('zella_owner_invoice_pay_status', 'zella_owner_invoice_pay_start', 'zella_owner_billing_access', 'zella_billing_stripe_refs', 'zella_owner_pack_status', 'zella_owner_pack_act_start', 'zella_billing_address_prefill', 'zella_owner_autopay_status', 'zella_owner_autopay_set', 'zella_stripe_autopay_sync',
       'zella_stripe_autopay_next_attempt', 'zella_billing_autopay_next_command', 'zella_stripe_after_autopay', 'zella_stripe_autopay_check', 'zella_billing_pack_reopen',
       'zella_billing_pack_reopen_expire', 'zella_billing_checkout_autopay', 'zella_billing_checkout_autopay_trg')")" = "0" ] \
  && [ "$(md5of 'public.zella_owner_pack_buy(uuid,text,text)')|$(md5of 'public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)')" = "ce968b09b251a2192c48fefd2de0cb52|e7a39b17547fe5eefda25aa12c7fc0d2" ] \
  && [ "$(q "select to_regclass('public.billing_owner_requests') is null")" = "t" ] \
  && [ "$(md5of 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)')" = "c9b70ddd6dfdf324e93d3f2aa79d7ab4" ] \
  && [ "$(q "select count(*) from information_schema.columns where table_name = 'subscriptions' and column_name in ('desired_autopay', 'autopay_version')")" = "0" ] \
  && [ "$(md5of 'public.zella_billing_email_invoice_trg()')" = "cc75a8987f19e2ae96c066395b79af45" ] \
  && ok "rollback restores zella_owner_invoices and the email trigger exactly and drops the rest" || bad "rollback: $("${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -m1 ERROR)"
"${P[@]}" -d "$DB" -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "second rollback: $("${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -m1 ERROR)"
"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && [ "$(md5of 'public.zella_owner_invoices(uuid)')" = "$made" ] && ok "applies again after the rollback" || bad "reapply"
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_owner_pack_status(uuid,uuid)'::regprocedure), 'processing_error', 'processing_errors'); end \$\$" > /dev/null
[ "$(code "$RB")" = "ROLLBACK_DRIFT" ] && ok "rollback refuses a changed function" || bad "drift rollback"
[ "$(code "$MIG")" = "VERSION_MISMATCH" ] && ok "the file refuses a version it didn't make" || bad "drift apply"
"${P[@]}" -d postgres -c "drop database $DB" > /dev/null
echo; [ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
