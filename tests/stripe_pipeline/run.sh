#!/usr/bin/env bash
# sql/zella_stripe_pipeline.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: a "subscription active" event alone makes a past due subscription active (gap C-3). Then: apply, apply
# again, rollback twice, apply again, drift refused both ways; the live 15 minute job keeps its exact body and never
# touches the new rows; the inbox stores once and refuses a wrong mode; events wait while payments are off; events of
# one subscription are claimed oldest first; an object that isn't the event's, an unbound invoice, a wrong customer,
# a wrong currency and an unhandled billing reason are quarantined with nothing granted; a subscription never moves
# backwards and an active status grants nothing; the ledger refuses unbalanced or repeated postings; the outbox keeps
# its key and body, waits on 429 or 5xx, holds an idempotency conflict; signed in users and anonymous callers can't
# call any of it; the rollback refuses while rows exist.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
zf_build zlf_t_pipeline
b=$(zf_business "Pipe One"); b2=$(zf_business "Pipe Two")
q "insert into public.subscriptions (business_id, status, billing_interval, provider, external_subscription_id, past_due_since) values ('$b', 'past_due', 'monthly', 'stripe', 'sub_old1', now())" > /dev/null
q "select public.zella_process_billing_event('stripe', 'evt_old1', 'subscription_renewed', 'sub_old1', null, null, null, null, now(), now() + interval '30 days', null, null, now(), null)" > /dev/null
[ "$(q "select status from public.subscriptions where business_id = '$b'")" = "active" ] && ok "before: a status event alone made a past due subscription active, no payment (gap C-3)" || bad "before"
q "delete from public.billing_events; delete from public.subscriptions" > /dev/null
recon=$(q "select md5(pg_get_functiondef('public.zella_reconcile_billing_events(integer)'::regprocedure))")

zf_cycle zella_stripe_pipeline zella_stripe_pipeline_rollback 'public.zella_stripe_apply_event(uuid,jsonb,boolean)' '^zella_(stripe|billing_outbox|payments|billing_worker|ledger|subscription_transition)'
[ "$(q "select md5(pg_get_functiondef('public.zella_reconcile_billing_events(integer)'::regprocedure))")" = "$recon" ] && [ "$recon" = "9f59ce3f06d391759dce9a17ff5fef77" ] \
  && ok "zella_reconcile_billing_events keeps its exact body (the live job)" || bad "reconcile changed: $recon"
[ "$(q "select active from cron.job where jobname = 'zella_billing_worker'")" = "f" ] && [ "$(q "select public.zella_payments_live()")" = "f" ] && ok "payments switch and worker job start off" || bad "switch off"

ev() { # id type object_json [livemode] [created offset seconds]
  q "select public.zella_stripe_event_store(jsonb_build_object('id', '$1', 'type', '$2', 'livemode', ${4:-false}, 'created', extract(epoch from now())::bigint + ${5:-0}, 'data', jsonb_build_object('object', '$3'::jsonb)), false)"
}
[ "$(ev evt_mode1 invoice.paid '{"id":"in_1","object":"invoice"}' true)" = "mode_mismatch" ] && [ "$(q "select count(*) from public.billing_events")" = "0" ] && ok "a live event to a sandbox key is refused, nothing stored" || bad "mode"
[ "$(ev evt_x1 something.new '{"id":"x_1","object":"x"}')" = "ignored" ] && ok "an unknown type is acknowledged, not stored" || bad "unknown"
[ "$(q "select public.zella_stripe_event_store('{\"id\":\"nope\",\"type\":\"invoice.paid\"}', false)")" = "bad_event" ] && ok "a malformed event is refused" || bad "bad event"
[ "$(ev evt_s1 customer.subscription.updated '{"id":"sub_A","object":"subscription","status":"active"}' false -20)" = "stored" ] && ok "stores once" || bad "store"
[ "$(ev evt_s1 customer.subscription.updated '{"id":"sub_A","object":"subscription","status":"active"}' false -20)" = "duplicate" ] && ok "a redelivery is a duplicate" || bad "dup"
q "select public.zella_reconcile_billing_events()" > /dev/null
[ "$(q "select status from public.billing_events where external_event_id = 'evt_s1'")" = "received" ] && ok "the old 15 minute job never touches the new rows" || bad "reconcile touched v2"
[ "$(q "select count(*) from public.zella_stripe_claim_events(10)")" = "0" ] && ok "nothing is claimed while payments are off" || bad "claimed while off"
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
ev evt_s2 customer.subscription.updated '{"id":"sub_A","object":"subscription","status":"past_due"}' false -10 > /dev/null
ev evt_s0 customer.subscription.created '{"id":"sub_A","object":"subscription","status":"active"}' false -30 > /dev/null
[ "$(q "select string_agg(e.external_event_id, ',') from public.zella_stripe_claim_events(10) c join public.billing_events e on e.id = c.id")" = "evt_s0" ] && ok "one subscription's events are claimed oldest first, one at a time" || bad "order"
id_of() { q "select id from public.billing_events where external_event_id = '$1'"; }
app() { q "select public.zella_stripe_apply_event('$(id_of "$1")', '$2'::jsonb, false)"; }
[ "$(app evt_s0 '{"id":"sub_A","object":"subscription","status":"active","livemode":false}')" = "waiting" ] && ok "a subscription we never linked waits" || bad "waiting"
[ "$(q "select status || ':' || (error like 'WAITING:%') from public.billing_events where external_event_id = 'evt_s0'")" = "received:true" ] && ok "a waiting event stays stored with its reason" || bad "waiting state"
q "insert into public.subscriptions (business_id, status, billing_interval, provider, external_subscription_id) values ('$b', 'trial', 'monthly', 'stripe', 'sub_A')" > /dev/null
q "select public.zella_stripe_link_add('cus_A', 'customer', '$b', false); select public.zella_stripe_link_add('sub_A', 'subscription', '$b', false)" > /dev/null
[ "$(qe "select public.zella_stripe_link_add('sub_A', 'subscription', '$b2', false)")" = "BINDING:" ] && ok "a Stripe id can't be linked to a second business" || bad "relink"
q "update public.billing_events set next_attempt_at = now()" > /dev/null
[ "$(app evt_s0 '{"id":"sub_A","object":"subscription","status":"active","livemode":false}')" = "applied" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "trial" ] \
  && ok "subscription active in Stripe grants nothing here: no period, status unchanged (C-3)" || bad "C-3 after"
