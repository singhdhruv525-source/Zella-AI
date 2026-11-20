#!/usr/bin/env bash
# sql/zella_stripe_cancel.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: scheduling a cancellation told Stripe nothing. Then: apply, apply again, rollback twice, apply again, drift
# refused; cancel, continue, cancel: versions rise, only the latest is waiting to be sent, each with its own key;
# "Continue my plan" (zella_owner_continue_plan) syncs too; an older send that landed last is resent with a new attempt
# key; a subscription event that disagrees with the latest choice, with nothing waiting, resends it; a trial is
# cancelled at once; the period end event records the cancellation; nothing is queued for a business without Stripe.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_cancel zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Cancel One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 C1
setc() { q "update public.businesses set cancel_at = $1 where id = '$b'" > /dev/null; }
setc "now() + interval '1 day'"
[ "$(q "select count(*) from public.billing_outbox")" = "0" ] && ok "before: scheduling a cancellation told Stripe nothing" || bad "before"
setc null
zf_cycle zella_stripe_cancel zella_stripe_cancel_rollback 'public.zella_stripe_cancel_sync(uuid,integer)' '^zella_stripe_(cancel|after_cancel|on_customer_subscription_updated)'
waiting() { q "select string_agg(idempotency_key || '=' || coalesce(body ->> 'cancel_at_period_end', method), ',' order by created_at) from public.billing_outbox where kind = 'cancel' and status = 'pending'"; }
setc "now() + interval '1 day'"
[ "$(waiting)" = "cancel:sub_C1:1:1=true" ] && ok "cancel: version 1, cancel at period end" || bad "cancel: $(waiting)"
q "select public.zella_owner_continue_plan('$b')" > /dev/null 2>&1 || as_user "$u" aal2 "select public.zella_owner_continue_plan('$b')" > /dev/null
[ "$(waiting)" = "cancel:sub_C1:2:1=false" ] && ok "continue (the owner's own function): version 2 replaces version 1, which is never sent" || bad "continue: $(waiting)"
setc "now() + interval '1 day'"
[ "$(waiting)" = "cancel:sub_C1:3:1=true" ] && [ "$(q "select count(*) from public.billing_outbox where kind = 'cancel' and status = 'cancelled'")" = "2" ] && ok "cancel again: only the latest choice waits" || bad "again: $(waiting)"
oid=$(q "select id from public.billing_outbox where idempotency_key = 'cancel:sub_C1:3:1'")
q "select id from public.zella_billing_outbox_claim(1, '$oid')" > /dev/null
setc null   # the owner continues while version 3 is being sent
v4=$(q "select id from public.billing_outbox where idempotency_key = 'cancel:sub_C1:4:1'")
q "select public.zella_billing_outbox_result('$oid', true, 'sub_C1', '{\"id\":\"sub_C1\",\"cancel_at_period_end\":true,\"livemode\":false}', null, false, false, (select attempts from public.billing_outbox where id = '$oid'))" > /dev/null
[ "$(waiting)" = "cancel:sub_C1:4:1=false" ] && ok "a click while a send is in flight: the newer version still goes after it" || bad "in flight: $(waiting)"
q "select id from public.zella_billing_outbox_claim(1, '$v4')" > /dev/null
q "select public.zella_billing_outbox_result('$v4', true, 'sub_C1', '{\"id\":\"sub_C1\",\"cancel_at_period_end\":true,\"livemode\":false}', null, false, false, (select attempts from public.billing_outbox where id = '$v4'))" > /dev/null
[ "$(waiting)" = "cancel:sub_C1:4:2=false" ] && ok "Stripe still says cancel (an older send landed last): the latest is resent with attempt 2" || bad "resend: $(waiting)"
q "update public.billing_outbox set status = 'sent' where kind = 'cancel' and status = 'pending'" > /dev/null
r=$(zf_apply evt_c1 customer.subscription.updated '{"id":"sub_C1","object":"subscription","status":"active","cancel_at_period_end":true,"livemode":false}')
[ "$r" = "applied" ] && [ "$(waiting)" = "cancel:sub_C1:4:3=false" ] && ok "a subscription event that disagrees with the latest choice resends it" || bad "event check: $r $(waiting)"
q "update public.billing_outbox set status = 'sent' where kind = 'cancel' and status = 'pending'" > /dev/null
r=$(zf_apply evt_c2 customer.subscription.updated '{"id":"sub_C1","object":"subscription","status":"active","cancel_at_period_end":false,"livemode":false}')
[ "$r" = "applied" ] && [ -z "$(waiting)" ] && ok "when Stripe agrees the event applies and nothing is sent" || bad "agree: $r $(waiting)"
[ "$(zf_apply evt_c3 customer.subscription.deleted '{"id":"sub_C1","object":"subscription","status":"canceled","livemode":false}')" = "applied" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "cancelled" ] && ok "the period end event records the cancellation" || bad "deleted"
t=$(zf_business "Cancel Trial"); tp=$(zf_plan "$t" 19900 0 monthly true); zf_active "$t" "$tp" 19900 CT
q "update public.subscriptions set status = 'trial' where business_id = '$t'; update public.businesses set cancel_at = now() + interval '1 day' where id = '$t'" > /dev/null
[ "$(q "select method || ' ' || idempotency_key from public.billing_outbox where business_id = '$t'")" = "DELETE cancelnow:sub_CT:1" ] && ok "a trial is cancelled at once, nothing charged" || bad "trial"
q "update public.businesses set cancel_at = null where id = '$t'; update public.businesses set cancel_at = now() + interval '1 day' where id = '$t'" > /dev/null
[ "$(q "select string_agg(method || ' ' || idempotency_key, ',') from public.billing_outbox where business_id = '$t' and status = 'pending'")" = "DELETE cancelnow:sub_CT:3" ] \
  && ok "cancel, continue, cancel again in a trial: a new DELETE for the latest choice (the old one is never reused)" || bad "trial again: $(q "select string_agg(idempotency_key || '=' || status, ',') from public.billing_outbox where business_id = '$t'")"
n=$(zf_business "No Stripe"); q "update public.businesses set cancel_at = now() + interval '1 day' where id = '$n'" > /dev/null
[ "$(q "select count(*) from public.billing_outbox where business_id = '$n'")" = "0" ] && ok "a business without a Stripe subscription queues nothing" || bad "no stripe"
echo "$fails failed"; [ "$fails" = 0 ]
