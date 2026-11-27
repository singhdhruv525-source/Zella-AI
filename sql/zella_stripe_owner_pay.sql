-- Zella Voice: paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now";
-- docs/PAYMENTS_ARCHITECTURE.md §6.11, §6.4). Auto charge stays the default: Stripe charges the saved card on the
-- renewal date (unchanged). This file adds what the owner's own payments need, every one through billing-api:
--   1. zella_owner_invoices (replaced, archived first): each invoice also carries our id, the amount still due and
--      whether Pay now is offered.
--   2. zella_owner_invoice_pay_status / zella_owner_invoice_pay_start: one invoice by our id alone (the emailed Pay now
--      link). The id grants nothing: only the active owner of the invoice's business gets an answer, anyone else gets
--      NOT_FOUND. Starting needs a code verified session, payments live, and an invoice still open. Nothing is created:
--      the invoice's own PaymentIntent is confirmed in Stripe's form, so it can never be paid twice.
--   3. zella_owner_billing_access: the owner check for the card actions (the saved card's brand and last 4; Stripe's
--      Customer Portal for a card update).
--   4. zella_billing_stripe_refs (server only): the business's Stripe customer and subscription, from our own links.
--   5. zella_owner_pack_status / zella_owner_pack_act_start: a pack the bank wanted to confirm, or whose saved card was
--      declined, can be finished by the owner in Stripe's form on the SAME PaymentIntent (back to pending; granted only
--      by Stripe's payment_intent.succeeded and the binding check, unchanged).
--   6. zella_billing_address_prefill (server only): the business's own address, to prefill Stripe's billing address
--      fields in the checkout; the owner can change it there and nothing is saved back.
--   8. Auto pay (owner decision, 27 Nov 2026: "Auto pay switch, on by default"): subscriptions.desired_autopay and
--      autopay_version (the owner's latest choice); zella_owner_autopay_status / zella_owner_autopay_set (owner only,
--      audited billing.autopay_changed, email H1 held while email_live is off); server only zella_stripe_autopay_sync
--      (one Stripe command per choice, key autopay:<subscription>:<version>:<attempt>, body stored), its after send and
--      event checks, and zella_billing_autopay_next_command. customer.subscription.updated (zella_stripe_plan_change.sql's
--      version, archived first, two exact text changes) records Stripe's collection_method and days_until_due, the ONLY
--      way our record of Auto pay changes, and resends the latest choice on a mismatch.
--   7. zella_billing_email_invoice_trg (sql/zella_stripe_emails.sql's version, archived first, changed by one exact text
--      replacement): the invoice emails' data also carries our invoice id, so their Pay now link opens that invoice's own
--      page (/pay/invoice/<id>, sign in first) instead of the general Payments page.
-- Needs sql/zella_stripe_invoices.sql, sql/zella_stripe_packs.sql and sql/zella_stripe_emails.sql. Rollback:
-- sql/rollback/zella_stripe_owner_pay_rollback.sql (restores zella_owner_invoices exactly, drops the rest; refuses on
-- drift). Tests: tests/stripe_owner_pay/stub_run.sh, web/supabase/functions/billing-api/handle_test.ts.
begin;

