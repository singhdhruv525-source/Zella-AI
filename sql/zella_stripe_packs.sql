-- Zella Voice: packs bought by the owner and auto reload, race free (docs/PAYMENTS_ARCHITECTURE.md §6.4,
-- REQ-BIL-23, REQ-BIL-32), built switched off.
--   - zella_owner_pack_buy(business, pack, key): the active owner (code verified session) buys a pack from the fixed
--     catalog; the price comes from billing_pack_catalog, never the browser. A pending purchase and one outbox command:
--     a PaymentIntent on the saved card (key pack:<purchase id>).
--   - Auto reload: after each usage entry, if the owner switched it on for that resource, the balance is at or below
--     their threshold, no reload is pending (a partial unique index: one at a time, however many calls end together)
--     and this month's reloads plus the pack stay within their spend cap, a pending purchase and a PaymentIntent
--     (key reload:<purchase id>). Never blocks or fails the usage entry itself.
--   - payment_intent.succeeded (fetched, bound to OUR PaymentIntent for that purchase, exact amount, usd, our customer):
--     the pack's balance is granted until the end of the period it was bought in, one bound payment and balanced
--     ledger postings. Failed or waiting for the bank: the purchase fails and the owner is told; nothing is granted.
--   - The saved card: the subscription events now also record Stripe's default payment method id (an id, no card data).
-- Replaces zella_stripe_on_customer_subscription_updated (zella_stripe_pipeline.sql's version, archived first).
-- Widens pack_purchases (applied table): status pending/failed/cancelled and sources owner_purchase/auto_reload, plus
-- three columns; existing admin grants are unchanged.
-- Rollback: sql/rollback/zella_stripe_packs_rollback.sql. Tests: tests/stripe_packs/run.sh.
begin;

do $$
declare s text; d text;
  known constant jsonb := '{
    "public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)": ["c02680d28b2527875d15e3ec1d8f354a", "697fc98401d8f2f588fdff1ec93c1454"]
  }';
  owned constant jsonb := '{
    "public.zella_billing_pack_next_command(uuid)": "2a5d455f3775411b79535374a09fc1c6",
    "public.zella_owner_pack_buy(uuid,text,text)": "d6a31963fd637d0b57584df3349157a1",
    "public.zella_billing_maybe_reload(uuid,text)": "d802867b376a6ed0c4ba30344c649b47",
    "public.zella_billing_reload_trg()": "8ca4aed8ecc092d3ba4916d9fe3902bc",
    "public.zella_billing_pack_command(pack_purchases)": "6509163e4d12bbf5186b0610f0524f5f",
    "public.zella_stripe_after_payment_intent(billing_outbox)": "838b8a815320adee2f4a368c79492250",
    "public.zella_stripe_failed_payment_intent(billing_outbox)": "0367f4bb6f1682640c50c398597390ad",
    "public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)": "d744eacbdf8179827a0ec86f765e6ec8",
    "public.zella_stripe_on_payment_intent_payment_failed(billing_events,jsonb)": "f8a364ae8345e8d0ddeb787e82bb8ab8",
    "public.zella_stripe_on_payment_intent_requires_action(billing_events,jsonb)": "b5f1c4f5240f4e958947a575241cd6e9"
  }';
begin
  if to_regprocedure('public.zella_stripe_grant_subscription_cycle(jsonb,jsonb)') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_renewals.sql'; end if;
  for s in select jsonb_object_keys(known) loop
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then
      insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_packs', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

alter table public.pack_purchases drop constraint if exists pack_purchases_status_check;
alter table public.pack_purchases add constraint pack_purchases_status_check check (status in ('granted', 'pending', 'failed', 'cancelled'));
alter table public.pack_purchases drop constraint if exists pack_purchases_source_check;
alter table public.pack_purchases add constraint pack_purchases_source_check check (source in ('admin_grant', 'owner_purchase', 'auto_reload'));
alter table public.pack_purchases add column if not exists stripe_payment_intent text;
alter table public.pack_purchases add column if not exists failure_reason text;
alter table public.pack_purchases add column if not exists settled_at timestamptz;
create unique index if not exists pack_purchases_one_pending_reload_uidx on public.pack_purchases (business_id, resource) where status = 'pending' and source = 'auto_reload';

