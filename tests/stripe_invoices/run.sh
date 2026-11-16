#!/usr/bin/env bash
# sql/zella_stripe_invoices.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Before: invoice.created and invoice.finalized are stored but nothing records the invoice. Then: apply, apply again,
# rollback twice, apply again, drift refused; created then finalized record one row moving forward (draft, open, with
# number and links); a void never undoes a paid invoice; a deleted event acts only on our draft; an invoice that isn't
# ours is quarantined; admins with billing.view read every invoice, a business's owner only theirs, others nothing.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../stripe_pipeline/lib.sh"
zf_build zlf_t_invoices zella_stripe_pipeline zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel
q "update public.platform_settings set value = 'true' where key = 'payments_live'" > /dev/null
b=$(zf_business "Invoice One"); u=$(owner_of "$b"); plan=$(zf_plan "$b" 29900 0); zf_active "$b" "$plan" 29900 I1
b2=$(zf_business "Invoice Two"); u2=$(owner_of "$b2")
ro=f2000000-0000-0000-0000-000000000001; sup=f2000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email) values ('$ro', 'ro@inv.test'), ('$sup', 'support@inv.test'); insert into public.platform_admins (user_id, role) values ('$ro', 'read_only_admin'), ('$sup', 'support_admin');
   insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'billing.view'), ('support_admin', 'support.manage') on conflict do nothing" > /dev/null
inv() { echo "{\"id\":\"$1\",\"object\":\"invoice\",\"status\":\"$2\",\"currency\":\"usd\",\"number\":${3:-null},\"amount_paid\":0,\"amount_due\":29900,\"total\":29900,\"customer\":\"${4:-cus_I1}\",\"billing_reason\":\"subscription_cycle\",\"livemode\":false,\"created\":$(date +%s),\"hosted_invoice_url\":${5:-null},\"parent\":{\"subscription_details\":{\"subscription\":\"sub_I1\"}},\"lines\":{\"data\":[{\"amount\":29900,\"pricing\":{\"price_details\":{\"price\":\"price_I1\"}}}],\"has_more\":false}}"; }
zf_apply evt_i0 invoice.created "$(inv in_I0 draft)" > /dev/null
[ "$(q "select count(*) from public.billing_invoices")" = "0" ] && ok "before: a new invoice was not recorded" || bad "before"
zf_cycle zella_stripe_invoices zella_stripe_invoices_rollback 'public.zella_admin_invoices(uuid,text,integer)' '^zella_(stripe_(invoice_record|on_invoice_(created|finalized|voided|deleted))|admin_invoices|owner_invoices)'
[ "$(zf_apply evt_i1 invoice.created "$(inv in_I1 draft)")" = "applied" ] && [ "$(q "select status from public.billing_invoices where stripe_invoice_id = 'in_I1'")" = "draft" ] && ok "invoice.created records a draft" || bad "created"
zf_apply evt_i2 invoice.finalized "$(inv in_I1 open '"ZV-0001"' cus_I1 '"https://invoice.example.test/in_I1"')" > /dev/null
[ "$(q "select status || ',' || number || ',' || hosted_invoice_url || ',' || total_minor from public.billing_invoices where stripe_invoice_id = 'in_I1'")" = "open,ZV-0001,https://invoice.example.test/in_I1,29900" ] && ok "finalized: open, its number, the hosted page, the total in cents" || bad "finalized"
zf_apply evt_i3 invoice.created "$(inv in_I1 draft)" > /dev/null
[ "$(q "select status from public.billing_invoices where stripe_invoice_id = 'in_I1'")" = "open" ] && ok "a late created event never moves it back to draft" || bad "backwards"
q "update public.billing_invoices set status = 'paid' where stripe_invoice_id = 'in_I1'" > /dev/null
[ "$(zf_apply evt_i4 invoice.voided "$(inv in_I1 paid)")" = "older" ] && [ "$(q "select status from public.billing_invoices where stripe_invoice_id = 'in_I1'")" = "paid" ] && ok "a void fetched as paid never undoes the payment" || bad "void paid"
zf_apply evt_i5 invoice.created "$(inv in_I5 draft)" > /dev/null
[ "$(zf_apply evt_i6 invoice.voided "$(inv in_I5 void)")" = "applied" ] && [ "$(q "select status from public.billing_invoices where stripe_invoice_id = 'in_I5'")" = "void" ] && ok "a voided invoice is recorded as void" || bad "void"
zf_apply evt_i7 invoice.created "$(inv in_I7 draft)" > /dev/null
[ "$(zf_apply evt_i8 invoice.deleted '{"id":"in_I7","object":"invoice","status":"draft","deleted":true,"livemode":false}')" = "applied" ] && [ "$(q "select status from public.billing_invoices where stripe_invoice_id = 'in_I7'")" = "deleted" ] && ok "a deleted draft of ours is marked deleted" || bad "deleted draft"
[ "$(zf_apply evt_i9 invoice.deleted '{"id":"in_I1","object":"invoice","status":"draft","deleted":true,"livemode":false}')" = "quarantined" ] && ok "a deleted event for an invoice we hold as paid is held for a person" || bad "deleted paid"
[ "$(zf_apply evt_i10 invoice.finalized "$(inv in_I10 open null cus_OTHER)")" = "quarantined" ] && ok "an invoice for another customer is quarantined" || bad "foreign"
[ "$(as_user "$ro" aal2 "select jsonb_array_length(public.zella_admin_invoices(null, null, 50))")" = "2" ] && ok "an admin with billing.view reads every invoice (deleted ones hidden)" || bad "admin read"
[ "$(as_user_e "$sup" aal2 "select public.zella_admin_invoices(null, null, 50)")" = "NOT_ALLOWED" ] && ok "an admin without billing.view is refused" || bad "support"
[ "$(as_user "$u" aal2 "select jsonb_array_length(public.zella_owner_invoices('$b'))")" = "2" ] && ok "the owner reads their own issued invoices (drafts hidden)" || bad "owner read"
[ "$(as_user_e "$u2" aal2 "select public.zella_owner_invoices('$b')")" = "NOT_ALLOWED" ] && ok "another business's owner is refused" || bad "other owner"
[ "$(q "set role anon; select public.zella_owner_invoices('$b')" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "anonymous is refused" || bad "anon"
[ "$(as_user "$u" aal2 "select count(*) from public.billing_invoices" 2>&1 | grep -c 'permission denied')" = "1" ] && ok "the table itself is closed to signed in users" || bad "table"
echo "$fails failed"; [ "$fails" = 0 ]
