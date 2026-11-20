#!/usr/bin/env bash
# Shared by the lane F payment tests (sourced). Builds an ISOLATED copy of the production schema (never production):
# the template, then the writing cleanup and the merged migrations not applied yet, then the files a test names.
#   zf_build <db> <file>...          build from $TEMPLATE (default zprod3)
#   zf_cycle <migration> <rollback> <some owned function signature>
#                                    apply, apply again, rollback twice, apply again; on a throwaway copy, a changed
#                                    function makes both the rollback (ROLLBACK_DRIFT) and the file (VERSION_MISMATCH) refuse
set -uo pipefail
ZF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; TEMPLATE=${TEMPLATE:-zprod3}
. "$ZF_REPO/tests/lib/isolated_guard.sh"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
ZF_MERGED=(zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_retry_event_safe)
zf_build() {
  local db=$1; shift
  zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$db" || exit 1
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $db" -c "create database $db template $TEMPLATE" > /dev/null || exit 1
  local f; for f in "${ZF_MERGED[@]}" "$@"; do
    "${P[@]}" -d "$db" -f "$ZF_REPO/sql/$f.sql" > /dev/null 2>&1 || { echo "FAIL building $db: $f"; "${P[@]}" -d "$db" -f "$ZF_REPO/sql/$f.sql" 2>&1 | grep -m3 ERROR; exit 1; }
  done
  DB=$db
}
q() { "${P[@]}" -d "$DB" -c "$1"; }
qe() { "${P[@]}" -d "$DB" -c "$1" 2>&1 | sed -nE 's/^ERROR: +([A-Za-z_]+:?).*/\1/p' | head -1; }   # the error code a statement raises
fp_owned() { q "select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname ~ '$1'"; }
zf_cycle() {
  local mig=$1 rb=$2 sig=$3 pat=${4:-^zella_}
  local before; before=$(fp_owned "$pat")
  "${P[@]}" -d "$DB" -f "$ZF_REPO/sql/$mig.sql" > /dev/null 2>&1 && ok "$mig applies" || { bad "$mig applies"; "${P[@]}" -d "$DB" -f "$ZF_REPO/sql/$mig.sql" 2>&1 | grep -m3 ERROR; return; }
  local after; after=$(fp_owned "$pat")
  "${P[@]}" -d "$DB" -f "$ZF_REPO/sql/$mig.sql" > /dev/null 2>&1 && [ "$(fp_owned "$pat")" = "$after" ] && ok "$mig applies again, functions unchanged" || bad "$mig second apply"
  "${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/$rb.sql" > /dev/null 2>&1 && [ "$(fp_owned "$pat")" = "$before" ] && ok "rollback restores every function exactly" || bad "rollback: $("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/$rb.sql" 2>&1 | grep -m2 ERROR)"
  "${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/$rb.sql" > /dev/null 2>&1 && [ "$(fp_owned "$pat")" = "$before" ] && ok "rollback runs twice" || bad "second rollback"
  "${P[@]}" -d "$DB" -f "$ZF_REPO/sql/$mig.sql" > /dev/null 2>&1 && [ "$(fp_owned "$pat")" = "$after" ] && ok "applies again after the rollback, same functions" || bad "reapply"
  local copy="${DB}_drift"
  "${P[@]}" -d postgres -c "drop database if exists $copy" -c "create database $copy template $DB" > /dev/null
  "${P[@]}" -d "$copy" -c "do \$\$ begin execute replace(pg_get_functiondef('$sig'::regprocedure), 'AS \$function\$', 'AS \$function\$ '); end \$\$" > /dev/null
  local out; out=$("${P[@]}" -d "$copy" -f "$ZF_REPO/sql/rollback/$rb.sql" 2>&1)
  [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "rollback refuses a changed function (drift)" || bad "drift rollback: $(echo "$out" | grep -m1 ERROR)"
  out=$("${P[@]}" -d "$copy" -f "$ZF_REPO/sql/$mig.sql" 2>&1)
  [[ "$out" == *VERSION_MISMATCH* ]] && ok "the file refuses a version it didn't make" || bad "drift apply: $(echo "$out" | grep -m1 ERROR)"
  "${P[@]}" -d postgres -c "drop database $copy" > /dev/null
}
# a business with an active owner and a saved plan; prints the business id
zf_business() {
  q "with b as (insert into public.businesses (name) values ('$1') returning id),
     u as (insert into auth.users (id, email, aud, role, raw_app_meta_data, raw_user_meta_data) values (gen_random_uuid(), lower(replace('$1',' ','.')) || substr(md5(random()::text),1,6) || '@example.test', 'authenticated', 'authenticated', '{}', '{}') returning id),
     m as (insert into public.business_members (business_id, user_id, role, status) select b.id, u.id, 'owner', 'active' from b, u returning business_id)
     select business_id from m"
}
# a saved plan version for a business (integer cents): zf_plan <business> <price> <setup fee> [monthly|yearly] [trial true|false] [version] [overage cents]
zf_plan() {
  q "insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, setup_fee_cents, currency, minutes, texts, emails, team_seats, phone_numbers, locations, languages, trial_enabled, overage_cents_per_minute, contact_limits, estimate, acknowledged_warnings, effective_from, idempotency_key, values_hash)
     values ('$1', ${6:-1}, 'base', '${4:-monthly}', $2, $3, 'USD', 500, 200, 200, 3, 1, 1, array['en'], ${5:-false}, ${7:-20}, '{}', '{}', '[]', now() - interval '1 day', 'plan-key-${6:-1}-' || substr(md5(random()::text),1,8), md5(random()::text)) returning id"
}
# runs SQL as a signed in user: as_user <user id> <aal1|aal2> <sql>
as_user() { q "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')::text, false); $3" | tail -n +2; }
as_user_e() { "${P[@]}" -d "$DB" -c "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', '$2')::text, false); $3" 2>&1 | sed -nE 's/^ERROR: +([A-Za-z_]+:?).*/\1/p' | head -1; }
owner_of() { q "select user_id from public.business_members where business_id = '$1' and role = 'owner'"; }
# puts a business's owner onboarding on step 6 (identity done, plan accepted): zf_at_payment <business>
zf_at_payment() {
  q "insert into public.owner_onboarding (business_id, current_step, plan_accepted_version, plan_accepted_at) values ('$1', 'payment', (select max(version) from public.business_plans where business_id = '$1'), now())
       on conflict (business_id) do update set current_step = 'payment', plan_accepted_version = excluded.plan_accepted_version;
     insert into public.owner_onboarding_steps (business_id, step, reached_at, completed_at) select '$1', k, now(), now() from unnest(array['welcome','security','details','identity','plan']) k on conflict do nothing;
     insert into public.owner_onboarding_steps (business_id, step, reached_at) values ('$1', 'payment', now()) on conflict do nothing" > /dev/null
}
# records a successful send of the next outbox row with a made up Stripe answer: zf_sent <business> <stripe id> [extra response json]
zf_sent() {
  local pending id
  # this business's next pending command first: with none, nothing is claimed (an empty id would claim any business's)
  pending=$(q "select id from public.billing_outbox where business_id = '$1' and status = 'pending' order by created_at limit 1")
  [ -n "$pending" ] || { echo "none"; return; }
  id=$(q "select id from public.zella_billing_outbox_claim(1, '$pending')")
  [ -n "$id" ] || { echo "none"; return; }
  q "select public.zella_billing_outbox_result('$id', true, '$2', (select jsonb_build_object('id', '$2', 'livemode', false) || coalesce(body, '{}') - 'metadata' || '${3:-{\}}'::jsonb from public.billing_outbox where id = '$id'), null, false, false, (select attempts from public.billing_outbox where id = '$id'))"
}
# an active Stripe subscription as if Checkout had run: zf_active <business> <plan id> <price cents> <n> [period end, unix]
#   -> links cus_<n>, sub_<n>, price_<n>
zf_active() {
  local n=$4 end="now() + interval '1 day'"; [ -n "${5:-}" ] && end="to_timestamp($5)"
  q "select public.zella_stripe_link_add('cus_$n', 'customer', '$1', false); select public.zella_stripe_link_add('sub_$n', 'subscription', '$1', false, 'checkout', null, null);
     select public.zella_stripe_link_add('price_$n', 'price', '$1', false, 'plan_price', '$2', $3);
     insert into public.subscriptions (business_id, status, billing_interval, provider, external_subscription_id, current_period_start, current_period_end)
     values ('$1', 'active', 'monthly', 'stripe', 'sub_$n', now() - interval '29 days', $end);
     select public.zella_billing_open_period('$1', now())" > /dev/null
}
# stores an event and applies a fetched object: zf_apply <event id> <type> <object json>
zf_apply() {
  local oid otype id
  oid=$(echo "$3" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])"); otype=$(echo "$3" | python3 -c "import json,sys; print(json.load(sys.stdin)['object'])")
  q "select public.zella_stripe_event_store(jsonb_build_object('id', '$1', 'type', '$2', 'livemode', false, 'created', extract(epoch from now())::bigint, 'data', jsonb_build_object('object', jsonb_build_object('id', '$oid', 'object', '$otype'))), false)" > /dev/null
  id=$(q "select id from public.billing_events where external_event_id = '$1'")
  q "update public.billing_events set next_attempt_at = now() where id = '$id'" > /dev/null
  q "select public.zella_stripe_apply_event('$id', \$j\$$3\$j\$::jsonb, false)"
}
