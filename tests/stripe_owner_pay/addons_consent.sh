# Sourced by tests/stripe_owner_pay/stub_run.sh after the migration is applied (same database, same helpers): add ons
# on the Pay pages and the required "I agree" box (owner decisions, 27 Nov 2026), and the review fixes of round 1.
#   - the agreement's words: the database's and the page's (paymentConsent.js) are the same; refused without the box or
#     with other words; recorded once; read only by the business's owner; no client writes
#   - onboarding: the plan and 2 packs in ONE Checkout Session, granted once from the verified first invoice; a replayed
#     event grants nothing more; a selection changed mid session expires the old session first and only the new one is
#     granted; a price that differs, a pack no longer on offer and other session metadata are quarantined
#   - Pay now: add ons bought after the plan payment, each with its own key, only under the owner's agreement, a pack
#     failing after the invoice is paid, a retry with the same keys, a reload mid way (the server lists them)
#   - Auto pay pending while a command is in flight; an off choice saved after the subscription is linked; a card changed
#     on Stripe's page becomes the subscription's card (customer.updated)
JS_CONSENT="$REPO/web/supabase/functions/_shared/paymentConsent.js"
js_text() { node --input-type=module -e "import { consentText } from '$JS_CONSENT'; process.stdout.write(String(consentText($1)));"; }
ev_row() { q "insert into public.billing_events (type, object_id, livemode, event_created_at, ordering_key) values ('$1', '$2', false, clock_timestamp(), '$2') returning id" | head -1; }
apply() { local e; e=$(ev_row "$1" "$(echo "$2" | sed -nE 's/.*"id": "([^"]+)".*/\1/p' | head -1)"); q "set role service_role; select public.zella_stripe_apply_event('$e', '$2'::jsonb, false)" | tail -1; }
# sends this business's next waiting command with a made up Stripe answer: send1 <business> <stripe id> [extra answer json]
send1() {
  local id; id=$(q "select id from public.billing_outbox where business_id = '$1' and status in ('pending', 'retry_wait') order by created_at limit 1")
  [ -n "$id" ] || { echo none; return; }
  q "select id from public.zella_billing_outbox_claim(1, '$id')" > /dev/null
  q "select public.zella_billing_outbox_result('$id', true, '$2', (select jsonb_build_object('id', '$2', 'livemode', false) || (body - 'metadata') || '${3:-{\}}'::jsonb from public.billing_outbox where id = '$id'), null, false, false, (select attempts from public.billing_outbox where id = '$id'))" | tail -1
}
# a business on the Pay step with its owner: biz <name> <setup fee cents>; sets B and U
biz() {
  B=$(q "insert into public.businesses (name) values ('$1') returning id"); U=$(q "select gen_random_uuid()")
  q "insert into public.business_members values ('$B', '$U', 'owner', 'active'); insert into public.business_plans (business_id, version, price_cents, setup_fee_cents) values ('$B', 1, 24900, $2);
     insert into public.owner_onboarding values ('$B', 'payment', 1)" > /dev/null
}
start() { as "$U" aal2 "select public.zella_owner_billing_checkout_start('$B', '$1', '$2'::text[], ${4:-true}, '$3') ->> '${5:-checkout_id}'"; }
start_e() { err "$U" aal2 "select public.zella_owner_billing_checkout_start('$B', '$1', '$2'::text[], $3, $4)"; }
# drives a checkout's commands to an open session: open_session <checkout> <prefix>; the add on prices come in code order
open_session() {
  q "set role service_role; select public.zella_billing_checkout_continue('$1', false)" > /dev/null
  local n=0 k id
  while :; do
    k=$(q "select kind || ':' || coalesce(body #>> '{metadata,pack_code}', body #>> '{metadata,kind}', '') from public.billing_outbox where business_id = '$B' and status = 'pending' order by created_at limit 1")
    [ -n "$k" ] || break
    n=$((n + 1)); [ $n -gt 9 ] && break
    case "$k" in
      customer:*) id="cus_$2" ;; product:*) id="prod_$2" ;; price:plan_price) id="price_$2" ;; price:setup_fee_price) id="price_$2s" ;;
      addon_price:*) id="price_$2_${k#addon_price:}" ;;
      checkout_session:*) send1 "$B" "cs_$2" "{\"amount_total\": $(q "select first_amount_minor from public.billing_checkouts where id = '$1'"), \"expires_at\": $(($(date +%s) + 3600)), \"url\": null}" > /dev/null; continue ;;
      *) break ;;
    esac
    send1 "$B" "$id" > /dev/null
  done
}
line() { echo "{\"amount\": $1, \"quantity\": 1, \"pricing\": {\"price_details\": {\"price\": \"$2\"}}, \"period\": {\"start\": $(date +%s), \"end\": $(($(date +%s) + 2592000))}}"; }
paid() { echo "{\"id\": \"$1\", \"object\": \"invoice\", \"livemode\": false, \"customer\": \"$2\", \"subscription\": \"$3\", \"billing_reason\": \"subscription_create\", \"status\": \"paid\", \"currency\": \"usd\", \"amount_paid\": $4, \"amount_due\": $4, \"total\": $4, \"lines\": {\"data\": [$5], \"has_more\": false}}"; }
completed() { echo "{\"id\": \"$1\", \"object\": \"checkout.session\", \"livemode\": false, \"customer\": \"$2\", \"status\": \"complete\", \"mode\": \"subscription\", \"subscription\": \"$3\", \"metadata\": {$4}}"; }

# ---- the agreement's words ----
for args in "'plan', 94500, true, 24900, 4700|{ kind: 'plan', todayMinor: 94500, autopay: true, renewalMinor: 24900, addonsMinor: 4700 }" \
            "'plan', 24900, false, 24900, 0|{ kind: 'plan', todayMinor: 24900, autopay: false, renewalMinor: 24900 }" \
            "'plan', 123456789, true, 1050, 0|{ kind: 'plan', todayMinor: 123456789, autopay: true, renewalMinor: 1050 }" \
            "'invoice', 24900, true, 24900, 4700|{ kind: 'invoice', todayMinor: 24900, autopay: true, renewalMinor: 24900, addonsMinor: 4700 }" \
            "'invoice', 24900, false, 24900, 2950|{ kind: 'invoice', todayMinor: 24900, autopay: false, renewalMinor: 24900, addonsMinor: 2950 }" \
            "'pack', 2950, null, null, 0|{ kind: 'pack', todayMinor: 2950 }" "'plan', 0, true, 24900, 0|{ kind: 'plan', todayMinor: 0, autopay: true, renewalMinor: 24900 }"; do
  sq=$(ctext "${args%%|*}"); jv=$(js_text "${args#*|}")
  [ -n "$sq" ] && [ "$sq" = "$jv" ] && [ "$(hx "$sq")" = "$(node --input-type=module -e "import { consentHash } from '$JS_CONSENT'; process.stdout.write(await consentHash(process.argv[1]))" "$jv")" ] \
    && ok "the words are the same in the database and on the page, and so is their sha256: $sq" || bad "words differ: [$sq] [$jv]"