[ "$(app evt_s2 '{"id":"sub_A","object":"subscription","status":"past_due","livemode":false}')" = "applied" ] && [ "$(q "select status from public.subscriptions where business_id = '$b'")" = "past_due" ] && ok "past due is recorded" || bad "past due"
[ "$(app evt_s1 '{"id":"sub_A","object":"subscription","status":"active","livemode":false}')" = "older" ] && ok "an older event is recorded only, never moves the subscription back" || bad "older"
[ "$(app evt_s1 '{"id":"sub_A","object":"subscription","livemode":false}')" = "duplicate" ] && ok "an applied event can't be applied again" || bad "reapply event"
ev evt_m1 invoice.paid '{"id":"in_M","object":"invoice"}' > /dev/null
[ "$(app evt_m1 '{"id":"in_OTHER","object":"invoice","livemode":false}')" = "quarantined" ] && ok "an object that isn't the event's is quarantined" || bad "object mismatch"
inv() { echo "{\"id\":\"$1\",\"object\":\"invoice\",\"status\":\"paid\",\"currency\":\"${3:-usd}\",\"amount_paid\":1000,\"amount_due\":1000,\"total\":1000,\"customer\":\"${2:-cus_A}\",\"billing_reason\":\"${4:-subscription_create}\",\"livemode\":false,\"parent\":{\"subscription_details\":{\"subscription\":\"${5:-sub_A}\"}},\"payments\":{\"data\":[{\"status\":\"paid\",\"payment\":{\"payment_intent\":\"pi_$1\"}}]}}"; }
n=0; for case in "in_c1 cus_B usd subscription_create sub_A:customer" "in_c2 cus_A eur subscription_create sub_A:currency" "in_c3 cus_A usd subscription_create sub_ZZ:not linked" "in_c4 cus_A usd subscription_cycle sub_A:no grant for the reason yet"; do
  set -- ${case%%:*}; why=${case#*:}
  ev "evt_$1" invoice.paid "{\"id\":\"$1\",\"object\":\"invoice\"}" > /dev/null
  r=$(app "evt_$1" "$(inv "$1" "$2" "$3" "$4" "$5")")
  if [ "$5" = "sub_ZZ" ]; then [ "$r" = "waiting" ] && ok "invoice of a subscription not linked waits ($why)" || bad "$why: $r"
  else [ "$r" = "quarantined" ] && ok "invoice.paid quarantined: $why" || bad "$why: $r"; fi
done
[ "$(q "select count(*) from public.payments") $(q "select count(*) from public.billing_invoices") $(q "select count(*) from public.money_ledger")" = "0 0 0" ] && ok "nothing recorded or granted from a quarantined invoice" || bad "granted from quarantine"
[ "$(q "select count(*) from public.billing_quarantine where resolved_at is null") $(q "select count(*) from public.platform_alerts where kind = 'billing_quarantine'")" = "4 4" ] && ok "each quarantine has a row and an urgent alert" || bad "quarantine rows"
[ "$(qe "select public.zella_ledger_post('$b', 'op:1', '[{\"account\":\"cash\",\"amount\":100},{\"account\":\"revenue\",\"amount\":-99}]')")" = "LEDGER_UNBALANCED" ] && ok "an unbalanced posting is refused" || bad "unbalanced"
[ "$(qe "select public.zella_ledger_post('$b', 'op:1', '[{\"account\":\"cash\",\"amount\":1.5},{\"account\":\"revenue\",\"amount\":-1.5}]')")" = "LEDGER_NOT_INTEGER" ] && ok "money is integer cents only" || bad "float"
[ "$(q "select public.zella_ledger_post('$b', 'op:1', '[{\"account\":\"cash\",\"amount\":100},{\"account\":\"revenue\",\"amount\":-100}]')")$(q "select public.zella_ledger_post('$b', 'op:1', '[{\"account\":\"cash\",\"amount\":100},{\"account\":\"revenue\",\"amount\":-100}]')")" = "tf" ] && ok "the same operation posts once" || bad "ledger twice"
oid=$(q "select (public.zella_billing_outbox_add('$b', 'customer', 'customer:$b', 'POST', '/v1/customers', '{\"metadata\":{\"business_id\":\"$b\"}}')).id")
[ "$(qe "select public.zella_billing_outbox_add('$b', 'customer', 'customer:$b', 'POST', '/v1/customers', '{\"metadata\":{\"business_id\":\"other\"}}')")" = "IDEMPOTENCY_CONFLICT" ] && ok "the same key with another body is refused" || bad "outbox conflict"
[ "$(q "select status from public.zella_billing_outbox_claim(5, null)")" = "sending" ] && [ "$(q "select count(*) from public.zella_billing_outbox_claim(5, null)")" = "0" ] && ok "a claimed row isn't claimed twice" || bad "claim"
[ "$(q "select public.zella_billing_outbox_result('$oid', false, null, null, 'rate limit', true, false)")" = "retry_wait" ] && ok "429 or 5xx waits and keeps the same key and body" || bad "retry"
q "update public.billing_outbox set next_attempt_at = now() where id = '$oid'" > /dev/null
[ "$(q "select idempotency_key from public.zella_billing_outbox_claim(5, null)")" = "customer:$b" ] && ok "the resend carries the stored key" || bad "resend key"
q "update public.billing_outbox set lease_until = now() - interval '1 second' where id = '$oid'" > /dev/null
[ "$(q "select status from public.zella_billing_outbox_claim(5, null)")" = "sending" ] && ok "a lapsed lease is sent again with the same key (Stripe returns the first answer)" || bad "lease"
[ "$(q "select public.zella_billing_outbox_result('$oid', false, null, null, 'idempotency_error', false, true)")" = "held" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'billing_outbox_held'")" = "1" ] && ok "an idempotency conflict is held and alerted" || bad "held"
for role in anon authenticated; do
  out=$(q "set role $role; select public.zella_stripe_event_store('{}', false)" 2>&1; q "set role $role; select * from public.billing_outbox" 2>&1; q "set role $role; select public.zella_stripe_apply_event(gen_random_uuid(), '{}', false)" 2>&1)
  [ "$(echo "$out" | grep -c 'permission denied')" = "3" ] && ok "$role can't store, apply or read the outbox" || bad "$role: $out"
done
[ "$(qe "select public.zella_payments_switch(true, 'http://bad')")" = "WORKER_URL_REQUIRED" ] && ok "turning on needs the worker's https address" || bad "switch url"
q "select public.zella_payments_switch(true, 'https://example.supabase.co/functions/v1/billing-worker')" > /dev/null
[ "$(q "select active from cron.job where jobname = 'zella_billing_worker'")" = "t" ] && ok "the switch turns the worker job on" || bad "job on"
q "select public.zella_payments_switch(false)" > /dev/null
[ "$(q "select active from cron.job where jobname = 'zella_billing_worker'")$(q "select public.zella_payments_live()")" = "ff" ] && ok "and off again" || bad "job off"
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_pipeline_rollback.sql" 2>&1)
[[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while payment rows exist (nothing deleted)" || bad "rollback with data"
echo "$fails failed"; [ "$fails" = 0 ]
