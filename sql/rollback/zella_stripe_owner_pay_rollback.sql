-- Rollback of sql/zella_stripe_owner_pay.sql. Restores zella_owner_invoices, zella_billing_email_invoice_trg and
-- zella_stripe_on_customer_subscription_updated exactly as archived (the versions sql/zella_stripe_invoices.sql,
-- sql/zella_stripe_emails.sql and sql/zella_stripe_plan_change.sql make) and drops the functions, columns, table, index and trigger
-- the file added (the owner's pending Auto pay choice is lost; Stripe keeps whatever it has). Refuses
-- with ROLLBACK_HAS_PENDING while an Auto pay command is waiting or being sent. Refuses with ROLLBACK_DRIFT if any of
-- them differs from what the file made. Data is untouched: a pack an owner reopened stays as it is (pending until
-- Stripe's event settles it). Safe to run twice.
begin;

-- refusals first (review M5): the rollback can't undo what Stripe has, so it waits until every business is back on Auto
-- pay and no reopened pack is waiting
do $x$
declare v boolean;
begin
  if exists (select 1 from public.subscriptions where coalesce(metadata ->> 'collection_method', '') = 'send_invoice') then
    raise exception 'ROLLBACK_AUTOPAY_OFF: a business has Auto pay off at Stripe; switch every business back to Auto pay first';
  end if;
  -- (the columns are gone after a first rollback, so they are read only while they exist)
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'subscriptions' and column_name = 'desired_autopay') then
    execute 'select exists (select 1 from public.subscriptions where desired_autopay is false)' into v;
    if v then raise exception 'ROLLBACK_AUTOPAY_OFF: a business asked for Auto pay off; switch every business back to Auto pay first'; end if;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pack_purchases' and column_name = 'reopen_expires_at') then
    execute 'select exists (select 1 from public.pack_purchases where reopen_expires_at is not null and status = ''pending'')' into v;
    if v then raise exception 'ROLLBACK_HAS_PENDING: a reopened pack is still waiting for Stripe'; end if;
  end if;
end $x$;

drop trigger if exists zella_billing_checkout_autopay on public.billing_checkouts;
do $x$
declare d text;
begin
  if md5(pg_get_functiondef('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)'::regprocedure)) not in ('e7a39b17547fe5eefda25aa12c7fc0d2', 'aa9d3e91554cb0a8286017c849a982c1') then raise exception 'ROLLBACK_DRIFT: public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb) is not the version zella_stripe_owner_pay.sql made'; end if;
  if md5(pg_get_functiondef('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)'::regprocedure)) = 'aa9d3e91554cb0a8286017c849a982c1' then
    select definition into d from public.zella_function_archive where migration = 'zella_stripe_owner_pay' and signature = 'public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)' and definition_md5 = 'e7a39b17547fe5eefda25aa12c7fc0d2';
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb) is missing'; end if;
    execute d;
    if md5(pg_get_functiondef('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)'::regprocedure)) <> 'e7a39b17547fe5eefda25aa12c7fc0d2' then raise exception 'ROLLBACK_DRIFT: public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb) did not restore exactly'; end if;
  end if;
end $x$;
do $x$
declare d text;
begin
  if md5(pg_get_functiondef('public.zella_owner_pack_buy(uuid,text,text)'::regprocedure)) not in ('ce968b09b251a2192c48fefd2de0cb52', 'd10a9c769091f776da0989ecff14ccde') then raise exception 'ROLLBACK_DRIFT: public.zella_owner_pack_buy(uuid,text,text) is not the version zella_stripe_owner_pay.sql made'; end if;
  if md5(pg_get_functiondef('public.zella_owner_pack_buy(uuid,text,text)'::regprocedure)) = 'd10a9c769091f776da0989ecff14ccde' then
    select definition into d from public.zella_function_archive where migration = 'zella_stripe_owner_pay' and signature = 'public.zella_owner_pack_buy(uuid,text,text)' and definition_md5 = 'ce968b09b251a2192c48fefd2de0cb52';
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived public.zella_owner_pack_buy(uuid,text,text) is missing'; end if;
    execute d;
    if md5(pg_get_functiondef('public.zella_owner_pack_buy(uuid,text,text)'::regprocedure)) <> 'ce968b09b251a2192c48fefd2de0cb52' then raise exception 'ROLLBACK_DRIFT: public.zella_owner_pack_buy(uuid,text,text) did not restore exactly'; end if;
  end if;
end $x$;

do $x$
declare d text;
begin
  if exists (select 1 from public.billing_outbox where kind = 'autopay' and status in ('pending', 'retry_wait', 'sending')) then
    raise exception 'ROLLBACK_HAS_PENDING: an Auto pay command is still waiting for Stripe';
  end if;
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) not in ('c9b70ddd6dfdf324e93d3f2aa79d7ab4', 'a803f166b2a317d4b061ef01de4a3a04') then
    raise exception 'ROLLBACK_DRIFT: public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb) is not the version zella_stripe_owner_pay.sql made';
  end if;
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) = 'a803f166b2a317d4b061ef01de4a3a04' then
    select definition into d from public.zella_function_archive
     where migration = 'zella_stripe_owner_pay' and signature = 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)' and definition_md5 = 'c9b70ddd6dfdf324e93d3f2aa79d7ab4';
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived customer.subscription.updated handler is missing'; end if;
    execute d;
    if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> 'c9b70ddd6dfdf324e93d3f2aa79d7ab4' then raise exception 'ROLLBACK_DRIFT: the customer.subscription.updated handler did not restore exactly'; end if;
  end if;
