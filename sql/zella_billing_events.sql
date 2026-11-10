-- Zella - billing events, renewal checks and plan entitlements. Safe to run more than once.
-- The billing webhook (edge function) turns the payment provider's events into a few plain event types and calls
-- zella_process_billing_event. Each provider event is handled once. Nothing here charges anyone.

create table if not exists public.billing_events (
  id uuid primary key default gen_random_uuid(), provider text not null, external_event_id text not null, type text not null,
  business_id uuid, subscription_id uuid, data jsonb not null default '{}'::jsonb,
  status text not null default 'processed' check (status in ('processed','ignored','failed')), error text,
  received_at timestamptz not null default now(), unique (provider, external_event_id));
alter table public.billing_events enable row level security;   -- no policies: service role only

create or replace function public.zella_process_billing_event(
  p_provider text, p_event_id text, p_type text, p_external_subscription_id text default null, p_business_id uuid default null,
  p_amount numeric default null, p_currency text default null, p_external_payment_id text default null,
  p_period_start timestamptz default null, p_period_end timestamptz default null, p_plan_slug text default null, p_reason text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s record; v_biz uuid; v_plan uuid; v_res text := 'processed'; v_ins uuid;
begin
  insert into public.billing_events (provider, external_event_id, type, business_id, data)
  values (left(p_provider, 40), left(p_event_id, 200), left(p_type, 60), p_business_id,
          jsonb_build_object('external_subscription_id', p_external_subscription_id, 'external_payment_id', p_external_payment_id, 'amount', p_amount, 'currency', p_currency, 'plan', p_plan_slug))
  on conflict (provider, external_event_id) do nothing returning id into v_ins;
  if v_ins is null then return 'duplicate'; end if;

  begin
    -- A refund or dispute names a payment, not a subscription: find the business from that payment.
    if p_type = 'payment_reversed' and p_external_subscription_id is null and p_business_id is null then
      select pm.business_id into p_business_id from public.payments pm where pm.external_payment_id = p_external_payment_id limit 1;
    end if;
    select * into s from public.subscriptions
     where (p_external_subscription_id is not null and external_subscription_id = p_external_subscription_id)
        or (p_external_subscription_id is null and p_business_id is not null and business_id = p_business_id)
     order by created_at desc limit 1;
    if s.id is null then
      update public.billing_events set status = 'ignored', error = 'no_matching_subscription' where id = v_ins;
      return 'ignored';
    end if;
    v_biz := s.business_id;
    update public.billing_events set business_id = v_biz, subscription_id = s.id where id = v_ins;

    if p_type = 'payment_succeeded' then
      insert into public.payments (business_id, subscription_id, amount, currency, status, provider, external_payment_id, paid_at)
      values (v_biz, s.id, coalesce(p_amount, 0), coalesce(lower(p_currency), 'usd'), 'succeeded', p_provider, p_external_payment_id, now());
      perform public.zella_record_payment_result(v_biz, true, p_external_payment_id, null);
      if p_period_end is not null then
        update public.subscriptions set current_period_start = coalesce(p_period_start, current_period_start), current_period_end = p_period_end where id = s.id;
      end if;
      perform public.zella_notify_owners(v_biz, 'payment_received', 'Payment received', 'Thank you. Your payment went through and your account is up to date.', 'info', 'settings');
    elsif p_type = 'payment_failed' then
      insert into public.payments (business_id, subscription_id, amount, currency, status, provider, external_payment_id, failure_reason)
      values (v_biz, s.id, coalesce(p_amount, 0), coalesce(lower(p_currency), 'usd'), 'failed', p_provider, p_external_payment_id, left(p_reason, 300));
      perform public.zella_record_payment_result(v_biz, false, p_external_payment_id, coalesce(p_reason, 'Payment failed'));
      perform public.zella_notify_owners(v_biz, 'payment_failed', 'Your payment did not go through', 'Please update your billing details so your service is not interrupted.', 'urgent', 'settings');
    elsif p_type = 'subscription_renewed' then
      update public.subscriptions set status = 'active', current_period_start = coalesce(p_period_start, current_period_start),
             current_period_end = coalesce(p_period_end, current_period_end) where id = s.id;
    elsif p_type = 'subscription_cancelled' then
      update public.subscriptions set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()) where id = s.id and status <> 'cancelled';
      perform public.zella_notify_owners(v_biz, 'subscription_cancelled', 'Your subscription was cancelled', 'Your plan has been cancelled. Contact support if this is a mistake.', 'warning', 'settings');
    elsif p_type = 'payment_reversed' then
      update public.payments set status = 'refunded', updated_at = now() where business_id = v_biz and external_payment_id = p_external_payment_id;
      perform public.zella_platform_alert('payment_reversed', 'A payment was refunded or disputed', left(p_reason, 300), 'warning', v_biz, 'payment_reversed:' || coalesce(p_external_payment_id, ''));
    elsif p_type = 'plan_changed' then
      select id into v_plan from public.plans where slug = p_plan_slug and is_active;
      if v_plan is null then
        update public.billing_events set status = 'ignored', error = 'unknown_plan' where id = v_ins; v_res := 'ignored';
      else
        update public.subscriptions set plan_id = v_plan where id = s.id;
      end if;
    else
      update public.billing_events set status = 'ignored', error = 'unknown_type' where id = v_ins; v_res := 'ignored';
    end if;
    return v_res;
  exception when others then
    -- The event row is removed so the provider's retry is processed again; the alert stays so a person sees it.
    delete from public.billing_events where id = v_ins;
    perform public.zella_platform_alert('billing_event_failed', 'A billing event could not be applied', left(sqlerrm, 200), 'urgent', p_business_id, 'billing_event_failed');
    return 'failed';   -- the webhook answers with an error
  end;
