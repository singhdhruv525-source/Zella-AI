#!/usr/bin/env bash
# sql/zella_stripe_refunds.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: there is no refund request, and a refund made in the Stripe Dashboard only raised a generic alert. Then:
# apply, apply again, rollback twice, apply again, drift refused; the server decides eligibility (30 day guarantee on
# the plan fee only, setup fee within 48 hours, unused pack within 14 days, one guarantee per business); who may
# request (another owner, anonymous, a session without the code) and who may decide (only the Zella Voice owner, not a
# billing admin); requests can never reserve more than was captured, even at the same moment; approval re-checks and
# queues one refund keyed refund:<id>; the fetched refund is processed and posted once; a refund made outside Zella
# Voice is recorded, audited and alerted; the rollback refuses while refunds exist.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_refunds zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Refund One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 59900); zf_active "$b" "$plan" 29900 F1
b2=$(zf_business "Refund Two"); u2=$(owner_of "$b2")
q "insert into public.billing_checkouts (business_id, business_plan_id, mode, status, first_amount_minor, setup_fee_minor, idempotency_key) values ('$b', '$plan', 'pay', 'paid', 89800, 59900, 'refund-test-1')" > /dev/null
pay=$(q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at, metadata) values ('$b', 898, 89800, 'usd', 'succeeded', 'stripe', 'pi_F1', now() - interval '1 hour', '{\"bound\":true,\"billing_reason\":\"subscription_create\",\"stripe_invoice\":\"in_F1\"}') returning id")
owner=f1000000-0000-0000-0000-000000000001; badmin=f1000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email) values ('$owner', 'owner@refund.test'), ('$badmin', 'billing@refund.test'); insert into public.platform_admins (user_id, role) values ('$owner', 'zella_owner'), ('$badmin', 'billing_admin');
   insert into public.platform_role_permissions (role, permission) values ('billing_admin', 'billing.manage'), ('billing_admin', 'billing.view') on conflict do nothing" > /dev/null