do $$
declare s text; d text;
  v_from constant text := '60c0659f065c58b03dc279ffb007825c';   -- sql/zella_stripe_invoices.sql's zella_owner_invoices
  v_to constant text := 'effc5ab4a36f94ac7429909fd534849b';
  owned constant jsonb := '{
    "public.zella_owner_invoice_pay_status(uuid)": "3801f9664e172f095b4bd88652f31b4f",
    "public.zella_owner_invoice_pay_start(uuid)": "cb72de188cfae050d77a29bc3d627fd7",
    "public.zella_owner_billing_access(uuid,boolean)": "5738697783e8f82adc1872bea88bbf86",
    "public.zella_billing_stripe_refs(uuid,boolean)": "f850df5700bfb546c084e41d4267fab9",
    "public.zella_owner_pack_status(uuid,uuid)": "a48b5589765fe94049fa3f6a2ca78a6d",
    "public.zella_owner_pack_act_start(uuid,uuid)": "078d951809d38ead0c747863259fe7b7",
    "public.zella_billing_address_prefill(uuid)": "55f277f7ce0649984442cb26898b47ad",
    "public.zella_owner_autopay_status(uuid)": "caf4ad7c04a3c894fc3806a652e72f69",
    "public.zella_owner_autopay_set(uuid,boolean,text)": "fe2d1f7d660f048901005300c94fd866",
    "public.zella_stripe_autopay_sync(uuid,integer)": "357e73815eee8de255247d5d62a5aca2",
    "public.zella_stripe_autopay_next_attempt(subscriptions)": "dc4d089e243c392c41942b1d2ce08664",
    "public.zella_billing_autopay_next_command(uuid)": "f87fce08f349bf2655b1a91f99d9670c",
    "public.zella_stripe_after_autopay(billing_outbox)": "224cb171280d5b08940468c76b852080",
    "public.zella_stripe_autopay_check(billing_events,jsonb)": "c22f67551dab05e6fedff8235c44e4c5"
  }';
begin
  if to_regclass('public.billing_invoices') is null or to_regclass('public.pack_purchases') is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_owner_invoices(uuid)') is null or to_regprocedure('public.zella_owner_pack_buy(uuid,text,text)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_invoices.sql and zella_stripe_packs.sql';
  end if;
  if to_regclass('public.billing_plan_changes') is null or to_regprocedure('public.zella_stripe_cancel_check(billing_events,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_cancel.sql and zella_stripe_plan_change.sql';
  end if;
  d := pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure);
  if md5(d) = v_from then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_stripe_owner_pay', 'public.zella_owner_invoices(uuid)', d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> v_to then
    raise exception 'VERSION_MISMATCH: public.zella_owner_invoices(uuid) is not a version this file was written for';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then
      if md5(pg_get_functiondef(to_regprocedure(s))) <> owned ->> s then raise exception 'VERSION_MISMATCH: % is not the version this file makes', s; end if;
    end if;
  end loop;
end $$;

-- 8. Auto pay: the owner's latest choice, versioned (Stripe's own value is kept in metadata, from its events only)
alter table public.subscriptions add column if not exists desired_autopay boolean;
alter table public.subscriptions add column if not exists autopay_version integer not null default 0;

-- The owner's invoices (replaces sql/zella_stripe_invoices.sql's version): the same rows plus our invoice id, the
-- amount still due and whether Pay now is offered (open or failed, payments live).
create or replace function public.zella_owner_invoices(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);   -- the business's active owner only
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'status', status, 'total_minor', total_minor, 'amount_paid_minor', amount_paid_minor,
           'amount_due_minor', amount_due_minor, 'currency', currency, 'period_start', period_start, 'period_end', period_end, 'hosted_invoice_url', hosted_invoice_url,
           'invoice_pdf', invoice_pdf, 'paid_at', paid_at, 'created_at', coalesce(stripe_created_at, created_at),
           'payable', status in ('open', 'payment_failed') and amount_due_minor > 0 and public.zella_payments_live()) order by coalesce(stripe_created_at, created_at) desc)
    from public.billing_invoices where business_id = p_business_id and status not in ('draft', 'deleted')), '[]'::jsonb);
end $$;

