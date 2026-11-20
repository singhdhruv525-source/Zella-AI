-- Zella Voice: Stripe Checkout for the first payment, and the saved card trial (docs/PAYMENTS_ARCHITECTURE.md §6.1,
-- §6.2; owner onboarding screen 6, docs/OWNER_ONBOARDING_CONTRACT.md). Built switched off (payments_live false).
--
--   1. zella_owner_billing_checkout_start(business, idempotency key): the business's active owner, on step 6, asks to
--      pay. The amount comes only from the accepted business_plans version (price + setup fee, integer cents); the
--      browser sends no amount. One open Checkout per business: a second tab gets the same one. The Stripe customer,
--      product, prices and session are created by the worker through the outbox, one command after the other
--      (zella_stripe_after_<kind>), each with its own stored body and key.
--   2. checkout.session.completed (our stored session id only) links the Stripe subscription to the business.
--   3. invoice.paid, billing_reason subscription_create (zella_stripe_grant_subscription_create): the paid amount must
--      equal what we computed, every line must be one of our prices; then the subscription is active from Stripe's
--      period and the period's balances are granted. A trial checkout ($0 invoice) starts the trial instead, with
--      Stripe's trial end; the setup fee is added to the first paid invoice (REQ-BIL-12: nothing charged at the start).
--   4. The onboarding rules: first_payment stays "pay_before_live"; payments_connected follows payments_live; the go
--      live gate counts only a bound Stripe payment (metadata bound = true), never any other payments row.
-- Replaces three functions of sql/zella_owner_onboarding.sql (archived first; must be that file's version).
-- Who: the owner functions check the caller with zella_onboarding_authorize (active owner of THAT business, a code
--   verified session); everything else is server only. Rollback: sql/rollback/zella_stripe_checkout_rollback.sql.
-- Tests: tests/stripe_checkout/run.sh, tests/stripe_pipeline/flow.sh tests/stripe_checkout/flow_test.ts.
begin;

do $$
declare s text; d text;
  known constant jsonb := '{
    "public.zella_onboarding_rules()": ["44a476a30d23837102550359e28f5c67", "26a478446b850a960496d86e13484979"],
    "public.zella_onboarding_payment_confirmed_at(uuid)": ["3bd343a55794b4120ed6421bba3f5ab8", "8f9e449e953522c5a931d282c58912c5"],
    "public.zella_onboarding_payment(uuid)": ["65909f32d9e0e9259bd5b07b1e1a5543", "c777f4fddec15495ef2f1fa2c2c95cd8"]
  }';
  owned constant jsonb := '{
    "public.zella_billing_checkout_continue(uuid,boolean)": "7f998f18370021b4668ce06f057d0055",
    "public.zella_billing_checkout_next_command(uuid)": "1de829f1bf61b380be0b25226d03368f",
    "public.zella_owner_billing_checkout_start(uuid,text)": "ccd57eed688b61cf9cec456b33fd4f55",
    "public.zella_stripe_after_customer(billing_outbox)": "79869917c8050995b88a9bebeaa57c31",
    "public.zella_stripe_after_product(billing_outbox)": "a9eb61e5d51628b53253a83df4efdb68",
    "public.zella_stripe_after_price(billing_outbox)": "651dce986b81b8bcf00033b3f32c8323",
    "public.zella_stripe_after_checkout_session(billing_outbox)": "5df8106e56d16ca2580479906e4aa8f0",
    "public.zella_stripe_failed_checkout_session(billing_outbox)": "3274f0c8857d89ebf9790d2ffa6d4295",
    "public.zella_stripe_failed_customer(billing_outbox)": "564a538acd61da179d341d99bccb8d47",
    "public.zella_stripe_failed_product(billing_outbox)": "a41bc5d5f292e6862e8b0b0e770468fc",
    "public.zella_stripe_failed_price(billing_outbox)": "fea8c8ed9d6a8abec71237a97e20276b",
    "public.zella_stripe_after_checkout_expire(billing_outbox)": "cc2a749acddcf304d7bc5e69821e2949",
    "public.zella_stripe_on_checkout_session_completed(billing_events,jsonb)": "f73812ee1419833c6ec08db5011e5a2a",
    "public.zella_stripe_on_checkout_session_expired(billing_events,jsonb)": "61970b0fbe942ccaa1dbc7e3a06afe56",
    "public.zella_stripe_grant_subscription_create(jsonb,jsonb)": "617d28551ada05a996984777eae97aa2"
  }';
