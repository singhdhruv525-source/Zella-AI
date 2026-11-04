-- Zella - billing events: durable retry, ordering, idempotent payments, exact currency amounts (2026-11-04).
-- Safe to re-run. Needs: zella_billing_events.sql. Deploy order: this file, then the billing-webhook function.
-- Live data when written: 0 billing events, 0 payments, 0 subscriptions, so no existing rows are converted.
--
-- Problems fixed
--   1. An event whose subscription wasn't known yet was stored as 'ignored' and answered 200; the provider's later
--      retries got 'duplicate', so it was lost for good. Now it waits as 'pending' with its arguments and is applied
--      when its subscription or payment appears (trigger + zella_reconcile_billing_events), or a redelivery comes.
--   2. A failing event was deleted to let the provider retry. Now it stays as 'failed' (with the error) and a
--      redelivery applies it again; nothing is lost from the record.
--   3. Out-of-order delivery could move a subscription backwards (an older "renewed" after "cancelled", an older
--      "payment failed" after a newer success). Status changes now apply only if the event is not older than the
--      last one applied to that subscription (subscriptions.billing_event_at, from the provider's event time).
--   4. Payments are one row per provider payment id (unique), moving only forward: failed -> succeeded -> refunded.
--      A retry that succeeds updates the failed row instead of adding a second payment.
--   5. Refunds: a partial refund no longer marks the whole payment refunded; disputes no longer count as refunds
--      until the dispute is lost.
--   6. Amounts: the provider sends integer minor units. payments.amount_minor keeps that exact integer and
--      payments.amount is derived with the currency's own decimals (JPY 0, KWD 3, USD 2 ...), instead of /100 for all.
--      Currencies outside the platform's list (platform_profile: USD, CAD, GBP, EUR, AUD) are recorded and alerted.
--
-- Authorization: all functions are service-role only (the webhook); nothing is exposed to signed-in users.
-- Rollback: re-run zella_billing_events.sql (old processing function) and redeploy the previous webhook. The new
-- columns and the unique index can stay.

alter table public.billing_events add column if not exists args jsonb;
alter table public.billing_events add column if not exists event_created_at timestamptz;
alter table public.billing_events add column if not exists attempts integer not null default 0;
alter table public.billing_events add column if not exists next_attempt_at timestamptz;
alter table public.billing_events add column if not exists processed_at timestamptz;
alter table public.billing_events drop constraint if exists billing_events_status_check;
alter table public.billing_events add constraint billing_events_status_check check (status in ('received', 'pending', 'processed', 'ignored', 'failed'));
create index if not exists billing_events_waiting_idx on public.billing_events (next_attempt_at) where status in ('pending', 'failed');

alter table public.payments add column if not exists amount_minor bigint;
-- numeric(10,2) silently cut three-decimal currencies (KWD 1.234 -> 1.23) and capped amounts; the exact value is
-- amount_minor, and amount now keeps the currency's own decimals. (0 rows when written; a no-op if already changed.)
do $$ begin
  if (select numeric_scale from information_schema.columns where table_schema = 'public' and table_name = 'payments' and column_name = 'amount') is not null then
    alter table public.payments alter column amount type numeric;
  end if;
end $$;
alter table public.subscriptions add column if not exists billing_event_at timestamptz;
create unique index if not exists payments_provider_payment_uidx on public.payments (provider, external_payment_id) where external_payment_id is not null;

-- Decimal places of a currency's minor unit (ISO 4217; zero-decimal and three-decimal lists as the payment
-- provider documents them). Everything else has 2.
create or replace function public.zella_currency_exponent(p_currency text) returns integer
language sql immutable set search_path = '' as $$
  select case
    when lower(p_currency) in ('bif','clp','djf','gnf','jpy','kmf','krw','mga','pyg','rwf','ugx','vnd','vuv','xaf','xof','xpf') then 0
    when lower(p_currency) in ('bhd','jod','kwd','omr','tnd') then 3
    else 2 end;
$$;
grant execute on function public.zella_currency_exponent(text) to authenticated, service_role;

