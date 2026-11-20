#!/usr/bin/env bash
# sql/zella_stripe_checkout.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: payments are "not connected" and any succeeded payments row with a provider passes the go live gate. Then:
# apply, apply again, rollback twice, apply again, drift refused; who may start Checkout (anonymous, another
# business's owner, a team member, a session without the code, payments off, the wrong step: all refused); the amount
# comes only from the accepted plan; a double click and a second tab get the same Checkout; the outbox builds customer,
# product, prices and session in order with stored keys; a session that isn't ours, a wrong amount and a price that
# isn't ours are quarantined; the bound first payment activates the subscription with Stripe's period, grants the
# period's balances, posts a balanced ledger once, and passes the go live gate; a redelivered event grants nothing more;
# the saved card trial (rule trial_with_card) starts a trial with Stripe's dates and puts the setup fee on the first
# paid invoice; the rollback refuses while a checkout exists.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_checkout zella_stripe_pipeline zella_owner_onboarding
b=$(zf_business "Checkout One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 59900)
b2=$(zf_business "Checkout Two"); u2=$(owner_of "$b2")
staff=$(q "insert into auth.users (id, email, aud, role) values (gen_random_uuid(), 'staff' || substr(md5(random()::text),1,6) || '@example.test', 'authenticated', 'authenticated') returning id")
q "insert into public.business_members (business_id, user_id, role, status) values ('$b', '$staff', 'staff', 'active')" > /dev/null
q "insert into public.platform_settings (key, value) values ('app_base_url', '\"https://app.example.test\"') on conflict (key) do update set value = excluded.value" > /dev/null
zf_at_payment "$b"
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_payment_status('$b') ->> 'reason'")" = "payments_not_connected" ] && ok "before: payment shows not connected" || bad "before reason"
q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at) values ('$b', 1, 100, 'usd', 'succeeded', 'stripe', 'pi_unbound', now())" > /dev/null
[ -n "$(q "select public.zella_onboarding_payment_confirmed_at('$b')")" ] && ok "before: any succeeded payments row with a provider passed the go live gate (not bound to our Checkout)" || bad "before gate"
q "delete from public.payments" > /dev/null

zf_cycle zella_stripe_checkout zella_stripe_checkout_rollback 'public.zella_stripe_grant_subscription_create(jsonb,jsonb)' '^zella_(onboarding_(rules|payment)|billing_checkout|owner_billing|stripe_(after|failed|on_checkout|grant))'
q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at) values ('$b', 1, 100, 'usd', 'succeeded', 'stripe', 'pi_unbound', now())" > /dev/null
[ "$(q "select public.zella_onboarding_payment_confirmed_at('$b') is null")" = "t" ] && ok "after: an unbound payments row no longer passes the gate" || bad "unbound counts"
q "delete from public.payments" > /dev/null
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_get('$b') -> 'rules' ->> 'payments_connected'")" = "false" ] && ok "payments_connected follows the switch (off)" || bad "rules off"