done
[ "$(ctext "'plan', 24900, false, 24900, 2900")" = "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card \$249 today. Add ons are one time." ] \
  && [ "$(ctext "'invoice', 24900, true, 24900, 2900")" = "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge \$249 to this card and \$29 for add ons to my saved card today, and \$249 each renewal until I cancel. Add ons are one time." ] \
  && [ "$(ctext "'pack', 2900, null, null, 0")" = "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge \$29 today for this add on." ] \
  && ok "the owner's wording: Auto pay off, Pay now naming which card, and a pack on its own" || bad "wording"
[ "$(q "select coalesce(public.zella_billing_consent_text('plan', 100, true, null, 0), 'none')")" = "none" ] && ok "a missing renewal price gives no words, so nothing can be agreed (never guessed)" || bad "null words"

# ---- onboarding: plan and two packs, one payment ----
q "insert into public.billing_pack_catalog values ('texts_500', 'texts', 500, 1800, true), ('emails_10000', 'emails', 10000, 2500, true), ('minutes_250', 'minutes', 250, 8900, false)" > /dev/null
biz "Add Ons One" 64900; B1=$B; U1=$U
T=$(ctext "'plan', 94500, true, 24900, 4700"); H=$(hx "$T"); HNO=$(hx "$(ctext "'plan', 89800, true, 24900, 0")")
[ "$(start_e key-addons-0001 '{minutes_100,texts_500}' true null)" = "CONSENT_REQUIRED" ] && ok "the Pay step's start is refused without the agreement" || bad "no consent"
[ "$(start_e key-addons-0001 '{minutes_100,texts_500}' true "'$HNO'")" = "CONSENT_MISMATCH" ] && [ "$(q "select count(*) from public.billing_checkouts where business_id = '$B'")" = "0" ] \
  && ok "and with words other than the server's for these amounts (here without the add ons): nothing is created" || bad "consent mismatch"
[ "$(start_e key-addons-0001 '{minutes_100,texts_500}' false "'$H'")" = "CONSENT_MISMATCH" ] && ok "the words depend on Auto pay: the on wording with Auto pay off is refused" || bad "autopay words"
[ "$(start_e key-addons-0001 '{minutes_100,nope_1}' true "'$H'")" = "UNKNOWN_PACK" ] && [ "$(start_e key-addons-0001 '{minutes_250}' true "'$H'")" = "UNKNOWN_PACK" ] \
  && ok "an unknown pack, or one no longer on offer, starts nothing" || bad "unknown pack"
[ "$(q "set role authenticated; select public.zella_owner_billing_checkout_start('$B', 'key-addons-0001')" 2>&1 | grep -c 'permission denied')" = "1" ] \
  && ok "the earlier two argument start is server only now: no payment starts without the agreement" || bad "old start grant"
c1=$(start key-addons-0001 '{texts_500,minutes_100}' "$H")
[ -n "$c1" ] && [ "$(q "select first_amount_minor || ',' || status || ',' || desired_autopay from public.billing_checkouts where id = '$c1'")" = "94500,preparing,true" ] \
  && [ "$(q "select string_agg(pack_code || '=' || price_cents, ',' order by pack_code) from public.billing_checkout_addons where checkout_id = '$c1'")" = "minutes_100=2900,texts_500=1800" ] \
  && ok "the plan, the setup fee and two packs: one checkout of \$945, the packs priced from the catalogue (codes only from the page)" || bad "checkout with add ons: $c1"
[ "$(start key-addons-0001 '{minutes_100,texts_500}' "$H")" = "$c1" ] && [ "$(start_e key-addons-0001 '{texts_500,minutes_100,minutes_100}' true "'$H'")" = "INVALID_INPUT" ] \
  && [ "$(start key-addons-0001 '{texts_500,minutes_100}' "$H")" = "$c1" ] && ok "the same selection gets the same checkout (a double click, any order); a repeated code is refused" || bad "same selection"