-- One invoice, by our id alone (the emailed Pay now link). The id grants nothing: the caller must be the active owner
-- of the invoice's business; a missing invoice and someone else's invoice answer the same NOT_FOUND.
create or replace function public.zella_owner_invoice_pay_status(p_invoice_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i public.billing_invoices;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select * into i from public.billing_invoices where id = p_invoice_id;
  if i.id is null or i.status in ('draft', 'deleted') or not exists (select 1 from public.business_members m where m.business_id = i.business_id
       and m.user_id = auth.uid() and m.role = 'owner' and m.status = 'active') then
    raise exception 'NOT_FOUND';
  end if;
  perform public.zella_onboarding_authorize(i.business_id, false, false);
  return jsonb_build_object('invoice_id', i.id, 'business_id', i.business_id, 'business_name', (select name from public.businesses where id = i.business_id),
    'stripe_invoice_id', i.stripe_invoice_id, 'number', i.number, 'status', i.status, 'kind', i.kind, 'total_minor', i.total_minor, 'amount_due_minor', i.amount_due_minor, 'amount_paid_minor', i.amount_paid_minor,
    'currency', i.currency, 'period_start', i.period_start, 'period_end', i.period_end, 'hosted_invoice_url', i.hosted_invoice_url, 'invoice_pdf', i.invoice_pdf, 'paid_at', i.paid_at,
    'payments_live', public.zella_payments_live(),
    'payable', i.status in ('open', 'payment_failed') and i.amount_due_minor > 0 and public.zella_payments_live());
end $$;

-- Pay now: checks the owner (code verified session), payments live and the invoice still payable, and audits the
-- start. Nothing is created here or at Stripe: the invoice's own PaymentIntent is confirmed, so a double start, a
-- second tab or the emailed link all reach the same intent, and the invoice can never be paid twice.
create or replace function public.zella_owner_invoice_pay_start(p_invoice_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i public.billing_invoices;
begin
  perform public.zella_owner_invoice_pay_status(p_invoice_id);   -- NOT_FOUND for anything not this owner's
  select * into i from public.billing_invoices where id = p_invoice_id;
  perform public.zella_onboarding_authorize(i.business_id, true, true);
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  if i.status = 'paid' then raise exception 'ALREADY_PAID'; end if;
  if i.status not in ('open', 'payment_failed') or i.amount_due_minor <= 0 then raise exception 'NOT_PAYABLE'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (i.business_id, auth.uid(), 'billing.invoice_pay_started', 'billing_invoice', i.id, jsonb_build_object('amount_due_minor', i.amount_due_minor));
  return jsonb_build_object('invoice_id', i.id, 'business_id', i.business_id, 'stripe_invoice_id', i.stripe_invoice_id, 'number', i.number,
    'amount_due_minor', i.amount_due_minor, 'currency', i.currency, 'hosted_invoice_url', i.hosted_invoice_url, 'livemode', i.livemode);
end $$;

-- The owner check for billing-api's card actions (read: the saved card's brand and last 4; write: the card update
-- page), with the address Stripe's page returns to.
create or replace function public.zella_owner_billing_access(p_business_id uuid, p_write boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, p_write, p_write);
  if p_write and not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  return jsonb_build_object('business_id', p_business_id, 'payments_live', public.zella_payments_live(),
    'app_base_url', nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''));
end $$;

-- Server only: the business's Stripe customer and subscription (our own links), in the key's mode.
create or replace function public.zella_billing_stripe_refs(p_business_id uuid, p_livemode boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'customer', (select stripe_id from public.billing_stripe_links where business_id = p_business_id and kind = 'customer' and livemode = coalesce(p_livemode, false)),
    'subscription', (select external_subscription_id from public.subscriptions where business_id = p_business_id and provider = 'stripe'));
$$;