key=chk-key-0001
[ "$(q "set role anon; select public.zella_owner_billing_checkout_start('$b', '$key')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "anonymous can't start Checkout" || bad "anon"
[ "$(as_user_e "$u2" aal2 "select public.zella_owner_billing_checkout_start('$b', '$key')")" = "NOT_ALLOWED" ] && ok "another business's owner is refused" || bad "other owner"
[ "$(as_user_e "$staff" aal2 "select public.zella_owner_billing_checkout_start('$b', '$key')")" = "NOT_ALLOWED" ] && ok "a team member who isn't the owner is refused" || bad "staff"
[ "$(as_user_e "$u" aal1 "select public.zella_owner_billing_checkout_start('$b', '$key')")" = "MFA_REQUIRED" ] && ok "a session without the authenticator code is refused" || bad "aal1"
[ "$(as_user_e "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', '$key')")" = "PAYMENTS_NOT_LIVE" ] && ok "nothing starts while payments are off" || bad "off"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_get('$b') -> 'rules' ->> 'payments_connected'")" = "true" ] && ok "payments_connected on with the switch" || bad "rules on"
q "update public.owner_onboarding set current_step = 'plan' where business_id = '$b'" > /dev/null
[ "$(as_user_e "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', '$key')")" = "STEP_LOCKED" ] && ok "only on the payment step" || bad "step"
q "update public.owner_onboarding set current_step = 'payment' where business_id = '$b'" > /dev/null
r=$(as_user "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', '$key')")
cid=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['checkout_id'])")
[ "$(echo "$r" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['amount_minor'], d['mode'])")" = "89800 pay" ] && ok "the amount is the accepted plan's price plus setup fee, from the database" || bad "amount: $r"
[ "$(as_user "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', '$key') ->> 'checkout_id'")" = "$cid" ] && ok "a double click gets the same Checkout" || bad "double click"
[ "$(as_user "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', 'chk-key-0002') ->> 'checkout_id'")" = "$cid" ] && ok "a second tab gets the same Checkout" || bad "two tabs"
[ "$(q "select count(*) from public.audit_logs where action = 'billing.checkout_started'")" = "1" ] && ok "the start is audited once" || bad "audit"
[ "$(as_user "$u" aal2 "select public.zella_billing_checkout_continue('$cid', false)" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "only the server queues Stripe commands" || bad "continue as owner"
q "select public.zella_billing_checkout_continue('$cid', false)" > /dev/null
[ "$(q "select idempotency_key from public.billing_outbox where business_id = '$b'")" = "customer:$b" ] && ok "first the Stripe customer, keyed by the business" || bad "customer first"
zf_sent "$b" cus_T1 > /dev/null; zf_sent "$b" prod_T1 > /dev/null
zf_sent "$b" price_T1 '{"unit_amount":29900}' > /dev/null; zf_sent "$b" price_T1fee '{"unit_amount":59900}' > /dev/null
[ "$(q "select string_agg(kind || '=' || idempotency_key, ',' order by created_at) from public.billing_outbox where business_id = '$b'")" = "customer=customer:$b,product=product:$b,price=price:$plan,price=price:$plan:setup,checkout_session=checkout:$cid" ] && ok "then product, plan price, setup fee price and the session, each with its own key" || bad "chain: $(q "select string_agg(idempotency_key, ',') from public.billing_outbox")"
[ "$(q "select body #>> '{line_items,0,price}' || ',' || (body #>> '{line_items,1,price}') || ',' || (body ->> 'customer') from public.billing_outbox where kind = 'checkout_session'")" = "price_T1,price_T1fee,cus_T1" ] && ok "the session uses only our prices and customer" || bad "session body"
zf_sent "$b" cs_T1 "{\"url\":\"https://checkout.example.test/cs_T1\",\"amount_total\":89800,\"expires_at\":$(date -d '+1 day' +%s)}" > /dev/null
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_payment_status('$b') #>> '{checkout,url}'")" = "https://checkout.example.test/cs_T1" ] && ok "the owner gets the Checkout link" || bad "url"
ev() { q "select public.zella_stripe_event_store(jsonb_build_object('id', '$1', 'type', '$2', 'livemode', false, 'created', extract(epoch from now())::bigint, 'data', jsonb_build_object('object', jsonb_build_object('id', '$3', 'object', '$4'))), false)" > /dev/null; q "select id from public.billing_events where external_event_id = '$1'"; }
app() { q "update public.billing_events set next_attempt_at = now() where id = '$1'" > /dev/null; q "select public.zella_stripe_apply_event('$1', '$2'::jsonb, false)"; }
e=$(ev evt_cs_x checkout.session.completed cs_NOT checkout.session)
[ "$(app "$e" '{"id":"cs_NOT","object":"checkout.session","livemode":false,"status":"complete","customer":"cus_T1","mode":"subscription","subscription":"sub_T1"}')" = "quarantined" ] && ok "a session we didn't create is quarantined" || bad "foreign session"
e=$(ev evt_cs_1 checkout.session.completed cs_T1 checkout.session)
[ "$(app "$e" '{"id":"cs_T1","object":"checkout.session","livemode":false,"status":"complete","customer":"cus_T1","mode":"subscription","subscription":"sub_T1"}')" = "applied" ] \
  && [ "$(q "select status || ',' || external_subscription_id from public.subscriptions where business_id = '$b'")" = "pending_payment,sub_T1" ] && ok "our completed session links the subscription; still unpaid" || bad "session completed"
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_payment_status('$b') ->> 'reason'")" = "processing" ] && ok "back from Stripe the owner sees processing, not paid" || bad "processing"
[ "$(as_user "$u" aal2 "select public.zella_owner_billing_checkout_start('$b', 'chk-key-0003') ->> 'checkout_id'")" = "$cid" ] && ok "a start while Stripe's payment is being confirmed returns that Checkout, never a second one" || bad "processing start"
for fn in "zella_onboarding_payment('$b')" "zella_onboarding_payment_confirmed_at('$b')"; do
  [ "$(as_user "$u2" aal2 "select public.$fn" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "a signed in user can't call $fn directly (another business's link or payment time)" || bad "direct $fn"
done
now=$(date +%s); later=$((now + 2592000))
inv() { echo "{\"id\":\"$1\",\"object\":\"invoice\",\"status\":\"paid\",\"currency\":\"usd\",\"amount_paid\":$2,\"amount_due\":$2,\"total\":$2,\"customer\":\"cus_T1\",\"billing_reason\":\"subscription_create\",\"livemode\":false,\"created\":$now,\"parent\":{\"subscription_details\":{\"subscription\":\"sub_T1\"}},\"payments\":{\"data\":[{\"status\":\"paid\",\"payment\":{\"payment_intent\":\"pi_$1\"}}]},\"lines\":{\"data\":[{\"amount\":29900,\"pricing\":{\"price_details\":{\"price\":\"price_T1\"}},\"period\":{\"start\":$now,\"end\":$later}},{\"amount\":$(( $2 - 29900 )),\"pricing\":{\"price_details\":{\"price\":\"$3\"}},\"period\":{\"start\":$now,\"end\":$now}}]}}"; }
e=$(ev evt_in_bad1 invoice.paid in_T1 invoice); [ "$(app "$e" "$(inv in_T1 89700 price_T1fee)")" = "quarantined" ] && ok "a first payment of another amount is quarantined" || bad "wrong amount"
e=$(ev evt_in_bad2 invoice.paid in_T2 invoice); [ "$(app "$e" "$(inv in_T2 89800 price_OTHER)")" = "quarantined" ] && ok "a line with a price that isn't ours is quarantined" || bad "foreign price"
[ "$(q "select count(*) from public.payments")$(q "select count(*) from public.allowance_buckets where business_id = '$b'")" = "00" ] && ok "nothing paid or granted so far" || bad "granted early"
e=$(ev evt_in_ok invoice.paid in_T3 invoice); [ "$(app "$e" "$(inv in_T3 89800 price_T1fee)")" = "applied" ] && ok "the bound first payment applies" || bad "first payment: $(q "select error from public.billing_events where id = '$e'")"
[ "$(q "select status || ',' || (current_period_end - current_period_start = interval '30 days') from public.subscriptions where business_id = '$b'")" = "active,true" ] && ok "the subscription is active for Stripe's period" || bad "active"
[ "$(q "select string_agg(resource || ':' || granted::int, ',' order by resource, kind) from public.allowance_buckets where business_id = '$b'")" = "emails:10,emails:200,minutes:500,texts:10,texts:200" ] && ok "the period's balances are granted from the plan" || bad "buckets: $(q "select string_agg(resource || ':' || kind || ':' || granted, ',') from public.allowance_buckets where business_id = '$b'")"
[ "$(q "select amount_minor || ',' || (metadata ->> 'bound') from public.payments where business_id = '$b'")" = "89800,true" ] && ok "one bound payment of 89800 cents" || bad "payment"
[ "$(q "select sum(amount_minor) || ',' || count(*) from public.money_ledger where business_id = '$b'")" = "0,4" ] && ok "the ledger balances: receivable, revenue, cash" || bad "ledger"
[ -n "$(q "select public.zella_onboarding_payment_confirmed_at('$b')")" ] && [ "$(q "select (x ->> 'ok') from jsonb_array_elements(public.zella_activation_checks('$b') -> 'checks') x where x ->> 'key' = 'payment'")" = "true" ] && ok "the go live gate's payment check passes" || bad "gate"
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_complete_step('$b', 'payment') ->> 'changed'")" = "true" ] && ok "the owner can finish the payment step" || bad "complete step"
e=$(ev evt_in_again invoice.paid in_T3 invoice); app "$e" "$(inv in_T3 89800 price_T1fee)" > /dev/null
[ "$(q "select count(*) from public.payments")$(q "select count(*) from public.money_ledger")$(q "select count(*) from public.allowance_buckets where business_id = '$b'")" = "145" ] && ok "a second event for the same invoice grants and posts nothing more" || bad "replay"

# a Checkout open for a plan that changed: Stripe expires the old session first; a new one only after Stripe confirms
b4=$(zf_business "Checkout Four"); u4=$(owner_of "$b4"); zf_plan "$b4" 19900 0 > /dev/null; zf_at_payment "$b4"
c4=$(as_user "$u4" aal2 "select public.zella_owner_billing_checkout_start('$b4', 'chk-four-0001') ->> 'checkout_id'")
q "select public.zella_billing_checkout_continue('$c4', false)" > /dev/null
zf_sent "$b4" cus_F4 > /dev/null; zf_sent "$b4" prod_F4 > /dev/null; zf_sent "$b4" price_F4 '{"unit_amount":19900}' > /dev/null
zf_sent "$b4" cs_F4 "{\"url\":\"https://checkout.example.test/cs_F4\",\"amount_total\":19900,\"expires_at\":$(date -d '+1 day' +%s)}" > /dev/null
zf_plan "$b4" 24900 0 monthly false 2 > /dev/null; q "update public.owner_onboarding set plan_accepted_version = 2 where business_id = '$b4'" > /dev/null
r4=$(as_user "$u4" aal2 "select public.zella_owner_billing_checkout_start('$b4', 'chk-four-0002')")
[ "$(echo "$r4" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['checkout_id'], d['status'], d['url'])")" = "$c4 expiring None" ] \
  && [ "$(q "select method || ' ' || path from public.billing_outbox where business_id = '$b4' and kind = 'checkout_expire'")" = "POST /v1/checkout/sessions/cs_F4/expire" ] \
  && ok "a changed plan with a session still payable at Stripe: Stripe expires it first, no new link yet" || bad "expiring: $r4"
zf_sent "$b4" cs_F4 '{"object":"checkout.session","status":"expired"}' > /dev/null
c4b=$(as_user "$u4" aal2 "select public.zella_owner_billing_checkout_start('$b4', 'chk-four-0003') ->> 'checkout_id'")
[ "$(q "select status from public.billing_checkouts where id = '$c4'")" = "expired" ] && [ -n "$c4b" ] && [ "$c4b" != "$c4" ] \
  && [ "$(q "select first_amount_minor from public.billing_checkouts where id = '$c4b'")" = "24900" ] && ok "once Stripe confirms the expiry, the new plan gets a new Checkout" || bad "after expiry: $c4b"
# a setup command Stripe refuses for good fails the Checkout (the owner can start again), never leaves it preparing
b5=$(zf_business "Checkout Five"); u5=$(owner_of "$b5"); zf_plan "$b5" 19900 0 > /dev/null; zf_at_payment "$b5"
c5=$(as_user "$u5" aal2 "select public.zella_owner_billing_checkout_start('$b5', 'chk-five-0001') ->> 'checkout_id'")
q "select public.zella_billing_checkout_continue('$c5', false)" > /dev/null; zf_sent "$b5" cus_F5 > /dev/null
o5=$(q "select id from public.billing_outbox where business_id = '$b5' and kind = 'product'"); q "select id from public.zella_billing_outbox_claim(1, '$o5')" > /dev/null
q "select public.zella_billing_outbox_result('$o5', false, null, '{\"type\":\"invalid_request_error\"}', 'refused', false, false, 1)" > /dev/null
[ "$(q "select status from public.billing_checkouts where id = '$c5'")" = "failed" ] && ok "a product command refused for good fails the Checkout" || bad "held product: $(q "select status from public.billing_checkouts where id = '$c5'")"
c5b=$(as_user "$u5" aal2 "select public.zella_owner_billing_checkout_start('$b5', 'chk-five-0002') ->> 'checkout_id'")
q "select public.zella_billing_checkout_continue('$c5b', false)" > /dev/null
[ "$(q "select status from public.billing_checkouts where id = '$c5b'")" = "failed" ] && ok "a new start meets the same held command: that attempt fails too (a person checks the alert), never stuck preparing" || bad "again: $(q "select status from public.billing_checkouts where id = '$c5b'")"

# the saved card trial, under the other rule value (on a copy: the rule is a constant in the file)
"${P[@]}" -d postgres -c "drop database if exists zlf_t_checkout_trial" -c "create database zlf_t_checkout_trial template $DB" > /dev/null; DB=zlf_t_checkout_trial
q "do \$\$ begin execute replace(pg_get_functiondef('public.zella_onboarding_rules()'::regprocedure), '''pay_before_live'',', '''trial_with_card'','); end \$\$" > /dev/null
t=$(zf_business "Trial One"); tu=$(owner_of "$t"); zf_plan "$t" 19900 10000 monthly true > /dev/null; zf_at_payment "$t"
r=$(as_user "$tu" aal2 "select public.zella_owner_billing_checkout_start('$t', 'trial-key-001')"); tc=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['checkout_id'])")
[ "$(q "select mode || ',' || first_amount_minor || ',' || (trial_end_at::date - now()::date) from public.billing_checkouts where id = '$tc'")" = "trial,0,5" ] && ok "trial: nothing to pay now, 5 days" || bad "trial checkout"
q "select public.zella_billing_checkout_continue('$tc', false)" > /dev/null
zf_sent "$t" cus_TR > /dev/null; zf_sent "$t" prod_TR > /dev/null; zf_sent "$t" price_TR '{"unit_amount":19900}' > /dev/null; zf_sent "$t" price_TRfee '{"unit_amount":10000}' > /dev/null
[ "$(q "select jsonb_array_length(body -> 'line_items') || ',' || (body #>> '{subscription_data,trial_end}' is not null) from public.billing_outbox where business_id = '$t' and kind = 'checkout_session'")" = "1,true" ] && ok "the trial session has the plan only and Stripe's trial end; no setup fee at the start" || bad "trial body"
zf_sent "$t" cs_TR '{"url":"https://checkout.example.test/cs_TR","amount_total":0}' > /dev/null
e=$(ev evt_tr_cs checkout.session.completed cs_TR checkout.session); app "$e" '{"id":"cs_TR","object":"checkout.session","livemode":false,"status":"complete","customer":"cus_TR","mode":"subscription","subscription":"sub_TR"}' > /dev/null
tend=$((now + 432000))
e=$(ev evt_tr_in invoice.paid in_TR invoice)
[ "$(app "$e" "{\"id\":\"in_TR\",\"object\":\"invoice\",\"status\":\"paid\",\"currency\":\"usd\",\"amount_paid\":0,\"amount_due\":0,\"total\":0,\"customer\":\"cus_TR\",\"billing_reason\":\"subscription_create\",\"livemode\":false,\"parent\":{\"subscription_details\":{\"subscription\":\"sub_TR\"}},\"lines\":{\"data\":[{\"amount\":0,\"pricing\":{\"price_details\":{\"price\":\"price_TR\"}},\"period\":{\"start\":$now,\"end\":$tend}}]}}")" = "applied" ] && ok "the \$0 trial invoice applies" || bad "trial apply: $(q "select error from public.billing_events where id = '$e'")"
[ "$(q "select status || ',' || (trial_end_at = to_timestamp($tend)) from public.subscriptions where business_id = '$t'")" = "trial,true" ] && ok "the trial uses Stripe's trial end" || bad "trial dates"
[ "$(q "select string_agg(resource || ':' || granted::int, ',' order by resource) from public.allowance_buckets where business_id = '$t'")" = "emails:5,minutes:20,texts:5" ] && ok "trial balances: 20 minutes, 5 texts, 5 emails" || bad "trial buckets"
[ "$(q "select (body ->> 'amount') || ',' || (body ->> 'subscription') from public.billing_outbox where idempotency_key = 'setupfee:$tc'")" = "10000,sub_TR" ] && ok "the setup fee is queued for the first paid invoice" || bad "setup fee item"
[ "$(q "select count(*) from public.payments where business_id = '$t'")" = "0" ] && [ -n "$(q "select public.zella_onboarding_payment_confirmed_at('$t')")" ] && ok "a trial confirms step 6 under trial_with_card, with no payment" || bad "trial confirms"
DB=zlf_t_checkout; "${P[@]}" -d postgres -c "drop database zlf_t_checkout_trial" > /dev/null
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_checkout_rollback.sql" 2>&1)
[[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while a checkout exists" || bad "rollback with data"
echo "$fails failed"; [ "$fails" = 0 ]