[ "$(q "select count(*) || ',' || min(amount_today_minor) || ',' || bool_and(recurring) || ',' || min(recurring_amount_minor) || ',' || min(terms_version) || ',' || (min(consent_sha256) = '$H') || ',' || (min(user_id::text) = '$U') || ',' || (min(consent_text) = '$(echo "$T" | sed "s/'/''/g")')
           from public.billing_payment_consents where payment_kind = 'checkout' and payment_id = '$c1'")" = "1,94500,true,24900,terms-draft-2026-11-27,true,true,true" ] \
  && ok "the agreement is recorded ONCE with who, the exact words and their sha256, the terms version, \$945 today and \$249 recurring" || bad "consent record: $(q "select count(*) from public.billing_payment_consents where payment_id = '$c1'")"
STAFF_B=$(q "select gen_random_uuid()"); q "insert into public.business_members values ('$B', '$STAFF_B', 'staff', 'active')" > /dev/null   # a team member of THIS business
[ "$(as "$U" aal1 "select count(*) from public.billing_payment_consents")" = "1" ] && [ "$(as "$u" aal1 "select count(*) from public.billing_payment_consents where business_id = '$B'")" = "0" ] \
  && [ "$(as "$staff" aal1 "select count(*) from public.billing_payment_consents")" = "0" ] \
  && [ "$(as "$STAFF_B" aal1 "select count(*) from public.billing_payment_consents where business_id = '$B'")" = "0" ] \
  && ok "only the business's owner reads its agreements (another owner, a team member elsewhere, and this business's own team member see none)" || bad "consent read"
[ "$(q "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub', '$U', 'role', 'authenticated')::text, false); insert into public.billing_payment_consents (business_id, payment_kind, payment_id, consent_text, consent_sha256, terms_version, amount_today_minor, recurring) values ('$B', 'pack', gen_random_uuid(), repeat('x', 50), repeat('a', 64), 'x', 0, false)" 2>&1 | grep -c 'permission denied')" = "1" ] \
  && ok "no client writes to the agreements" || bad "consent write"
open_session "$c1" A1
[ "$(q "select status from public.billing_checkouts where id = '$c1'")" = "open" ] \
  && [ "$(q "select jsonb_array_length(body -> 'line_items') || ',' || (body -> 'line_items')::text || ',' || (body #>> '{metadata,addons}') from public.billing_outbox where kind = 'checkout_session' and business_id = '$B'")" \
       = '4,[{"price": "price_A1", "quantity": 1}, {"price": "price_A1s", "quantity": 1}, {"price": "price_A1_minutes_100", "quantity": 1}, {"price": "price_A1_texts_500", "quantity": 1}],minutes_100,texts_500' ] \
  && [ "$(q "select string_agg(idempotency_key || '=' || (body ->> 'unit_amount'), ',' order by idempotency_key) from public.billing_outbox where kind = 'addon_price' and business_id = '$B'")" = "$(q "select string_agg('price:addon:' || id || '=' || price_cents, ',' order by 'price:addon:' || id) from public.billing_checkout_addons where checkout_id = '$c1'")" ] \
  && ok "one Checkout Session: the plan, the setup fee and each pack as a one time Price (key price:addon:<id>, body stored), the selection in its metadata" || bad "session body: $(q "select body from public.billing_outbox where kind = 'checkout_session' and business_id = '$B'")"
[ "$(apply checkout.session.completed "$(completed cs_A1 cus_A1 sub_A1 '"addons": "minutes_100"')")" = "quarantined" ] \
  && [ "$(q "select count(*) from public.billing_quarantine where reason like 'checkout add ons differ%'")" = "1" ] && ok "a session whose metadata names other add ons than ours is quarantined" || bad "metadata mismatch"
[ "$(apply checkout.session.completed "$(completed cs_A1 cus_A1 sub_A1 '"addons": "minutes_100,texts_500"')")" = "applied" ] && ok "the session with our add ons links Stripe's subscription" || bad "completed"
INV=$(paid in_A1 cus_A1 sub_A1 94500 "$(line 24900 price_A1), $(line 64900 price_A1s), $(line 2900 price_A1_minutes_100), $(line 1800 price_A1_texts_500)")
[ "$(apply invoice.paid "$INV")" = "applied" ] \
  && [ "$(q "select string_agg(p.pack_code || ':' || p.status || ':' || k.granted, ',' order by p.pack_code) from public.pack_purchases p join public.allowance_buckets k on k.pack_purchase_id = p.id where p.business_id = '$B' and p.source = 'checkout_addon'")" = "minutes_100:granted:100,texts_500:granted:500" ] \
  && [ "$(q "select status from public.billing_checkouts where id = '$c1'")" = "paid" ] && ok "plan plus 2 packs paid: both packs granted from the verified, bound first invoice" || bad "grant: $(q "select error from public.billing_events order by received_at desc limit 1")"
[ "$(apply invoice.paid "$INV")" = "applied" ] && [ "$(q "select count(*) from public.pack_purchases where business_id = '$B' and source = 'checkout_addon'")|$(q "select count(*) from public.allowance_buckets k join public.pack_purchases p on p.id = k.pack_purchase_id where p.business_id = '$B'")" = "2|2" ] \
  && ok "a replayed invoice.paid grants nothing more (exactly once)" || bad "replay"

# ---- a selection changed mid session ----
biz "Add Ons Two" 0
cA=$(start key-change-0001 '{minutes_100}' "$(hx "$(ctext "'plan', 27800, true, 24900, 2900")")"); open_session "$cA" B1
[ "$(start key-change-0001 '{texts_500}' "$(hx "$(ctext "'plan', 26700, true, 24900, 1800")")" true status)" = "expiring" ] \
  && [ "$(q "select count(*) from public.billing_outbox where idempotency_key = 'checkoutexpire:$cA' and status = 'pending'")" = "1" ] \
  && [ "$(q "select count(*) from public.billing_checkouts where business_id = '$B'")" = "1" ] \
  && ok "the selection changed while a session is open: that session is expired at Stripe first, and no second one opens meanwhile" || bad "expiring"
send1 "$B" "cs_B1" '{"status": "expired"}' > /dev/null
cB=$(start key-change-0001 '{texts_500}' "$(hx "$(ctext "'plan', 26700, true, 24900, 1800")")")
[ -n "$cB" ] && [ "$cB" != "$cA" ] && [ "$(q "select status from public.billing_checkouts where id = '$cA'")|$(q "select first_amount_minor from public.billing_checkouts where id = '$cB'")" = "expired|26700" ] \
  && ok "once Stripe expired it, the new selection gets a new checkout at its own amount" || bad "new checkout: $cB"
open_session "$cB" B2
[ "$(apply checkout.session.completed "$(completed cs_B2 cus_B1 sub_B2 '"addons": "texts_500"')")" = "applied" ] \
  && [ "$(apply invoice.paid "$(paid in_B2 cus_B1 sub_B2 26700 "$(line 24900 price_B1), $(line 1800 price_B2_texts_500)")")" = "applied" ] \
  && [ "$(q "select string_agg(pack_code, ',') from public.pack_purchases where business_id = '$B'")" = "texts_500" ] \
  && ok "only the new session's add ons are granted; the expired one's never are" || bad "changed selection grant"

# ---- a price that differs, a pack no longer on offer: quarantined, nothing granted ----
biz "Add Ons Three" 0
cC=$(start key-price-00001 '{minutes_100}' "$(hx "$(ctext "'plan', 27800, true, 24900, 2900")")"); open_session "$cC" C1
apply checkout.session.completed "$(completed cs_C1 cus_C1 sub_C1 '"addons": "minutes_100"')" > /dev/null
[ "$(apply invoice.paid "$(paid in_C1 cus_C1 sub_C1 27800 "$(line 25300 price_C1), $(line 2500 price_C1_minutes_100)")")" = "quarantined" ] \
  && [ "$(q "select count(*) from public.billing_quarantine where reason like 'add on minutes_100 is not on the invoice once at its price%'")" = "1" ] \
  && [ "$(q "select count(*) from public.alerts_stub a join public.billing_quarantine x on a.dedupe = 'billing_quarantine:' || x.id where a.kind = 'billing_quarantine' and x.reason like 'add on minutes_100 is not%'")" = "1" ] \
  && [ "$(q "select count(*) from public.pack_purchases where business_id = '$B'")|$(q "select status from public.billing_checkouts where id = '$cC'")" = "0|completed" ] \
  && ok "a price mismatch (the pack line at \$25, the total unchanged) is quarantined with an alert: nothing granted, the checkout not paid" || bad "price mismatch: $(q "select count(*) from public.billing_quarantine where reason like 'add on minutes_100%'") $(q "select count(*) from public.alerts_stub where kind = 'billing_quarantine' and business_id = '$B'") $(q "select count(*) from public.pack_purchases where business_id = '$B'")|$(q "select status from public.billing_checkouts where id = '$cC'")"
q "update public.billing_pack_catalog set price_cents = 3100 where code = 'minutes_100'" > /dev/null
[ "$(apply invoice.paid "$(paid in_C1 cus_C1 sub_C1 27800 "$(line 24900 price_C1), $(line 2900 price_C1_minutes_100)")")" = "quarantined" ] && ok "the catalogue's price changed since the start: quarantined for a person, never guessed" || bad "catalogue price"
q "update public.billing_pack_catalog set price_cents = 2900, active = false where code = 'minutes_100'" > /dev/null
[ "$(apply invoice.paid "$(paid in_C1 cus_C1 sub_C1 27800 "$(line 24900 price_C1), $(line 2900 price_C1_minutes_100)")")" = "quarantined" ] && ok "a pack no longer on offer: quarantined" || bad "inactive pack"
q "update public.billing_pack_catalog set active = true where code = 'minutes_100'" > /dev/null
[ "$(apply invoice.paid "$(paid in_C1 cus_C1 sub_C1 27800 "$(line 24900 price_C1)")")" = "quarantined" ] && ok "the invoice without the agreed pack: quarantined (the amount check too)" || bad "missing pack line"
[ "$(apply invoice.paid "$(paid in_C1 cus_C1 sub_C1 27800 "$(line 24900 price_C1), $(line 2900 price_C1_minutes_100)")")" = "applied" ] && [ "$(q "select count(*) from public.pack_purchases where business_id = '$B'")" = "1" ] \
  && ok "the verified invoice at our prices grants it, once" || bad "after quarantine"
[ "$(q "select public.zella_stripe_bind_lines('{\"total\": 2900, \"lines\": {\"data\": [$(line 2900 price_C1_minutes_100)]}}'::jsonb, '$B')" 2>&1 | grep -c "BINDING: line price price_C1_minutes_100 is not our plan price")" = "1" ] \
  && ok "a renewal can never carry an add on: zella_stripe_renewals.sql's line check refuses it (add ons are one time)" || bad "renewal line"

# ---- Pay now: the plan payment, then each add on separately, under the owner's agreement ----
q "update public.billing_invoices set status = 'open', amount_due_minor = 24900, paid_at = null where id = '$open'" > /dev/null
q "update public.billing_outbox set status = 'sent' where business_id = '$b' and status in ('pending', 'retry_wait')" > /dev/null
ADD='[{"code": "minutes_100", "key": "pay-now-key-a1"}, {"code": "texts_500", "key": "pay-now-key-b1"}]'
TP=$(ctext "'invoice', 24900, true, 24900, 4700"); HPN=$(hx "$TP")
pn() { err "$u" aal2 "select public.zella_owner_invoice_pay_start('$open', true, '$1'::jsonb, '$2')"; }
[ "$(pn "$ADD" "$HI")" = "CONSENT_MISMATCH" ] && ok "Pay now with add ons: the words without them are refused" || bad "pay now mismatch"
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$open', true, '$ADD'::jsonb, null)")" = "CONSENT_REQUIRED" ] && ok "Pay now without the agreement is refused" || bad "pay now none"
[ "$(pn '[{"code": "minutes_100", "key": "pay-now-key-a1"}, {"code": "minutes_100", "key": "pay-now-key-a2"}]' "$HPN")" = "INVALID_INPUT" ] \
  && [ "$(pn '[{"code": "nope_1", "key": "pay-now-key-a1"}]' "$HPN")" = "UNKNOWN_PACK" ] && [ "$(pn '[{"code": "minutes_100", "key": "x"}]' "$HPN")" = "INVALID_INPUT" ] \
  && ok "a pack twice, an unknown pack or a bad key is refused" || bad "pay now input"
[ "$(as "$u" aal2 "select (x ->> 'total_minor') || ',' || (x ->> 'amount_due_minor') || ',' || jsonb_array_length(x -> 'addons') from public.zella_owner_invoice_pay_start('$open', true, '$ADD'::jsonb, '$HPN') x")" = "29600,24900,2" ] \
  && [ "$(as "$u" aal2 "select (public.zella_owner_invoice_pay_start('$open', true, '$ADD'::jsonb, '$HPN', true, 'pi_open')) ->> 'stripe_invoice_id'")" = "in_open" ] \
  && [ "$(q "select count(*) from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$open' and consent_sha256 = '$HPN'")" = "1" ] \
  && ok "Pay now: the invoice's own amount is what Stripe takes; the \$296 agreed covers the 2 add ons; recorded once" || bad "pay now start"
[ "$(as "$u" aal1 "select (x ->> 'addons_consent') || ',' || (select string_agg((a ->> 'code') || ':' || coalesce(a ->> 'status', 'none'), ',') from jsonb_array_elements(x -> 'addons') a) from public.zella_owner_invoice_pay_status('$open') x")" = "$HPN,minutes_100:none,texts_500:none" ] \
  && ok "the server lists the add ons agreed with this payment and their keys (a reload resumes them)" || bad "status addons"
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pay-now-key-a1', '$HPN', '$open')")" = "INVOICE_NOT_PAID" ] && ok "an add on is never bought before OUR record says the plan payment is paid" || bad "before paid"
q "update public.billing_invoices set status = 'paid', amount_due_minor = 0, paid_at = now(), payment_intent = 'pi_open' where id = '$open'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pay-now-key-zz', '$HPN', '$open')")" = "CONSENT_MISMATCH" ] \
  && [ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pay-now-key-a1', '$HP', '$open')")" = "CONSENT_MISMATCH" ] \
  && [ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'emails_10000', 'pay-now-key-a1', '$HPN', '$open')")" = "CONSENT_MISMATCH" ] \
  && ok "an add on not named in that agreement, with another key or other words, is refused" || bad "add on consent"
p1=$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pay-now-key-a1', '$HPN', '$open') ->> 'purchase_id'")
p1b=$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'pay-now-key-a1', '$HPN', '$open') ->> 'purchase_id'")
[ -n "$p1" ] && [ "$p1" = "$p1b" ] && [ "$(q "select count(*) from public.billing_outbox where idempotency_key = 'pack:$p1'")" = "1" ] \
  && ok "after the plan payment the first add on is bought once; a double click or a retry with the same key reaches the same purchase and charge" || bad "add on buy: $p1 $p1b"
