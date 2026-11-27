-- Zella Voice: the first payment with Stripe's card fields in our page (owner, 27 Nov 2026: the onboarding Pay step
-- becomes a glass checkout with Stripe's own fields mounted inside our page; docs/PAYMENTS_ARCHITECTURE.md G1, §6.1, §16).
-- (The file keeps its first name, embedded_checkout; the session is ui_mode "custom", Checkout Sessions with Elements.)
--
--   1. zella_billing_checkout_continue: the Checkout Session it queues now asks Stripe for ui_mode "custom" with a
--      return_url, instead of success_url and cancel_url (Stripe refuses both with an in page session). The metadata
--      also carries the plan version. Everything else is unchanged: the same
--      customer, prices, line items, trial, idempotency key (checkout:<id>) and stored body (§8.1). Card details are
--      still typed only into Stripe's own form, in Stripe's frame (NN-9).
--   2. zella_billing_checkout_session (new, server only): the business's latest checkout with its Stripe session id,
--      so billing-api can fetch that session from Stripe and hand its client_secret to the owner's browser. The client
--      secret is never stored (zella_billing_outbox_result already drops it from every stored response).
-- Needs sql/zella_stripe_checkout.sql (this file refuses unless that file's version of the function is in place, and
-- archives it first). Rollback: sql/rollback/zella_stripe_embedded_checkout_rollback.sql (refuses on drift, and while a
-- checkout is still open, so no in page session is left without the page that can show it).
-- Tests: tests/stripe_embedded_checkout/run.sh, tests/stripe_checkout/flow_test.ts.
begin;

do $$
declare d text;
  s constant text := 'public.zella_billing_checkout_continue(uuid,boolean)';
  v_from constant text := '7f998f18370021b4668ce06f057d0055';   -- sql/zella_stripe_checkout.sql's version
  v_to constant text := 'bc675ce2a18d443bfd0d1bc0e64e4344';     -- this file's version
begin
  if to_regclass('public.billing_checkouts') is null or to_regclass('public.zella_function_archive') is null or to_regprocedure(s) is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_checkout.sql';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = v_from then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_stripe_embedded_checkout', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> v_to then
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  if to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)') is not null then
    if md5(pg_get_functiondef(to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)'))) <> '4338711a1aad11ba1b708695aaf122fb' then
      raise exception 'VERSION_MISMATCH: public.zella_billing_checkout_session(uuid,uuid) is not the version this file makes';
    end if;
  end if;
end $$;

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
        -- Stripe's card fields inside our page (owner, 27 Nov 2026): a Checkout Session for Stripe Elements (ui_mode
        -- custom); no success or cancel page. Stripe returns to return_url only when a payment method needs a redirect;
        -- otherwise the page confirms in place.
        'ui_mode', 'custom',
        'return_url', rtrim(v_app, '/') || '/welcome/setup?business=' || c.business_id || '&checkout=return&session_id={CHECKOUT_SESSION_ID}',
        'payment_method_collection', 'always',
        'metadata', jsonb_build_object('business_id', c.business_id, 'checkout_id', c.id, 'plan_version_id', c.business_plan_id),
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

-- The business's latest checkout (or the one named), for billing-api only: it fetches that session from Stripe with the
-- server key, checks it is ours, open and ui_mode custom, and passes on its client_secret. Never readable by a signed in user.
create or replace function public.zella_billing_checkout_session(p_business_id uuid, p_checkout_id uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('checkout_id', c.id, 'status', c.status, 'stripe_session_id', c.stripe_session_id, 'expires_at', c.expires_at,
                            'mode', c.mode, 'amount_minor', c.first_amount_minor, 'currency', 'usd', 'plan_version_id', c.business_plan_id)
    from public.billing_checkouts c
   where c.business_id = p_business_id and (p_checkout_id is null or c.id = p_checkout_id)
   order by c.created_at desc limit 1;
$$;

revoke execute on function public.zella_billing_checkout_continue(uuid, boolean) from public, anon, authenticated;
grant execute on function public.zella_billing_checkout_continue(uuid, boolean) to service_role;
revoke execute on function public.zella_billing_checkout_session(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_billing_checkout_session(uuid, uuid) to service_role;

-- what this file made is exactly what it says it makes
do $$ begin
  if md5(pg_get_functiondef('public.zella_billing_checkout_continue(uuid,boolean)'::regprocedure)) <> 'bc675ce2a18d443bfd0d1bc0e64e4344'
     or md5(pg_get_functiondef('public.zella_billing_checkout_session(uuid,uuid)'::regprocedure)) <> '4338711a1aad11ba1b708695aaf122fb' then
    raise exception 'VERSION_MISMATCH: the functions made differ from this file''s versions';
  end if;
end $$;

commit;
