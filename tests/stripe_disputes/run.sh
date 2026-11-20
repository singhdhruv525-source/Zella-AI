#!/usr/bin/env bash
# sql/zella_stripe_disputes.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: a chargeback is stored but nothing records it or suspends the account. Then: apply, apply again, rollback
# twice, apply again, drift refused; a dispute suspends the account once, saving the earlier state; a second dispute
# never overwrites it; winning one while another is open keeps the suspension; winning the last restores the saved
# state; a loss is posted once and stays suspended; funds withdrawn and reinstated post once each; admins with
# billing.view read the list, others are refused.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_disputes zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Dispute One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 D1
q "update public.subscriptions set status = 'past_due', past_due_since = now() where business_id = '$b'" > /dev/null
q "insert into public.payments (business_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at, metadata) values ('$b', 299, 29900, 'usd', 'succeeded', 'stripe', 'pi_D1', now(), '{\"bound\":true}'), ('$b', 29, 2900, 'usd', 'succeeded', 'stripe', 'pi_D2', now(), '{\"bound\":true}')" > /dev/null
ro=f4000000-0000-0000-0000-000000000001; q "insert into auth.users (id, email) values ('$ro', 'ro@dispute.test'); insert into public.platform_admins (user_id, role) values ('$ro', 'read_only_admin'); insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'billing.view') on conflict do nothing" > /dev/null
dp() { echo "{\"id\":\"$1\",\"object\":\"dispute\",\"status\":\"$2\",\"amount\":$3,\"currency\":\"usd\",\"payment_intent\":\"$4\",\"reason\":\"fraudulent\",\"evidence_details\":{\"due_by\":$(( $(date +%s) + 604800 ))},\"livemode\":false}"; }
zf_apply evt_d0 charge.dispute.created "$(dp dp_D0 needs_response 29900 pi_D1)" > /dev/null
[ "$(q "select status from public.subscriptions where business_id = '$b'")" = "past_due" ] && ok "before: a chargeback changed nothing" || bad "before"
zf_cycle zella_stripe_disputes zella_stripe_disputes_rollback 'public.zella_admin_disputes(integer)' '^zella_(stripe_(dispute_record|on_charge_dispute)|admin_disputes)'
st() { q "select status || ',' || coalesce(metadata ->> 'saved_status', '-') from public.subscriptions where business_id = '$b'"; }
[ "$(zf_apply evt_d1 charge.dispute.created "$(dp dp_D1 needs_response 29900 pi_D1)")" = "applied" ] && [ "$(st)" = "suspended_dispute,past_due" ] && ok "a dispute suspends the account and saves the earlier state" || bad "suspend: $(st)"
[ "$(q "select count(*) from public.platform_alerts where kind = 'payment_disputed'")" = "1" ] && ok "an urgent alert with the respond by date" || bad "alert"
zf_apply evt_d2 charge.dispute.created "$(dp dp_D2 needs_response 2900 pi_D2)" > /dev/null
[ "$(st)" = "suspended_dispute,past_due" ] && ok "a second dispute never overwrites the saved state" || bad "second: $(st)"
zf_apply evt_d3 charge.dispute.created "$(dp dp_D1 needs_response 29900 pi_D1)" > /dev/null
[ "$(q "select count(*) from public.billing_disputes")" = "2" ] && ok "a repeated event is one dispute row" || bad "dup"
zf_apply evt_d4 charge.dispute.funds_withdrawn "$(dp dp_D1 needs_response 29900 pi_D1)" > /dev/null; zf_apply evt_d4b charge.dispute.funds_withdrawn "$(dp dp_D1 needs_response 29900 pi_D1)" > /dev/null
[ "$(q "select count(*) || ',' || sum(amount_minor) from public.money_ledger where operation_key like 'dispute:dp_D1:%'")" = "2,0" ] && ok "funds withdrawn posted once, balanced" || bad "withdrawn"
zf_apply evt_d5 charge.dispute.closed "$(dp dp_D1 won 29900 pi_D1)" > /dev/null
[ "$(st)" = "suspended_dispute,past_due" ] && ok "winning one while another is open keeps the suspension" || bad "partial win: $(st)"
zf_apply evt_d6 charge.dispute.funds_reinstated "$(dp dp_D1 won 29900 pi_D1)" > /dev/null
zf_apply evt_d7 charge.dispute.closed "$(dp dp_D2 won 2900 pi_D2)" > /dev/null
[ "$(st)" = "past_due,-" ] && ok "winning the last one restores the saved state" || bad "restore: $(st)"
rein="select string_agg(account || '=' || amount_minor, ',' order by account) from public.money_ledger where operation_key = 'dispute:dp_D1:reinstated'"
[ "$(q "$rein")" = "cash=29900,disputes=-29900" ] && ok "the reinstatement posts exactly cash +29900 and disputes -29900" || bad "reinstated: $(q "$rein")"
zf_apply evt_d6b charge.dispute.funds_reinstated "$(dp dp_D1 won 29900 pi_D1)" > /dev/null
[ "$(q "$rein")" = "cash=29900,disputes=-29900" ] && [ "$(q "select sum(amount_minor) from public.money_ledger where operation_key like 'dispute:%'")" = "0" ] \
  && ok "a repeated reinstatement posts nothing more; withdrawn and reinstated balance out" || bad "ledger"