[ "$(as "$u" aal1 "select (select string_agg((a ->> 'code') || ':' || coalesce(a ->> 'status', 'none'), ',') from jsonb_array_elements(x -> 'addons') a) from public.zella_owner_invoice_pay_status('$open') x")" = "minutes_100:pending,texts_500:none" ] \
  && ok "a reload mid way: the server says the first is being paid and the second not bought yet (the page resumes it with its key)" || bad "reload mid way"
p2=$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'texts_500', 'pay-now-key-b1', '$HPN', '$open') ->> 'purchase_id'")
q "update public.pack_purchases set status = 'failed', failure_reason = 'card_declined', stripe_payment_intent = 'pi_pn2' where id = '$p2'" > /dev/null
[ "$(as "$u" aal1 "select (select string_agg((a ->> 'code') || ':' || coalesce(a ->> 'status', 'none') || ':' || (a ->> 'can_act'), ',') from jsonb_array_elements(x -> 'addons') a) from public.zella_owner_invoice_pay_status('$open') x")" = "minutes_100:pending:false,texts_500:failed:true" ] \
  && [ "$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'texts_500', 'pay-now-key-b1', '$HPN', '$open') ->> 'purchase_id'")" = "$p2" ] \
  && [ "$(q "select count(*) from public.billing_outbox where idempotency_key like 'pack:%' and local_id in ('$p1', '$p2')")" = "2" ] \
  && [ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$open', true, '$ADD'::jsonb, '$HPN')")" = "ALREADY_PAID" ] \
  && ok "a pack failing after the invoice is paid: the plan stays paid, the invoice can't be charged again, a retry with the same key reaches that pack only" || bad "pack fails after invoice"
[ "$(q "select count(*) from public.billing_payment_consents where payment_kind = 'pack' and payment_id in ('$p1', '$p2')")" = "2" ] && ok "each add on carries the agreement it was bought under, once" || bad "add on consent rows"