create or replace function public.zella_minor_to_amount(p_minor bigint, p_currency text) returns numeric
language sql immutable set search_path = '' as $$
  select case when p_minor is null then null else round(p_minor::numeric / power(10::numeric, public.zella_currency_exponent(p_currency)), public.zella_currency_exponent(p_currency)) end;
$$;
grant execute on function public.zella_minor_to_amount(bigint, text) to authenticated, service_role;

-- Applies one stored event. Returns processed | pending | ignored | failed. Called with the event row locked.
create or replace function public.zella_apply_billing_event(p_event_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  e public.billing_events; a jsonb; s record; v_biz uuid; v_plan uuid; v_res text := 'processed';
  v_type text; v_sub_ext text; v_pay text; v_cur text; v_minor bigint; v_at timestamptz; v_newer boolean; v_pay_row record;
begin
  select * into e from public.billing_events where id = p_event_id for update;
  if not found then return 'ignored'; end if;
  if e.status in ('processed', 'ignored') then return 'duplicate'; end if;
  a := coalesce(e.args, '{}'::jsonb);
  v_type := e.type; v_sub_ext := nullif(a ->> 'external_subscription_id', ''); v_pay := nullif(a ->> 'external_payment_id', '');
  v_cur := lower(nullif(a ->> 'currency', '')); v_minor := nullif(a ->> 'amount_minor', '')::bigint; v_at := e.event_created_at;

  begin
    v_biz := nullif(a ->> 'business_id', '')::uuid;
    -- refunds and disputes name a payment, not a subscription
    if v_sub_ext is null and v_biz is null and v_pay is not null then
      select pm.business_id into v_biz from public.payments pm where pm.provider = e.provider and pm.external_payment_id = v_pay;
    end if;
    select * into s from public.subscriptions
     where (v_sub_ext is not null and external_subscription_id = v_sub_ext)
        or (v_sub_ext is null and v_biz is not null and business_id = v_biz)
     order by created_at desc limit 1 for update;
    if s.id is null then
      -- not known yet (out of order, or the subscription is linked later): wait and try again
      update public.billing_events set status = 'pending', attempts = attempts + 1, error = 'no_matching_subscription',
             next_attempt_at = now() + least(interval '6 hours', interval '1 minute' * power(2, least(attempts, 9)))
       where id = e.id;
      return 'pending';
    end if;
    v_biz := s.business_id;
    -- newer-or-equal events may change the subscription's status; older ones are recorded only
    v_newer := v_at is null or s.billing_event_at is null or v_at >= s.billing_event_at;

    if v_type in ('payment_succeeded', 'payment_failed') then
      if v_minor is null or v_minor < 0 or v_cur is null or v_cur !~ '^[a-z]{3}$' then raise exception 'BAD_AMOUNT'; end if;
      if not (upper(v_cur) = any (array['USD','CAD','GBP','EUR','AUD'])) then
        perform public.zella_platform_alert('billing_currency', 'A payment arrived in an unsupported currency', upper(v_cur), 'warning', v_biz, 'billing_currency:' || v_cur);
      end if;
      select * into v_pay_row from public.payments where provider = e.provider and external_payment_id = v_pay for update;
      if v_type = 'payment_succeeded' then
        if v_pay_row.id is null then
          insert into public.payments (business_id, subscription_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at)
          values (v_biz, s.id, public.zella_minor_to_amount(v_minor, v_cur), v_minor, v_cur, 'succeeded', e.provider, v_pay, coalesce(v_at, now()));
        elsif v_pay_row.status in ('pending', 'processing', 'failed') then
          update public.payments set status = 'succeeded', amount = public.zella_minor_to_amount(v_minor, v_cur), amount_minor = v_minor, currency = v_cur,
                 failure_reason = null, paid_at = coalesce(v_at, now()), updated_at = now() where id = v_pay_row.id;
        end if;   -- already succeeded or refunded: nothing to change
        if v_newer then
          perform public.zella_record_payment_result(v_biz, true, v_pay, null);
          update public.subscriptions set billing_event_at = coalesce(v_at, billing_event_at),
                 current_period_start = coalesce(nullif(a ->> 'period_start', '')::timestamptz, current_period_start),
                 current_period_end = coalesce(nullif(a ->> 'period_end', '')::timestamptz, current_period_end) where id = s.id;
          perform public.zella_notify_owners(v_biz, 'payment_received', 'Payment received', 'Thank you. Your payment went through and your account is up to date.', 'info', 'settings');
        end if;
      else
        if v_pay_row.id is null then
          insert into public.payments (business_id, subscription_id, amount, amount_minor, currency, status, provider, external_payment_id, failure_reason)
          values (v_biz, s.id, public.zella_minor_to_amount(v_minor, v_cur), v_minor, v_cur, 'failed', e.provider, v_pay, left(a ->> 'reason', 300));
        elsif v_pay_row.status in ('pending', 'processing', 'failed') then
          update public.payments set failure_reason = left(a ->> 'reason', 300), updated_at = now() where id = v_pay_row.id;
        end if;   -- a failure never undoes a success or a refund
        if v_newer and coalesce(v_pay_row.status, 'failed') not in ('succeeded', 'refunded') then
          perform public.zella_record_payment_result(v_biz, false, v_pay, coalesce(a ->> 'reason', 'Payment failed'));
          update public.subscriptions set billing_event_at = coalesce(v_at, billing_event_at) where id = s.id;
          perform public.zella_notify_owners(v_biz, 'payment_failed', 'Your payment did not go through', 'Please update your billing details so your service is not interrupted.', 'urgent', 'settings');
        end if;
      end if;

    elsif v_type = 'subscription_renewed' then
      if v_newer then
        update public.subscriptions set status = 'active', billing_event_at = coalesce(v_at, billing_event_at),
               current_period_start = coalesce(nullif(a ->> 'period_start', '')::timestamptz, current_period_start),
               current_period_end = coalesce(nullif(a ->> 'period_end', '')::timestamptz, current_period_end) where id = s.id;
      else
        update public.billing_events set error = 'older_than_current_state' where id = e.id;
      end if;

    elsif v_type = 'subscription_cancelled' then
      if v_newer then
        update public.subscriptions set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()), billing_event_at = coalesce(v_at, billing_event_at)
         where id = s.id and status <> 'cancelled';
        if found then
          perform public.zella_notify_owners(v_biz, 'subscription_cancelled', 'Your subscription was cancelled', 'Your plan has been cancelled. Contact support if this is a mistake.', 'warning', 'settings');
        end if;
      else
        update public.billing_events set error = 'older_than_current_state' where id = e.id;
      end if;

    elsif v_type in ('payment_reversed', 'payment_refunded_partial', 'payment_disputed', 'dispute_won') then
      select * into v_pay_row from public.payments where provider = e.provider and external_payment_id = v_pay and business_id = v_biz for update;
      if v_pay_row.id is null then
        -- the payment itself hasn't arrived yet: wait for it
        update public.billing_events set status = 'pending', attempts = attempts + 1, error = 'no_matching_payment',
               next_attempt_at = now() + least(interval '6 hours', interval '1 minute' * power(2, least(attempts, 9))) where id = e.id;
        return 'pending';
      end if;
      if v_type = 'payment_reversed' then
        update public.payments set status = 'refunded', updated_at = now(),
               metadata = metadata || jsonb_build_object('reversal', left(a ->> 'reason', 120), 'refunded_minor', coalesce(nullif(a ->> 'refund_minor', '')::bigint, v_pay_row.amount_minor))
         where id = v_pay_row.id and status = 'succeeded';
        perform public.zella_platform_alert('payment_reversed', 'A payment was refunded or a dispute was lost', left(a ->> 'reason', 300), 'warning', v_biz, 'payment_reversed:' || coalesce(v_pay, ''));
      elsif v_type = 'payment_refunded_partial' then
        update public.payments set updated_at = now(), metadata = metadata || jsonb_build_object('refunded_minor', nullif(a ->> 'refund_minor', '')::bigint)
         where id = v_pay_row.id;
        perform public.zella_platform_alert('payment_partial_refund', 'Part of a payment was refunded', left(a ->> 'reason', 300), 'info', v_biz, 'payment_partial_refund:' || coalesce(v_pay, ''));
      elsif v_type = 'payment_disputed' then
        update public.payments set updated_at = now(), metadata = metadata || jsonb_build_object('disputed', true) where id = v_pay_row.id;
        perform public.zella_platform_alert('payment_disputed', 'A payment is disputed', left(a ->> 'reason', 300), 'warning', v_biz, 'payment_disputed:' || coalesce(v_pay, ''));
      else
        update public.payments set updated_at = now(), metadata = metadata - 'disputed' || jsonb_build_object('dispute', 'won') where id = v_pay_row.id;
      end if;

    elsif v_type = 'plan_changed' then
      select id into v_plan from public.plans where slug = a ->> 'plan' and is_active;
      if v_plan is null then v_res := 'ignored'; update public.billing_events set error = 'unknown_plan' where id = e.id;
      elsif v_newer then update public.subscriptions set plan_id = v_plan, billing_event_at = coalesce(v_at, billing_event_at) where id = s.id;
      end if;
    else
      v_res := 'ignored'; update public.billing_events set error = 'unknown_type' where id = e.id;
    end if;

    update public.billing_events set status = v_res, business_id = v_biz, subscription_id = s.id, processed_at = now(),
           error = case when v_res = 'processed' and error in ('no_matching_subscription', 'no_matching_payment') then null else error end
     where id = e.id;
    return v_res;
  exception when others then
    -- kept (not deleted) so it shows up and a redelivery or the reconciler applies it again
    update public.billing_events set status = 'failed', attempts = attempts + 1, error = left(sqlerrm, 300),
           next_attempt_at = now() + least(interval '6 hours', interval '1 minute' * power(2, least(attempts, 9))) where id = e.id;
    perform public.zella_platform_alert('billing_event_failed', 'A billing event could not be applied', left(sqlerrm, 200), 'urgent', v_biz, 'billing_event_failed');
    return 'failed';
  end;