-- A pack the owner bought: its state, and whether the owner can finish it with Stripe's form (the bank asked to
-- confirm, or the saved card was declined: the same PaymentIntent is confirmed, never a second charge).
create or replace function public.zella_owner_pack_status(p_business_id uuid, p_purchase_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v public.pack_purchases;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  select * into v from public.pack_purchases where id = p_purchase_id and business_id = p_business_id and source = 'owner_purchase';
  if v.id is null then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('purchase_id', v.id, 'status', v.status, 'pack_code', v.pack_code, 'resource', v.resource, 'quantity', v.quantity,
    'price_cents', v.price_cents, 'currency', 'usd', 'failure_reason', v.failure_reason, 'payment_intent', v.stripe_payment_intent,
    'can_act', v.status = 'failed' and v.stripe_payment_intent is not null
               and coalesce(v.failure_reason, '') in ('authentication_required', 'card_declined', 'expired_card', 'insufficient_funds', 'incorrect_cvc', 'processing_error'));
end $$;

-- The owner finishes a pack with Stripe's form: the purchase goes back to pending on the same PaymentIntent, and is
-- granted only by Stripe's payment_intent.succeeded after the binding check (unchanged). Repeating it answers the same.
create or replace function public.zella_owner_pack_act_start(p_business_id uuid, p_purchase_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.pack_purchases; st jsonb;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into v from public.pack_purchases where id = p_purchase_id and business_id = p_business_id and source = 'owner_purchase' for update;
  if v.id is null then raise exception 'NOT_FOUND'; end if;
  if v.status = 'granted' then raise exception 'ALREADY_PAID'; end if;
  if v.status = 'failed' then
    st := public.zella_owner_pack_status(p_business_id, p_purchase_id);
    if not (st ->> 'can_act')::boolean then raise exception 'NOT_PAYABLE'; end if;
    update public.pack_purchases set status = 'pending', failure_reason = null, settled_at = null where id = v.id;
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
    values (p_business_id, auth.uid(), 'billing.pack_owner_action', 'pack_purchase', v.id, jsonb_build_object('failure_reason', v.failure_reason), jsonb_build_object('status', 'pending'));
  elsif v.status <> 'pending' or v.stripe_payment_intent is null then
    raise exception 'NOT_PAYABLE';
  end if;
  return jsonb_build_object('purchase_id', v.id, 'payment_intent', v.stripe_payment_intent, 'price_cents', v.price_cents, 'currency', 'usd');
end $$;

-- Server only: the business's own address, to prefill Stripe's billing address fields in the checkout (the owner can
-- change it there; nothing is saved back here). Country as a two letter code when it is one, or "US" for the usual
-- spellings of the United States; otherwise left out (Stripe's field then defaults to the United States). Any country.
create or replace function public.zella_billing_address_prefill(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'line1', nullif(left(trim(b.address_line_1), 100), ''), 'line2', nullif(left(trim(b.address_line_2), 100), ''),
    'city', nullif(left(trim(b.city), 100), ''), 'state', nullif(left(trim(b.state), 100), ''), 'postal_code', nullif(left(trim(b.postal_code), 20), ''),
    'country', case when upper(trim(b.country)) ~ '^[A-Z]{2}$' then upper(trim(b.country))
                    when lower(trim(b.country)) in ('united states', 'united states of america', 'usa') then 'US' end))
    from public.businesses b where b.id = p_business_id;
$$;

-- Auto pay (owner decision, 27 Nov 2026: "Auto pay switch, on by default"; docs/PAYMENTS_ARCHITECTURE.md §6.11): the
-- owner's choice is a versioned desired value on the subscription (desired_autopay, autopay_version). What Stripe has
-- (collection_method) is recorded ONLY from customer.subscription.updated, never from the browser or our own command.
-- Shown to the owner: whether Auto pay is on (Stripe's word), whether a change is on its way, the renewal date.
create or replace function public.zella_owner_autopay_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; v_on boolean;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);   -- the business's active owner only
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe';
  v_on := coalesce(s.metadata ->> 'collection_method', 'charge_automatically') <> 'send_invoice';
  return jsonb_build_object('on', v_on, 'desired', coalesce(s.desired_autopay, v_on),
    'pending', s.desired_autopay is not null and s.desired_autopay <> v_on and s.external_subscription_id is not null,
    'days_until_due', case when v_on then null else coalesce((s.metadata ->> 'days_until_due')::int, 3) end,
    'current_period_end', s.current_period_end, 'status', s.status, 'subscribed', s.external_subscription_id is not null,
    'has_card', coalesce(s.metadata ->> 'default_payment_method', '') <> '',
    'payments_live', public.zella_payments_live(),
    'email_live', coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false));
end $$;

-- The owner switches Auto pay on or off (code verified session, payments live). The onboarding checkout sends the
-- owner's choice once the server has confirmed the first payment, when the subscription exists. Turning it on needs a saved card (billing-api also
-- checks with Stripe that it is still usable). The same key, or the same choice again, changes nothing (a double
-- submit). Each change: a new version, one audit entry, one email (held while email_live is off), one Stripe command.
create or replace function public.zella_owner_autopay_set(p_business_id uuid, p_on boolean, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions; v_on boolean; v_due date;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);   -- active owner of THIS business, code verified session
  if p_on is null or p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then raise exception 'INVALID_INPUT'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe' for update;
  if s.id is null or s.external_subscription_id is null or s.status in ('cancelled', 'expired') then raise exception 'NO_SUBSCRIPTION'; end if;
  -- the same request again (same key), or a choice already made: answered as it stands
  if exists (select 1 from public.audit_logs where business_id = p_business_id and action = 'billing.autopay_changed' and new_data ->> 'key' = p_idempotency_key) then
    return public.zella_owner_autopay_status(p_business_id);
  end if;
  v_on := coalesce(s.metadata ->> 'collection_method', 'charge_automatically') <> 'send_invoice';
  if coalesce(s.desired_autopay, v_on) = p_on then return public.zella_owner_autopay_status(p_business_id); end if;
  if p_on and coalesce(s.metadata ->> 'default_payment_method', '') = '' then raise exception 'NO_SAVED_CARD'; end if;
  update public.subscriptions set desired_autopay = p_on, autopay_version = autopay_version + 1, updated_at = now() where id = s.id returning * into s;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'billing.autopay_changed', 'subscription', s.id, jsonb_build_object('autopay', v_on),
          jsonb_build_object('autopay', p_on, 'version', s.autopay_version, 'key', p_idempotency_key));
  v_due := (coalesce(s.current_period_end, now()) + interval '3 days')::date;
  perform public.zella_billing_email(p_business_id, 'H1', s.id::text, s.autopay_version::text, jsonb_build_object('autoPayOn', p_on,
    'dueDate', to_char(v_due, 'FMMonth FMDD, YYYY'), 'changedBy', 'The business owner', 'time', to_char(now() at time zone 'UTC', 'FMMonth FMDD, YYYY HH24:MI "UTC"')));
  perform public.zella_stripe_autopay_sync(p_business_id, 1);
  return public.zella_owner_autopay_status(p_business_id);
