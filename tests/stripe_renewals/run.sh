#!/usr/bin/env bash
# sql/zella_stripe_renewals.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: a renewal's paid invoice is quarantined (no grant for subscription_cycle yet). Then: apply, apply again,
# rollback twice, apply again, drift refused; a renewal with a line we didn't make, a price at another amount or lines
# that don't add up is quarantined; a bound renewal moves the period forward and opens fresh balances with the 20%
# rollover; an older period's invoice changes nothing; a failed renewal is past due with an urgent notice, and paying
# brings it back; a failure fetched after the invoice was paid changes nothing; 5 days past due pauses (calls would go
# to the fallback number) and paying restores; nothing happens while payments are off; the trial end invoice with our
# setup fee item activates a trial; signed in users can't run any of it.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_renewals zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
now=$(date +%s); p1=$((now + 86400)); p2=$((p1 + 2592000))
b=$(zf_business "Renew One"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 R1 $p1
inv() { # id status amount_paid lines_json [reason] [customer]
  echo "{\"id\":\"$1\",\"object\":\"invoice\",\"status\":\"$2\",\"currency\":\"usd\",\"amount_paid\":$3,\"amount_due\":$4,\"total\":$4,\"customer\":\"${7:-cus_R1}\",\"billing_reason\":\"${6:-subscription_cycle}\",\"livemode\":false,\"created\":$now,\"parent\":{\"subscription_details\":{\"subscription\":\"sub_R1\"}},\"lines\":{\"data\":$5,\"has_more\":false}}"; }
line() { echo "{\"amount\":$1,\"pricing\":{\"price_details\":{\"price\":\"$2\"}},\"period\":{\"start\":${3:-$p1},\"end\":${4:-$p2}}}"; }
[ "$(zf_apply evt_r0 invoice.paid "$(inv in_R0 paid 29900 29900 "[$(line 29900 price_R1)]")")" = "quarantined" ] && ok "before: a renewal can't be granted (no subscription_cycle grant)" || bad "before"
q "delete from public.billing_quarantine; update public.billing_events set status = 'ignored'" > /dev/null

zf_cycle zella_stripe_renewals zella_stripe_renewals_rollback 'public.zella_stripe_grant_subscription_cycle(jsonb,jsonb)' '^zella_(stripe_(bind_lines|grant_subscription_cycle|payment_problem|on_invoice_payment|on_customer_subscription_trial|after_invoice_item)|billing_nonpayment)'
r=$(zf_apply evt_r1 invoice.paid "$(inv in_R1 paid 39900 39900 "[$(line 29900 price_R1), {\"amount\":10000,\"invoice_item\":\"ii_unknown\"}]")"); [ "$r" = "quarantined" ] && ok "a renewal with a line we didn't make is quarantined" || bad "foreign line: $r"
r=$(zf_apply evt_r2 invoice.paid "$(inv in_R2 paid 30000 30000 "[$(line 30000 price_R1)]")"); [ "$r" = "quarantined" ] && ok "our price at another amount is quarantined" || bad "price amount: $r"
r=$(zf_apply evt_r4 invoice.paid "$(inv in_R4 paid 29900 30000 "[$(line 29900 price_R1)]")"); [ "$r" = "quarantined" ] && ok "a partly paid renewal is quarantined" || bad "partial: $r"
q "update public.allowance_buckets set used = 350 where business_id = '$b' and resource = 'minutes' and kind = 'plan'" > /dev/null
r=$(zf_apply evt_r5 invoice.paid "$(inv in_R5 paid 29900 29900 "[$(line 29900 price_R1)]")"); [ "$r" = "applied" ] && ok "a bound renewal applies" || bad "renewal: $r $(q "select error from public.billing_events where external_event_id = 'evt_r5'")"
[ "$(q "select status || ',' || (current_period_start = to_timestamp($p1)) from public.subscriptions where business_id = '$b'")" = "active,true" ] && ok "the period moves to Stripe's new one" || bad "period"
[ "$(q "select string_agg(kind || ':' || granted::int, ',' order by kind) from public.allowance_buckets k join public.billing_periods p on p.id = k.period_id where k.business_id = '$b' and k.resource = 'minutes' and p.period_start = to_timestamp($p1)")" = "plan:500,rollover:100" ] && ok "fresh 500 minutes and a 100 minute rollover (20%, 150 unused)" || bad "rollover: $(q "select string_agg(kind || ':' || granted, ',') from public.allowance_buckets where business_id = '$b'")"
r=$(zf_apply evt_r6 invoice.paid "$(inv in_R6 paid 29900 29900 "[$(line 29900 price_R1 $((now - 5000000)) $((now - 2400000)))]")")
[ "$r" = "applied" ] && [ "$(q "select count(*) from public.payments where business_id = '$b' and metadata ->> 'stripe_invoice' = 'in_R6' and status = 'succeeded'")" = "1" ] \
  && [ "$(q "select current_period_start = to_timestamp($p1) from public.subscriptions where business_id = '$b'")" = "t" ] \
  && ok "an older period's invoice is recorded (its payment) and never moves the subscription back" || bad "older: $r"
r=$(zf_apply evt_f0 invoice.payment_failed "$(inv in_F0 open 0 29900 "[$(line 29900 price_R1 $((now - 5000000)) $((now - 2400000)))]")")
[ "$r" = "applied" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "active" ] && [ "$(q "select status from public.billing_invoices where stripe_invoice_id = 'in_F0'")" = "payment_failed" ] \
  && ok "a delayed failure of an older invoice is recorded, and never makes a paid newer period past due" || bad "older failure: $r"
r=$(zf_apply evt_f1 invoice.payment_failed "$(inv in_F1 open 0 29900 "[$(line 29900 price_R1 $p2 $((p2 + 2592000)))]")"); [ "$r" = "applied" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "past_due" ] && ok "a failed renewal is past due" || bad "failed: $r"
[ "$(q "select count(*) from public.staff_notifications where business_id = '$b' and title = 'Your payment did not go through'")" -ge 1 ] && ok "with an urgent notice to the owner" || bad "notice: $(q "select string_agg(title, ',') from public.staff_notifications where business_id = '$b'")"
r=$(zf_apply evt_f2 invoice.payment_failed "$(inv in_F1 paid 29900 29900 "[$(line 29900 price_R1 $p2 $((p2 + 2592000)))]")"); [ "$r" = "older" ] && ok "a failure event fetched after the invoice was paid changes nothing" || bad "fail after paid: $r"
r=$(zf_apply evt_r5b invoice.paid "$(inv in_R5 paid 29900 29900 "[$(line 29900 price_R1)]")")
[ "$(q "select status from public.subscriptions where business_id = '$b'")" = "past_due" ] && [ "$(q "select count(*) from public.staff_notifications where business_id = '$b' and title = 'Payment received'")" = "0" ] \
  && ok "the already granted period's invoice seen again (a new event id) never clears the nonpayment" || bad "repeat paid: $r $(q "select status from public.subscriptions where business_id = '$b'")"
q "update public.subscriptions set past_due_since = now() - interval '6 days' where business_id = '$b'" > /dev/null
q "update public.platform_settings set value = 'false' where key = 'payments_live'" > /dev/null
[ "$(q "select public.zella_billing_nonpayment_sweep() ->> 'off'")" = "true" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "past_due" ] && ok "the pause waits while payments are off" || bad "sweep off"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
[ "$(q "select public.zella_billing_nonpayment_sweep() ->> 'paused'")" = "1" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "paused_nonpayment" ] && ok "5 days past due pauses the receptionist" || bad "pause"
[ "$(q "select public.zella_call_entitlement_check('$b') ->> 'status'")" = "inactive" ] && ok "a paused business is inactive at the call gate (calls go to the fallback number once enforcement is on)" || bad "gate: $(q "select public.zella_call_entitlement_check('$b')")"
[ "$(q "select public.zella_billing_nonpayment_sweep() ->> 'paused'")" = "0" ] && ok "the sweep pauses once" || bad "sweep twice"
r=$(zf_apply evt_r7 invoice.paid "$(inv in_F1 paid 29900 29900 "[$(line 29900 price_R1 $p2 $((p2 + 2592000)))]")"); [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "active" ] && ok "paying the open invoice restores service" || bad "restore: $r"
q "update public.subscriptions set past_due_since = now() - interval '31 days' where business_id = '$b'; update public.subscriptions set status = 'paused_nonpayment' where business_id = '$b'" > /dev/null
q "select public.zella_billing_nonpayment_sweep()" > /dev/null
[ "$(q "select count(*) from public.platform_alerts where kind = 'billing_unpaid_30_days'")" = "1" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "paused_nonpayment" ] && ok "30 days unpaid alerts a person; nothing is cancelled" || bad "30 days"
r=$(zf_apply evt_a1 invoice.payment_action_required "$(inv in_A1 open 0 29900 "[$(line 29900 price_R1)]")"); [ "$(q "select count(*) from public.staff_notifications where business_id = '$b' and title = 'Your bank needs you to confirm a payment'")" = "1" ] && ok "a payment waiting for the bank tells the owner to confirm it" || bad "action required: $r"
# a trial ends: plan price plus our setup fee item
t=$(zf_business "Renew Trial"); tplan=$(zf_plan "$t" 19900 10000 monthly true); zf_active "$t" "$tplan" 19900 T1
q "update public.subscriptions set status = 'trial', trial_start_at = now() - interval '5 days', trial_end_at = to_timestamp($p1), current_period_start = null, current_period_end = null where business_id = '$t'" > /dev/null
r=$(zf_apply evt_w1 customer.subscription.trial_will_end '{"id":"sub_T1","object":"subscription","status":"trialing","trial_end":'$p1',"livemode":false}')
[ "$r" = "applied" ] && [ "$(q "select count(*) from public.staff_notifications where business_id = '$t' and title = 'Your trial ends soon'")" = "1" ] \
  && ok "trial will end (still trialing): the owner is reminded" || bad "trial will end: $r"
oid=$(q "select (public.zella_billing_outbox_add('$t', 'invoice_item', 'setupfee:test', 'POST', '/v1/invoiceitems', '{\"amount\":10000,\"metadata\":{\"kind\":\"setup_fee\"}}')).id")
q "select id from public.zella_billing_outbox_claim(1, '$oid')" > /dev/null; q "select public.zella_billing_outbox_result('$oid', true, 'ii_T1', '{\"id\":\"ii_T1\",\"amount\":10000,\"livemode\":false}', null, false, false, (select attempts from public.billing_outbox where id = '$oid'))" > /dev/null
[ "$(q "select expected_amount_minor from public.billing_stripe_links where stripe_id = 'ii_T1'")" = "10000" ] && ok "our invoice item is linked with its amount" || bad "item link"
r=$(zf_apply evt_t1 invoice.paid "$(inv in_T1 paid 29900 29900 "[$(line 19900 price_T1), {\"amount\":10000,\"parent\":{\"invoice_item_details\":{\"invoice_item\":\"ii_T1\"}}}]" subscription_cycle cus_T1 | sed 's/sub_R1/sub_T1/')")
[ "$r" = "applied" ] && [ "$(q "select status from public.subscriptions where business_id = '$t'")" = "active" ] && ok "the trial end invoice (plan + setup fee) activates the plan" || bad "trial end: $r $(q "select error from public.billing_events where external_event_id = 'evt_t1'")"
out=$(q "set role authenticated; select public.zella_billing_nonpayment_sweep()" 2>&1)
[[ "$out" == *"permission denied"* ]] && ok "signed in users can't run the sweep" || bad "sweep auth"
echo "$fails failed"; [ "$fails" = 0 ]
