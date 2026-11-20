#!/usr/bin/env bash
# sql/zella_stripe_reconcile.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: nothing compares Stripe with our records. Then: apply, apply again, rollback twice, apply again, drift
# refused; the live zella_reconcile_billing_events keeps its exact body, and the file refuses if it ever differs; the
# ledger check finds an unbalanced operation; the object check finds a paid invoice we don't have, a wrong amount, a
# refund we never approved and a dispute we never recorded, ignores objects that aren't ours, alerts once and never
# changes a row; it runs once a day; the events cursor starts an hour before the last completed scan (a watermark), never the newest stored event.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_reconcile zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes zella_stripe_emails
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Recon One"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 RC
[ -n "$(q "select to_regprocedure('public.zella_billing_ledger_check()') is null")" ] && [ "$(q "select to_regprocedure('public.zella_billing_ledger_check()') is null")" = "t" ] && ok "before: nothing compares Stripe with our records" || bad "before"
recon=$(q "select md5(pg_get_functiondef('public.zella_reconcile_billing_events(integer)'::regprocedure))")
zf_cycle zella_stripe_reconcile zella_stripe_reconcile_rollback 'public.zella_billing_reconcile_objects(jsonb)' '^zella_billing_(ledger_check|reconcile_objects|reconcile_due|events_cursor|events_scanned)'
[ "$(q "select md5(pg_get_functiondef('public.zella_reconcile_billing_events(integer)'::regprocedure))")" = "$recon" ] && [ "$recon" = "9f59ce3f06d391759dce9a17ff5fef77" ] && ok "zella_reconcile_billing_events (the live job) keeps its exact body" || bad "reconcile body"
copy=zlf_t_reconcile_md5; "${P[@]}" -d postgres -c "drop database if exists $copy" -c "create database $copy template $DB" > /dev/null
"${P[@]}" -d $copy -c "do \$\$ begin execute replace(pg_get_functiondef('public.zella_reconcile_billing_events(integer)'::regprocedure), 'AS \$function\$', 'AS \$function\$ '); end \$\$" > /dev/null
out=$("${P[@]}" -d $copy -f "$ZF_REPO/sql/zella_stripe_reconcile.sql" 2>&1); [[ "$out" == *"zella_reconcile_billing_events is not the version"* ]] && ok "the file refuses if the live job's body ever differs (md5 guard)" || bad "md5 guard"
"${P[@]}" -d postgres -c "drop database $copy" > /dev/null
q "select public.zella_ledger_post('$b', 'invoice:in_RC1', '[{\"account\":\"receivable\",\"amount\":29900},{\"account\":\"revenue\",\"amount\":-29900}]')" > /dev/null
[ "$(q "select jsonb_array_length(public.zella_billing_ledger_check() -> 'mismatches')")" = "0" ] && ok "a balanced ledger passes" || bad "ledger ok"
q "set session_replication_role = replica; insert into public.money_ledger (business_id, operation_key, account, amount_minor) values ('$b', 'invoice:in_RC1', 'cash', 1)" > /dev/null
[ "$(q "select public.zella_billing_ledger_check() #>> '{mismatches,0,operation}'")" = "invoice:in_RC1" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'billing_ledger_unbalanced'")" = "1" ] && ok "an unbalanced operation is found and alerted" || bad "ledger bad"
q "insert into public.billing_invoices (business_id, stripe_invoice_id, kind, status, total_minor, amount_due_minor, amount_paid_minor, livemode) values ('$b', 'in_RC2', 'renewal', 'paid', 29900, 29900, 29900, false)" > /dev/null
q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at) values ('$b', 299, 29900, 'usd', 'succeeded', 'stripe', 'pi_RC', now())" > /dev/null
before=$(q "select md5(string_agg(t::text, ',' order by t::text)) from (select * from public.billing_invoices) t")
objs='[{"type":"invoice","id":"in_RC2","customer":"cus_RC","status":"paid","amount":29900},{"type":"invoice","id":"in_RC3","customer":"cus_RC","status":"paid","amount":100},
 {"type":"invoice","id":"in_NOTOURS","customer":"cus_SOMEONE","status":"paid","amount":5},{"type":"refund","id":"re_RC","payment_intent":"pi_RC","status":"succeeded","amount":500},
 {"type":"refund","id":"re_NOTOURS","payment_intent":"pi_OTHER","status":"succeeded","amount":5},{"type":"dispute","id":"dp_RC","payment_intent":"pi_RC","amount":29900}]'
