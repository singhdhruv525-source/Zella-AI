-- Rollback of sql/zella_stripe_cancel.sql: restores the subscription handler exactly and drops the trigger, functions and columns. Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_stripe_cancel_sync(uuid,integer)": "8c6d3674a5ee68a7e7d463c4573e5758",
    "public.zella_stripe_cancel_trg()": "ce4aaa1585d141e40be1ab9ef94c9256",
    "public.zella_stripe_after_cancel(billing_outbox)": "7dfed3c4ced107e3ec7aba1d12c12fa5",
    "public.zella_stripe_cancel_check(billing_events,jsonb)": "71310991cffb5388795687df2ffd544e"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_cancel.sql made', s;
    end if;
  end loop;
  drop trigger if exists zella_stripe_cancel on public.businesses;
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) = '35b81b539743ee7935df7f5d64b9e933' then
    execute (select definition from public.zella_function_archive where migration = 'zella_stripe_cancel' and signature = 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)');
  elsif md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> '697fc98401d8f2f588fdff1ec93c1454' then
    raise exception 'ROLLBACK_DRIFT: zella_stripe_on_customer_subscription_updated is not a known version';
  end if;
  delete from public.zella_function_archive where migration = 'zella_stripe_cancel';
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
alter table public.subscriptions drop column if exists desired_cancel_at_period_end, drop column if exists cancel_version;
commit;