end $$;

-- Server only: queues the latest choice for Stripe (key autopay:<subscription>:<version>:<attempt>, the exact body
-- stored, §8.1); older choices still waiting are never sent, so the latest always wins. Off: send_invoice, due in 3 days.
create or replace function public.zella_stripe_autopay_sync(p_business_id uuid, p_attempt integer default 1) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions; o public.billing_outbox; v_key text;
begin
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe' and external_subscription_id is not null for update;
  if s.id is null or s.desired_autopay is null or s.status in ('cancelled', 'expired') then return null; end if;
  v_key := 'autopay:' || s.external_subscription_id || ':' || s.autopay_version || ':' || p_attempt;
  update public.billing_outbox set status = 'cancelled', updated_at = now()
   where business_id = p_business_id and kind = 'autopay' and status in ('pending', 'retry_wait') and local_id = s.id and idempotency_key <> v_key;
  o := public.zella_billing_outbox_add(p_business_id, 'autopay', v_key, 'POST', '/v1/subscriptions/' || s.external_subscription_id,
    case when s.desired_autopay then jsonb_build_object('collection_method', 'charge_automatically')
         else jsonb_build_object('collection_method', 'send_invoice', 'days_until_due', 3) end, 'subscription', s.id);
  return o.id;
end $$;