r=$(q "select string_agg(x ->> 'type' || ':' || (x ->> 'id'), ',') from jsonb_array_elements(public.zella_billing_reconcile_objects('$objs') -> 'mismatches') x")
[ "$r" = "invoice:in_RC3,refund:re_RC,dispute:dp_RC" ] && ok "found: a paid invoice we don't have, a refund we never approved, a dispute never recorded; ours that match and others' objects pass" || bad "objects: $r"
q "update public.billing_invoices set amount_paid_minor = 29000 where stripe_invoice_id = 'in_RC2'" > /dev/null
pre=$(q "select amount_paid_minor || ' ' || status from public.billing_invoices where stripe_invoice_id = 'in_RC2'")
r=$(q "select string_agg(x ->> 'id', ',') from jsonb_array_elements(public.zella_billing_reconcile_objects('[{\"type\":\"invoice\",\"id\":\"in_RC2\",\"customer\":\"cus_RC\",\"status\":\"paid\",\"amount\":29900}]') -> 'mismatches') x")
[ "$r" = "in_RC2" ] && [ "$(q "select amount_paid_minor || ' ' || status from public.billing_invoices where stripe_invoice_id = 'in_RC2'")" = "$pre" ] \
  && ok "a paid amount that differs is found, and our row is left exactly as it was" || bad "amount: $r"
q "update public.billing_invoices set amount_paid_minor = 29900 where stripe_invoice_id = 'in_RC2'" > /dev/null
[ "$(q "select md5(string_agg(t::text, ',' order by t::text)) from (select * from public.billing_invoices) t")" = "$before" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'billing_reconcile_mismatch'")" = "1" ] && ok "one alert a day; no row is ever corrected" || bad "no correction"
[ "$(q "select public.zella_billing_reconcile_due()")" = "f" ] && ok "the object check runs once a day" || bad "due"
q "update public.billing_invoices set status = 'open' where stripe_invoice_id = 'in_RC2'" > /dev/null
r=$(q "select string_agg(x ->> 'id', ',') from jsonb_array_elements(public.zella_billing_reconcile_objects('[{\"type\":\"invoice\",\"id\":\"in_RC2\",\"customer\":\"cus_RC\",\"status\":\"void\",\"amount\":0}]') -> 'mismatches') x")
[ "$r" = "in_RC2" ] && ok "an invoice Stripe voided that is still open here is a difference" || bad "void: $r"
q "update public.billing_invoices set status = 'paid' where stripe_invoice_id = 'in_RC2'" > /dev/null
# the watermark: before any completed scan, 3 days back; a newer webhook event never moves it
[ "$(q "select public.zella_billing_events_cursor() between extract(epoch from now() - interval '3 days 1 minute') and extract(epoch from now() - interval '2 days 23 hours 59 minutes')")" = "t" ] && ok "before a completed scan, missed events are read from 3 days back" || bad "cursor start"
q "select public.zella_billing_events_scanned(extract(epoch from now() - interval '5 hours')::bigint, 3, true)" > /dev/null
q "insert into public.billing_events (provider, external_event_id, type, status, pipeline, event_created_at, data) values ('stripe', 'evt_cursor', 'invoice.paid', 'processed', 'stripe_v2', now() - interval '1 minute', '{}')" > /dev/null
[ "$(q "select public.zella_billing_events_cursor() between extract(epoch from now() - interval '6 hours 1 minute') and extract(epoch from now() - interval '5 hours 59 minutes')")" = "t" ] \
  && ok "after a gap longer than the overlap, a newer stored event never skips the missed one: the scan starts an hour before the last completed scan" || bad "cursor gap"
q "select public.zella_billing_events_scanned(extract(epoch from now())::bigint, 5000, false)" > /dev/null
[ "$(q "select public.zella_billing_events_cursor() between extract(epoch from now() - interval '6 hours 1 minute') and extract(epoch from now() - interval '5 hours 59 minutes')")" = "t" ] \
  && [ "$(q "select count(*) from public.platform_alerts where kind = 'billing_events_scan_incomplete'")" = "1" ] && ok "a scan cut short moves nothing and alerts a person (the backfill is a manual step)" || bad "incomplete scan"
echo "$fails failed"; [ "$fails" = 0 ]
