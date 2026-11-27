#!/usr/bin/env bash
# A function level check of sql/zella_stripe_embedded_checkout.sql that runs on any isolated test server, even without
# the production schema template (zprod3) that run.sh needs. It builds a throwaway database with minimal stand ins for
# the tables the function reads (only the columns it uses), installs zella_billing_checkout_continue exactly as
# sql/zella_stripe_checkout.sql makes it (its md5 is checked), then: apply, apply again, the Checkout Session body,
# rollback refused while a checkout is open, rollback, rollback again, drift refused both ways.
# This proves the file's guards and the body it builds; run.sh proves it against the real schema.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zemb_stub}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d "$DB" -c "$1"; }
code() { "${P[@]}" -d "$DB" -f "$1" 2>&1 | sed -nE 's/^.*ERROR: +([A-Z_]+):.*/\1/p' | head -1; }
md5of() { q "select md5(pg_get_functiondef('$1'::regprocedure))"; }
MIG="$REPO/sql/zella_stripe_embedded_checkout.sql"; RB="$REPO/sql/rollback/zella_stripe_embedded_checkout_rollback.sql"
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB" > /dev/null || exit 1

q "do \$\$ begin if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
     if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
     if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if; end \$\$;
   create table public.zella_function_archive (migration text, signature text, definition text, definition_md5 text, saved_at timestamptz default now(), primary key (migration, signature));
   create table public.business_plans (id uuid primary key default gen_random_uuid(), business_id uuid, price_cents bigint, setup_fee_cents bigint, billing_interval text);
   create table public.billing_checkouts (id uuid primary key default gen_random_uuid(), business_id uuid, business_plan_id uuid, mode text, status text,
     first_amount_minor bigint, trial_end_at timestamptz, stripe_session_id text, expires_at timestamptz, created_at timestamptz default now());
   create table public.billing_stripe_links (stripe_id text, business_id uuid, kind text, livemode boolean, local_id uuid, local_kind text, created_at timestamptz default now());
   create table public.billing_outbox (id uuid primary key default gen_random_uuid(), business_id uuid, kind text, idempotency_key text, method text, path text, body jsonb,
     local_kind text, local_id uuid, status text default 'pending', created_at timestamptz default now());
   create function public.zella_setting(k text, d jsonb) returns jsonb language sql as \$f\$ select '\"https://app.example.test\"'::jsonb \$f\$;
   create function public.zella_billing_outbox_add(b uuid, k text, key text, m text, p text, body jsonb, lk text, lid uuid) returns public.billing_outbox
     language sql as \$f\$ insert into public.billing_outbox (business_id, kind, idempotency_key, method, path, body, local_kind, local_id) values (b, k, key, m, p, body, lk, lid) returning * \$f\$;" > /dev/null || { bad "stand ins"; exit 1; }
# zella_billing_checkout_continue exactly as sql/zella_stripe_checkout.sql makes it
start=$(grep -n "^create or replace function public.zella_billing_checkout_continue" "$REPO/sql/zella_stripe_checkout.sql" | cut -d: -f1)
end=$(awk -v s="$start" 'NR > s && /^end \$\$;/ { print NR; exit }' "$REPO/sql/zella_stripe_checkout.sql")
sed -n "${start},${end}p" "$REPO/sql/zella_stripe_checkout.sql" | "${P[@]}" -d "$DB" > /dev/null || { bad "install the original"; exit 1; }
[ "$(md5of 'public.zella_billing_checkout_continue(uuid,boolean)')" = "7f998f18370021b4668ce06f057d0055" ] && ok "the original function is zella_stripe_checkout.sql's version" || bad "original md5"

"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies: $("${P[@]}" -d "$DB" -f "$MIG" 2>&1 | grep -m2 ERROR)"; exit 1; }
made=$(md5of 'public.zella_billing_checkout_continue(uuid,boolean)')
"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && [ "$(md5of 'public.zella_billing_checkout_continue(uuid,boolean)')" = "$made" ] && ok "applies again, unchanged" || bad "second apply"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_billing_checkout_session(uuid,uuid)', 'execute')::text || has_function_privilege('anon', 'public.zella_billing_checkout_continue(uuid,boolean)', 'execute')::text || has_function_privilege('service_role', 'public.zella_billing_checkout_session(uuid,uuid)', 'execute')::text")" = "falsefalsetrue" ] && ok "server only" || bad "grants"

