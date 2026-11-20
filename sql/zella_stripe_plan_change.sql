-- Zella Voice: upgrade and downgrade with Stripe (docs/PAYMENTS_ARCHITECTURE.md §6.6, REQ-BIL-30), built switched off.
-- Plans are set per business by Zella Voice (rule plan_choice "accept_only"): an admin saves the new business_plans
-- version as today, then starts the change here; the owner sees the exact amount and confirms an upgrade.
--   - zella_admin_plan_change_start(business, plan version, reason) (billing.manage, audited): one open change per
--     subscription. The version's Stripe Price is created if needed (key price:<version>).
--   - Upgrade (higher price): Stripe's own preview of the prorated invoice (POST /v1/invoices/create_preview, with one
--     proration_date T stored on the change, valid 15 minutes) -> the owner confirms (zella_owner_plan_change_confirm,
--     code verified session) -> POST /v1/subscriptions/:id with the new Price, always_invoice, the SAME proration_date T
--     and pending_if_incomplete (key upgrade:<change id>), so Stripe applies the Price only if that invoice is paid.
--     invoice.paid with billing_reason subscription_update (zella_stripe_grant_subscription_update): the paid total must
--     equal the preview and every line must be this business's old or new Price; then the change is applied and the
--     prorated extra allowance for the rest of this period is added (integer, rounded down).
--   - Downgrade (lower price): a subscription schedule whose next phase, from the period end, uses the lower Price
--     (keys downgrade:<change id> and downgrade:<change id>:phases). Nothing is refunded or credited now.
--   - The subscription events also record Stripe's subscription item id and Price (archived handler replaced).
-- Rollback: sql/rollback/zella_stripe_plan_change_rollback.sql. Tests: tests/stripe_plan_change/run.sh.
begin;

do $$
declare s text; d text;
  known constant jsonb := '{
    "public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)": ["159c43b07625ac49bdd9deffcf244b5c", "c9b70ddd6dfdf324e93d3f2aa79d7ab4"]
  }';
  owned constant jsonb := '{
    "public.zella_admin_plan_change_start(uuid,uuid,text)": "613fbf10d8d84d39afac99a905f21a5e",
    "public.zella_plan_change_next(uuid)": "df0864c9ce6b9246aca4d0698ec5f0c1",
    "public.zella_stripe_after_change_price(billing_outbox)": "54ef182d2bffa4cd0eddde655ced000c",
    "public.zella_stripe_after_preview(billing_outbox)": "1120e19a16455e55364712309ef1a500",
    "public.zella_owner_plan_change_confirm(uuid,uuid)": "c48b353eb0ceff16706d2a0560eb2bc0",
    "public.zella_owner_plan_change(uuid)": "dda2436517e55a9f269d49d45609ff67",
    "public.zella_stripe_after_schedule(billing_outbox)": "cd6b54170113960f975f2a5a9b9a1006",
    "public.zella_stripe_failed_upgrade(billing_outbox)": "e813e7451754e058e7bc263c2c323eba",
    "public.zella_stripe_grant_subscription_update(jsonb,jsonb)": "84cc70fdbb9213ebb797c61042ebb9e2",
    "public.zella_stripe_on_customer_subscription_pending_update_expired(billing_events,jsonb)": "8827b643e7c370b4ca010a0615481cf2",
    "public.zella_admin_plan_change_cancel(uuid,text)": "cea6980e7a8a5996633fe5a877b5ab37",
    "public.zella_stripe_after_schedule_release(billing_outbox)": "326b8dbf19d29fdd543d12ac11a6d5ff",
    "public.zella_stripe_failed_schedule_release(billing_outbox)": "b2a06b9b50eac41d194923ec162cd9bb"
  }';
begin
  if to_regprocedure('public.zella_billing_ledger_check()') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_reconcile.sql'; end if;
  for s in select jsonb_object_keys(known) loop
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then
      insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_plan_change', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create table if not exists public.billing_plan_changes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  subscription_id uuid not null references public.subscriptions(id) on delete restrict,
  from_plan_id uuid not null references public.business_plans(id) on delete restrict,
  to_plan_id uuid not null references public.business_plans(id) on delete restrict,
  direction text not null check (direction in ('up', 'down')),
  status text not null default 'preparing' check (status in ('preparing', 'previewed', 'confirmed', 'applied', 'scheduled', 'failed', 'expired', 'cancelled')),
  proration_date bigint,
  preview_total_minor bigint check (preview_total_minor >= 0),
  preview_expires_at timestamptz,
  stripe_invoice_id text,
  stripe_schedule_id text,
  release_error text,   -- a person asked to cancel a scheduled downgrade and Stripe refused to release the schedule
  reason text not null,
  created_by uuid,
  confirmed_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.billing_plan_changes add column if not exists release_error text;
