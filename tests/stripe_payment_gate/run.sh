#!/usr/bin/env bash
# sql/zella_stripe_payment_gate.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Owner decision (16 Nov 2026): the first payment is required only once payments are live.
# Before: with payments off, the go live gate still waits for a payment and the owner is stuck on step 6. Then: apply,
# apply again, rollback twice, apply again, drift refused. Payments off: the rule says not until payments are live,
# step 6 shows waiting (payments not connected, not required, never "confirmed"), the owner can pass it, and the go
# live gate's payment check passes. Payments on: the rule is pay before going live, the check fails and step 6 refuses
# until a bound Stripe payment exists, then both pass. An unbound payments row never counts.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_gate zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes zella_stripe_emails zella_stripe_reconcile zella_stripe_plan_change
b=$(zf_business "Gate One"); u=$(owner_of "$b"); zf_plan "$b" 29900 0 > /dev/null; zf_at_payment "$b"
check() { q "select (x ->> 'ok') from jsonb_array_elements(public.zella_activation_checks('$b') -> 'checks') x where x ->> 'key' = 'payment'"; }
[ "$(check)" = "false" ] && [ "$(as_user_e "$u" aal2 "select public.zella_owner_onboarding_complete_step('$b', 'payment')")" = "PAYMENT_NOT_CONFIRMED" ] && ok "before: payments off, yet go live waits for a payment and step 6 can't be passed" || bad "before"
zf_cycle zella_stripe_payment_gate zella_stripe_payment_gate_rollback 'public.zella_onboarding_payment_passed(uuid)' '^zella_(onboarding_(rules|payment|payment_passed)|activation_checks|request_activation|owner_onboarding_complete_step)$'
# payments off (the default)
[ "$(q "select public.zella_payments_live()")" = "f" ] && [ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_get('$b') -> 'rules' ->> 'first_payment'")" = "not_until_payments_live" ] && ok "off: the rule is not until payments are live" || bad "off rule"
[ "$(as_user "$u" aal2 "select concat_ws(',', p ->> 'status', p ->> 'reason', p ->> 'required', p ->> 'confirmed_at') from public.zella_owner_onboarding_payment_status('$b') p")" = "waiting,payments_not_connected,false" ] && ok "off: step 6 says payments aren't connected, not required, never confirmed" || bad "off status: $(as_user "$u" aal2 "select public.zella_owner_onboarding_payment_status('$b')")"
[ "$(check)" = "true" ] && ok "off: the go live gate doesn't wait for a payment" || bad "off gate"
# payments on, a second business still on step 6
c=$(zf_business "Gate Two"); uc=$(owner_of "$c"); zf_plan "$c" 29900 0 > /dev/null; zf_at_payment "$c"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
checkc() { q "select (x ->> 'ok') from jsonb_array_elements(public.zella_activation_checks('$c') -> 'checks') x where x ->> 'key' = 'payment'"; }
[ "$(as_user "$uc" aal2 "select public.zella_owner_onboarding_get('$c') -> 'rules' ->> 'first_payment'")" = "pay_before_live" ] && ok "on: the rule is pay before going live" || bad "on rule"
[ "$(checkc)" = "false" ] && [ "$(as_user_e "$uc" aal2 "select public.zella_owner_onboarding_complete_step('$c', 'payment')")" = "PAYMENT_NOT_CONFIRMED" ] && ok "on: the gate and step 6 wait for a payment" || bad "on wait"
[ "$(as_user "$uc" aal2 "select public.zella_owner_onboarding_payment_status('$c') ->> 'required'")" = "true" ] && ok "on: step 6 says a payment is required" || bad "on required"
q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at) values ('$c', 299, 29900, 'usd', 'succeeded', 'stripe', 'pi_unbound', now())" > /dev/null
[ "$(checkc)" = "false" ] && ok "on: an unbound payments row never counts" || bad "unbound"
q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at, metadata) values ('$c', 299, 29900, 'usd', 'succeeded', 'stripe', 'pi_bound', now(), '{\"bound\":true}')" > /dev/null
[ "$(checkc)" = "true" ] && [ "$(as_user "$uc" aal2 "select public.zella_owner_onboarding_complete_step('$c', 'payment') ->> 'changed'")" = "true" ] && ok "on: a bound Stripe payment passes the gate and step 6" || bad "bound"
# back off: the off state again; the first business can now pass step 6 without paying
q "update public.platform_settings set value = 'false' where key = 'payments_live'" > /dev/null
[ "$(as_user "$u" aal2 "select public.zella_owner_onboarding_complete_step('$b', 'payment') ->> 'changed'")" = "true" ] && ok "off: the owner passes step 6 without a payment" || bad "off pass"
echo "$fails failed"; [ "$fails" = 0 ]