[ -n "$(as_user "$u" aal2 "select public.zella_owner_refund_options('$b')" 2>&1 | grep 'does not exist')" ] && ok "before: no refund request exists" || bad "before"
zf_cycle zella_stripe_refunds zella_stripe_refunds_rollback 'public.zella_refund_options(uuid)' '^zella_(refund_|owner_refund|admin_refund|stripe_(after_refund|failed_refund|on_refund))'
opt() { as_user "$u" aal2 "select x ->> '$2' from jsonb_array_elements(public.zella_owner_refund_options('$b') -> 'options') x where x ->> 'kind' = '$1'"; }
[ "$(opt guarantee amount_minor),$(opt guarantee eligible),$(opt setup_fee amount_minor),$(opt setup_fee eligible)" = "29900,true,59900,true" ] && ok "within 48 hours: the plan fee (guarantee) and the setup fee, decided by the server" || bad "options: $(as_user "$u" aal2 "select public.zella_owner_refund_options('$b')")"
q "update public.payments set paid_at = now() - interval '3 days' where id = '$pay'" > /dev/null
[ "$(opt setup_fee eligible),$(opt setup_fee reason),$(opt guarantee eligible)" = "false,onboarding_started,true" ] && ok "after 48 hours the setup fee is not refundable; the guarantee still is" || bad "48h"
[ "$(as_user_e "$u2" aal2 "select public.zella_owner_refund_request('$b', 'guarantee', '$pay', 'refund-key-01')")" = "NOT_ALLOWED" ] && ok "another business's owner can't ask" || bad "other owner"
[ "$(as_user_e "$u" aal1 "select public.zella_owner_refund_request('$b', 'guarantee', '$pay', 'refund-key-01')")" = "MFA_REQUIRED" ] && ok "a session without the code can't ask" || bad "aal1"
[ "$(q "set role anon; select public.zella_owner_refund_request('$b', 'guarantee', '$pay', 'refund-key-01')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "anonymous can't ask" || bad "anon"
[ "$(as_user_e "$u" aal2 "select public.zella_owner_refund_request('$b', 'setup_fee', '$pay', 'refund-key-00')")" = "NOT_ELIGIBLE" ] && ok "an option the server says no to is refused" || bad "not eligible"
# two requests for the guarantee at the same moment: one reserve only
for k in 11 12; do as_user "$u" aal2 "select public.zella_owner_refund_request('$b', 'guarantee', '$pay', 'refund-key-$k')" > /dev/null 2>&1 & done; wait
[ "$(q "select count(*) || ',' || sum(amount_minor) from public.billing_refunds")" = "1,29900" ] && ok "two requests at once reserve the guarantee once" || bad "race: $(q "select count(*) from public.billing_refunds")"
rid=$(q "select id from public.billing_refunds")
[ "$(opt guarantee eligible),$(opt guarantee reason)" = "false,guarantee_used" ] && ok "one guarantee per business" || bad "once"
[ "$(as_user_e "$badmin" aal2 "select public.zella_admin_refund_decide('$rid', true, 'Customer asked')")" = "NOT_ALLOWED" ] && ok "a billing admin can't approve (REQ-BIL-45: the Zella Voice owner only)" || bad "billing admin"
[ -n "$(as_user "$badmin" aal2 "select public.zella_admin_refunds(null, 10)" | grep "$rid")" ] && ok "a billing admin can see the request" || bad "list"
[ "$(as_user_e "$owner" aal2 "select public.zella_admin_refund_decide('$rid', true, 'no')")" = "REASON_REQUIRED" ] && ok "a decision needs a reason" || bad "reason"
q "update public.payments set paid_at = now() - interval '31 days' where id = '$pay'" > /dev/null
[ "$(as_user_e "$owner" aal2 "select public.zella_admin_refund_decide('$rid', true, 'Customer asked in week one')")" = "NOT_ELIGIBLE" ] && ok "approval re-checks: after 30 days it is refused" || bad "stale approve"
q "update public.payments set paid_at = now() - interval '3 days' where id = '$pay'" > /dev/null
[ "$(as_user "$owner" aal2 "select public.zella_admin_refund_decide('$rid', true, 'Customer asked in week one') ->> 'status'")" = "sending" ] && ok "the Zella Voice owner approves: sending" || bad "approve"
[ "$(as_user "$owner" aal2 "select public.zella_admin_refund_decide('$rid', true, 'Customer asked in week one') ->> 'changed'")" = "false" ] && ok "approving twice changes nothing" || bad "approve twice"
[ "$(q "select idempotency_key || ',' || (body ->> 'amount') || ',' || (body ->> 'payment_intent') from public.billing_outbox where kind = 'refund'")" = "refund:$rid,29900,pi_F1" ] && ok "one Stripe refund queued, key refund:<id>, the reserved amount" || bad "outbox"
[ "$(q "select count(*) from public.audit_logs where action in ('billing.refund_requested', 'billing.refund_approved')")" = "2" ] && ok "request and approval audited" || bad "audit"
zf_sent "$b" re_F1 '{"amount":29900}' > /dev/null
ref() { echo "{\"id\":\"$1\",\"object\":\"refund\",\"status\":\"$2\",\"amount\":$3,\"currency\":\"usd\",\"payment_intent\":\"pi_F1\",\"livemode\":false}"; }
[ "$(zf_apply evt_rf0 refund.created "$(ref re_F1 succeeded 29000)")" = "quarantined" ] && ok "a refund of another amount than approved is quarantined" || bad "amount"
[ "$(zf_apply evt_rf1 refund.updated "$(ref re_F1 succeeded 29900)")" = "applied" ] && [ "$(q "select status from public.billing_refunds where id = '$rid'")" = "processed" ] && ok "the fetched refund is processed" || bad "processed"
zf_apply evt_rf2 refund.updated "$(ref re_F1 succeeded 29900)" > /dev/null
[ "$(q "select count(*) || ',' || sum(amount_minor) from public.money_ledger where operation_key like 'refund:%'")" = "2,0" ] && ok "posted once, balanced" || bad "ledger"
[ "$(zf_apply evt_rf3 refund.created "$(ref re_DASH succeeded 1000)")" = "applied" ] && [ "$(q "select kind || ',' || status from public.billing_refunds where stripe_refund_id = 're_DASH'")" = "outside,processed" ] \
  && [ "$(q "select count(*) from public.platform_alerts where kind = 'refund_outside_zella'")" = "1" ] && [ "$(q "select count(*) from public.audit_logs where action = 'billing.refund_outside_zella'")" = "1" ] && ok "a refund made in the Stripe Dashboard is recorded, audited and alerted (C-8)" || bad "outside"
[ "$(as_user_e "$owner" aal2 "select public.zella_admin_refund_raise('$pay', 999999, 'Charged twice by mistake')")" = "NOT_ELIGIBLE" ] && ok "an error refund can't exceed what is left on the payment" || bad "raise cap"
[ -n "$(as_user "$owner" aal2 "select public.zella_admin_refund_raise('$pay', 500, 'Charged twice by mistake')")" ] && ok "the owner can raise an error refund (REQ-BIL-43)" || bad "raise"
rid5=$(q "select id from public.billing_refunds where kind = 'error' and amount_minor = 500")
big=$(as_user "$owner" aal2 "select public.zella_admin_refund_raise('$pay', 58000, 'Charged the wrong plan')")
# a refund made in the Stripe Dashboard meanwhile: the error refund no longer fits, so approval refuses it
[ "$(zf_apply evt_rf4 refund.created "$(ref re_DASH2 succeeded 1000)")" = "applied" ] && ok "a second Dashboard refund is recorded" || bad "dash2"
[ "$(q "select status from public.payments where id = '$pay'")" = "succeeded" ] && ok "the payment's status follows what was refunded, not what is only requested" || bad "status: $(q "select status from public.payments where id = '$pay'")"
[ "$(as_user_e "$owner" aal2 "select public.zella_admin_refund_decide('$big', true, 'Charged the wrong plan')")" = "NOT_ELIGIBLE" ] && ok "approving an error refund re-checks what the payment still has free" || bad "error capacity"
# an approved request's refund event that arrives before Stripe's answer is recorded is bound to it, never an outside refund
as_user "$owner" aal2 "select public.zella_admin_refund_decide('$big', false, 'Not the wrong plan after all')" > /dev/null
as_user "$owner" aal2 "select public.zella_admin_refund_decide('$rid5', true, 'Charged twice by mistake')" > /dev/null
alerts=$(q "select count(*) from public.platform_alerts where kind = 'refund_outside_zella'")
[ "$(zf_apply evt_rf5 refund.created "{\"id\":\"re_E5\",\"object\":\"refund\",\"status\":\"succeeded\",\"amount\":500,\"currency\":\"usd\",\"payment_intent\":\"pi_F1\",\"livemode\":false,\"metadata\":{\"refund_id\":\"$rid5\"}}")" = "applied" ] \
  && [ "$(q "select status || ',' || stripe_refund_id from public.billing_refunds where id = '$rid5'")" = "processed,re_E5" ] \
  && [ "$(q "select count(*) from public.platform_alerts where kind = 'refund_outside_zella'")" = "$alerts" ] && [ "$(q "select count(*) from public.billing_refunds where stripe_refund_id = 're_E5'")" = "1" ] \
  && ok "an approved refund's event seen before its command's answer is recorded as that request (no outside refund, no alert)" || bad "early refund event: $(q "select string_agg(kind || ':' || status, ',') from public.billing_refunds where stripe_refund_id = 're_E5' or id = '$rid5'")"
# a pack can't be used while its refund is pending: the unused units are taken back at approval and given back on failure
per=$(q "select id from public.billing_periods where business_id = '$b' order by period_start desc limit 1")
pk=$(q "insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key, stripe_payment_intent)
        values ('$b', 'minutes_100', 'minutes', 100, 2900, 'granted', 'owner_purchase', 'Bought by the owner', '$per', 'pack-refund-01', 'pi_PK') returning id" | head -1)
q "insert into public.allowance_buckets (business_id, period_id, resource, kind, pack_purchase_id, granted, expires_at) select '$b', '$per', 'minutes', 'pack', '$pk', 100, period_end from public.billing_periods where id = '$per';
   insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at, metadata) values ('$b', 29, 2900, 'usd', 'succeeded', 'stripe', 'pi_PK', now(), '{\"bound\":true,\"kind\":\"pack\"}')" > /dev/null
ppay=$(q "select id from public.payments where external_payment_id = 'pi_PK'")
prid=$(as_user "$u" aal2 "select public.zella_owner_refund_request('$b', 'pack', '$ppay', 'refund-pack-01') ->> 'refund_id'")
as_user "$owner" aal2 "select public.zella_admin_refund_decide('$prid', true, 'Unused pack, within 14 days')" > /dev/null
[ "$(q "select granted::int || ',' || used::int from public.allowance_buckets where pack_purchase_id = '$pk'")" = "100,100" ] && ok "approving a pack refund holds its units at once (no use while the refund is pending)" || bad "pack revoke: $(q "select granted || ',' || used from public.allowance_buckets where pack_purchase_id = '$pk'")"
po=$(q "select id from public.billing_outbox where local_id = '$prid'"); q "select id from public.zella_billing_outbox_claim(1, '$po')" > /dev/null
q "select public.zella_billing_outbox_result('$po', false, null, '{\"type\":\"invalid_request_error\"}', 'refused', false, false, 1)" > /dev/null
[ "$(q "select status from public.billing_refunds where id = '$prid'")" = "failed" ] && [ "$(q "select granted::int || ',' || used::int from public.allowance_buckets where pack_purchase_id = '$pk'")" = "100,0" ] \
  && ok "a pack refund Stripe refuses gives the units back" || bad "pack restore: $(q "select granted from public.allowance_buckets where pack_purchase_id = '$pk'")"
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_refunds_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while refunds exist" || bad "rollback data"
echo "$fails failed"; [ "$fails" = 0 ]