-- The next unused attempt number for the current choice (under the subscription's row lock).
create or replace function public.zella_stripe_autopay_next_attempt(s public.subscriptions) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(max(nullif(split_part(idempotency_key, ':', 4), '')::int), 0) + 1 from public.billing_outbox
   where kind = 'autopay' and local_id = s.id and idempotency_key like 'autopay:' || s.external_subscription_id || ':' || s.autopay_version || ':%';
$$;

-- Server only: the waiting Stripe command for this business's Auto pay choice, for billing-api to send at once.
create or replace function public.zella_billing_autopay_next_command(p_business_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.billing_outbox where business_id = p_business_id and kind = 'autopay' and status in ('pending', 'retry_wait') order by created_at desc limit 1;
$$;

-- After a send: nothing is recorded from our own command (the event does that); if Stripe's answer doesn't match the
-- latest choice (an older send landed last) and nothing is waiting, the latest is sent again.
create or replace function public.zella_stripe_after_autopay(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions;
begin
  select * into s from public.subscriptions where id = r.local_id for update;
  if s.id is null or s.desired_autopay is null then return; end if;
  if (r.response ->> 'collection_method' = 'charge_automatically') is distinct from s.desired_autopay
     and not exists (select 1 from public.billing_outbox where kind = 'autopay' and local_id = s.id and status in ('pending', 'retry_wait', 'sending') and id <> r.id) then
    perform public.zella_stripe_autopay_sync(s.business_id, public.zella_stripe_autopay_next_attempt(s));
  end if;
end $$;

-- From customer.subscription.updated (fetched): Stripe's collection method against the latest choice; a mismatch with
-- nothing waiting is sent again. Called by the event handler after it recorded Stripe's value.
create or replace function public.zella_stripe_autopay_check(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions;
begin
  if l.stripe_id is null then return 'ignored'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null or s.desired_autopay is null or o ->> 'status' in ('canceled', 'incomplete_expired') then return 'ignored'; end if;
  if s.external_subscription_id is distinct from o ->> 'id' then return 'ignored'; end if;
  if (o ->> 'collection_method' = 'charge_automatically') is distinct from s.desired_autopay
     and not exists (select 1 from public.billing_outbox where kind = 'autopay' and local_id = s.id and status in ('pending', 'retry_wait', 'sending')) then
    perform public.zella_stripe_autopay_sync(s.business_id, public.zella_stripe_autopay_next_attempt(s));
    return 'applied';
  end if;
  return 'ignored';
end $$;

-- 6. the invoice emails carry our invoice id (one exact text replacement on a known version, archived first)
do $x$
declare d text;
  v_from constant text := 'cc75a8987f19e2ae96c066395b79af45';   -- sql/zella_stripe_emails.sql's version
  v_to constant text := 'e71bf72e22f1e906f1022c5e94f44f5e';
  v_old constant text := $r$jsonb_build_object('invoice', new.number,$r$;
  v_new constant text := $r$jsonb_build_object('invoiceId', new.id, 'invoice', new.number,$r$;
begin
  if to_regprocedure('public.zella_billing_email_invoice_trg()') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_emails.sql'; end if;
  d := pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure);
  if md5(d) = v_to then return; end if;
  if md5(d) <> v_from then raise exception 'VERSION_MISMATCH: public.zella_billing_email_invoice_trg() is not a version this file was written for'; end if;
  if (length(d) - length(replace(d, v_old, ''))) / length(v_old) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_stripe_owner_pay', 'public.zella_billing_email_invoice_trg()', d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, v_old, v_new);
  if md5(pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure)) <> v_to then raise exception 'VERSION_MISMATCH: the changed trigger function is not the expected version'; end if;
end $x$;

-- 8. customer.subscription.updated records Stripe's collection method (two exact text changes, archived first)
do $x$
declare d text;
  o0 constant text := $r$'stripe_item', o #>> '{items,data,0,id}',$r$;
  n0 constant text := $r$'collection_method', o ->> 'collection_method', 'days_until_due', (o ->> 'days_until_due')::int, 'stripe_item', o #>> '{items,data,0,id}',$r$;
  o1 constant text := $r$  perform public.zella_stripe_cancel_check(e, o);   -- the owner's latest cancel choice against Stripe's
$r$;
  n1 constant text := $r$  perform public.zella_stripe_cancel_check(e, o);   -- the owner's latest cancel choice against Stripe's
  perform public.zella_stripe_autopay_check(e, o);   -- the owner's latest Auto pay choice against Stripe's
$r$;
begin
  d := pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure);
  if md5(d) = 'a803f166b2a317d4b061ef01de4a3a04' then return; end if;
  if md5(d) <> 'c9b70ddd6dfdf324e93d3f2aa79d7ab4' then raise exception 'VERSION_MISMATCH: public.zella_stripe_on_customer_subscription_updated is not a version this file was written for'; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_stripe_owner_pay', 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)', d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(replace(d, o0, n0), o1, n1);
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> 'a803f166b2a317d4b061ef01de4a3a04' then raise exception 'VERSION_MISMATCH: the changed event handler is not the expected version'; end if;
end $x$;

do $$ declare f text; begin
  foreach f in array array['zella_owner_invoices(uuid)', 'zella_owner_invoice_pay_status(uuid)', 'zella_owner_invoice_pay_start(uuid)',
    'zella_owner_billing_access(uuid,boolean)', 'zella_owner_pack_status(uuid,uuid)', 'zella_owner_pack_act_start(uuid,uuid)',
    'zella_owner_autopay_status(uuid)', 'zella_owner_autopay_set(uuid,boolean,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  revoke execute on function public.zella_billing_stripe_refs(uuid, boolean) from public, anon, authenticated;
  grant execute on function public.zella_billing_stripe_refs(uuid, boolean) to service_role;
  revoke execute on function public.zella_billing_address_prefill(uuid) from public, anon, authenticated;
  grant execute on function public.zella_billing_address_prefill(uuid) to service_role;
  foreach f in array array['zella_stripe_autopay_sync(uuid,integer)', 'zella_stripe_autopay_next_attempt(subscriptions)', 'zella_billing_autopay_next_command(uuid)',
    'zella_stripe_after_autopay(billing_outbox)', 'zella_stripe_autopay_check(billing_events,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- what this file made is exactly what it says it makes
do $$
declare s text;
  made constant jsonb := '{
    "public.zella_owner_invoices(uuid)": "effc5ab4a36f94ac7429909fd534849b",
    "public.zella_owner_invoice_pay_status(uuid)": "3801f9664e172f095b4bd88652f31b4f",
    "public.zella_owner_invoice_pay_start(uuid)": "cb72de188cfae050d77a29bc3d627fd7",
    "public.zella_owner_billing_access(uuid,boolean)": "5738697783e8f82adc1872bea88bbf86",
    "public.zella_billing_stripe_refs(uuid,boolean)": "f850df5700bfb546c084e41d4267fab9",
    "public.zella_owner_pack_status(uuid,uuid)": "a48b5589765fe94049fa3f6a2ca78a6d",
    "public.zella_owner_pack_act_start(uuid,uuid)": "078d951809d38ead0c747863259fe7b7",
    "public.zella_billing_address_prefill(uuid)": "55f277f7ce0649984442cb26898b47ad",
    "public.zella_owner_autopay_status(uuid)": "caf4ad7c04a3c894fc3806a652e72f69",
    "public.zella_owner_autopay_set(uuid,boolean,text)": "fe2d1f7d660f048901005300c94fd866",
    "public.zella_stripe_autopay_sync(uuid,integer)": "357e73815eee8de255247d5d62a5aca2",
    "public.zella_stripe_autopay_next_attempt(subscriptions)": "dc4d089e243c392c41942b1d2ce08664",
    "public.zella_billing_autopay_next_command(uuid)": "f87fce08f349bf2655b1a91f99d9670c",
    "public.zella_stripe_after_autopay(billing_outbox)": "224cb171280d5b08940468c76b852080",
    "public.zella_stripe_autopay_check(billing_events,jsonb)": "c22f67551dab05e6fedff8235c44e4c5"
  }';
begin
  for s in select jsonb_object_keys(made) loop
    if md5(pg_get_functiondef(to_regprocedure(s))) <> made ->> s then raise exception 'VERSION_MISMATCH: % differs from this file''s version', s; end if;
  end loop;
end $$;

commit;