begin
  if to_regclass('public.billing_outbox') is null or to_regclass('public.owner_onboarding') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_pipeline.sql and zella_owner_onboarding.sql';
  end if;
  for s in select jsonb_object_keys(known) loop
    if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_stripe_checkout', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

-- One Checkout per attempt. Server only: owners read it through zella_owner_onboarding_payment_status.
create table if not exists public.billing_checkouts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  business_plan_id uuid not null references public.business_plans(id) on delete restrict,
  mode text not null check (mode in ('pay', 'trial')),
  status text not null default 'preparing' check (status in ('preparing', 'open', 'expiring', 'completed', 'paid', 'expired', 'failed')),
  first_amount_minor bigint not null check (first_amount_minor >= 0),
  setup_fee_minor bigint not null check (setup_fee_minor >= 0),
  trial_end_at timestamptz,
  idempotency_key text not null check (length(idempotency_key) between 8 and 100),
  stripe_session_id text,
  stripe_subscription_id text,
  url text,
  expires_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, idempotency_key)
);
create unique index if not exists billing_checkouts_one_open_uidx on public.billing_checkouts (business_id) where status in ('preparing', 'open', 'expiring', 'completed');
alter table public.billing_checkouts enable row level security;
revoke all on public.billing_checkouts from anon, authenticated;
grant select, insert, update on public.billing_checkouts to service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The onboarding rules and payment state (replacing sql/zella_owner_onboarding.sql's versions)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_onboarding_rules() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'identity_provider', 'none',              -- manual upload, checked in Verification; later 'persona'
    'plan_choice', 'accept_only',             -- the owner accepts the plan Zella Voice set
    'first_payment', 'pay_before_live',       -- or 'trial_with_card' (the saved card trial, built)
    'failed_check', 'retry_then_review',      -- or 'stop_and_contact_support' (set identity_attempts to 1)
    'identity_attempts', 2,                   -- failed checks on step 4 before manual review
    'payments_connected', public.zella_payments_live());   -- Stripe Checkout is built; on only with the owner's switch
$$;