end $x$;

do $x$
declare d text;
begin
  if md5(pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure)) not in ('cc75a8987f19e2ae96c066395b79af45', 'e71bf72e22f1e906f1022c5e94f44f5e') then
    raise exception 'ROLLBACK_DRIFT: public.zella_billing_email_invoice_trg() is not the version zella_stripe_owner_pay.sql made';
  end if;
  if md5(pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure)) = 'e71bf72e22f1e906f1022c5e94f44f5e' then
    select definition into d from public.zella_function_archive
     where migration = 'zella_stripe_owner_pay' and signature = 'public.zella_billing_email_invoice_trg()' and definition_md5 = 'cc75a8987f19e2ae96c066395b79af45';
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived zella_billing_email_invoice_trg is missing'; end if;
    execute d;
    if md5(pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure)) <> 'cc75a8987f19e2ae96c066395b79af45' then raise exception 'ROLLBACK_DRIFT: zella_billing_email_invoice_trg did not restore exactly'; end if;
  end if;
end $x$;

do $$
declare s text; d text;
  v_orig constant text := '60c0659f065c58b03dc279ffb007825c';
  v_made constant text := 'effc5ab4a36f94ac7429909fd534849b';
  owned constant jsonb := '{
    "public.zella_owner_invoice_pay_status(uuid)": "3801f9664e172f095b4bd88652f31b4f",
    "public.zella_owner_invoice_pay_start(uuid)": "cb72de188cfae050d77a29bc3d627fd7",
    "public.zella_owner_billing_access(uuid,boolean)": "5738697783e8f82adc1872bea88bbf86",
    "public.zella_billing_stripe_refs(uuid,boolean)": "f850df5700bfb546c084e41d4267fab9",
    "public.zella_owner_pack_status(uuid,uuid)": "6e71430a8f8331ba81fce4300d15dfa7",
    "public.zella_owner_pack_act_start(uuid,uuid)": "ab55593e4a88a1e5198cd72decbcfaac",
    "public.zella_billing_address_prefill(uuid)": "55f277f7ce0649984442cb26898b47ad",
    "public.zella_billing_pack_reopen(uuid,uuid,text,boolean,uuid)": "2950fa09737c3f6952e467a693c3a90f",
    "public.zella_billing_pack_reopen_expire(uuid)": "657a7c8fdf778b20ab1f65acad872aff",
    "public.zella_owner_autopay_status(uuid)": "caf4ad7c04a3c894fc3806a652e72f69",
    "public.zella_owner_autopay_set(uuid,boolean,text)": "a8d07ed668c4a53ac76932950dcd5410",
    "public.zella_stripe_autopay_sync(uuid,integer)": "357e73815eee8de255247d5d62a5aca2",
    "public.zella_stripe_autopay_next_attempt(subscriptions)": "dc4d089e243c392c41942b1d2ce08664",
    "public.zella_billing_autopay_next_command(uuid)": "f87fce08f349bf2655b1a91f99d9670c",
    "public.zella_stripe_after_autopay(billing_outbox)": "f122a64fc699523b8df7c3cd0c93b4e0",
    "public.zella_stripe_autopay_check(billing_events,jsonb)": "aad451723faf8a0322bac862974aeb5a",
    "public.zella_billing_checkout_autopay(uuid,uuid,boolean)": "9beca42d2898efc46af25cc12f2feb62",
    "public.zella_billing_checkout_autopay_trg()": "75550950726e34e2de939691c8613040"
  }';
begin
  if md5(pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure)) not in (v_orig, v_made) then
    raise exception 'ROLLBACK_DRIFT: public.zella_owner_invoices(uuid) is not the version zella_stripe_owner_pay.sql made';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then
      if md5(pg_get_functiondef(to_regprocedure(s))) <> owned ->> s then raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_owner_pay.sql made', s; end if;
    end if;
  end loop;
  if md5(pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure)) = v_made then
    select definition into d from public.zella_function_archive
     where migration = 'zella_stripe_owner_pay' and signature = 'public.zella_owner_invoices(uuid)' and definition_md5 = v_orig;
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived zella_owner_invoices is missing'; end if;
    execute d;
    if md5(pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure)) <> v_orig then raise exception 'ROLLBACK_DRIFT: zella_owner_invoices did not restore exactly'; end if;
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', to_regprocedure(s)); end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_stripe_owner_pay';
end $$;

alter table public.subscriptions drop column if exists desired_autopay, drop column if exists autopay_version;
drop index if exists public.pack_purchases_one_pending_owner;
alter table public.pack_purchases drop column if exists reopen_expires_at;
alter table public.billing_checkouts drop column if exists desired_autopay;
drop table if exists public.billing_owner_requests;

commit;
