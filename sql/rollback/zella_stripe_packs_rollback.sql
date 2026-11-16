-- Rollback of sql/zella_stripe_packs.sql: restores the subscription handler exactly, drops what that file made and narrows pack_purchases back. Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
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
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_packs.sql made', s;
    end if;
  end loop;
  if exists (select 1 from public.pack_purchases where source <> 'admin_grant' or status <> 'granted') then
    raise exception 'ROLLBACK_HAS_DATA: packs bought through Stripe exist; a person decides what to keep';
  end if;
  drop trigger if exists zella_billing_reload on public.usage_charges;
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) = '697fc98401d8f2f588fdff1ec93c1454' then
    execute (select definition from public.zella_function_archive where migration = 'zella_stripe_packs' and signature = 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)');
  elsif md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> 'c02680d28b2527875d15e3ec1d8f354a' then
    raise exception 'ROLLBACK_DRIFT: zella_stripe_on_customer_subscription_updated is not a known version';
  end if;
  delete from public.zella_function_archive where migration = 'zella_stripe_packs';
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop index if exists public.pack_purchases_one_pending_reload_uidx;
alter table public.pack_purchases drop column if exists stripe_payment_intent, drop column if exists failure_reason, drop column if exists settled_at;
alter table public.pack_purchases drop constraint if exists pack_purchases_status_check;
alter table public.pack_purchases add constraint pack_purchases_status_check check (status = 'granted');
alter table public.pack_purchases drop constraint if exists pack_purchases_source_check;
alter table public.pack_purchases add constraint pack_purchases_source_check check (source = 'admin_grant');
commit;