b=$(q "select gen_random_uuid()"); plan=$(q "insert into public.business_plans (business_id, price_cents, setup_fee_cents, billing_interval) values ('$b', 29900, 59900, 'monthly') returning id")
q "insert into public.billing_stripe_links (stripe_id, business_id, kind, livemode) values ('cus_S1', '$b', 'customer', false), ('prod_S1', '$b', 'product', false);
   insert into public.billing_stripe_links (stripe_id, kind, livemode, local_id, local_kind) values ('price_S1', 'price', false, '$plan', 'plan_price'), ('price_S1fee', 'price', false, '$plan', 'setup_fee_price')" > /dev/null
cid=$(q "insert into public.billing_checkouts (business_id, business_plan_id, mode, status, first_amount_minor) values ('$b', '$plan', 'pay', 'preparing', 89800) returning id")
q "select public.zella_billing_checkout_continue('$cid', false)" > /dev/null
body() { q "select body $1 from public.billing_outbox where kind = 'checkout_session'"; }
[ "$(body "->> 'ui_mode'")|$(body "? 'redirect_on_completion'")" = "custom|f" ] && ok "ui_mode custom (Stripe's card fields in our page), no redirect_on_completion (embedded only)" || bad "ui_mode"
[ "$(body "->> 'return_url'")" = "https://app.example.test/welcome/setup?business=$b&checkout=return&session_id={CHECKOUT_SESSION_ID}" ] && ok "return_url to the Pay step" || bad "return_url"
[ "$(body "?| array['success_url','cancel_url']")" = "f" ] && ok "no success_url or cancel_url" || bad "hosted urls"
[ "$(q "select idempotency_key from public.billing_outbox where kind = 'checkout_session'")" = "checkout:$cid" ] && ok "key checkout:<id>, unchanged" || bad "key"
[ "$(body "#>> '{metadata,plan_version_id}'"),$(body "->> 'client_reference_id'"),$(body "#>> '{metadata,business_id}'")" = "$plan,$cid,$b" ] && ok "binding metadata: plan version, checkout, business" || bad "metadata"
[ "$(body "#>> '{line_items,0,price}'"),$(body "#>> '{line_items,1,price}'"),$(body "->> 'mode'"),$(body "->> 'payment_method_collection'")" = "price_S1,price_S1fee,subscription,always" ] && ok "same prices, mode and card collection as before" || bad "lines"
q "update public.billing_checkouts set status = 'open', stripe_session_id = 'cs_S1' where id = '$cid'" > /dev/null
[ "$(q "select public.zella_billing_checkout_session('$b') ->> 'stripe_session_id'")" = "cs_S1" ] && ok "the session lookup finds the business's checkout" || bad "lookup"
[ "$(code "$RB")" = "ROLLBACK_HAS_OPEN_CHECKOUT" ] && ok "rollback refuses while a checkout is open" || bad "rollback open: $(code "$RB")"
q "update public.billing_checkouts set status = 'expired' where id = '$cid'" > /dev/null
"${P[@]}" -d "$DB" -f "$RB" > /dev/null 2>&1 && [ "$(md5of 'public.zella_billing_checkout_continue(uuid,boolean)')" = "7f998f18370021b4668ce06f057d0055" ] \
  && [ "$(q "select to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)') is null")" = "t" ] && ok "rollback restores the original exactly and drops the lookup" || bad "rollback"
"${P[@]}" -d "$DB" -f "$RB" > /dev/null 2>&1 && [ "$(md5of 'public.zella_billing_checkout_continue(uuid,boolean)')" = "7f998f18370021b4668ce06f057d0055" ] && ok "rollback runs twice" || bad "second rollback"
"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1 && [ "$(md5of 'public.zella_billing_checkout_continue(uuid,boolean)')" = "$made" ] && ok "applies again after the rollback" || bad "reapply"
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_billing_checkout_session(uuid,uuid)'::regprocedure), 'limit 1', 'limit 2'); end \$\$" > /dev/null
[ "$(code "$RB")" = "ROLLBACK_DRIFT" ] && ok "rollback refuses a changed function" || bad "drift rollback"
[ "$(code "$MIG")" = "VERSION_MISMATCH" ] && ok "the file refuses a version it didn't make" || bad "drift apply"
"${P[@]}" -d postgres -c "drop database $DB" > /dev/null
echo; [ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
