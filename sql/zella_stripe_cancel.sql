-- Zella Voice: cancel and continue with Stripe (docs/PAYMENTS_ARCHITECTURE.md §6.10, §8.1 cancel row, REQ-BIL-44),
-- built switched off. In line with the merged scheduled cancellations (zella_cancellations_scheduled.sql): the
-- business's cancel_at stays the one source of the owner's choice. Every change of it (Settings, the admin, the
-- "Continue my plan" email link, zella_owner_continue_plan) now also syncs Stripe:
--   - a versioned desired value on the subscription (desired_cancel_at_period_end, cancel_version), raised on every
--     change under the subscription row lock, so the latest choice always wins;
--   - one Stripe command per version (key cancel:<subscription>:<version>:<attempt>); queuing a new version cancels
--     every older one still waiting, so an older choice is never sent after a newer one;
--   - customer.subscription.updated compares Stripe's cancel_at_period_end with the latest desired value and, if they
--     differ and nothing is waiting, resends the latest value with a new attempt number;
--   - a trial is cancelled at once instead (DELETE, key cancelnow:<subscription>:<version>): nothing has been paid (§6.2);
--   - the period ends: customer.subscription.deleted (step 2) records the cancellation; the daily cancellation job
--     still does the full business cancellation at cancel_at, as before.
-- Who: the trigger runs as the definer; the functions are server only. Rollback: sql/rollback/zella_stripe_cancel_rollback.sql.
-- Tests: tests/stripe_cancel/run.sh.
begin;

do $$
declare s text; d text;
  known constant jsonb := '{
    "public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)": ["5ecdf2844d5d37c14c9ae1f027119fe6", "159c43b07625ac49bdd9deffcf244b5c"]
  }';
  owned constant jsonb := '{
    "public.zella_stripe_cancel_sync(uuid,integer)": "95a45270466f1cd39ee5c389b911e56a",
    "public.zella_stripe_cancel_trg()": "ce4aaa1585d141e40be1ab9ef94c9256",
    "public.zella_stripe_after_cancel(billing_outbox)": "7c65d1baa034eced5c2803761f21139c",
    "public.zella_stripe_cancel_check(billing_events,jsonb)": "fbfb923606af688cbaf3ff1582901a51",
    "public.zella_stripe_cancel_next_attempt(subscriptions)": "b4b15cf6cdb35ac177a761cb07732a6f"
  }';
begin
  if to_regprocedure('public.zella_owner_pack_buy(uuid,text,text)') is null or to_regprocedure('public.zella_process_cancellations()') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_packs.sql and the scheduled cancellations';
  end if;
  for s in select jsonb_object_keys(known) loop
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then
      insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_cancel', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

alter table public.subscriptions add column if not exists desired_cancel_at_period_end boolean;
alter table public.subscriptions add column if not exists cancel_version integer not null default 0;

