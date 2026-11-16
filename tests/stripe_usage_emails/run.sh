#!/usr/bin/env bash
# sql/zella_stripe_usage_emails.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: an 80% or 100% minutes threshold queues no billing email. Then: apply, apply again, rollback twice, apply
# again, drift refused; nothing while payments are off; 80% gives F1 with the minutes and days left, 100% F2 with the
# rate and limit, once per period; texts thresholds give nothing; a broken notice never blocks the threshold row.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_usage_emails zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes zella_stripe_emails zella_stripe_reconcile zella_stripe_plan_change zella_stripe_payment_gate
b=$(zf_business "Usage One"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 UE
q "insert into public.business_usage_preferences (business_id, overage_mode, spend_limit_cents) values ('$b', 'pay_as_you_go', 30000)" > /dev/null
ev() { q "insert into public.usage_threshold_events (business_id, threshold_key, period_key, event_type, usage_minutes, limit_minutes, resource) values ('$b', '$1:pct:$2', '$3', 'approaching', 400, 500, '$1')" > /dev/null; }
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
ev minutes 80 p0
[ "$(q "select count(*) from public.billing_email_intents")" = "0" ] && ok "before: a threshold queued no billing email" || bad "before"
zf_cycle zella_stripe_usage_emails zella_stripe_usage_emails_rollback 'public.zella_billing_usage_email_trg()' '^zella_billing_usage_email_trg$'
q "update public.platform_settings set value = 'false' where key = 'payments_live'" > /dev/null; ev minutes 80 p1
[ "$(q "select count(*) from public.billing_email_intents")" = "0" ] && ok "nothing while payments are off" || bad "off"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
ev minutes 80 p2; ev minutes 100 p2; ev texts 80 p2
[ "$(q "select string_agg(code || '=' || coalesce(data ->> 'minutesUsed', data ->> 'rate'), ',' order by code) from public.billing_email_intents")" = "F1=400,F2=\$0.20" ] && ok "80% gives F1 with the minutes used, 100% gives F2 with the rate; texts give nothing" || bad "codes: $(q "select string_agg(code || ':' || data::text, ' ') from public.billing_email_intents")"
[ "$(q "select (data ->> 'limit') || ',' || (data ->> 'daysLeft' is not null) from public.billing_email_intents where code = 'F1' or code = 'F2' order by code desc limit 1")" = "\$300.00,false" ] && ok "F2 carries the monthly limit" || bad "limit"
q "insert into public.usage_threshold_events (business_id, threshold_key, period_key, event_type, usage_minutes, limit_minutes, resource) values ('$b', 'minutes:pct:80', 'p2b', 'approaching', 400, 500, 'minutes')" > /dev/null
[ "$(q "select count(*) from public.usage_threshold_events where business_id = '$b'")" -ge 5 ] && ok "every threshold row is kept" || bad "rows"
echo "$fails failed"; [ "$fails" = 0 ]