-- When the first payment was confirmed, by the owner's rule; null while it isn't. Only a payment bound to our own
-- Stripe objects counts (written by zella_stripe_on_invoice_paid after the binding check); a trial counts only under
-- 'trial_with_card', from the trial Stripe confirmed.
create or replace function public.zella_onboarding_payment_confirmed_at(p_business_id uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select case public.zella_onboarding_rules() ->> 'first_payment'
    when 'pay_before_live' then (select min(p.paid_at) from public.payments p
                                  where p.business_id = p_business_id and p.status in ('succeeded', 'refunded') and p.provider = 'stripe'
                                    and p.paid_at is not null and p.metadata ->> 'bound' = 'true')
    when 'trial_with_card' then (select min(c.updated_at) from public.billing_checkouts c
                                  where c.business_id = p_business_id and c.status = 'paid')
    else null end;
$$;

create or replace function public.zella_onboarding_payment(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_at timestamptz := public.zella_onboarding_payment_confirmed_at(p_business_id); v_identity_done boolean; c public.billing_checkouts;
  v_live boolean := public.zella_payments_live();
begin
  v_identity_done := exists (select 1 from public.owner_onboarding_steps where business_id = p_business_id and step = 'identity' and completed_at is not null);
  select * into c from public.billing_checkouts where business_id = p_business_id order by created_at desc limit 1;
  return jsonb_build_object(
    'status', case when v_at is not null then 'confirmed' when not v_identity_done then 'locked' else 'waiting' end,
    'reason', case when v_at is not null then null when not v_identity_done then 'identity_first'
                   when not v_live then 'payments_not_connected'
                   when c.status = 'completed' then 'processing'                 -- back from Stripe, the webhook hasn't confirmed yet
                   when c.status = 'open' and c.expires_at > now() then 'checkout_open'
                   else 'checkout_not_started' end,
    'checkout_available', v_at is null and v_identity_done and v_live,
    'due_now_minor', (select case when bp.trial_enabled and public.zella_onboarding_rules() ->> 'first_payment' = 'trial_with_card' then 0
                                  else bp.price_cents + bp.setup_fee_cents end
                        from public.business_plans bp where bp.business_id = p_business_id order by bp.version desc limit 1),
    'checkout', case when c.id is null or v_at is not null then null else jsonb_build_object('mode', c.mode, 'amount_minor', c.first_amount_minor, 'currency', 'usd',
                     'url', case when c.status = 'open' and c.expires_at > now() then c.url end, 'expires_at', c.expires_at, 'trial_end_at', c.trial_end_at) end,
    'confirmed_at', v_at);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Start Checkout
-- ---------------------------------------------------------------------------------------------------------------
-- Queues the next command the checkout needs: customer, product, plan price, setup fee price, then the session.
-- Server only: the billing API calls it with its key's mode, each after-send step with the mode Stripe answered in.
create or replace function public.zella_billing_checkout_continue(p_checkout_id uuid, p_livemode boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare c public.billing_checkouts; p public.business_plans; v_cus text; v_prod text; v_price text; v_fee text; v_app text; o public.billing_outbox;
  v_live boolean := coalesce(p_livemode, false);   -- the mode of the key that will send it (links are kept per mode)
begin
  select * into c from public.billing_checkouts where id = p_checkout_id for update;
  if c.id is null or c.status <> 'preparing' then return null; end if;
  select * into p from public.business_plans where id = c.business_plan_id;
  v_cus := (select stripe_id from public.billing_stripe_links where business_id = c.business_id and kind = 'customer' and livemode = v_live);
  v_prod := (select stripe_id from public.billing_stripe_links where business_id = c.business_id and kind = 'product' and livemode = v_live order by created_at limit 1);
  v_price := (select stripe_id from public.billing_stripe_links where local_id = p.id and local_kind = 'plan_price' and livemode = v_live);
  v_fee := (select stripe_id from public.billing_stripe_links where local_id = p.id and local_kind = 'setup_fee_price' and livemode = v_live);
  if v_cus is null then
    o := public.zella_billing_outbox_add(c.business_id, 'customer', 'customer:' || c.business_id, 'POST', '/v1/customers',
      jsonb_build_object('metadata', jsonb_build_object('business_id', c.business_id)), 'checkout', c.id);
  elsif v_prod is null then
    o := public.zella_billing_outbox_add(c.business_id, 'product', 'product:' || c.business_id, 'POST', '/v1/products',
      jsonb_build_object('name', 'Zella Voice plan', 'metadata', jsonb_build_object('business_id', c.business_id)), 'checkout', c.id);
  elsif v_price is null then
    o := public.zella_billing_outbox_add(c.business_id, 'price', 'price:' || p.id, 'POST', '/v1/prices',
      jsonb_build_object('product', v_prod, 'currency', 'usd', 'unit_amount', p.price_cents,
        'recurring', jsonb_build_object('interval', case p.billing_interval when 'yearly' then 'year' else 'month' end),
        'metadata', jsonb_build_object('business_id', c.business_id, 'plan_version_id', p.id, 'kind', 'plan_price')), 'checkout', c.id);
  elsif p.setup_fee_cents > 0 and v_fee is null then
    o := public.zella_billing_outbox_add(c.business_id, 'price', 'price:' || p.id || ':setup', 'POST', '/v1/prices',
      jsonb_build_object('product', v_prod, 'currency', 'usd', 'unit_amount', p.setup_fee_cents,
        'metadata', jsonb_build_object('business_id', c.business_id, 'plan_version_id', p.id, 'kind', 'setup_fee_price')), 'checkout', c.id);
  else
    v_app := nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), '');
    if v_app is null or v_app !~ '^https://[^/?#]+' then raise exception 'APP_URL_MISSING'; end if;
    o := public.zella_billing_outbox_add(c.business_id, 'checkout_session', 'checkout:' || c.id, 'POST', '/v1/checkout/sessions',
      jsonb_strip_nulls(jsonb_build_object('mode', 'subscription', 'customer', v_cus, 'client_reference_id', c.id,
        'line_items', case when c.mode = 'pay' and v_fee is not null
                           then jsonb_build_array(jsonb_build_object('price', v_price, 'quantity', 1), jsonb_build_object('price', v_fee, 'quantity', 1))
                           else jsonb_build_array(jsonb_build_object('price', v_price, 'quantity', 1)) end,
        'success_url', rtrim(v_app, '/') || '/welcome/setup?business=' || c.business_id || '&checkout=return&session_id={CHECKOUT_SESSION_ID}',
        'cancel_url', rtrim(v_app, '/') || '/welcome/setup?business=' || c.business_id || '&checkout=cancelled',
        'payment_method_collection', 'always',
        'metadata', jsonb_build_object('business_id', c.business_id, 'checkout_id', c.id),
        'subscription_data', jsonb_strip_nulls(jsonb_build_object('metadata', jsonb_build_object('business_id', c.business_id, 'checkout_id', c.id),
                                                                  'trial_end', extract(epoch from c.trial_end_at)::bigint)))), 'checkout', c.id);
  end if;
  -- a setup command Stripe refused for good (held for a person) never leaves this Checkout waiting: it fails, and the
  -- owner's next start is a new attempt (the held command still needs the person the alert asked for)
  if o.status = 'held' then
    update public.billing_checkouts set status = 'failed', updated_at = now() where id = c.id;
    return null;
  end if;
  return o.id;
end $$;

create or replace function public.zella_owner_billing_checkout_start(p_business_id uuid, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding; p public.business_plans; c public.billing_checkouts; v_trial boolean; s jsonb := public.zella_billing_settings();
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then raise exception 'INVALID_INPUT'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  perform 1 from public.businesses where id = p_business_id for update;   -- one start at a time per business
  if public.zella_onboarding_payment_confirmed_at(p_business_id) is not null then raise exception 'ALREADY_PAID'; end if;
  select * into o from public.owner_onboarding where business_id = p_business_id;
  if o.current_step is distinct from 'payment' then raise exception 'STEP_LOCKED'; end if;
  select * into p from public.business_plans where business_id = p_business_id order by version desc limit 1;
  if p.id is null then raise exception 'PLAN_MISSING'; end if;
  if p.version is distinct from o.plan_accepted_version then raise exception 'PLAN_CHANGED'; end if;
  -- the same key returns the same checkout (a double click); another key while one is in progress returns that one
  -- (two tabs, or a payment Stripe took that the webhook hasn't confirmed yet: 'completed' stays until it is paid)
  select * into c from public.billing_checkouts where business_id = p_business_id and idempotency_key = p_idempotency_key;
  if c.id is null then
    select * into c from public.billing_checkouts where business_id = p_business_id and status in ('preparing', 'open', 'expiring', 'completed') order by created_at desc limit 1;
    if c.id is not null and c.status in ('preparing', 'open') and (c.business_plan_id <> p.id or (c.status = 'open' and c.expires_at <= now())) then
      if c.status = 'open' and c.expires_at > now() and c.stripe_session_id is not null then
        -- the old session could still be paid at Stripe: Stripe expires it first; a new one is offered only after Stripe
        -- confirms (zella_stripe_after_checkout_expire). If it was paid meanwhile, that payment is processed as usual.
        update public.billing_checkouts set status = 'expiring', url = null, updated_at = now() where id = c.id;
        perform public.zella_billing_outbox_add(p_business_id, 'checkout_expire', 'checkoutexpire:' || c.id, 'POST',
          '/v1/checkout/sessions/' || c.stripe_session_id || '/expire', '{}'::jsonb, 'checkout', c.id);
        select * into c from public.billing_checkouts where id = c.id;
      else
        update public.billing_checkouts set status = 'expired', updated_at = now() where id = c.id;
        c := null;
      end if;
    end if;
  end if;
  if c.id is null then
    v_trial := p.trial_enabled and public.zella_onboarding_rules() ->> 'first_payment' = 'trial_with_card';
    insert into public.billing_checkouts (business_id, business_plan_id, mode, first_amount_minor, setup_fee_minor, trial_end_at, idempotency_key, created_by)
    values (p_business_id, p.id, case when v_trial then 'trial' else 'pay' end, case when v_trial then 0 else p.price_cents + p.setup_fee_cents end,
            p.setup_fee_cents, case when v_trial then now() + make_interval(days => (s ->> 'trial_days')::int) end, p_idempotency_key, auth.uid())
    returning * into c;
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
    values (p_business_id, auth.uid(), 'billing.checkout_started', 'billing_checkout', c.id,
            jsonb_build_object('mode', c.mode, 'amount_minor', c.first_amount_minor, 'plan_version', p.version));
  end if;
  return jsonb_build_object('checkout_id', c.id, 'status', c.status, 'mode', c.mode, 'amount_minor', c.first_amount_minor, 'currency', 'usd',
                            'url', case when c.status = 'open' and c.expires_at > now() then c.url end);
end $$;

-- The checkout's next command still to send (the billing API sends them at once, so the owner waits seconds, not minutes).
create or replace function public.zella_billing_checkout_next_command(p_checkout_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.billing_outbox where local_kind = 'checkout' and local_id = p_checkout_id and status in ('pending', 'retry_wait')
   order by created_at limit 1;
$$;

-- After each command: link what Stripe made, then queue the next one.
create or replace function public.zella_stripe_after_customer(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.zella_stripe_link_add(r.stripe_id, 'customer', r.business_id, (r.response ->> 'livemode')::boolean);
  if r.local_kind = 'checkout' then perform public.zella_billing_checkout_continue(r.local_id, (r.response ->> 'livemode')::boolean); end if;
end $$;

create or replace function public.zella_stripe_after_product(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.zella_stripe_link_add(r.stripe_id, 'product', r.business_id, (r.response ->> 'livemode')::boolean);
  if r.local_kind = 'checkout' then perform public.zella_billing_checkout_continue(r.local_id, (r.response ->> 'livemode')::boolean); end if;
end $$;

create or replace function public.zella_stripe_after_price(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (r.response ->> 'unit_amount')::bigint is distinct from (r.body ->> 'unit_amount')::bigint then raise exception 'BINDING: Stripe price amount differs'; end if;
  perform public.zella_stripe_link_add(r.stripe_id, 'price', r.business_id, (r.response ->> 'livemode')::boolean, r.body #>> '{metadata,kind}',
                                       (r.body #>> '{metadata,plan_version_id}')::uuid, (r.body ->> 'unit_amount')::bigint);
  if r.local_kind = 'checkout' then perform public.zella_billing_checkout_continue(r.local_id, (r.response ->> 'livemode')::boolean); end if;
end $$;

create or replace function public.zella_stripe_after_checkout_session(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
declare c public.billing_checkouts;
begin
  select * into c from public.billing_checkouts where id = r.local_id for update;
  if (r.response ->> 'amount_total')::bigint is distinct from c.first_amount_minor and c.mode = 'pay' then
    perform public.zella_platform_alert('billing_checkout_amount', 'A Checkout total differs from the plan', null, 'urgent', r.business_id, 'checkout:' || c.id);
  end if;
  perform public.zella_stripe_link_add(r.stripe_id, 'checkout_session', r.business_id, (r.response ->> 'livemode')::boolean, 'checkout', c.id, c.first_amount_minor);
  update public.billing_checkouts set status = 'open', stripe_session_id = r.stripe_id, url = left(r.response ->> 'url', 2000),
         expires_at = coalesce(to_timestamp(nullif(r.response ->> 'expires_at', '')::double precision), now() + interval '23 hours'), updated_at = now()
   where id = c.id and status = 'preparing';
end $$;

create or replace function public.zella_stripe_failed_checkout_session(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_checkouts set status = 'failed', updated_at = now() where id = r.local_id and status = 'preparing';
$$;

-- A setup command (customer, product, price) Stripe refused for good: the Checkout that waited for it fails, so the
-- owner can start again; the held command stays for the person the outbox alert asked for.
create or replace function public.zella_stripe_failed_customer(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_checkouts set status = 'failed', updated_at = now() where id = r.local_id and r.local_kind = 'checkout' and status = 'preparing';
$$;
create or replace function public.zella_stripe_failed_product(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_checkouts set status = 'failed', updated_at = now() where id = r.local_id and r.local_kind = 'checkout' and status = 'preparing';
$$;
create or replace function public.zella_stripe_failed_price(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_checkouts set status = 'failed', updated_at = now() where id = r.local_id and r.local_kind = 'checkout' and status = 'preparing';
$$;

-- Stripe expired the old session (it can no longer be paid): the owner's next start opens a new one.
create or replace function public.zella_stripe_after_checkout_expire(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  if r.response ->> 'status' is distinct from 'expired' then raise exception 'BINDING: Stripe did not expire the session'; end if;
  update public.billing_checkouts set status = 'expired', url = null, updated_at = now() where id = r.local_id and status = 'expiring';
end $$;
-- If Stripe refuses to expire it (usually because it was just paid), nothing is replaced: the payment is processed
-- from its events, and the held command's alert asks a person to check.

-- ---------------------------------------------------------------------------------------------------------------
-- 2, 3. Events
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_stripe_on_checkout_session_completed(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'checkout_session'); c public.billing_checkouts; p public.business_plans;
begin
  if l.stripe_id is null then raise exception 'BINDING: checkout session is not ours'; end if;
  if o ->> 'customer' is distinct from public.zella_stripe_customer(l.business_id) then raise exception 'BINDING: checkout customer is not this business''s'; end if;
  if o ->> 'status' is distinct from 'complete' then raise exception 'BINDING: checkout session is not complete'; end if;
  if l.local_kind is distinct from 'checkout' then return 'ignored'; end if;   -- packs bought through Checkout are handled by their own flow
  select * into c from public.billing_checkouts where id = l.local_id for update;
  select * into p from public.business_plans where id = c.business_plan_id;
  if o ->> 'mode' is distinct from 'subscription' or coalesce(o ->> 'subscription', '') = '' then raise exception 'BINDING: checkout has no subscription'; end if;
  perform public.zella_stripe_link_add(o ->> 'subscription', 'subscription', l.business_id, l.livemode, 'checkout', c.id, null);
  insert into public.subscriptions (business_id, status, billing_interval, provider, external_subscription_id, metadata)
  values (l.business_id, 'pending_payment', p.billing_interval, 'stripe', o ->> 'subscription', jsonb_build_object('checkout_id', c.id))
  on conflict (business_id) do update set external_subscription_id = excluded.external_subscription_id, provider = 'stripe', updated_at = now()
   where subscriptions.status in ('pending_payment', 'cancelled', 'expired') or subscriptions.external_subscription_id is null;
  update public.billing_checkouts set status = case when status in ('preparing', 'open', 'expiring') then 'completed' else status end, stripe_subscription_id = o ->> 'subscription', updated_at = now()
   where id = c.id;
  -- the events that were waiting for this link are due again now (their invoice.paid usually is among them)
  update public.billing_events set next_attempt_at = now()
   where pipeline = 'stripe_v2' and status = 'received' and ordering_key = o ->> 'subscription' and error like 'WAITING:%';
  update public.billing_events set business_id = l.business_id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_checkout_session_expired(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'checkout_session');
begin
  if l.stripe_id is null then raise exception 'BINDING: checkout session is not ours'; end if;
  update public.billing_checkouts set status = 'expired', url = null, updated_at = now() where id = l.local_id and status in ('preparing', 'open', 'expiring');
  return 'applied';
end $$;

-- The first invoice of a subscription we created at Checkout. Pay: the amount must be exactly the plan price plus
-- the setup fee we computed, with only our prices on it. Trial: a $0 invoice whose period is Stripe's trial.
create or replace function public.zella_stripe_grant_subscription_create(o jsonb, b jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_biz uuid := (b ->> 'business_id')::uuid; c public.billing_checkouts; p public.business_plans; s public.subscriptions; per public.billing_periods;
  v_start timestamptz; v_end timestamptz; v_ours int; v_lines int;
begin
  if b ->> 'link_kind' <> 'subscription' or b ->> 'local_kind' is distinct from 'checkout' then raise exception 'BINDING: first invoice of a subscription we did not start'; end if;
  select * into c from public.billing_checkouts where id = (b ->> 'local_id')::uuid for update;
  select * into p from public.business_plans where id = c.business_plan_id;
  if (o ->> 'amount_paid')::bigint <> c.first_amount_minor then raise exception 'BINDING: paid % but the plan says %', o ->> 'amount_paid', c.first_amount_minor; end if;
  select count(*), count(*) filter (where l.business_id = v_biz and l.local_id = p.id) into v_lines, v_ours
    from jsonb_array_elements(o #> '{lines,data}') x
    left join public.billing_stripe_links l on l.kind = 'price' and l.stripe_id = coalesce(x #>> '{pricing,price_details,price}', x #>> '{price,id}');
  if v_lines = 0 or v_ours <> v_lines then raise exception 'BINDING: invoice lines are not our prices for this plan'; end if;
  select min(to_timestamp((x #>> '{period,start}')::double precision)), max(to_timestamp((x #>> '{period,end}')::double precision))
    into v_start, v_end from jsonb_array_elements(o #> '{lines,data}') x
   where exists (select 1 from public.billing_stripe_links l where l.kind = 'price' and l.local_kind = 'plan_price' and l.stripe_id = coalesce(x #>> '{pricing,price_details,price}', x #>> '{price,id}'));
  if v_start is null or v_end is null or v_end <= v_start then raise exception 'BINDING: invoice has no plan period'; end if;
  select * into s from public.subscriptions where business_id = v_biz for update;
  if s.id is null then raise exception 'WAITING: subscription row not created yet'; end if;
  if c.mode = 'trial' then
    if s.status not in ('pending_payment', 'trial') then return; end if;
    update public.subscriptions set status = 'trial', trial_start_at = v_start, trial_end_at = v_end, current_period_start = null, current_period_end = null,
           billing_interval = p.billing_interval, billing_event_at = greatest(coalesce(billing_event_at, now()), coalesce((b ->> 'event_created')::timestamptz, now())), updated_at = now()
     where id = s.id;
    if c.setup_fee_minor > 0 then   -- REQ-BIL-12: the setup fee goes on the first paid invoice, at the trial end
      perform public.zella_billing_outbox_add(v_biz, 'invoice_item', 'setupfee:' || c.id, 'POST', '/v1/invoiceitems',
        jsonb_build_object('customer', o ->> 'customer', 'subscription', b ->> 'subscription', 'amount', c.setup_fee_minor, 'currency', 'usd',
                           'description', 'Setup fee', 'metadata', jsonb_build_object('business_id', v_biz, 'kind', 'setup_fee', 'checkout_id', c.id)), 'checkout', c.id);
    end if;
  else
    if not public.zella_subscription_transition_ok(s.status, 'active') then raise exception 'BINDING: subscription is % and cannot become active', s.status; end if;
    update public.subscriptions set status = 'active', current_period_start = v_start, current_period_end = v_end, billing_interval = p.billing_interval,
           past_due_since = null, billing_event_at = greatest(coalesce(billing_event_at, now()), coalesce((b ->> 'event_created')::timestamptz, now())), updated_at = now()
     where id = s.id;
  end if;
  update public.billing_checkouts set status = 'paid', updated_at = now() where id = c.id;
  per := public.zella_billing_open_period(v_biz, greatest(v_start, least(now(), v_end - interval '1 second')));
  perform public.zella_notify_owners(v_biz, 'payment_received', case when c.mode = 'trial' then 'Your trial has started' else 'Payment received' end,
    case when c.mode = 'trial' then 'Your card is saved. Nothing is charged until your trial ends.' else 'Thank you. Your payment went through.' end, 'info', 'settings');
  insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
  values (v_biz, 'billing.first_payment_confirmed', 'billing_checkout', c.id, jsonb_build_object('mode', c.mode, 'amount_minor', (o ->> 'amount_paid')::bigint, 'invoice', o ->> 'id'));
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_billing_checkout_continue(uuid,boolean)', 'zella_billing_checkout_next_command(uuid)', 'zella_stripe_after_customer(billing_outbox)', 'zella_stripe_after_product(billing_outbox)',
    'zella_stripe_after_price(billing_outbox)', 'zella_stripe_after_checkout_session(billing_outbox)', 'zella_stripe_failed_checkout_session(billing_outbox)',
    'zella_stripe_failed_customer(billing_outbox)', 'zella_stripe_failed_product(billing_outbox)', 'zella_stripe_failed_price(billing_outbox)',
    'zella_stripe_after_checkout_expire(billing_outbox)',
    'zella_stripe_on_checkout_session_completed(billing_events,jsonb)', 'zella_stripe_on_checkout_session_expired(billing_events,jsonb)',
    'zella_stripe_grant_subscription_create(jsonb,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
-- the payment state and its Checkout link are read only through the owner functions, which check the caller first
revoke execute on function public.zella_onboarding_payment(uuid) from public, anon, authenticated;
revoke execute on function public.zella_onboarding_payment_confirmed_at(uuid) from public, anon, authenticated;
-- the rules constant (read by owners) now asks whether payments are live: a yes or no only
grant execute on function public.zella_payments_live() to authenticated;
revoke execute on function public.zella_owner_billing_checkout_start(uuid, text) from public, anon;
grant execute on function public.zella_owner_billing_checkout_start(uuid, text) to authenticated, service_role;

commit;