create unique index if not exists billing_plan_changes_one_open_uidx on public.billing_plan_changes (subscription_id) where status in ('preparing', 'previewed', 'confirmed');
alter table public.billing_plan_changes enable row level security;
revoke all on public.billing_plan_changes from anon, authenticated;
grant select, insert, update on public.billing_plan_changes to service_role;

-- The subscription events also keep Stripe's item id and Price (the change commands name the item). Otherwise unchanged.
create or replace function public.zella_stripe_on_customer_subscription_updated(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions; v_to text;
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null then raise exception 'WAITING: no local subscription'; end if;
  if s.external_subscription_id is distinct from o ->> 'id' then return 'ignored'; end if;   -- an earlier, replaced Stripe subscription
  if s.billing_event_at is not null and e.event_created_at < s.billing_event_at then return 'older'; end if;
  update public.subscriptions set metadata = metadata || jsonb_strip_nulls(jsonb_build_object('stripe_status', o ->> 'status',
           'cancel_at_period_end', (o ->> 'cancel_at_period_end')::boolean, 'stripe_trial_end', o ->> 'trial_end',
           'default_payment_method', coalesce(o #>> '{default_payment_method,id}', o ->> 'default_payment_method'),
           'stripe_item', o #>> '{items,data,0,id}', 'stripe_price', coalesce(o #>> '{items,data,0,price,id}', o #>> '{items,data,0,price}'))),
         billing_event_at = greatest(coalesce(billing_event_at, e.event_created_at), e.event_created_at), updated_at = now()
   where id = s.id;
  v_to := case o ->> 'status' when 'past_due' then 'past_due' when 'unpaid' then 'past_due' else null end;   -- active comes only from a paid invoice
  if v_to is not null and s.status <> v_to and public.zella_subscription_transition_ok(s.status, v_to) then
    update public.subscriptions set status = v_to, past_due_since = coalesce(past_due_since, now()) where id = s.id;
  end if;
  perform public.zella_stripe_cancel_check(e, o);   -- the owner's latest cancel choice against Stripe's
  -- a scheduled downgrade has taken effect once Stripe bills its lower Price: it is finished, and no longer blocks a change
  update public.billing_plan_changes c set status = 'applied', updated_at = now()
   where c.subscription_id = s.id and c.status = 'scheduled'
     and exists (select 1 from public.billing_stripe_links k where k.local_id = c.to_plan_id and k.local_kind = 'plan_price'
                  and k.stripe_id = coalesce(o #>> '{items,data,0,price,id}', o #>> '{items,data,0,price}'));
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

-- A person cancels a downgrade scheduled at Stripe (billing.manage, a reason, audited): Stripe releases the schedule
-- first (key release:<change id>); the change is cancelled only once Stripe confirms (zella_stripe_after_schedule_release).
create or replace function public.zella_admin_plan_change_cancel(p_change_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.billing_plan_changes; r public.billing_outbox;
begin
  if auth.uid() is null or not public.zella_admin_can('billing.manage') then raise exception 'NOT_ALLOWED'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into c from public.billing_plan_changes where id = p_change_id for update;
  if c.id is null then raise exception 'NOT_FOUND'; end if;
  if c.status <> 'scheduled' or c.stripe_schedule_id is null then raise exception 'INVALID_INPUT'; end if;
  -- Stripe refused this release before: the downgrade stays scheduled, and a person resolves the held command first
  if c.release_error is not null then raise exception 'RELEASE_REFUSED'; end if;
  r := public.zella_billing_outbox_add(c.business_id, 'schedule_release', 'release:' || c.id, 'POST',
    '/v1/subscription_schedules/' || c.stripe_schedule_id || '/release', '{}'::jsonb, 'plan_change', c.id);
  if r.status in ('held', 'cancelled') then raise exception 'RELEASE_REFUSED'; end if;
  if r.created_at < now() then return jsonb_build_object('change_id', c.id, 'status', 'releasing', 'changed', false); end if;   -- already asked: no second audit
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (c.business_id, auth.uid(), 'billing.plan_downgrade_cancelled', 'billing_plan_change', c.id, jsonb_build_object('reason', left(trim(p_reason), 500)));
  return jsonb_build_object('change_id', c.id, 'status', 'releasing', 'changed', true);
end $$;

-- Stripe refused to release the schedule: the downgrade stays scheduled (it still happens at the period end), the
-- refusal is recorded on the change, and the held command's alert asks a person to decide.
create or replace function public.zella_stripe_failed_schedule_release(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_plan_changes set release_error = left(coalesce(r.error, 'refused'), 300), updated_at = now() where id = r.local_id and status = 'scheduled';
$$;

create or replace function public.zella_stripe_after_schedule_release(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_plan_changes set status = 'cancelled', updated_at = now() where id = r.local_id and status = 'scheduled';
$$;

-- Queues the change's next command: the new version's Price, then the preview (up) or the schedule (down).
create or replace function public.zella_plan_change_next(p_change_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare c public.billing_plan_changes; s public.subscriptions; p public.business_plans; v_price text; v_prod text; v_t bigint;
begin
  select * into c from public.billing_plan_changes where id = p_change_id for update;
  if c.id is null or c.status <> 'preparing' then return null; end if;
  select * into s from public.subscriptions where id = c.subscription_id;
  select * into p from public.business_plans where id = c.to_plan_id;
  v_price := (select stripe_id from public.billing_stripe_links where local_id = p.id and local_kind = 'plan_price');
  if v_price is null then
    v_prod := (select stripe_id from public.billing_stripe_links where business_id = c.business_id and kind = 'product' order by created_at limit 1);
    if v_prod is null then raise exception 'NO_STRIPE_PRODUCT'; end if;
    return (public.zella_billing_outbox_add(c.business_id, 'change_price', 'price:' || p.id, 'POST', '/v1/prices',
      jsonb_build_object('product', v_prod, 'currency', 'usd', 'unit_amount', p.price_cents,
        'recurring', jsonb_build_object('interval', case p.billing_interval when 'yearly' then 'year' else 'month' end),
        'metadata', jsonb_build_object('business_id', c.business_id, 'plan_version_id', p.id, 'kind', 'plan_price')), 'plan_change', c.id)).id;
  end if;
  if c.direction = 'up' then
    v_t := extract(epoch from now())::bigint;
    update public.billing_plan_changes set proration_date = v_t, updated_at = now() where id = c.id;
    return (public.zella_billing_outbox_add(c.business_id, 'preview', 'preview:' || c.id || ':' || v_t, 'POST', '/v1/invoices/create_preview',
      jsonb_build_object('customer', public.zella_stripe_customer(c.business_id), 'subscription', s.external_subscription_id,
        'subscription_details', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('id', s.metadata ->> 'stripe_item', 'price', v_price)),
          'proration_behavior', 'always_invoice', 'proration_date', v_t)), 'plan_change', c.id)).id;
  end if;
  return (public.zella_billing_outbox_add(c.business_id, 'schedule', 'downgrade:' || c.id, 'POST', '/v1/subscription_schedules',
    jsonb_build_object('from_subscription', s.external_subscription_id), 'plan_change', c.id)).id;
end $$;

create or replace function public.zella_admin_plan_change_start(p_business_id uuid, p_plan_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions; p public.business_plans; cur public.billing_stripe_links; v public.billing_plan_changes; o public.business_plans;
begin
  if auth.uid() is null or not public.zella_admin_can('billing.manage') then raise exception 'NOT_ALLOWED'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe' for update;
  if s.id is null or s.status <> 'active' or s.metadata ->> 'stripe_item' is null then raise exception 'NO_ACTIVE_SUBSCRIPTION'; end if;
  select * into cur from public.billing_stripe_links where stripe_id = s.metadata ->> 'stripe_price' and kind = 'price' and business_id = p_business_id;
  select * into o from public.business_plans where id = cur.local_id;
  select * into p from public.business_plans where id = p_plan_id and business_id = p_business_id;
  if o.id is null or p.id is null or p.id = o.id then raise exception 'INVALID_INPUT'; end if;
  if p.billing_interval <> o.billing_interval then raise exception 'INTERVAL_CHANGE_NOT_BUILT'; end if;
  if p.price_cents = o.price_cents then raise exception 'SAME_PRICE'; end if;
  -- a preview past its 15 minutes no longer holds the one open change (its owner can't confirm it any more)
  update public.billing_plan_changes set status = 'expired', updated_at = now()
   where subscription_id = s.id and status = 'previewed' and preview_expires_at <= now();
  -- default chosen pending owner decision: a downgrade already scheduled at Stripe stays as it is, and no other change
  -- starts until it has taken effect or a person cancels it; both are never applied
  if exists (select 1 from public.billing_plan_changes where subscription_id = s.id and status = 'scheduled') then raise exception 'DOWNGRADE_SCHEDULED'; end if;
  insert into public.billing_plan_changes (business_id, subscription_id, from_plan_id, to_plan_id, direction, reason, created_by)
  values (p_business_id, s.id, o.id, p.id, case when p.price_cents > o.price_cents then 'up' else 'down' end, left(trim(p_reason), 500), auth.uid()) returning * into v;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'billing.plan_change_started', 'billing_plan_change', v.id, jsonb_build_object('direction', v.direction, 'from', o.version, 'to', p.version, 'reason', v.reason));
  perform public.zella_plan_change_next(v.id);
  return jsonb_build_object('change_id', v.id, 'direction', v.direction, 'status', v.status);
end $$;

create or replace function public.zella_stripe_after_change_price(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (r.response ->> 'unit_amount')::bigint is distinct from (r.body ->> 'unit_amount')::bigint then raise exception 'BINDING: Stripe price amount differs'; end if;
  perform public.zella_stripe_link_add(r.stripe_id, 'price', r.business_id, (r.response ->> 'livemode')::boolean, 'plan_price', (r.body #>> '{metadata,plan_version_id}')::uuid, (r.body ->> 'unit_amount')::bigint);
  perform public.zella_plan_change_next(r.local_id);
end $$;

-- Stripe's preview: the exact prorated amount the owner sees, valid 15 minutes with this proration time.
create or replace function public.zella_stripe_after_preview(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.billing_plan_changes set status = 'previewed', preview_total_minor = greatest((r.response ->> 'total')::bigint, 0),
         preview_expires_at = to_timestamp((r.body #>> '{subscription_details,proration_date}')::double precision) + interval '15 minutes', updated_at = now()
   where id = r.local_id and status = 'preparing' and proration_date = (r.body #>> '{subscription_details,proration_date}')::bigint;
  perform public.zella_notify_owners(r.business_id, 'plan_upgrade', 'Your new plan is ready to confirm',
    'Confirm it in Settings, Billing within 15 minutes to see the amount charged today.', 'info', 'settings');
end $$;

-- What the owner sees: the open change with Stripe's previewed amount (cents), if any.
create or replace function public.zella_owner_plan_change(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.billing_plan_changes; p public.business_plans;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  select * into c from public.billing_plan_changes where business_id = p_business_id and status in ('preparing', 'previewed', 'confirmed', 'scheduled') order by created_at desc limit 1;
  if c.id is null then return null; end if;
  select * into p from public.business_plans where id = c.to_plan_id;
  return jsonb_build_object('change_id', c.id, 'direction', c.direction, 'status', case when c.status = 'previewed' and c.preview_expires_at <= now() then 'expired' else c.status end,
    'amount_today_minor', c.preview_total_minor, 'currency', 'usd', 'expires_at', c.preview_expires_at,
    'plan', jsonb_build_object('tier', p.tier, 'price_cents', p.price_cents, 'minutes', p.minutes, 'texts', p.texts, 'emails', p.emails));
end $$;

-- The owner confirms the previewed upgrade: the update is sent with the SAME proration time, so Stripe charges the
-- previewed amount; a stale preview needs a fresh one (the admin starts it again).
create or replace function public.zella_owner_plan_change_confirm(p_business_id uuid, p_change_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.billing_plan_changes; s public.subscriptions; v_price text;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into c from public.billing_plan_changes where id = p_change_id and business_id = p_business_id for update;
  if c.id is null or c.direction <> 'up' then raise exception 'NOT_FOUND'; end if;
  if c.status = 'confirmed' then return jsonb_build_object('change_id', c.id, 'status', c.status, 'changed', false); end if;
  if c.status <> 'previewed' then raise exception 'INVALID_INPUT'; end if;
  if c.preview_expires_at <= now() then update public.billing_plan_changes set status = 'expired', updated_at = now() where id = c.id; raise exception 'PREVIEW_EXPIRED'; end if;
  select * into s from public.subscriptions where id = c.subscription_id;
  v_price := (select stripe_id from public.billing_stripe_links where local_id = c.to_plan_id and local_kind = 'plan_price');
  update public.billing_plan_changes set status = 'confirmed', confirmed_by = auth.uid(), updated_at = now() where id = c.id;
  perform public.zella_billing_outbox_add(c.business_id, 'upgrade', 'upgrade:' || c.id, 'POST', '/v1/subscriptions/' || s.external_subscription_id,
    jsonb_build_object('items', jsonb_build_array(jsonb_build_object('id', s.metadata ->> 'stripe_item', 'price', v_price)), 'proration_behavior', 'always_invoice',
      'proration_date', c.proration_date, 'payment_behavior', 'pending_if_incomplete', 'metadata', jsonb_build_object('change_id', c.id)), 'plan_change', c.id);
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (c.business_id, auth.uid(), 'billing.plan_upgrade_confirmed', 'billing_plan_change', c.id, jsonb_build_object('amount_today_minor', c.preview_total_minor));
  return jsonb_build_object('change_id', c.id, 'status', 'confirmed', 'changed', true);
end $$;

create or replace function public.zella_stripe_failed_upgrade(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_plan_changes set status = 'failed', updated_at = now() where id = r.local_id and status in ('preparing', 'previewed', 'confirmed');
$$;

-- Stripe dropped an unpaid pending upgrade (it voids that invoice): the confirmed change for this subscription fails,
-- so the plan stays as it was and a new change can start. Nothing is granted or charged here.
create or replace function public.zella_stripe_on_customer_subscription_pending_update_expired(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions; c public.billing_plan_changes;
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null or s.external_subscription_id is distinct from o ->> 'id' then return 'ignored'; end if;
  if o -> 'pending_update' is not null and jsonb_typeof(o -> 'pending_update') = 'object' then return 'older'; end if;   -- fetched now: a pending update is still there
  -- only the upgrade Stripe had made pending: its command was sent before this notice; a newer confirmed change whose
  -- command isn't sent yet is not the one that expired
  select * into c from public.billing_plan_changes x where x.subscription_id = s.id and x.status = 'confirmed'
     and exists (select 1 from public.billing_outbox b where b.kind = 'upgrade' and b.local_id = x.id and b.status = 'sent' and b.updated_at <= e.event_created_at)
   order by x.created_at desc limit 1 for update;
  if c.id is null then return 'ignored'; end if;
  update public.billing_plan_changes set status = 'failed', updated_at = now() where id = c.id;
  perform public.zella_notify_owners(l.business_id, 'plan_upgrade', 'Your plan upgrade did not go through',
    'The payment for your new plan was not completed, so your plan stays as it was. Nothing extra was charged.', 'warning', 'settings');
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

-- Downgrade: the schedule is made from the subscription, then its phases are set: this period at the current Price,
-- then the lower Price from the period end.
create or replace function public.zella_stripe_after_schedule(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
declare c public.billing_plan_changes; s public.subscriptions; v_old text; v_new text;
begin
  select * into c from public.billing_plan_changes where id = r.local_id for update;
  if r.path = '/v1/subscription_schedules' then
    perform public.zella_stripe_link_add(r.stripe_id, 'schedule', r.business_id, (r.response ->> 'livemode')::boolean, 'plan_change', c.id, null);
    select * into s from public.subscriptions where id = c.subscription_id;
    v_old := (select stripe_id from public.billing_stripe_links where local_id = c.from_plan_id and local_kind = 'plan_price');
    v_new := (select stripe_id from public.billing_stripe_links where local_id = c.to_plan_id and local_kind = 'plan_price');
    update public.billing_plan_changes set stripe_schedule_id = r.stripe_id, updated_at = now() where id = c.id;
    perform public.zella_billing_outbox_add(c.business_id, 'schedule', 'downgrade:' || c.id || ':phases', 'POST', '/v1/subscription_schedules/' || r.stripe_id,
      jsonb_build_object('end_behavior', 'release', 'phases', jsonb_build_array(
        jsonb_build_object('items', jsonb_build_array(jsonb_build_object('price', v_old, 'quantity', 1)), 'start_date', extract(epoch from s.current_period_start)::bigint, 'end_date', extract(epoch from s.current_period_end)::bigint),
        jsonb_build_object('items', jsonb_build_array(jsonb_build_object('price', v_new, 'quantity', 1)), 'iterations', 1))), 'plan_change', c.id);
  else
    update public.billing_plan_changes set status = 'scheduled', updated_at = now() where id = c.id and status = 'preparing';
    perform public.zella_notify_owners(c.business_id, 'plan_downgrade', 'Your plan changes at your next renewal', 'Your current plan stays until the end of this period.', 'info', 'settings');
  end if;
end $$;

-- invoice.paid, billing_reason subscription_update: the confirmed upgrade, paid at the previewed amount.
create or replace function public.zella_stripe_grant_subscription_update(o jsonb, b jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_biz uuid := (b ->> 'business_id')::uuid; c public.billing_plan_changes; s public.subscriptions; x jsonb; v_price text; po public.business_plans; pn public.business_plans;
  v_left numeric; per public.billing_periods; r text; v_extra bigint; v_at timestamptz;
begin
  select * into c from public.billing_plan_changes where business_id = v_biz and status = 'confirmed' order by created_at desc limit 1 for update;
  if c.id is null then raise exception 'BINDING: a plan change invoice with no confirmed change'; end if;
  -- the invoice total must be the previewed total (Stripe's credit balance can lower what the card paid; that it was
  -- paid in full is checked by the binding check)
  if (o ->> 'total')::bigint is distinct from c.preview_total_minor then raise exception 'BINDING: invoice total % but the preview said %', o ->> 'total', c.preview_total_minor; end if;
  for x in select * from jsonb_array_elements(o #> '{lines,data}') loop
    v_price := coalesce(x #>> '{pricing,price_details,price}', x #>> '{price,id}');
    if not exists (select 1 from public.billing_stripe_links where stripe_id = v_price and kind = 'price' and business_id = v_biz and local_id in (c.from_plan_id, c.to_plan_id)) then
      raise exception 'BINDING: a line that is not the old or new plan price';
    end if;
  end loop;
  select * into s from public.subscriptions where id = c.subscription_id for update;
  select * into po from public.business_plans where id = c.from_plan_id; select * into pn from public.business_plans where id = c.to_plan_id;
  update public.billing_plan_changes set status = 'applied', stripe_invoice_id = o ->> 'id', updated_at = now() where id = c.id;
  update public.subscriptions set metadata = metadata || jsonb_build_object('stripe_price', (select stripe_id from public.billing_stripe_links where local_id = c.to_plan_id and local_kind = 'plan_price')) where id = s.id;
  -- REQ-BIL-30: the extra allowance for the rest of the period, prorated, rounded down: from the proration time the
  -- charge used (stored on the change), in the period that time falls in, so a late event grants the same amount
  v_at := to_timestamp(c.proration_date);
  per := public.zella_billing_open_period(v_biz, v_at);
  -- the period the charge covered can't be found (never opened, and no longer the current one): a person decides the
  -- extra allowance; nothing is marked applied without it
  if per.id is null then raise exception 'BINDING: no billing period for the upgrade''s proration time'; end if;
  if per.id is not null then
    v_left := greatest(0, extract(epoch from per.period_end - v_at)) / nullif(extract(epoch from per.period_end - per.period_start), 0);
    foreach r in array array['minutes', 'texts', 'emails'] loop
      v_extra := floor(greatest(0, case r when 'minutes' then pn.minutes - po.minutes when 'texts' then pn.texts - po.texts else pn.emails - po.emails end) * coalesce(v_left, 0));
      if v_extra > 0 then
        update public.allowance_buckets set granted = granted + v_extra where period_id = per.id and resource = r and kind = 'plan';
        if not found then insert into public.allowance_buckets (business_id, period_id, resource, kind, granted, expires_at) values (v_biz, per.id, r, 'plan', v_extra, per.period_end); end if;
      end if;
    end loop;
  end if;
  insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
  values (v_biz, 'billing.plan_upgraded', 'billing_plan_change', c.id, jsonb_build_object('paid_minor', (o ->> 'amount_paid')::bigint, 'to_version', pn.version));
  perform public.zella_notify_owners(v_biz, 'plan_upgraded', 'Your plan is upgraded', 'Your new plan is active now, with extra allowance for the rest of this period.', 'info', 'settings');
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_plan_change_next(uuid)', 'zella_stripe_after_change_price(billing_outbox)', 'zella_stripe_after_preview(billing_outbox)', 'zella_stripe_after_schedule(billing_outbox)',
    'zella_stripe_failed_upgrade(billing_outbox)', 'zella_stripe_grant_subscription_update(jsonb,jsonb)',
    'zella_stripe_on_customer_subscription_pending_update_expired(billing_events,jsonb)', 'zella_stripe_after_schedule_release(billing_outbox)',
    'zella_stripe_failed_schedule_release(billing_outbox)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_admin_plan_change_start(uuid,uuid,text)', 'zella_owner_plan_change_confirm(uuid,uuid)', 'zella_owner_plan_change(uuid)',
    'zella_admin_plan_change_cancel(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

commit;