-- The saved card: Stripe's default payment method id on the subscription (Checkout sets it). Otherwise unchanged.
create or replace function public.zella_stripe_on_customer_subscription_updated(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions; v_to text;
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null then raise exception 'WAITING: no local subscription'; end if;
  if s.billing_event_at is not null and e.event_created_at < s.billing_event_at then return 'older'; end if;
  update public.subscriptions set metadata = metadata || jsonb_strip_nulls(jsonb_build_object('stripe_status', o ->> 'status',
           'cancel_at_period_end', (o ->> 'cancel_at_period_end')::boolean, 'stripe_trial_end', o ->> 'trial_end',
           'default_payment_method', coalesce(o #>> '{default_payment_method,id}', o ->> 'default_payment_method'))),
         billing_event_at = greatest(coalesce(billing_event_at, e.event_created_at), e.event_created_at), updated_at = now()
   where id = s.id;
  v_to := case o ->> 'status' when 'past_due' then 'past_due' when 'unpaid' then 'past_due' else null end;   -- active comes only from a paid invoice
  if v_to is not null and s.status <> v_to and public.zella_subscription_transition_ok(s.status, v_to) then
    update public.subscriptions set status = v_to, past_due_since = coalesce(past_due_since, now()) where id = s.id;
  end if;
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

-- The one command for a pending purchase: a PaymentIntent on the saved card, amount from the catalog row stored on it.
create or replace function public.zella_billing_pack_command(p public.pack_purchases) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_cus text := public.zella_stripe_customer(p.business_id); v_pm text;
begin
  select metadata ->> 'default_payment_method' into v_pm from public.subscriptions where business_id = p.business_id;
  if v_cus is null or v_pm is null then raise exception 'NO_SAVED_CARD'; end if;
  return (public.zella_billing_outbox_add(p.business_id, 'payment_intent', case p.source when 'auto_reload' then 'reload:' else 'pack:' end || p.id, 'POST', '/v1/payment_intents',
    jsonb_build_object('customer', v_cus, 'payment_method', v_pm, 'amount', p.price_cents, 'currency', 'usd', 'off_session', true, 'confirm', true,
      'description', 'Zella Voice pack', 'metadata', jsonb_build_object('business_id', p.business_id, 'purchase_id', p.id, 'kind', p.source)), 'pack', p.id)).id;
end $$;

create or replace function public.zella_billing_pack_next_command(p_purchase_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.billing_outbox where local_kind = 'pack' and local_id = p_purchase_id and status in ('pending', 'retry_wait') order by created_at limit 1;
$$;

create or replace function public.zella_owner_pack_buy(p_business_id uuid, p_pack_code text, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.billing_pack_catalog; per public.billing_periods; v public.pack_purchases; s public.subscriptions;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);   -- active owner of THIS business, code verified session
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then raise exception 'INVALID_INPUT'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into v from public.pack_purchases where business_id = p_business_id and idempotency_key = p_idempotency_key;
  if v.id is not null then
    if v.pack_code <> p_pack_code then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return jsonb_build_object('purchase_id', v.id, 'status', v.status, 'price_cents', v.price_cents);
  end if;
  select * into c from public.billing_pack_catalog where code = p_pack_code and active;
  if c.code is null then raise exception 'UNKNOWN_PACK'; end if;
  select * into s from public.subscriptions where business_id = p_business_id;
  if s.status is distinct from 'active' then raise exception 'NO_ACTIVE_PLAN'; end if;
  per := public.zella_billing_open_period(p_business_id, now());
  if per.id is null then raise exception 'NO_CURRENT_PERIOD'; end if;
  insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key, created_by)
  values (p_business_id, c.code, c.resource, c.quantity, c.price_cents, 'pending', 'owner_purchase', 'Bought by the owner', per.id, p_idempotency_key, auth.uid())
  returning * into v;
  perform public.zella_billing_pack_command(v);
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'billing.pack_bought', 'pack_purchase', v.id, jsonb_build_object('pack', c.code, 'price_cents', c.price_cents));
  return jsonb_build_object('purchase_id', v.id, 'status', v.status, 'price_cents', v.price_cents);
end $$;

-- Auto reload for one business and resource. Returns the purchase id it queued, or null. Locks the owner's settings
-- row first, so two usage entries at the same moment queue at most one (the partial unique index backs that up).
create or replace function public.zella_billing_maybe_reload(p_business_id uuid, p_resource text) returns uuid
language plpgsql security definer set search_path = public as $$
declare a public.auto_reload_settings; c public.billing_pack_catalog; v_left numeric; v_spent bigint; per public.billing_periods; v public.pack_purchases;
begin
  if not public.zella_payments_live() then return null; end if;
  select * into a from public.auto_reload_settings where business_id = p_business_id and resource = p_resource and enabled for update;
  if a.business_id is null then return null; end if;
  if exists (select 1 from public.pack_purchases where business_id = p_business_id and resource = p_resource and source = 'auto_reload' and status = 'pending') then return null; end if;
  if (select status from public.subscriptions where business_id = p_business_id) is distinct from 'active' then return null; end if;
  v_left := coalesce((public.zella_billing_balance(p_business_id, p_resource, now()) ->> 'remaining')::numeric, 0);
  if v_left > a.threshold then return null; end if;
  select * into c from public.billing_pack_catalog where code = a.pack_code and active and resource = p_resource;
  if c.code is null then return null; end if;
  select coalesce(sum(price_cents), 0) into v_spent from public.pack_purchases
   where business_id = p_business_id and source = 'auto_reload' and status in ('pending', 'granted') and purchased_at >= date_trunc('month', now());
  if v_spent + c.price_cents > a.monthly_cap_cents then
    perform public.zella_platform_alert('auto_reload_cap', 'Auto reload stopped at the monthly spend limit', p_resource, 'info', p_business_id, 'reload_cap:' || to_char(now(), 'YYYY-MM') || ':' || p_resource);
    perform public.zella_notify_owners(p_business_id, 'auto_reload_cap', 'Auto reload reached your monthly limit', 'No more packs are bought automatically this month. You can raise the limit in Settings, Billing.', 'warning', 'settings');
    return null;
  end if;
  per := public.zella_billing_open_period(p_business_id, now());
  if per.id is null then return null; end if;
  insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key)
  values (p_business_id, c.code, c.resource, c.quantity, c.price_cents, 'pending', 'auto_reload', 'Auto reload at the owner''s threshold', per.id, 'reload-' || gen_random_uuid())
  on conflict do nothing returning * into v;
  if v.id is null then return null; end if;
  perform public.zella_billing_pack_command(v);
  return v.id;
end $$;

-- After every usage entry: never blocks or fails the entry (a problem is an alert, the call is unaffected).
create or replace function public.zella_billing_reload_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.quantity > 0 and public.zella_payments_live() then
    begin
      perform public.zella_billing_maybe_reload(new.business_id, new.resource);
    exception when others then
      perform public.zella_platform_alert('auto_reload_failed', 'Auto reload could not be queued', left(sqlerrm, 200), 'warning', new.business_id, 'auto_reload_failed');
    end;
  end if;
  return null;
end $$;
drop trigger if exists zella_billing_reload on public.usage_charges;
create trigger zella_billing_reload after insert on public.usage_charges for each row execute function public.zella_billing_reload_trg();

create or replace function public.zella_stripe_after_payment_intent(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.zella_stripe_link_add(r.stripe_id, 'payment_intent', r.business_id, (r.response ->> 'livemode')::boolean, 'pack', r.local_id, (r.body ->> 'amount')::bigint);
  update public.pack_purchases set stripe_payment_intent = r.stripe_id where id = r.local_id;
end $$;

-- Stripe refused the charge (402: declined, or the bank wants the owner to confirm): the purchase fails, nothing granted.
create or replace function public.zella_stripe_failed_payment_intent(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
declare v_code text := coalesce(r.response ->> 'code', 'refused');
begin
  update public.pack_purchases set status = 'failed', failure_reason = left(v_code, 80), settled_at = now(),
         stripe_payment_intent = coalesce(r.response ->> 'payment_intent', stripe_payment_intent) where id = r.local_id and status = 'pending';
  perform public.zella_notify_owners(r.business_id, 'pack_failed', 'A pack could not be bought',
    case when v_code = 'authentication_required' then 'Your bank wants to confirm this payment. Update or confirm your card in Settings, Billing, then try again. Nothing was charged.'
         else 'Your card was declined, so nothing was charged and no pack was added. Update your card in Settings, Billing.' end, 'warning', 'settings');
  update public.billing_outbox set status = 'cancelled', updated_at = now() where id = r.id and r.response ->> 'type' = 'card_error';   -- a decline is final: no alert for a person
end $$;

create or replace function public.zella_stripe_on_payment_intent_succeeded(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'payment_intent'); p public.pack_purchases; per public.billing_periods; v_amount bigint := (o ->> 'amount')::bigint;
begin
  if l.stripe_id is null then return 'ignored'; end if;   -- a plan invoice's payment: invoice.paid handles it
  if l.local_kind is distinct from 'pack' then return 'ignored'; end if;
  select * into p from public.pack_purchases where id = l.local_id for update;
  if p.id is null or p.business_id <> l.business_id then raise exception 'BINDING: no purchase for this payment'; end if;
  if o ->> 'status' <> 'succeeded' then raise exception 'BINDING: payment is not succeeded'; end if;
  if lower(o ->> 'currency') <> 'usd' or v_amount <> p.price_cents or v_amount <> l.expected_amount_minor then raise exception 'BINDING: paid % but the pack costs %', v_amount, p.price_cents; end if;
  if o ->> 'customer' is distinct from public.zella_stripe_customer(p.business_id) then raise exception 'BINDING: customer is not this business''s'; end if;
  if p.status = 'granted' then return 'applied'; end if;   -- already granted
  if p.status <> 'pending' then raise exception 'BINDING: purchase is %', p.status; end if;
  select * into per from public.billing_periods where id = p.period_id;
  update public.pack_purchases set status = 'granted', settled_at = now() where id = p.id;
  insert into public.allowance_buckets (business_id, period_id, resource, kind, pack_purchase_id, granted, expires_at)
  values (p.business_id, p.period_id, p.resource, 'pack', p.id, p.quantity, per.period_end);
  insert into public.payments (business_id, subscription_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at, metadata)
  values (p.business_id, (select id from public.subscriptions where business_id = p.business_id), public.zella_minor_to_amount(v_amount, 'usd'), v_amount, 'usd', 'succeeded', 'stripe', o ->> 'id', now(),
          jsonb_build_object('kind', 'pack', 'purchase_id', p.id, 'bound', true))
  on conflict (provider, external_payment_id) where external_payment_id is not null do nothing;
  perform public.zella_ledger_post(p.business_id, 'payment:' || (o ->> 'id'), jsonb_build_array(jsonb_build_object('account', 'cash', 'amount', v_amount), jsonb_build_object('account', 'revenue', 'amount', -v_amount)));
  perform public.zella_notify_owners(p.business_id, 'pack_added', 'Pack added', p.quantity || ' ' || p.resource || ' added, available until ' || to_char(per.period_end at time zone 'UTC', 'FMMonth FMDD') || '.', 'info', 'settings');
  update public.billing_events set business_id = p.business_id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_payment_intent_payment_failed(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'payment_intent');
begin
  if l.stripe_id is null or l.local_kind is distinct from 'pack' then return 'ignored'; end if;
  if o ->> 'status' = 'succeeded' then return 'older'; end if;
  update public.pack_purchases set status = 'failed', failure_reason = left(coalesce(o #>> '{last_payment_error,code}', o ->> 'status'), 80), settled_at = now()
   where id = l.local_id and status = 'pending';
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_payment_intent_requires_action(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_on_payment_intent_payment_failed(e, o); $$;

do $$ declare f text; begin
  foreach f in array array['zella_billing_pack_next_command(uuid)', 'zella_billing_maybe_reload(uuid,text)', 'zella_billing_reload_trg()', 'zella_billing_pack_command(pack_purchases)',
    'zella_stripe_after_payment_intent(billing_outbox)', 'zella_stripe_failed_payment_intent(billing_outbox)', 'zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)',
    'zella_stripe_on_payment_intent_payment_failed(billing_events,jsonb)', 'zella_stripe_on_payment_intent_requires_action(billing_events,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
revoke execute on function public.zella_owner_pack_buy(uuid, text, text) from public, anon;
grant execute on function public.zella_owner_pack_buy(uuid, text, text) to authenticated, service_role;

commit;
