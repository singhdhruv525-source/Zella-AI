#!/usr/bin/env bash
# sql/zella_stripe_packs.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: an owner can't buy a pack (only admin grants exist). Then: apply, apply again, rollback twice, apply again,
# drift refused; who may buy (anonymous, another business's owner, a session without the code, payments off); the price
# is the catalog's; a double click is one purchase; the PaymentIntent command carries our customer, the saved card id
# and our key; a payment of another amount is quarantined; the bound payment grants the pack once until the period
# ends, with a bound payment and balanced ledger; a decline fails the purchase and grants nothing; auto reload queues
# one pending reload however many usage entries cross the threshold, stops at the monthly spend limit, does nothing
# while switched off, and never fails the usage entry; the rollback refuses while bought packs exist.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_packs zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Pack One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 P1
b2=$(zf_business "Pack Two"); u2=$(owner_of "$b2")
[ "$(as_user_e "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001')")" = "function" ] || [ -n "$(as_user "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001')" 2>&1 | grep 'does not exist')" ] && ok "before: an owner can't buy a pack" || bad "before"
zf_cycle zella_stripe_packs zella_stripe_packs_rollback 'public.zella_owner_pack_buy(uuid,text,text)' '^zella_(owner_pack|billing_(maybe_reload|reload_trg|pack_command)|stripe_(after_payment_intent|failed_payment_intent|on_payment_intent|on_customer_subscription_updated))'
[ "$(as_user_e "$u2" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001')")" = "NOT_ALLOWED" ] && ok "another business's owner is refused" || bad "other owner"
[ "$(as_user_e "$u" aal1 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001')")" = "MFA_REQUIRED" ] && ok "a session without the code is refused" || bad "aal1"
[ "$(q "set role anon; select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "anonymous is refused" || bad "anon"
[ "$(as_user_e "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001')")" = "NO_SAVED_CARD" ] && ok "no saved card known: refused, nothing queued" || bad "no card"
q "update public.subscriptions set metadata = metadata || '{\"default_payment_method\":\"pm_P1\"}' where business_id = '$b'" > /dev/null
pid=$(as_user "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001') ->> 'purchase_id'")
[ "$(as_user "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pack-key-0001') ->> 'purchase_id'")" = "$pid" ] && [ "$(q "select count(*) from public.pack_purchases")" = "1" ] && ok "a double click is one purchase" || bad "double click"
[ "$(as_user_e "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_250', 'pack-key-0001')")" = "IDEMPOTENCY_CONFLICT" ] && ok "the same key for another pack is refused" || bad "key reuse"
[ "$(q "select (body ->> 'amount') || ',' || (body ->> 'customer') || ',' || (body ->> 'payment_method') || ',' || idempotency_key from public.billing_outbox where local_id = '$pid'")" = "2900,cus_P1,pm_P1,pack:$pid" ] && ok "the command: catalog price, our customer, the saved card, key pack:<id>" || bad "command"
zf_sent "$b" pi_P1 '{"amount":2900,"status":"succeeded"}' > /dev/null
pi() { echo "{\"id\":\"$1\",\"object\":\"payment_intent\",\"status\":\"$2\",\"amount\":$3,\"currency\":\"usd\",\"customer\":\"cus_P1\",\"livemode\":false}"; }
[ "$(zf_apply evt_p0 payment_intent.succeeded "$(pi pi_P1 succeeded 2800)")" = "quarantined" ] && ok "a payment of another amount is quarantined" || bad "amount"
[ "$(zf_apply evt_p1 payment_intent.succeeded "$(pi pi_P1 succeeded 2900)")" = "applied" ] && ok "the bound payment applies" || bad "grant: $(q "select error from public.billing_events where external_event_id = 'evt_p1'")"
[ "$(q "select k.granted::int || ',' || (k.expires_at = p.period_end) from public.allowance_buckets k join public.billing_periods p on p.id = k.period_id where k.pack_purchase_id = '$pid'")" = "100,true" ] && ok "100 minutes until the end of the period it was bought in" || bad "bucket"
[ "$(q "select amount_minor || (metadata ->> 'bound') from public.payments where external_payment_id = 'pi_P1'")$(q "select sum(amount_minor) from public.money_ledger where business_id = '$b'")" = "2900true0" ] && ok "one bound payment, balanced ledger" || bad "payment"
zf_apply evt_p2 payment_intent.succeeded "$(pi pi_P1 succeeded 2900)" > /dev/null
[ "$(q "select count(*) from public.allowance_buckets where pack_purchase_id = '$pid'")$(q "select count(*) from public.payments")" = "11" ] && ok "a second event grants nothing more" || bad "twice"
[ "$(zf_apply evt_p3 payment_intent.succeeded "$(pi pi_SUBSCRIPTION succeeded 29900)")" = "ignored" ] && ok "a plan invoice's PaymentIntent is left to invoice.paid" || bad "unlinked"
pid2=$(as_user "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_250', 'pack-key-0002') ->> 'purchase_id'")
oid=$(q "select id from public.billing_outbox where local_id = '$pid2'"); q "select id from public.zella_billing_outbox_claim(1, '$oid')" > /dev/null
q "select public.zella_billing_outbox_result('$oid', false, null, '{\"type\":\"card_error\",\"code\":\"card_declined\",\"payment_intent\":\"pi_P2\"}', 'card_error card_declined', false, false)" > /dev/null
[ "$(q "select status || ',' || failure_reason from public.pack_purchases where id = '$pid2'")$(q "select count(*) from public.allowance_buckets where pack_purchase_id = '$pid2'")" = "failed,card_declined0" ] && ok "a declined card fails the purchase, nothing granted" || bad "decline"
# auto reload
q "insert into public.auto_reload_settings (business_id, resource, enabled, threshold, pack_code, monthly_cap_cents) values ('$b', 'minutes', true, 50, 'minutes_100', 5000)" > /dev/null
per=$(q "select id from public.billing_periods where business_id = '$b' order by period_start desc limit 1")
use() { q "insert into public.usage_charges (business_id, period_id, resource, idempotency_key, quantity, allocations, over_quantity, source_kind, occurred_at) values ('$b', '$per', 'minutes', 'call:test-$1', $2, '[]', 0, 'call', now())" > /dev/null; }
q "update public.allowance_buckets set used = granted where business_id = '$b' and resource = 'minutes'" > /dev/null
q "update public.platform_settings set value = 'false' where key = 'payments_live'" > /dev/null; use 0 1
[ "$(q "select count(*) from public.pack_purchases where source = 'auto_reload'")" = "0" ] && ok "auto reload does nothing while payments are off" || bad "reload off"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
for i in 1 2 3 4 5; do use $i 1 & done; wait
[ "$(q "select count(*) from public.pack_purchases where source = 'auto_reload' and status = 'pending'")$(q "select count(*) from public.usage_charges where business_id = '$b'")" = "16" ] && ok "five usage entries at once: one pending reload, every entry recorded" || bad "reload race: $(q "select count(*) from public.pack_purchases where source = 'auto_reload'")"
[ "$(q "select idempotency_key like 'reload:%' from public.billing_outbox where local_id = (select id from public.pack_purchases where source = 'auto_reload')")" = "t" ] && ok "the reload's command has key reload:<id>" || bad "reload key"
q "update public.pack_purchases set status = 'granted' where source = 'auto_reload'" > /dev/null; use 6 1
[ "$(q "select count(*) from public.pack_purchases where source = 'auto_reload'")" = "1" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'auto_reload_cap'")" = "1" ] && ok "the next reload would pass the 50.00 monthly limit: none, the owner is told" || bad "cap"
q "update public.auto_reload_settings set monthly_cap_cents = 100000 where business_id = '$b'; update public.subscriptions set metadata = metadata - 'default_payment_method' where business_id = '$b'" > /dev/null; use 7 1
[ "$(q "select count(*) from public.usage_charges where business_id = '$b'")" = "8" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'auto_reload_failed'")" = "1" ] && ok "a problem with auto reload never fails the usage entry" || bad "usage blocked"
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_packs_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while bought packs exist" || bad "rollback data"
echo "$fails failed"; [ "$fails" = 0 ]
