#!/usr/bin/env bash
# sql/zella_stripe_plan_change.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: an upgrade's paid invoice (subscription_update) is quarantined. Then: apply, apply again, rollback twice,
# apply again, drift refused; only billing.manage admins start a change, with a reason; one open change per
# subscription; an expired preview can't be confirmed; an upgrade paid at another amount than the preview, or with a
# price that isn't ours, is quarantined with nothing applied; the rollback refuses while changes exist.
# The full flow through the fake Stripe is tests/stripe_plan_change/flow_test.ts.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_change zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes zella_stripe_emails zella_stripe_reconcile
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Change One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 PC
q "update public.subscriptions set metadata = metadata || '{\"stripe_item\":\"si_PC\",\"stripe_price\":\"price_PC\"}' where business_id = '$b'; select public.zella_stripe_link_add('prod_PC', 'product', '$b', false)" > /dev/null
v2=$(zf_plan "$b" 59900 0 monthly false 2)
inv() { echo "{\"id\":\"$1\",\"object\":\"invoice\",\"status\":\"paid\",\"currency\":\"usd\",\"amount_paid\":$2,\"amount_due\":$2,\"total\":$2,\"customer\":\"cus_PC\",\"billing_reason\":\"subscription_update\",\"livemode\":false,\"parent\":{\"subscription_details\":{\"subscription\":\"sub_PC\"}},\"lines\":{\"data\":[{\"amount\":$2,\"pricing\":{\"price_details\":{\"price\":\"$3\"}}}],\"has_more\":false}}"; }
[ "$(zf_apply evt_u0 invoice.paid "$(inv in_U0 1000 price_PC)")" = "quarantined" ] && ok "before: an upgrade's invoice can't be granted" || bad "before"
zf_cycle zella_stripe_plan_change zella_stripe_plan_change_rollback 'public.zella_stripe_grant_subscription_update(jsonb,jsonb)' '^zella_(admin_plan_change|plan_change_next|owner_plan_change|stripe_(after_change_price|after_preview|after_schedule|failed_upgrade|grant_subscription_update|on_customer_subscription_updated|on_customer_subscription_pending))'
admin=f5000000-0000-0000-0000-000000000001; ro=f5000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email) values ('$admin', 'owner@change.test'), ('$ro', 'ro@change.test'); insert into public.platform_admins (user_id, role) values ('$admin', 'zella_owner'), ('$ro', 'read_only_admin')" > /dev/null
[ "$(as_user_e "$ro" aal2 "select public.zella_admin_plan_change_start('$b', '$v2', 'More minutes needed')")" = "NOT_ALLOWED" ] && ok "an admin without billing.manage can't start a change" || bad "ro"
[ "$(as_user_e "$u" aal2 "select public.zella_admin_plan_change_start('$b', '$v2', 'More minutes needed')")" = "NOT_ALLOWED" ] && ok "a business owner can't start one" || bad "owner start"
[ "$(as_user_e "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v2', 'no')")" = "REASON_REQUIRED" ] && ok "a reason is required" || bad "reason"
cid=$(as_user "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v2', 'More minutes needed') ->> 'change_id'")
[ "$(q "select idempotency_key from public.billing_outbox where local_id = '$cid'")" = "price:$v2" ] && ok "the new version's Stripe Price comes first" || bad "price first"
[ "$(as_user_e "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v2', 'More minutes again')" | head -1)" != "" ] && [ "$(q "select count(*) from public.billing_plan_changes")" = "1" ] && ok "one open change per subscription" || bad "one open"
zf_sent "$b" price_PC2 '{"unit_amount":59900}' > /dev/null
[ "$(q "select (body #>> '{subscription_details,items,0,id}') || ',' || (body #>> '{subscription_details,items,0,price}') || ',' || (body #>> '{subscription_details,proration_behavior}') from public.billing_outbox where kind = 'preview'")" = "si_PC,price_PC2,always_invoice" ] && ok "then Stripe's preview for our item and the new Price" || bad "preview body"
zf_sent "$b" upcoming_PC '{"total":15000}' > /dev/null
[ "$(as_user "$u" aal2 "select public.zella_owner_plan_change('$b') ->> 'amount_today_minor'")" = "15000" ] && ok "the owner sees Stripe's amount" || bad "owner sees"
q "update public.billing_plan_changes set preview_expires_at = now() - interval '1 second'" > /dev/null
[ "$(as_user_e "$u" aal2 "select public.zella_owner_plan_change_confirm('$b', '$cid')")" = "PREVIEW_EXPIRED" ] && ok "a preview older than 15 minutes can't be confirmed" || bad "expired"
q "update public.billing_plan_changes set status = 'confirmed', preview_expires_at = now() + interval '10 minutes'" > /dev/null
[ "$(zf_apply evt_u1 invoice.paid "$(inv in_U1 14000 price_PC2)")" = "quarantined" ] && ok "paid at another amount than the preview: quarantined" || bad "amount"
[ "$(zf_apply evt_u2 invoice.paid "$(inv in_U2 15000 price_OTHER)")" = "quarantined" ] && ok "a price that isn't ours: quarantined" || bad "price"
[ "$(q "select status from public.billing_plan_changes")" = "confirmed" ] && ok "nothing applied from a quarantined invoice" || bad "applied"
credit=$(inv in_U3 15000 price_PC2 | python3 -c "import json,sys; d=json.load(sys.stdin); d['amount_paid']=10000; d['amount_due']=10000; print(json.dumps(d))")
[ "$(zf_apply evt_u3 invoice.paid "$credit")" = "applied" ] && [ "$(q "select status from public.billing_plan_changes")" = "applied" ] && ok "the previewed total with our price, part paid from Stripe credit: applied" || bad "apply: $(q "select error from public.billing_events where external_event_id = 'evt_u3'")"
# a preview past its 15 minutes no longer blocks a new change: the next start expires it
v3=$(zf_plan "$b" 79900 0 monthly false 3)
c2=$(as_user "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v3', 'Even more minutes') ->> 'change_id'")
zf_sent "$b" price_PC3 '{"unit_amount":79900}' > /dev/null; zf_sent "$b" upcoming_PC3 '{"total":5000}' > /dev/null
q "update public.billing_plan_changes set preview_expires_at = now() - interval '1 second' where id = '$c2'" > /dev/null
c3=$(as_user "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v3', 'Even more minutes, again') ->> 'change_id'")
[ -n "$c3" ] && [ "$c3" != "$c2" ] && [ "$(q "select status from public.billing_plan_changes where id = '$c2'")" = "expired" ] && ok "a stale preview is expired when the next change starts" || bad "stale preview: $c3"
# Stripe drops an unpaid pending upgrade: the confirmed change fails, the plan stays, a new change can start
q "update public.billing_plan_changes set status = 'confirmed' where id = '$c3'" > /dev/null
[ "$(zf_apply evt_pe1 customer.subscription.pending_update_expired '{"id":"sub_PC","object":"subscription","status":"active","livemode":false}')" = "applied" ] \
  && [ "$(q "select status from public.billing_plan_changes where id = '$c3'")" = "failed" ] && ok "an expired pending update fails the confirmed change" || bad "pending update expired"
[ -n "$(as_user "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v3', 'Third try for more minutes') ->> 'change_id'")" ] && ok "after that a new change can start" || bad "start after expiry"
# a downgrade already scheduled at Stripe: no other change starts (both are never applied)
q "update public.billing_plan_changes set status = 'cancelled' where status in ('preparing', 'previewed', 'confirmed');
   insert into public.billing_plan_changes (business_id, subscription_id, from_plan_id, to_plan_id, direction, status, reason)
   select '$b', id, '$v2', '$plan', 'down', 'scheduled', 'Fewer minutes' from public.subscriptions where business_id = '$b'" > /dev/null
[ "$(as_user_e "$admin" aal2 "select public.zella_admin_plan_change_start('$b', '$v3', 'Upgrade over a scheduled downgrade')")" = "DOWNGRADE_SCHEDULED" ] && ok "a change over a scheduled downgrade is refused" || bad "scheduled downgrade"
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_plan_change_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while changes exist" || bad "rollback data"
echo "$fails failed"; [ "$fails" = 0 ]