# ---- the pack page and finishing a pack: the add on's own words ----
H18=$(hx "$(ctext "'pack', 1800, null, null, 0")")
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'emails_10000', 'pack-page-key-1', '$H18')")" = "CONSENT_MISMATCH" ] && ok "the pack page: words for another amount are refused" || bad "pack page mismatch"
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'emails_10000', 'pack-page-key-1', null)")" = "CONSENT_REQUIRED" ] && ok "the pack page: refused without the agreement" || bad "pack page none"
p3=$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'emails_10000', 'pack-page-key-1', '$(hx "$(ctext "'pack', 2500, null, null, 0")")') ->> 'purchase_id'")
[ -n "$p3" ] && [ "$(q "select count(*) || ',' || min(amount_today_minor) || ',' || bool_or(recurring) from public.billing_payment_consents where payment_kind = 'pack' and payment_id = '$p3'")" = "1,2500,false" ] \
  && ok "the pack page with the add on's own words: bought, the agreement recorded (one time, nothing recurring)" || bad "pack page"
[ "$(q "set role authenticated; select public.zella_owner_pack_buy('$b', 'emails_10000', 'pack-page-key-2')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "the three argument pack buy is server only now" || bad "old pack grant"
[ "$(err "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$p2', 'not-a-hash')")" = "CONSENT_REQUIRED" ] && [ "$(err "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$p2', '$HP')")" = "CONSENT_MISMATCH" ] \
  && [ "$(as "$u" aal2 "select public.zella_owner_pack_act_start('$b', '$p2', '$H18') ->> 'payment_intent'")" = "pi_pn2" ] \
  && [ "$(q "select count(*) from public.billing_payment_consents where payment_kind = 'pack_act' and payment_id = '$p2'")" = "1" ] \
  && ok "finishing a pack in Stripe's form needs the agreement for its own amount" || bad "pack act consent"

# ---- review fixes: Auto pay pending, the checkout's off choice after linking, the card changed on Stripe's page ----
sid=$(q "select id from public.subscriptions where business_id = '$b'")
q "update public.subscriptions set desired_autopay = true, metadata = metadata || '{\"collection_method\": \"charge_automatically\"}' where id = '$sid';
   insert into public.billing_outbox (business_id, kind, idempotency_key, method, path, body, local_kind, local_id, status) values ('$b', 'autopay', 'autopay:sub_P1:9:1', 'POST', '/v1/subscriptions/sub_P1', '{\"collection_method\": \"send_invoice\", \"days_until_due\": 3}', 'subscription', '$sid', 'sending')" > /dev/null
[ "$(as "$u" aal1 "select (x ->> 'on') || ',' || (x ->> 'desired') || ',' || (x ->> 'pending') from public.zella_owner_autopay_status('$b') x")" = "true,true,true" ] \
  && ok "Auto pay: an older off command still being sent while Stripe and the choice both say on shows as pending (review)" || bad "pending in flight"
q "update public.billing_outbox set status = 'sent' where idempotency_key = 'autopay:sub_P1:9:1'" > /dev/null
[ "$(as "$u" aal1 "select x ->> 'pending' from public.zella_owner_autopay_status('$b') x")" = "false" ] && ok "and not pending once nothing is left to land" || bad "pending cleared"
q "set role service_role; select public.zella_billing_checkout_autopay('00000000-0000-4000-8000-0000000000c3', '$co', false)" > /dev/null
[ "$(q "select desired_autopay::text from public.subscriptions where business_id = '00000000-0000-4000-8000-0000000000c3'")|$(q "select count(*) from public.billing_outbox where idempotency_key like 'autopay:sub_P3:%' and status = 'pending'")" = "false|1" ] \
  && ok "an off choice saved after Stripe's subscription was linked goes to the subscription and its command, never lost (review)" || bad "late off choice"
q "update public.subscriptions set desired_autopay = null where business_id = '00000000-0000-4000-8000-0000000000c3'; update public.billing_outbox set status = 'sent' where kind = 'autopay'" > /dev/null
[ "$(q "select 'customer.updated' = any (public.zella_stripe_event_types())")" = "t" ] && ok "customer.updated is now one of the events we take" || bad "event types"
cu() { echo "{\"id\": \"$1\", \"object\": \"customer\", \"livemode\": false, \"invoice_settings\": {\"default_payment_method\": \"$2\"}}"; }
apply customer.updated "$(cu cus_P1 pm_P9)" > /dev/null
[ "$(q "select count(*) || ',' || min(body::text) || ',' || min(path) || ',' || bool_and(idempotency_key like 'defaultpm:sub_P1:%') from public.billing_outbox where kind = 'default_pm'")" = '1,{"default_payment_method": "pm_P9"},/v1/subscriptions/sub_P1,true' ] \
  && ok "a new default card on our customer (Stripe's card page): one command makes it the subscription's card for renewals, key and body stored (review)" || bad "default pm: $(q "select error from public.billing_events where type = 'customer.updated' order by received_at desc limit 1")"
apply customer.updated "$(cu cus_P1 pm_P9)" > /dev/null
[ "$(q "select count(*) from public.billing_outbox where kind = 'default_pm'")" = "1" ] && ok "the same change again queues nothing more" || bad "default pm twice"
apply customer.updated "$(cu cus_P1 pm_P1)" > /dev/null; apply customer.updated "$(cu cus_nobody pm_P7)" > /dev/null
[ "$(q "select count(*) from public.billing_outbox where kind = 'default_pm'")" = "1" ] && ok "the subscription's own card, or a customer that isn't ours, changes nothing" || bad "default pm ignored"
q "update public.billing_outbox set status = 'sent' where kind = 'default_pm'" > /dev/null
# card A, then B, then A again (review round 2): three commands, and the subscription ends on A. Stripe's
# customer.subscription.updated records each card after its command (our record never changes from our own command).
sev() { local e; e=$(ev_row customer.subscription.updated sub_P1); q "select public.zella_stripe_on_customer_subscription_updated(e, '{\"id\": \"sub_P1\", \"status\": \"active\", \"collection_method\": \"charge_automatically\", \"default_payment_method\": \"$1\"}'::jsonb) from public.billing_events e where e.id = '$e'" > /dev/null; }
sev pm_P9
for pm in pm_PA pm_PB pm_PA; do
  apply customer.updated "$(cu cus_P1 $pm)" > /dev/null
  q "update public.billing_outbox set status = 'sent' where kind = 'default_pm' and status = 'pending'" > /dev/null
  sev $pm
done
[ "$(q "select count(*) || ',' || string_agg(body ->> 'default_payment_method', ',' order by created_at) from public.billing_outbox where kind = 'default_pm' and body ->> 'default_payment_method' <> 'pm_P9'")" = "3,pm_PA,pm_PB,pm_PA" ] \
  && [ "$(q "select metadata ->> 'default_payment_method' from public.subscriptions where business_id = '$b'")" = "pm_PA" ] \
  && ok "card A, then B, then A again: three commands sent (keyed by the event), the subscription ends on A (review round 2)" || bad "A B A: $(q "select string_agg(idempotency_key || '=' || status, ' ') from public.billing_outbox where kind = 'default_pm'")"
apply customer.updated "$(cu cus_P1 pm_PC)" > /dev/null; apply customer.updated "$(cu cus_P1 pm_PD)" > /dev/null
[ "$(q "select string_agg(body ->> 'default_payment_method' || ':' || status, ',' order by created_at) from public.billing_outbox where kind = 'default_pm' and body ->> 'default_payment_method' in ('pm_PC', 'pm_PD')")" = "pm_PC:cancelled,pm_PD:pending" ] \
  && ok "two cards set quickly: the latest wins, the older one waiting is never sent" || bad "latest card wins"
