-- Rollback of sql/zella_stripe_pipeline.sql. Exact: drops only what that file made, and refuses (ROLLBACK_DRIFT) if
-- any of its functions differs from that file's version. Refuses (ROLLBACK_HAS_DATA) while any of its tables, any
-- stripe_v2 event, or any subscription in a status it added holds a row: nothing is ever deleted. Safe to run twice.
begin;

do $$
declare s text; t text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_payments_live()": "17eb6407291d5642a4f8e0f5e4a4c305",
    "public.zella_payments_switch(boolean,text)": "b03c10f53aadce11186261bd159497d7",
    "public.zella_billing_worker_check(text)": "48bd09e5f2fa8108e15e7c197ad723af",
    "public.zella_billing_worker_kick()": "bbfbf30bf75a440dff76ed28691bff37",
    "public.zella_stripe_event_types()": "72349917704935916bf10c4cbe7f7be1",
    "public.zella_stripe_event_store(jsonb,boolean)": "63264b976eb9fa90992694e84fb16631",
    "public.zella_stripe_claim_events(integer)": "d27adc365d875decc6d561b52ce0781a",
    "public.zella_stripe_apply_event(uuid,jsonb,boolean)": "980fa27a2355488b094dddf09192605b",
    "public.zella_stripe_event_retry(uuid,text)": "5f985866e386f4e28efbac32b17715fc",
    "public.zella_stripe_quarantine(uuid,uuid,text,jsonb)": "fb95b9bbbc4c9f48e1221f27e66fb147",
    "public.zella_stripe_link_add(text,text,uuid,boolean,text,uuid,bigint)": "fce64f6b109108f226aa0a42ae52f04c",
    "public.zella_stripe_link(text,text)": "a2600ba62f55374f5634d828085a63e0",
    "public.zella_stripe_customer(uuid)": "3675b7c435f4636d15ec227bea769fb4",
    "public.zella_ledger_post(uuid,text,jsonb)": "c19b7255a08329f229c28f6ef08faf8e",
    "public.zella_subscription_transition_ok(text,text)": "ed6b9888e76e790efeaa5d67096a05ea",
    "public.zella_stripe_invoice_upsert(uuid,jsonb,text)": "5df9fab080ab0b92cc1d9a865ccb8a1c",
    "public.zella_stripe_bind_invoice(jsonb,boolean)": "12e6b5314c0346992ea2da3803c37bae",
    "public.zella_billing_outbox_add(uuid,text,text,text,text,jsonb,text,uuid)": "c15cfd429cf4843adc80db1fbf2988a3",
    "public.zella_billing_outbox_claim(integer,uuid)": "e3c617b57ee99c6cea9d0d626f8e35ae",
    "public.zella_billing_outbox_result(uuid,boolean,text,jsonb,text,boolean,boolean,integer)": "1adcdd5ce49c09f26854121a5561c71f",
    "public.zella_stripe_on_invoice_paid(billing_events,jsonb)": "2c91b24c363573d7eadb693aebf57403",
    "public.zella_stripe_on_customer_subscription_created(billing_events,jsonb)": "e150fff5538a8f20cc7c4b4e816fcb97",
    "public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)": "cdbc9f06927ff12a5675b733a991d15f",
    "public.zella_stripe_on_customer_subscription_deleted(billing_events,jsonb)": "0d15491cc1f4f77eac724fd9ef8fa399",
    "public.zella_stripe_on_charge_refunded(billing_events,jsonb)": "d413820b3034990a620248bb972dbd42"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_pipeline.sql made', s;
    end if;
  end loop;
  -- no writer can add a row between these checks and the drops: the locks are held until this rollback commits
  lock table public.billing_events, public.subscriptions in exclusive mode;
  foreach t in array array['billing_stripe_links', 'billing_outbox', 'billing_quarantine', 'billing_invoices', 'ledger_operation_keys', 'money_ledger'] loop
    if to_regclass('public.' || t) is not null then execute format('lock table public.%I in access exclusive mode', t); end if;
  end loop;
  foreach t in array array['billing_stripe_links', 'billing_outbox', 'billing_quarantine', 'billing_invoices', 'ledger_operation_keys'] loop
    if to_regclass('public.' || t) is not null then
      execute format('select exists (select 1 from public.%I)', t) into v_has;
      if v_has then raise exception 'ROLLBACK_HAS_DATA: % holds rows; a person decides what to keep', t; end if;
    end if;
  end loop;
  if exists (select 1 from public.subscriptions where status in ('pending_payment', 'paused_nonpayment', 'suspended_dispute')) then
    raise exception 'ROLLBACK_HAS_DATA: subscriptions use a status this file added';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'billing_events' and column_name = 'pipeline') then
    execute 'select exists (select 1 from public.billing_events where pipeline is not null)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: stripe_v2 events exist'; end if;
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;

do $$ begin
  if to_regnamespace('cron') is not null and exists (select 1 from cron.job where jobname = 'zella_billing_worker') then perform cron.unschedule('zella_billing_worker'); end if;
end $$;
drop table if exists public.money_ledger;
drop table if exists public.ledger_operation_keys;
drop table if exists public.billing_invoices;
drop table if exists public.billing_quarantine;
drop table if exists public.billing_outbox;
drop table if exists public.billing_stripe_links;
drop index if exists public.billing_events_v2_due_idx;
alter table public.billing_events drop column if exists pipeline, drop column if exists livemode, drop column if exists object_type,
  drop column if exists object_id, drop column if exists ordering_key, drop column if exists payload;
alter table public.subscriptions drop constraint if exists subscriptions_status_check;
alter table public.subscriptions add constraint subscriptions_status_check check (status in ('trial', 'active', 'renewal_due', 'past_due', 'grace_period', 'cancelled', 'expired'));
delete from public.platform_settings where key in ('payments_live', 'billing_worker_url');
delete from vault.secrets where name = 'zella_billing_worker_secret';

commit;
