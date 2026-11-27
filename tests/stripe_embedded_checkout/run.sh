#!/usr/bin/env bash
# sql/zella_stripe_embedded_checkout.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Apply, apply again, rollback twice, apply again, drift refused (both ways); then, on the Pay step with payments live:
# the Checkout Session the outbox stores asks Stripe for ui_mode "custom" (Stripe's card fields in our page) with a
# return_url, carries no success_url, cancel_url or redirect_on_completion, keeps the same key (checkout:<id>) and binding metadata (business,
# checkout, plan version); Stripe's client_secret is never stored; the owner can't read the server only session lookup;
# the server can; the owner's payment status shows the open checkout without a hosted link; the rollback refuses while a
# checkout is open, and restores the hosted page body once none is.
# Needs the production schema template (TEMPLATE, default zprod3), like every lane F suite.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_embedded zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout
zf_cycle zella_stripe_embedded_checkout zella_stripe_embedded_checkout_rollback 'public.zella_billing_checkout_session(uuid,uuid)' '^zella_billing_checkout_(continue|session)$'

b=$(zf_business "Embedded One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 59900)
q "insert into public.platform_settings (key, value) values ('app_base_url', '\"https://app.example.test\"') on conflict (key) do update set value = excluded.value" > /dev/null
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
zf_at_payment "$b"
cid=$(as_user "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', 'emb-key-0001') ->> 'checkout_id'")
q "select public.zella_billing_checkout_continue('$cid', false)" > /dev/null
zf_sent "$b" cus_E1 > /dev/null; zf_sent "$b" prod_E1 > /dev/null
zf_sent "$b" price_E1 '{"unit_amount":29900}' > /dev/null; zf_sent "$b" price_E1fee '{"unit_amount":59900}' > /dev/null
body() { q "select body $1 from public.billing_outbox where kind = 'checkout_session' and business_id = '$b'"; }
[ "$(body "->> 'ui_mode'")" = "custom" ] && ok "the session asks Stripe for its card fields in our page (ui_mode custom)" || bad "ui_mode: $(body "->> 'ui_mode'")"
[ "$(body "->> 'return_url'")" = "https://app.example.test/welcome/setup?business=$b&checkout=return&session_id={CHECKOUT_SESSION_ID}" ] && ok "the return_url comes back to the Pay step" || bad "return_url: $(body "->> 'return_url'")"
[ "$(body "? 'redirect_on_completion'")" = "f" ] && ok "no redirect_on_completion (it applies to embedded sessions only, not custom)" || bad "redirect_on_completion"
[ "$(body "?| array['success_url','cancel_url']")" = "f" ] && ok "no success_url or cancel_url (Stripe refuses them with an in page session)" || bad "hosted urls left"
[ "$(q "select idempotency_key from public.billing_outbox where kind = 'checkout_session' and business_id = '$b'")" = "checkout:$cid" ] && ok "the same idempotency key as before (checkout:<id>)" || bad "key"
[ "$(body "#>> '{metadata,business_id}'"),$(body "#>> '{metadata,checkout_id}'"),$(body "->> 'client_reference_id'"),$(body "#>> '{metadata,plan_version_id}'")" = "$b,$cid,$cid,$plan" ] && ok "binding: business, checkout and plan version in metadata, checkout in client_reference_id" || bad "metadata"
[ "$(body "#>> '{line_items,0,price}'"),$(body "#>> '{line_items,1,price}'"),$(body "->> 'customer'")" = "price_E1,price_E1fee,cus_E1" ] && ok "only our prices and customer, as before" || bad "lines"
zf_sent "$b" cs_E1 "{\"url\":null,\"ui_mode\":\"custom\",\"client_secret\":\"cs_E1_secret_test_only\",\"amount_total\":89800,\"expires_at\":$(date -d '+1 day' +%s)}" > /dev/null
[ "$(q "select count(*) from public.billing_outbox where response::text like '%secret_test_only%'")" = "0" ] && ok "Stripe's client_secret is never stored" || bad "client secret stored"
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_payment_status('$b') ->> 'reason'")" = "checkout_open" ] && ok "the owner's status shows the open checkout" || bad "reason"
[ "$(as_user "$u" aal2 "select coalesce(public.zella_owner_onboarding_payment_status('$b') #>> '{checkout,url}', 'none')")" = "none" ] && ok "and no hosted page link (there is none)" || bad "url"
[ "$(as_user "$u" aal2 "select public.zella_billing_checkout_session('$b')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "the owner can't read the session lookup" || bad "owner reads session"
[ "$(q "set role service_role; select public.zella_billing_checkout_session('$b', '$cid') ->> 'stripe_session_id'")" = "cs_E1" ] && ok "the server reads the Stripe session id" || bad "server read"
[ "$(q "set role service_role; select public.zella_billing_checkout_session('$b', gen_random_uuid())" | tr -d ' ')" = "" ] && ok "another checkout id finds nothing" || bad "other id"
[ "$(qe "\\i $ZF_REPO/sql/rollback/zella_stripe_embedded_checkout_rollback.sql")" = "ROLLBACK_HAS_OPEN_CHECKOUT:" ] && ok "the rollback refuses while a checkout is open" || bad "rollback with open checkout: $(qe "\\i $ZF_REPO/sql/rollback/zella_stripe_embedded_checkout_rollback.sql")"
q "update public.billing_checkouts set status = 'expired' where id = '$cid'" > /dev/null
"${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_embedded_checkout_rollback.sql" > /dev/null 2>&1 \
  && [ "$(q "select md5(pg_get_functiondef('public.zella_billing_checkout_continue(uuid,boolean)'::regprocedure))")" = "7f998f18370021b4668ce06f057d0055" ] \
  && [ "$(q "select to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)') is null")" = "t" ] && ok "once none is open, the rollback restores the hosted page version exactly" || bad "rollback after expiry"

echo; [ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