q "update public.billing_outbox set status = 'sent' where kind = 'default_pm' and status = 'pending'" > /dev/null

# ---- two tabs, different add ons, the first one pays (review round 2) ----
q "update public.pack_purchases set status = 'granted' where business_id = '$b' and status = 'pending'" > /dev/null   # earlier packs settled
q "insert into public.billing_invoices (id, business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor) values ('00000000-0000-4000-8000-00000000f001', '$b', 'in_tabs', 'open', 'ZV-0009', 24900, 24900)" > /dev/null
TAB='00000000-0000-4000-8000-00000000f001'
A1='[{"code": "minutes_100", "key": "tab-one-key-001"}]'; A2='[{"code": "texts_500", "key": "tab-two-key-001"}]'
H1=$(hx "$(ctext "'invoice', 24900, true, 24900, 2900")"); H2=$(hx "$(ctext "'invoice', 24900, true, 24900, 1800")")
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$TAB', true, '$A2'::jsonb, '$H2')" > /dev/null    # tab two opens the form first
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$TAB', true, '$A1'::jsonb, '$H1', true, 'pi_TAB')" > /dev/null   # tab one presses Pay
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$TAB', true, '$A2'::jsonb, '$H2', true, 'pi_TAB')")" = "ADDONS_IN_PROGRESS" ] \
  && ok "two tabs: while the first tab's payment may be in flight, Pay in the other tab with other add ons is refused" || bad "second tab submit"
[ "$(as "$u" aal1 "select (x ->> 'addons_consent') || ',' || (select string_agg(a ->> 'code', ',') from jsonb_array_elements(x -> 'addons') a) from public.zella_owner_invoice_pay_status('$TAB') x")" = "$H1,minutes_100" ] \
  && ok "the add ons listed are the paying tab's, not the newest agreement's" || bad "listed agreement"
q "update public.billing_invoices set status = 'paid', amount_due_minor = 0, paid_at = now(), payment_intent = 'pi_TAB' where id = '$TAB'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'texts_500', 'tab-two-key-001', '$H2', '$TAB')")" = "CONSENT_MISMATCH" ] \
  && ok "the other tab's add ons are never bought" || bad "other tab bought"
t1=$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'tab-one-key-001', '$H1', '$TAB') ->> 'purchase_id'")
t1b=$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'tab-one-key-001', '$H1', '$TAB') ->> 'purchase_id'")
[ -n "$t1" ] && [ "$t1" = "$t1b" ] && [ "$(q "select count(*) from public.pack_purchases where idempotency_key in ('tab-one-key-001', 'tab-two-key-001')")" = "1" ] \
  && ok "exactly the first tab's add ons are bought, once" || bad "first tab add ons: $t1 $t1b"
# an attempt Stripe says failed frees the add ons for a new choice
q "insert into public.billing_invoices (id, business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor) values ('00000000-0000-4000-8000-00000000f002', '$b', 'in_tabs2', 'open', 'ZV-0010', 24900, 24900)" > /dev/null
T2='00000000-0000-4000-8000-00000000f002'
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T2', true, '$A1'::jsonb, '$H1', true, 'pi_T2')" > /dev/null
q "set role service_role; select public.zella_billing_invoice_attempts_clear('$T2', 'pi_T2', now())" > /dev/null
[ "$(as "$u" aal2 "select jsonb_array_length(x -> 'addons') from public.zella_owner_invoice_pay_start('$T2', true, '$A2'::jsonb, '$H2', true, 'pi_T2') x")" = "1" ] \
  && [ "$(as "$u" aal1 "select (select string_agg(a ->> 'code', ',') from jsonb_array_elements(x -> 'addons') a) from public.zella_owner_invoice_pay_status('$T2') x")" = "texts_500" ] \
  && ok "once Stripe says the first attempt failed, the new choice goes ahead and is the one bought" || bad "attempt cleared"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_billing_invoice_attempts_clear(uuid,text,timestamptz)', 'execute')")" = "f" ] && ok "clearing an attempt is server only" || bad "clear grant"

# ---- review round 3: an agreement is its exact add ons, keys and prices, not only its words ----
q "update public.pack_purchases set status = 'granted' where business_id = '$b' and status = 'pending';
   insert into public.billing_pack_catalog values ('texts_900', 'texts', 900, 2900, true)" > /dev/null
q "insert into public.billing_invoices (id, business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor) values ('00000000-0000-4000-8000-00000000f003', '$b', 'in_tabs3', 'open', 'ZV-0011', 24900, 24900)" > /dev/null
T3='00000000-0000-4000-8000-00000000f003'
R1='[{"code": "minutes_100", "key": "r3-one-key-0001"}]'; R3='[{"code": "texts_900", "key": "r3-three-key-01"}]'   # the same total: the same words
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T3', true, '$R1'::jsonb, '$H1', true, 'pi_T3')" > /dev/null   # tab one presses Pay
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T3', true, '$R3'::jsonb, '$H1')" > /dev/null         # tab three opens the form
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$T3', true, '$R3'::jsonb, '$H1', true, 'pi_T3')")" = "ADDONS_IN_PROGRESS" ] \
  && [ "$(q "select count(*) || ',' || count(*) filter (where submitted_at is not null) from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$T3'")" = "2,1" ] \
  && [ "$(q "select addons ->> 0 from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$T3' and submitted_at is not null")" = '{"key": "r3-one-key-0001", "code": "minutes_100", "quantity": 100, "resource": "minutes", "price_cents": 2900}' ] \
  && ok "other add ons with the same total (the same words) are their own agreement: they never reuse or overwrite the first, and wait while it may be paying" || bad "same total: $(q "select count(*) from public.billing_payment_consents where payment_id = '$T3'")"
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T3', true, '$R1'::jsonb, '$H1', true, 'pi_T3')" > /dev/null
[ "$(q "select count(*) from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$T3'")" = "2" ] && ok "the same payload again (a retry) reaches its own agreement, nothing new" || bad "retry agreement"
q "update public.billing_invoices set status = 'paid', amount_due_minor = 0, paid_at = now(), payment_intent = 'pi_T3' where id = '$T3'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'texts_900', 'r3-three-key-01', '$H1', '$T3')")" = "CONSENT_MISMATCH" ] \
  && ok "the same words can't buy the add ons of the agreement that didn't pay" || bad "same words other pack"
q "update public.billing_pack_catalog set price_cents = 3100 where code = 'minutes_100'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'r3-one-key-0001', '$H1', '$T3')")" = "CONSENT_MISMATCH" ] \
  && [ "$(q "select count(*) from public.pack_purchases where idempotency_key = 'r3-one-key-0001'")" = "0" ] && ok "a pack whose price changed since the agreement is not bought at the new price" || bad "price binding"