zf_apply evt_d8 charge.dispute.created "$(dp dp_D3 needs_response 2900 pi_D2)" > /dev/null
zf_apply evt_d9 charge.dispute.closed "$(dp dp_D3 lost 2900 pi_D2)" > /dev/null; zf_apply evt_d9b charge.dispute.closed "$(dp dp_D3 lost 2900 pi_D2)" > /dev/null
[ "$(st | cut -d, -f1)" = "suspended_dispute" ] && [ "$(q "select count(*) from public.money_ledger where operation_key = 'dispute:dp_D3:lost'")" = "2" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'dispute_lost'")" = "1" ] && ok "a loss is posted once and the account stays suspended for a person" || bad "lost"
zf_apply evt_d11 charge.dispute.created "$(dp dp_D5 warning_needs_response 100 pi_D2)" > /dev/null
zf_apply evt_d12 charge.dispute.closed "$(dp dp_D5 won 100 pi_D2)" > /dev/null
[ "$(st | cut -d, -f1)" = "suspended_dispute" ] && ok "winning the last open dispute keeps the suspension while a lost one waits for a person" || bad "unsettled loss: $(st)"
q "update public.billing_disputes set settled_at = now() where stripe_dispute_id = 'dp_D3'" > /dev/null
zf_apply evt_d13 charge.dispute.created "$(dp dp_D6 warning_needs_response 100 pi_D2)" > /dev/null
[ "$(zf_apply evt_d14 charge.dispute.closed "$(dp dp_D6 warning_closed 100 pi_D2)")" = "applied" ] && [ "$(q "select outcome from public.billing_disputes where stripe_dispute_id = 'dp_D6'")" = "warning_closed" ] \
  && [ "$(st | cut -d, -f1)" = "past_due" ] && [ "$(q "select count(*) from public.money_ledger where operation_key like 'dispute:dp_D6:%'")" = "0" ] \
  && ok "an inquiry closed with no chargeback (warning_closed) closes without a loss, and service comes back once the loss is settled" || bad "warning closed: $(st)"
[ "$(zf_apply evt_d10 charge.dispute.created "$(dp dp_D4 needs_response 100 pi_UNKNOWN)")" = "waiting" ] && ok "a dispute for a payment not recorded yet waits" || bad "waiting"
zf_apply evt_d15 charge.dispute.created "$(dp dp_D7 needs_response 100 pi_D2)" > /dev/null
q "update public.billing_disputes set created_at = now() - interval '30 days' where stripe_dispute_id = 'dp_D7'" > /dev/null
[ "$(as_user "$ro" aal2 "select jsonb_array_length(public.zella_admin_disputes(50))")" = "6" ] && [ "$(as_user "$ro" aal2 "select public.zella_admin_disputes(1) -> 0 ->> 'outcome'")" = "open" ] && ok "an admin with billing.view reads the disputes, open ones first even with a limit" || bad "admin"
[ "$(as_user_e "$u" aal2 "select public.zella_admin_disputes(50)")" = "NOT_ALLOWED" ] && ok "a business owner is refused" || bad "owner"
out=$("${P[@]}" -d "$DB" -f "$ZF_REPO/sql/rollback/zella_stripe_disputes_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_HAS_DATA* ]] && ok "the rollback refuses while disputes exist" || bad "rollback data"
echo "$fails failed"; [ "$fails" = 0 ]