end $$;

-- What the business's plan allows. Members can read it; limits are checked with zella_within_plan_limit.
create or replace function public.zella_entitlements(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select jsonb_build_object('plan', p.slug, 'status', s.status, 'features', coalesce(p.features, '{}'::jsonb), 'limits', coalesce(p.limits, '{}'::jsonb),
                            'active', s.status in ('trial','active','renewal_due','past_due','grace_period'))
    into r from public.subscriptions s join public.plans p on p.id = s.plan_id
   where s.business_id = p_business_id order by s.created_at desc limit 1;
  return coalesce(r, jsonb_build_object('plan', null, 'status', 'none', 'features', '{}'::jsonb, 'limits', '{}'::jsonb, 'active', false));
end $$;

create or replace function public.zella_within_plan_limit(p_business_id uuid, p_key text, p_current numeric)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v jsonb := public.zella_entitlements(p_business_id) -> 'limits' -> p_key;
begin
  if v is null or jsonb_typeof(v) <> 'number' then return true; end if;   -- no limit set for this key
  return p_current < (v #>> '{}')::numeric;
end $$;

-- Daily: warn owners three days before the period ends; a period that ended with no payment goes past due.
create or replace function public.zella_check_renewals()
returns integer language plpgsql security definer set search_path = public as $$
declare s record; n integer := 0;
begin
  for s in select * from public.subscriptions where status = 'active' and current_period_end is not null
            and current_period_end < now() + interval '3 days' and current_period_end > now() for update skip locked loop
    update public.subscriptions set status = 'renewal_due' where id = s.id;
    perform public.zella_notify_owners(s.business_id, 'renewal_upcoming', 'Your plan renews soon', 'Your plan renews in the next few days. Make sure your billing details are up to date.', 'info', 'settings');
    n := n + 1;
  end loop;
  for s in select * from public.subscriptions where status in ('active', 'renewal_due') and current_period_end is not null
            and current_period_end < now() - interval '2 days' and provider is not null for update skip locked loop
    perform public.zella_record_payment_result(s.business_id, false, null, 'No payment received for the new period');
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  revoke execute on function public.zella_process_billing_event(text,text,text,text,uuid,numeric,text,text,timestamptz,timestamptz,text,text), public.zella_check_renewals(), public.zella_within_plan_limit(uuid,text,numeric) from public, anon, authenticated;
  grant execute on function public.zella_process_billing_event(text,text,text,text,uuid,numeric,text,text,timestamptz,timestamptz,text,text), public.zella_check_renewals(), public.zella_within_plan_limit(uuid,text,numeric) to service_role;
  revoke execute on function public.zella_entitlements(uuid) from public, anon;
  grant execute on function public.zella_entitlements(uuid) to authenticated, service_role;
end $$;
