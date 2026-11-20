#!/usr/bin/env bash
# sql/zella_stripe_emails.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: a paid invoice or a pause queued no billing email. Then: apply, apply again, rollback twice, apply again,
# drift refused; each billing moment decides one notice with a key on the business object (never twice, however many
# events); renewal (3 days, and 7 for yearly) and trial ending notices come from the sweep, once; nothing while payments
# are off; the worker's claim gives the owners as recipients; signed in users can't touch any of it.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_emails zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Email One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 E1
ins() { q "insert into public.billing_invoices (business_id, stripe_invoice_id, kind, status, number, total_minor, amount_due_minor, amount_paid_minor, livemode) values ('$b', '$1', '$2', '$3', 'ZV-$1', 29900, 29900, 0, false)" > /dev/null; }
ins in_E0 renewal paid
[ "$(q "select count(*) from public.platform_emails")" = "0" ] && ok "before: a paid invoice queued no email" || bad "before"
q "delete from public.billing_invoices" > /dev/null
zf_cycle zella_stripe_emails zella_stripe_emails_rollback 'public.zella_billing_email_claim(integer)' '^zella_(usd_text|billing_email)'
codes() { q "select string_agg(code, ',' order by created_at, code) from public.billing_email_intents"; }
ins in_E1 first open; q "update public.billing_invoices set status = 'paid', amount_paid_minor = 29900 where stripe_invoice_id = 'in_E1'" > /dev/null
q "update public.billing_invoices set status = 'paid' where stripe_invoice_id = 'in_E1'" > /dev/null
[ "$(codes)" = "C1,A1" ] && ok "first invoice: issued (C1), then the welcome receipt (A1), once each" || bad "first: $(codes)"
ins in_E2 renewal open; q "update public.billing_invoices set status = 'payment_failed' where stripe_invoice_id = 'in_E2'" > /dev/null; q "update public.billing_invoices set status = 'void' where stripe_invoice_id = 'in_E2'" > /dev/null
[ "$(codes)" = "C1,A1,C1,D1,C4" ] && ok "renewal: issued, payment failed (D1), cancelled (C4)" || bad "renewal: $(codes)"
[ "$(q "select data ->> 'total' from public.billing_email_intents where code = 'D1'")" = "\$299.00" ] && ok "amounts come from integer cents as \$299.00" || bad "money"
q "update public.subscriptions set past_due_since = now() - interval '6 days'; update public.subscriptions set status = 'past_due' where business_id = '$b'" > /dev/null
q "select public.zella_billing_nonpayment_sweep()" > /dev/null; q "update public.subscriptions set status = 'active' where business_id = '$b'" > /dev/null
[ "$(q "select string_agg(code, ',' order by created_at) from public.billing_email_intents where code in ('D5', 'D6')")" = "D5,D6" ] && ok "paused (D5) and recovered (D6)" || bad "pause"
q "update public.subscriptions set current_period_end = now() + interval '2 days' where business_id = '$b'" > /dev/null
q "update public.platform_settings set value = 'false' where key = 'payments_live'" > /dev/null
[ "$(q "select public.zella_billing_email_sweep()")" = "0" ] && ok "nothing is decided while payments are off" || bad "off"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
[ "$(q "select public.zella_billing_email_sweep()")$(q "select public.zella_billing_email_sweep()")" = "10" ] && [ "$(q "select data ->> 'renewDate' is not null from public.billing_email_intents where code = 'B1'")" = "t" ] && ok "renewal coming in 3 days: one notice, however often the sweep runs" || bad "B1"
y=$(zf_business "Email Yearly"); yp=$(zf_plan "$y" 299000 0 yearly); zf_active "$y" "$yp" 299000 EY
q "update public.subscriptions set current_period_end = now() + interval '2 days' where business_id = '$y'" > /dev/null; q "select public.zella_billing_email_sweep()" > /dev/null
[ "$(q "select string_agg(right(dedupe_key, 2), ',' order by right(dedupe_key, 2) desc) from public.billing_email_intents where business_id = '$y'")" = "d7,d3" ] && ok "a yearly plan gets the 7 day and the 3 day notice" || bad "yearly: $(q "select string_agg(dedupe_key, ',') from public.billing_email_intents where business_id = '$y'")"
q "update public.billing_events set status = 'processed'" > /dev/null
r=$(q "select jsonb_array_length(recipients) || ',' || (recipients -> 0 ->> 'user_id') from public.zella_billing_email_claim(50) where business_id = '$b' limit 1")
[ "$r" = "1,$u" ] && ok "the worker's claim gives the business's owner as the recipient" || bad "claim: $r"
[ "$(q "select count(*) from public.zella_billing_email_claim(50)")" = "0" ] && ok "a claimed notice isn't claimed twice" || bad "claim twice"
[ "$(as_user "$u" aal2 "select count(*) from public.billing_email_intents" 2>&1 | grep -c 'permission denied')$(as_user "$u" aal2 "select public.zella_billing_email_sweep()" 2>&1 | grep -c 'permission denied')" = "11" ] && ok "signed in users can't read the notices or run the sweep" || bad "auth"
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_emails_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while notices wait" || bad "rollback data"
echo "$fails failed"; [ "$fails" = 0 ]
