-- Rollback of sql/zella_stripe_cancel.sql: restores the subscription handler exactly and drops the trigger, functions and columns. Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_stripe_cancel_sync(uuid,integer)": "95a45270466f1cd39ee5c389b911e56a",
    "public.zella_stripe_cancel_trg()": "ce4aaa1585d141e40be1ab9ef94c9256",
    "public.zella_stripe_after_cancel(billing_outbox)": "7c65d1baa034eced5c2803761f21139c",
    "public.zella_stripe_cancel_check(billing_events,jsonb)": "fbfb923606af688cbaf3ff1582901a51",
    "public.zella_stripe_cancel_next_attempt(subscriptions)": "b4b15cf6cdb35ac177a761cb07732a6f"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_cancel.sql made', s;
    end if;
  end loop;
  -- an owner's saved choice, or a cancel command not finished, still needs this file: refuse (nothing is dropped).
  -- The locks stop a new choice or command between this check and the drops.
  lock table public.subscriptions, public.billing_outbox in exclusive mode;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'subscriptions' and column_name = 'desired_cancel_at_period_end') then
    execute 'select exists (select 1 from public.subscriptions where desired_cancel_at_period_end is not null)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: saved cancellation choices exist; a person decides what to keep'; end if;
  end if;
  if exists (select 1 from public.billing_outbox where kind = 'cancel' and status in ('pending', 'retry_wait', 'sending')) then
    raise exception 'ROLLBACK_HAS_DATA: cancellation commands are waiting to be sent';
  end if;
  drop trigger if exists zella_stripe_cancel on public.businesses;
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) = '159c43b07625ac49bdd9deffcf244b5c' then
    execute (select definition from public.zella_function_archive where migration = 'zella_stripe_cancel' and signature = 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)');
  elsif md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> '5ecdf2844d5d37c14c9ae1f027119fe6' then
    raise exception 'ROLLBACK_DRIFT: zella_stripe_on_customer_subscription_updated is not a known version';
  end if;
  delete from public.zella_function_archive where migration = 'zella_stripe_cancel';
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
alter table public.subscriptions drop column if exists desired_cancel_at_period_end, drop column if exists cancel_version;
commit;