-- Queues the latest desired value (or the trial's immediate cancel). p_attempt > 1 is a resend after reconciliation.
create or replace function public.zella_stripe_cancel_sync(p_business_id uuid, p_attempt integer default 1) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions; o public.billing_outbox; v_key text; v_now boolean;
begin
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe' and external_subscription_id is not null for update;
  if s.id is null or s.status in ('cancelled', 'expired', 'pending_payment') or s.desired_cancel_at_period_end is null then return null; end if;
  v_now := s.status = 'trial' and s.desired_cancel_at_period_end;
  -- one key per choice (version) and attempt: a new choice is never answered by an older, cancelled command
  v_key := case when v_now then 'cancelnow:' || s.external_subscription_id || ':' || s.cancel_version
                else 'cancel:' || s.external_subscription_id || ':' || s.cancel_version || ':' || p_attempt end;
  -- older versions still waiting are never sent: the latest choice wins (one already being sent stays tracked)
  update public.billing_outbox set status = 'cancelled', updated_at = now()
   where business_id = p_business_id and kind = 'cancel' and status in ('pending', 'retry_wait') and local_id = s.id and idempotency_key <> v_key;
  if v_now then
    o := public.zella_billing_outbox_add(p_business_id, 'cancel', v_key, 'DELETE', '/v1/subscriptions/' || s.external_subscription_id, '{}'::jsonb, 'subscription', s.id);
  else
    o := public.zella_billing_outbox_add(p_business_id, 'cancel', v_key,
      'POST', '/v1/subscriptions/' || s.external_subscription_id, jsonb_build_object('cancel_at_period_end', s.desired_cancel_at_period_end), 'subscription', s.id);
  end if;
  return o.id;
end $$;

-- The next unused attempt number for the subscription's current choice (called under its row lock): the highest one
-- recorded for this version, plus one, so a held or delayed attempt is never reused.
create or replace function public.zella_stripe_cancel_next_attempt(s public.subscriptions) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(max(nullif(split_part(idempotency_key, ':', 4), '')::int), 0) + 1 from public.billing_outbox
   where kind = 'cancel' and local_id = s.id and idempotency_key like 'cancel:' || s.external_subscription_id || ':' || s.cancel_version || ':%';
$$;

-- The owner's choice changed (cancel_at set or cleared, by anyone): a new version, then the command.
create or replace function public.zella_stripe_cancel_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.cancel_at is distinct from old.cancel_at and new.cancelled_at is null then
    update public.subscriptions set desired_cancel_at_period_end = new.cancel_at is not null, cancel_version = cancel_version + 1, updated_at = now()
     where business_id = new.id and provider = 'stripe' and external_subscription_id is not null and status not in ('cancelled', 'expired', 'pending_payment');
    if found then perform public.zella_stripe_cancel_sync(new.id, 1); end if;
  end if;
  return null;
end $$;
drop trigger if exists zella_stripe_cancel on public.businesses;
create trigger zella_stripe_cancel after update of cancel_at on public.businesses for each row execute function public.zella_stripe_cancel_trg();

-- After a send: Stripe's answer is the subscription itself; if it doesn't match the latest choice (an older send
-- landed last), resend the latest with the next attempt number.
create or replace function public.zella_stripe_after_cancel(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions;
begin
  select * into s from public.subscriptions where id = r.local_id for update;
  if s.id is null or r.method = 'DELETE' then return; end if;
  update public.subscriptions set metadata = metadata || jsonb_build_object('cancel_at_period_end', (r.response ->> 'cancel_at_period_end')::boolean) where id = s.id;
  if (r.response ->> 'cancel_at_period_end')::boolean is distinct from s.desired_cancel_at_period_end
     and not exists (select 1 from public.billing_outbox where kind = 'cancel' and local_id = s.id and status in ('pending', 'retry_wait', 'sending') and id <> r.id) then
    perform public.zella_stripe_cancel_sync(s.business_id, public.zella_stripe_cancel_next_attempt(s));
  end if;
end $$;

-- From the subscription events (fetched): Stripe's value against the latest desired one; a mismatch with nothing
-- waiting is resent. Called by the step 2 handler through this hook name.
create or replace function public.zella_stripe_cancel_check(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions;
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null or s.desired_cancel_at_period_end is null or o ->> 'status' in ('canceled', 'incomplete_expired') then return 'ignored'; end if;
  if s.external_subscription_id is distinct from o ->> 'id' then return 'ignored'; end if;   -- an earlier, replaced Stripe subscription
  if (o ->> 'cancel_at_period_end')::boolean is distinct from s.desired_cancel_at_period_end
     and not exists (select 1 from public.billing_outbox where kind = 'cancel' and local_id = s.id and status in ('pending', 'retry_wait', 'sending')) then
    perform public.zella_stripe_cancel_sync(s.business_id, public.zella_stripe_cancel_next_attempt(s));
    return 'applied';
  end if;
  return 'ignored';
end $$;

-- customer.subscription.updated (replacing the packs step's version, archived first): unchanged, plus the cancel check.
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
           'default_payment_method', coalesce(o #>> '{default_payment_method,id}', o ->> 'default_payment_method'))),
         billing_event_at = greatest(coalesce(billing_event_at, e.event_created_at), e.event_created_at), updated_at = now()
   where id = s.id;
  v_to := case o ->> 'status' when 'past_due' then 'past_due' when 'unpaid' then 'past_due' else null end;   -- active comes only from a paid invoice
  if v_to is not null and s.status <> v_to and public.zella_subscription_transition_ok(s.status, v_to) then
    update public.subscriptions set status = v_to, past_due_since = coalesce(past_due_since, now()) where id = s.id;
  end if;
  perform public.zella_stripe_cancel_check(e, o);   -- the owner's latest cancel choice against Stripe's
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_stripe_cancel_sync(uuid,integer)', 'zella_stripe_cancel_trg()', 'zella_stripe_after_cancel(billing_outbox)', 'zella_stripe_cancel_check(billing_events,jsonb)',
    'zella_stripe_cancel_next_attempt(subscriptions)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