end $$;
revoke execute on function public.zella_apply_billing_event(uuid) from public, anon, authenticated;
grant execute on function public.zella_apply_billing_event(uuid) to service_role;

-- Applies waiting events for one subscription or payment, oldest first (called after anything that may unblock them).
create or replace function public.zella_apply_waiting_billing_events(p_provider text, p_external_subscription_id text, p_external_payment_id text)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id from public.billing_events
            where provider = p_provider and status = 'pending'
              and ((p_external_subscription_id is not null and args ->> 'external_subscription_id' = p_external_subscription_id)
                or (p_external_payment_id is not null and args ->> 'external_payment_id' = p_external_payment_id))
            order by event_created_at nulls first, received_at limit 50 loop
    if public.zella_apply_billing_event(r.id) = 'processed' then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_apply_waiting_billing_events(text, text, text) from public, anon, authenticated;
grant execute on function public.zella_apply_waiting_billing_events(text, text, text) to service_role;

-- The webhook's entry point. Returns processed | pending | ignored | duplicate | failed.
-- pending = stored durably and applied later by Zella (answer 200); failed = answer 500 so the provider retries.
drop function if exists public.zella_process_billing_event(text,text,text,text,uuid,numeric,text,text,timestamptz,timestamptz,text,text);
create or replace function public.zella_process_billing_event(
  p_provider text, p_event_id text, p_type text, p_external_subscription_id text default null, p_business_id uuid default null,
  p_amount_minor bigint default null, p_currency text default null, p_external_payment_id text default null,
  p_period_start timestamptz default null, p_period_end timestamptz default null, p_plan_slug text default null, p_reason text default null,
  p_event_created timestamptz default null, p_refund_minor bigint default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status text; v_res text; v_sub text; v_pay text;
begin
  insert into public.billing_events (provider, external_event_id, type, business_id, status, event_created_at, data, args)
  values (left(p_provider, 40), left(p_event_id, 200), left(p_type, 60), p_business_id, 'received', p_event_created,
          jsonb_build_object('external_subscription_id', p_external_subscription_id, 'external_payment_id', p_external_payment_id,
                             'amount_minor', p_amount_minor, 'currency', lower(p_currency), 'plan', p_plan_slug),
          jsonb_strip_nulls(jsonb_build_object('external_subscription_id', p_external_subscription_id, 'business_id', p_business_id,
                             'amount_minor', p_amount_minor, 'currency', lower(p_currency), 'external_payment_id', p_external_payment_id,
                             'period_start', p_period_start, 'period_end', p_period_end, 'plan', p_plan_slug, 'reason', left(p_reason, 300),
                             'refund_minor', p_refund_minor)))
  on conflict (provider, external_event_id) do nothing returning id into v_id;
  if v_id is null then
    -- a redelivery: waits for a concurrent first delivery to finish, then re-applies only if it is still waiting
    select id, status into v_id, v_status from public.billing_events where provider = left(p_provider, 40) and external_event_id = left(p_event_id, 200) for update;
    if v_status not in ('pending', 'failed', 'received') then return 'duplicate'; end if;
  end if;
  v_res := public.zella_apply_billing_event(v_id);
  if v_res = 'processed' then
    select args ->> 'external_subscription_id', args ->> 'external_payment_id' into v_sub, v_pay from public.billing_events where id = v_id;
    perform public.zella_apply_waiting_billing_events(left(p_provider, 40), v_sub, v_pay);
  end if;
  return v_res;
end $$;
revoke execute on function public.zella_process_billing_event(text,text,text,text,uuid,bigint,text,text,timestamptz,timestamptz,text,text,timestamptz,bigint) from public, anon, authenticated;
grant execute on function public.zella_process_billing_event(text,text,text,text,uuid,bigint,text,text,timestamptz,timestamptz,text,text,timestamptz,bigint) to service_role;

-- Retries waiting and failed events that are due. Events still unmatched after 7 days are closed and alerted.
-- To schedule (needs approval): select cron.schedule('zella_billing_reconcile', '*/15 * * * *', 'select public.zella_reconcile_billing_events()');
create or replace function public.zella_reconcile_billing_events(p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v text; n_ok integer := 0; n_wait integer := 0; n_gone integer := 0;
begin
  for r in select id, received_at, type from public.billing_events
            where status in ('pending', 'failed') and (next_attempt_at is null or next_attempt_at <= now())
            order by event_created_at nulls first, received_at limit greatest(1, least(p_limit, 500)) for update skip locked loop
    if r.received_at < now() - interval '7 days' then
      update public.billing_events set status = 'ignored', error = coalesce(error, '') || ' (gave up after 7 days)' where id = r.id;
      perform public.zella_platform_alert('billing_event_unmatched', 'A billing event could not be matched for 7 days', r.type, 'urgent', null, 'billing_event_unmatched:' || r.id);
      n_gone := n_gone + 1; continue;
    end if;
    v := public.zella_apply_billing_event(r.id);
    if v = 'processed' then n_ok := n_ok + 1; else n_wait := n_wait + 1; end if;
  end loop;
  return jsonb_build_object('processed', n_ok, 'waiting', n_wait, 'closed', n_gone);
end $$;
revoke execute on function public.zella_reconcile_billing_events(integer) from public, anon, authenticated;
grant execute on function public.zella_reconcile_billing_events(integer) to service_role;

-- A subscription getting its provider id unblocks the events that were waiting for it.
create or replace function public.zella_billing_subscription_linked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.external_subscription_id is not null and new.external_subscription_id is distinct from coalesce(old.external_subscription_id, '') then
    perform public.zella_apply_waiting_billing_events(coalesce(new.provider, 'stripe'), new.external_subscription_id, null);
  end if;
  return null;
end $$;
drop trigger if exists zella_billing_subscription_linked on public.subscriptions;
create trigger zella_billing_subscription_linked after insert or update of external_subscription_id on public.subscriptions
  for each row execute function public.zella_billing_subscription_linked();
revoke execute on function public.zella_billing_subscription_linked() from public, anon, authenticated;
