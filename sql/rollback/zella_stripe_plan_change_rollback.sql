-- Rollback of sql/zella_stripe_plan_change.sql: restores the subscription handler exactly, drops its table and functions. Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
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
    "public.zella_admin_plan_change_cancel(uuid,text)": "a1cb7f996914716bbec43c3857bec3f5",
    "public.zella_stripe_after_schedule_release(billing_outbox)": "326b8dbf19d29fdd543d12ac11a6d5ff"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_plan_change.sql made', s;
    end if;
  end loop;
  if to_regclass('public.billing_plan_changes') is not null then
    lock table public.billing_plan_changes in access exclusive mode;   -- held until commit: no row can be added before the drop
    execute 'select exists (select 1 from public.billing_plan_changes)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: plan changes exist; a person decides what to keep'; end if;
  end if;
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) = 'c9b70ddd6dfdf324e93d3f2aa79d7ab4' then
    execute (select definition from public.zella_function_archive where migration = 'zella_stripe_plan_change' and signature = 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)');
  elsif md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> '159c43b07625ac49bdd9deffcf244b5c' then
    raise exception 'ROLLBACK_DRIFT: zella_stripe_on_customer_subscription_updated is not a known version';
  end if;
  delete from public.zella_function_archive where migration = 'zella_stripe_plan_change';
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop table if exists public.billing_plan_changes;
commit;