q "update public.billing_pack_catalog set price_cents = 2900 where code = 'minutes_100'" > /dev/null
[ -n "$(as "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'r3-one-key-0001', '$H1', '$T3') ->> 'purchase_id'")" ] && ok "at the agreed price, the agreed pack and key are bought" || bad "agreed pack"
# the clear is bound to the failed attempt: the invoice's own intent, and only Pay presses up to its failure
q "update public.pack_purchases set status = 'granted' where business_id = '$b' and status = 'pending';
   insert into public.billing_invoices (id, business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor, payment_intent) values ('00000000-0000-4000-8000-00000000f004', '$b', 'in_tabs4', 'open', 'ZV-0012', 24900, 24900, 'pi_T4')" > /dev/null
T4='00000000-0000-4000-8000-00000000f004'
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T4', true, '$A1'::jsonb, '$H1', true, 'pi_T4')" > /dev/null
[ "$(q "set role service_role; select public.zella_billing_invoice_attempts_clear('$T4', 'pi_T4', now() - interval '1 hour')")" = "0" ] \
  && [ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$T4', true, '$A2'::jsonb, '$H2', true, 'pi_T4')")" = "ADDONS_IN_PROGRESS" ] \
  && ok "a Pay pressed after the failed attempt (a retry that may be paying) is never cleared" || bad "clear after failure"
[ "$(q "set role service_role; select public.zella_billing_invoice_attempts_clear('$T4', 'pi_other', now())")" = "0" ] && ok "another intent than the invoice's clears nothing" || bad "clear other intent"
[ "$(q "set role service_role; select public.zella_billing_invoice_attempts_clear('$T4', 'pi_T4', now())")" = "1" ] \
  && [ -n "$(as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T4', true, '$A2'::jsonb, '$H2', true, 'pi_T4') ->> 'invoice_id'")" ] \
  && ok "the invoice's own intent, failed after that Pay: cleared, and the new choice goes ahead" || bad "bound clear"
q "update public.billing_invoices set status = 'paid' where id = '$T4'" > /dev/null
[ "$(q "set role service_role; select public.zella_billing_invoice_attempts_clear('$T4', 'pi_T4', now())")" = "0" ] && ok "a paid invoice: nothing cleared" || bad "clear paid"
[ "$("${P[@]}" -d "$DB" -c "set role service_role; select public.zella_billing_invoice_attempts_clear('$T4', null, now())" 2>&1 | grep -c 'INVALID_INPUT')" = "1" ] && ok "a clear names its intent and its failure time" || bad "clear input"
# the onboarding checkout reads the selected packs once: a price changed before the start is refused with the old words, nothing made
biz "Add Ons Snapshot" 0
HS=$(hx "$(ctext "'plan', 27800, true, 24900, 2900")")
q "update public.billing_pack_catalog set price_cents = 3100 where code = 'minutes_100'" > /dev/null
[ "$(start_e key-snap-000001 '{minutes_100}' true "'$HS'")" = "CONSENT_MISMATCH" ] \
  && [ "$(q "select count(*) from public.billing_checkouts where business_id = '$B'")|$(q "select count(*) from public.billing_checkout_addons where business_id = '$B'")" = "0|0" ] \
  && ok "the catalogue's price changed since the owner agreed: the checkout is refused before any Stripe session, nothing created" || bad "snapshot refused"
cS=$(start key-snap-000001 '{minutes_100}' "$(hx "$(ctext "'plan', 28000, true, 24900, 3100")")")
[ -n "$cS" ] && [ "$(q "select c.first_amount_minor || ',' || a.price_cents || ',' || k.amount_today_minor from public.billing_checkouts c join public.billing_checkout_addons a on a.checkout_id = c.id join public.billing_payment_consents k on k.payment_id = c.id where c.id = '$cS'")" = "28000,3100,28000" ] \
  && ok "the total, the add on line and the agreement all come from the same read of the catalogue" || bad "snapshot same: $cS"
q "update public.billing_pack_catalog set price_cents = 2900 where code = 'minutes_100'; delete from public.billing_pack_catalog where code = 'texts_900';
   update public.billing_checkouts set status = 'expired' where id = '$cS'" > /dev/null

# ---- review round 4: the press names its intent; add ons only from the confirmed payment's agreement ----
q "update public.pack_purchases set status = 'granted' where business_id = '$b' and status = 'pending'" > /dev/null
inv4() { q "insert into public.billing_invoices (id, business_id, stripe_invoice_id, status, number, total_minor, amount_due_minor) values ('$1', '$b', 'in_$2', 'open', 'ZV-$2', 24900, 24900)" > /dev/null; }
T5='00000000-0000-4000-8000-00000000f005'; inv4 "$T5" 5005
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$T5', true, '$A1'::jsonb, '$H1', true)")" = "INVALID_INPUT" ] && ok "a Pay press names the intent it confirms" || bad "press without intent"
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$T4', true, '$A1'::jsonb, '$H1', true, 'pi_not_T4')")" = "ALREADY_PAID" ] && ok "a paid invoice takes no press" || bad "press paid"
q "update public.billing_invoices set payment_intent = 'pi_T5known' where id = '$T5'" > /dev/null
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$T5', true, '$A1'::jsonb, '$H1', true, 'pi_other')")" = "NOT_PAYABLE" ] && ok "a press with another intent than the invoice's known one is refused" || bad "press other intent"
q "update public.billing_invoices set payment_intent = null where id = '$T5'" > /dev/null
# the moment of the press, not the transaction's start
[ "$(as "$u" aal2 "select pg_sleep(1); select public.zella_owner_invoice_pay_start('$T5', true, '$A1'::jsonb, '$H1', true, 'pi_T5') is not null; select (select submitted_at from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$T5' and submitted_at is not null) > now() + interval '900 milliseconds'" | tail -1)" = "t" ] \
  && ok "the press time is when it ran (clock_timestamp), not when its transaction began" || bad "clock_timestamp"
[ "$(q "select payment_intent from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$T5' and submitted_at is not null")" = "pi_T5" ] && ok "the agreement records the intent it went with" || bad "intent recorded"
# paid by ANOTHER intent than the one the agreement went with: its add ons are not bought, and none are listed to retry
q "update public.billing_invoices set status = 'paid', amount_due_minor = 0, paid_at = now(), payment_intent = 'pi_T5other' where id = '$T5'" > /dev/null
[ "$(as "$u" aal1 "select jsonb_array_length(x -> 'addons') || ',' || coalesce(x ->> 'addons_consent', 'none') from public.zella_owner_invoice_pay_status('$T5') x")" = "0,none" ] \
  && [ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'tab-one-key-001', '$H1', '$T5')")" = "CONSENT_MISMATCH" ] \
  && ok "add ons come only from the agreement tied to the confirmed payment: another intent paid, nothing listed or bought" || bad "other intent paid"
q "update public.billing_invoices set payment_intent = 'pi_T5' where id = '$T5'" > /dev/null
[ "$(as "$u" aal1 "select (select string_agg(a ->> 'code', ',') from jsonb_array_elements(x -> 'addons') a) from public.zella_owner_invoice_pay_status('$T5') x")" = "minutes_100" ] \
  && ok "paid by the intent the agreement went with: its add ons are listed" || bad "same intent paid"
# an agreement only shown (never pressed) on an invoice paid another way: nothing to buy or retry
T6='00000000-0000-4000-8000-00000000f006'; inv4 "$T6" 5006
as "$u" aal2 "select public.zella_owner_invoice_pay_start('$T6', true, '$A1'::jsonb, '$H1')" > /dev/null
[ "$(as "$u" aal1 "select jsonb_array_length(x -> 'addons') from public.zella_owner_invoice_pay_status('$T6') x")" = "1" ] && ok "before payment the shown add ons are listed as a preview" || bad "preview"
q "update public.billing_invoices set status = 'paid', amount_due_minor = 0, paid_at = now(), payment_intent = 'pi_T6' where id = '$T6'" > /dev/null
[ "$(as "$u" aal1 "select jsonb_array_length(x -> 'addons') from public.zella_owner_invoice_pay_status('$T6') x")" = "0" ] \
  && [ "$(err "$u" aal2 "select public.zella_owner_pack_buy('$b', 'minutes_100', 'tab-one-key-001', '$H1', '$T6')")" = "CONSENT_MISMATCH" ] \
  && ok "an agreement never pressed (auto charge paid it): no add on to buy and no retry offered" || bad "unsubmitted"
# under the lock: the invoice paid meanwhile (another transaction) is seen, nothing submitted
T7='00000000-0000-4000-8000-00000000f007'; inv4 "$T7" 5007
( "${P[@]}" -d "$DB" -c "begin; update public.billing_invoices set status = 'paid', amount_due_minor = 0, payment_intent = 'pi_T7' where id = '$T7'; select pg_sleep(3); commit;" > /dev/null 2>&1 & )
sleep 1
[ "$(err "$u" aal2 "select public.zella_owner_invoice_pay_start('$T7', true, '$A1'::jsonb, '$H1', true, 'pi_T7')")" = "ALREADY_PAID" ] \
  && [ "$(q "select count(*) from public.billing_payment_consents where payment_kind = 'invoice' and payment_id = '$T7' and submitted_at is not null")" = "0" ] \
  && ok "paid while the press waited for the invoice's lock: refused under the lock, nothing submitted" || bad "lock recheck"
sleep 3
# the onboarding checkout: an open session past its expiry, or priced differently now, is never reused
biz "Add Ons Reuse" 0
HR=$(hx "$(ctext "'plan', 27800, true, 24900, 2900")")
cR=$(start key-reuse-00001 '{minutes_100}' "$HR"); open_session "$cR" R1
q "update public.billing_checkouts set expires_at = now() - interval '1 minute' where id = '$cR'" > /dev/null
cR2=$(start key-reuse-00001 '{minutes_100}' "$HR")
[ -n "$cR2" ] && [ "$cR2" != "$cR" ] && [ "$(q "select status from public.billing_checkouts where id = '$cR'")" = "expired" ] \
  && ok "the same key after the session expired: marked expired and a new checkout made" || bad "expired reuse: $cR $cR2"
open_session "$cR2" R2
q "update public.billing_pack_catalog set price_cents = 3100 where code = 'minutes_100'" > /dev/null
[ "$(start key-reuse-00001 '{minutes_100}' "$(hx "$(ctext "'plan', 28000, true, 24900, 3100")")" true status)" = "expiring" ] \
  && [ "$(q "select count(*) from public.billing_outbox where idempotency_key = 'checkoutexpire:$cR2' and status = 'pending'")" = "1" ] \
  && ok "a pack's price changed since the session opened: that session is expired at Stripe first, never reused" || bad "amount reuse"
q "update public.billing_pack_catalog set price_cents = 2900 where code = 'minutes_100'; update public.billing_checkouts set status = 'expired' where business_id = '$B';
   update public.billing_outbox set status = 'sent' where idempotency_key like 'checkoutexpire:%'" > /dev/null
# the rollback while add ons agreed with Pay now are still to be bought
q "update public.billing_checkouts set status = 'paid' where id = '$cC'" > /dev/null
[ "$("${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -c 'add ons agreed with Pay now are still to be bought')" = "1" ] && ok "rollback refuses while a paid invoice's agreed add ons are still to be bought" || bad "rollback add ons: $("${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -m1 ERROR)"
q "update public.pack_purchases set status = 'granted' where business_id = '$b' and status = 'pending';
   update public.billing_invoices i set status = 'void' where i.status in ('open', 'payment_failed')
      and exists (select 1 from public.billing_payment_consents k where k.payment_kind = 'invoice' and k.payment_id = i.id and k.submitted_at is not null);
   insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, idempotency_key)
   select distinct on (a ->> 'key') '$b', a ->> 'code', 'minutes', 1, 0, 'cancelled', 'owner_purchase', a ->> 'key'
     from public.billing_payment_consents k cross join lateral jsonb_array_elements(k.addons) a
    where k.payment_kind = 'invoice' and k.submitted_at is not null
      and not exists (select 1 from public.pack_purchases pp where pp.business_id = '$b' and pp.idempotency_key = a ->> 'key')" > /dev/null
[ "$("${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -c 'add ons agreed with Pay now are still to be bought')" = "0" ] && ok "settled agreements (each add on granted, failed or cancelled) never block the rollback" || bad "settled block"
"${P[@]}" -d "$DB" -f "$MIG" > /dev/null 2>&1   # the check above may have rolled back: apply again for the tests below

# ---- rollback refusals added in this round ----
q "update public.billing_checkouts set status = 'open' where id = '$cC'" > /dev/null
[ "$(code "$RB")" = "ROLLBACK_HAS_PENDING" ] && ok "rollback refuses while a checkout with add ons is in progress" || bad "rollback addons in progress"
q "update public.billing_checkouts set status = 'paid' where id = '$cC'" > /dev/null
q "drop trigger zella_billing_checkout_autopay on public.billing_checkouts; create trigger zella_billing_checkout_autopay after update on public.billing_checkouts for each row execute function public.zella_billing_checkout_autopay_trg()" > /dev/null
[ "$(code "$RB")" = "ROLLBACK_DRIFT" ] && ok "rollback refuses a changed Auto pay trigger (review)" || bad "trigger drift"
q "drop trigger zella_billing_checkout_autopay on public.billing_checkouts; create trigger zella_billing_checkout_autopay after update of stripe_subscription_id on public.billing_checkouts for each row execute function public.zella_billing_checkout_autopay_trg()" > /dev/null
( "${P[@]}" -d "$DB" -c "begin; select id from public.subscriptions where business_id = '$b' for update; select pg_sleep(4); commit;" > /dev/null 2>&1 & )
sleep 1
[ "$(PGOPTIONS='-c lock_timeout=800' "${P[@]}" -d "$DB" -f "$RB" 2>&1 | grep -c 'lock timeout')" -ge 1 ] && [ "$(q "select count(*) from pg_trigger where tgname = 'zella_billing_checkout_autopay'")" = "1" ] \
  && ok "rollback takes a write barrier first: while an Auto pay change holds the subscription it waits, and changes nothing meanwhile (review)" || bad "write barrier"
sleep 4
