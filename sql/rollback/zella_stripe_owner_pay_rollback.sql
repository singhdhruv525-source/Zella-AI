-- Rollback of sql/zella_stripe_owner_pay.sql. Restores exactly as archived the functions the file changed in other
-- files (zella_owner_invoices, zella_billing_email_invoice_trg, zella_stripe_on_customer_subscription_updated,
-- zella_owner_pack_buy(uuid,text,text), zella_stripe_on_payment_intent_succeeded, and for the add ons and the agreement
-- zella_stripe_grant_subscription_create, zella_billing_checkout_continue, zella_stripe_on_checkout_session_completed and
-- zella_stripe_event_types), gives the two earlier entry points (zella_owner_billing_checkout_start(uuid,text),
-- zella_owner_pack_buy(uuid,text,text)) back to signed in owners, and drops the functions, columns, tables, index,
-- policy and trigger the file added (the owner's pending Auto pay choice is lost; Stripe keeps whatever it has).
-- Refuses with ROLLBACK_HAS_PENDING while an Auto pay or card command is waiting or being sent, or a checkout with add
-- ons is still in progress; with ROLLBACK_DRIFT if anything differs from what the file made. Data is untouched: a pack
-- an owner reopened stays as it is; the owners' agreements (billing_payment_consents) and the add ons sold
-- (billing_checkout_addons) are kept when they hold rows, and the pack source constraint keeps checkout_addon while
-- such packs exist. Safe to run twice.
begin;

-- a write barrier first (review): no Auto pay change, card command or checkout start can run between the checks below and
-- the column removal. Taken in the order zella_owner_autopay_set takes them (the subscription, then the outbox), so the
-- two never wait on each other in opposite orders; the rollback waits for one in progress to finish.
lock table public.subscriptions in access exclusive mode;
lock table public.billing_outbox in exclusive mode;
lock table public.billing_checkouts in exclusive mode;
lock table public.pack_purchases in exclusive mode;

-- refusals first (review M5): the rollback can't undo what Stripe has, so it waits until every business is back on Auto
-- pay, nothing is waiting for Stripe and no checkout with add ons is open
do $x$
declare v boolean;
begin
  if exists (select 1 from public.subscriptions where coalesce(metadata ->> 'collection_method', '') = 'send_invoice') then
    raise exception 'ROLLBACK_AUTOPAY_OFF: a business has Auto pay off at Stripe; switch every business back to Auto pay first';
  end if;
  -- (the columns and tables are gone after a first rollback, so they are read only while they exist)
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'subscriptions' and column_name = 'desired_autopay') then
    execute 'select exists (select 1 from public.subscriptions where desired_autopay is false)' into v;
    if v then raise exception 'ROLLBACK_AUTOPAY_OFF: a business asked for Auto pay off; switch every business back to Auto pay first'; end if;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pack_purchases' and column_name = 'reopen_expires_at') then
    execute 'select exists (select 1 from public.pack_purchases where reopen_expires_at is not null and status = ''pending'')' into v;
    if v then raise exception 'ROLLBACK_HAS_PENDING: a reopened pack is still waiting for Stripe'; end if;
  end if;
  if exists (select 1 from public.billing_outbox where kind in ('autopay', 'default_pm', 'addon_price') and status in ('pending', 'retry_wait', 'sending')) then
    raise exception 'ROLLBACK_HAS_PENDING: an Auto pay, card or add on price command is still waiting for Stripe';
  end if;
  if to_regclass('public.billing_checkout_addons') is not null then
    execute 'select exists (select 1 from public.billing_checkout_addons a join public.billing_checkouts c on c.id = a.checkout_id
                             where c.status in (''preparing'', ''open'', ''expiring'', ''completed''))' into v;
    if v then raise exception 'ROLLBACK_HAS_PENDING: a checkout with add ons is still in progress'; end if;
  end if;
  -- the trigger is the one the file made (review), or already gone (a repeat rollback)
  if exists (select 1 from pg_trigger where tgname = 'zella_billing_checkout_autopay' and tgrelid = 'public.billing_checkouts'::regclass)
     and (select regexp_replace(pg_get_triggerdef(t.oid), 'FUNCTION public\.', 'FUNCTION ') from pg_trigger t
           where t.tgname = 'zella_billing_checkout_autopay' and t.tgrelid = 'public.billing_checkouts'::regclass)
         <> 'CREATE TRIGGER zella_billing_checkout_autopay AFTER UPDATE OF stripe_subscription_id ON public.billing_checkouts FOR EACH ROW EXECUTE FUNCTION zella_billing_checkout_autopay_trg()' then
    raise exception 'ROLLBACK_DRIFT: the trigger zella_billing_checkout_autopay is not the one zella_stripe_owner_pay.sql made';
  end if;
end $x$;

drop trigger if exists zella_billing_checkout_autopay on public.billing_checkouts;

-- every function the file changed in another file goes back to its archived version (checked both ways)
do $x$
declare r record; d text; cur text;
begin
  for r in select * from (values
      ('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)', 'e7a39b17547fe5eefda25aa12c7fc0d2', 'aa9d3e91554cb0a8286017c849a982c1'),
      ('public.zella_owner_pack_buy(uuid,text,text)', 'ce968b09b251a2192c48fefd2de0cb52', 'd10a9c769091f776da0989ecff14ccde'),
      ('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)', 'c9b70ddd6dfdf324e93d3f2aa79d7ab4', 'a803f166b2a317d4b061ef01de4a3a04'),
      ('public.zella_billing_email_invoice_trg()', 'cc75a8987f19e2ae96c066395b79af45', 'e71bf72e22f1e906f1022c5e94f44f5e'),
      ('public.zella_owner_invoices(uuid)', '60c0659f065c58b03dc279ffb007825c', 'effc5ab4a36f94ac7429909fd534849b'),
      ('public.zella_stripe_grant_subscription_create(jsonb,jsonb)', '617d28551ada05a996984777eae97aa2', '29290a1596d10b6e9bd9a83acc886ef9'),
      ('public.zella_billing_checkout_continue(uuid,boolean)', '9b3ed39a3089059057a2ef7c36a96a19', 'ddb4d65d201aca53f66b55d52180eced'),
      ('public.zella_stripe_on_checkout_session_completed(billing_events,jsonb)', 'f73812ee1419833c6ec08db5011e5a2a', '02e0e712449f8c36e35777ba760ea618'),
      ('public.zella_stripe_event_types()', '72349917704935916bf10c4cbe7f7be1', '1a4b6e49cbb33ef2925eb62e9405d29f')) t(sig, orig, made) loop
    cur := md5(pg_get_functiondef(r.sig::regprocedure));
    if cur not in (r.orig, r.made) then raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_owner_pay.sql made', r.sig; end if;
  end loop;
  for r in select * from (values
      ('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)', 'e7a39b17547fe5eefda25aa12c7fc0d2', 'aa9d3e91554cb0a8286017c849a982c1'),
      ('public.zella_owner_pack_buy(uuid,text,text)', 'ce968b09b251a2192c48fefd2de0cb52', 'd10a9c769091f776da0989ecff14ccde'),
      ('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)', 'c9b70ddd6dfdf324e93d3f2aa79d7ab4', 'a803f166b2a317d4b061ef01de4a3a04'),
      ('public.zella_billing_email_invoice_trg()', 'cc75a8987f19e2ae96c066395b79af45', 'e71bf72e22f1e906f1022c5e94f44f5e'),
      ('public.zella_owner_invoices(uuid)', '60c0659f065c58b03dc279ffb007825c', 'effc5ab4a36f94ac7429909fd534849b'),
      ('public.zella_stripe_grant_subscription_create(jsonb,jsonb)', '617d28551ada05a996984777eae97aa2', '29290a1596d10b6e9bd9a83acc886ef9'),
      ('public.zella_billing_checkout_continue(uuid,boolean)', '9b3ed39a3089059057a2ef7c36a96a19', 'ddb4d65d201aca53f66b55d52180eced'),
      ('public.zella_stripe_on_checkout_session_completed(billing_events,jsonb)', 'f73812ee1419833c6ec08db5011e5a2a', '02e0e712449f8c36e35777ba760ea618'),
      ('public.zella_stripe_event_types()', '72349917704935916bf10c4cbe7f7be1', '1a4b6e49cbb33ef2925eb62e9405d29f')) t(sig, orig, made) loop
    if md5(pg_get_functiondef(r.sig::regprocedure)) = r.made then
      select definition into d from public.zella_function_archive where migration = 'zella_stripe_owner_pay' and signature = r.sig and definition_md5 = r.orig;
      if d is null then raise exception 'ROLLBACK_DRIFT: the archived % is missing', r.sig; end if;
      execute d;
      if md5(pg_get_functiondef(r.sig::regprocedure)) <> r.orig then raise exception 'ROLLBACK_DRIFT: % did not restore exactly', r.sig; end if;
    end if;
  end loop;
end $x$;

-- the functions this file made: each must still be its version, then all are dropped
do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_owner_invoice_pay_status(uuid)": "def8331d20227467d2553700d98e459d",
    "public.zella_owner_invoice_pay_start(uuid,boolean,jsonb,text,boolean)": "bad903805be54d7f02e80e2b35fe4db8",
    "public.zella_owner_billing_access(uuid,boolean)": "5738697783e8f82adc1872bea88bbf86",
    "public.zella_billing_stripe_refs(uuid,boolean)": "f850df5700bfb546c084e41d4267fab9",
    "public.zella_owner_pack_status(uuid,uuid)": "6e71430a8f8331ba81fce4300d15dfa7",
    "public.zella_owner_pack_act_start(uuid,uuid,text)": "0aae807c19c75defb0419cc4383ee3c7",
    "public.zella_billing_address_prefill(uuid)": "55f277f7ce0649984442cb26898b47ad",
    "public.zella_billing_pack_reopen(uuid,uuid,text,boolean,uuid)": "2950fa09737c3f6952e467a693c3a90f",
    "public.zella_billing_pack_reopen_expire(uuid)": "657a7c8fdf778b20ab1f65acad872aff",
    "public.zella_owner_autopay_status(uuid)": "e3793ec2d35df0dae53b15650dd9f4d8",
    "public.zella_owner_autopay_set(uuid,boolean,text)": "839958f51e1bb5f12edbec80ddd1bbd9",
    "public.zella_stripe_autopay_sync(uuid,integer)": "357e73815eee8de255247d5d62a5aca2",
    "public.zella_stripe_autopay_next_attempt(subscriptions)": "dc4d089e243c392c41942b1d2ce08664",
    "public.zella_billing_autopay_next_command(uuid)": "f87fce08f349bf2655b1a91f99d9670c",
    "public.zella_stripe_after_autopay(billing_outbox)": "f122a64fc699523b8df7c3cd0c93b4e0",
    "public.zella_stripe_autopay_check(billing_events,jsonb)": "aad451723faf8a0322bac862974aeb5a",
    "public.zella_billing_checkout_autopay(uuid,uuid,boolean)": "ce7d9b62c9d298af8d71493ee7eff507",
    "public.zella_billing_checkout_autopay_trg()": "75550950726e34e2de939691c8613040",
    "public.zella_billing_consent_money(bigint)": "57e167a263519821941eec064909fdd6",
    "public.zella_billing_terms_version()": "45054b7849bdfb9e4d5e8ddde39a9a2f",
    "public.zella_billing_consent_text(text,bigint,boolean,bigint,bigint)": "f71e539ac33a7aa48dfeee485e83d15d",
    "public.zella_billing_consent_check(text,text)": "d85ebeb30fb344fa1675fc928f61ef1d",
    "public.zella_billing_consent_record(uuid,text,uuid,text,text,bigint,boolean,bigint,jsonb)": "4db22aff67c22da2ce64fa7d7a86972d",
    "public.zella_owner_addon_catalog(uuid)": "89b1e2c913c527a6ea27377bdac1da9b",
    "public.zella_billing_card_checked(uuid,text)": "108b36e936fec7fc8b3386d9d576d87b",
    "public.zella_owner_pack_buy(uuid,text,text,text,uuid)": "fe0bb81b54e241cbd33608cf013a8956",
    "public.zella_billing_checkout_addon_codes(uuid)": "d0ec4062ffbf554269af24efc6e08841",
    "public.zella_billing_checkout_addon_lines(uuid,boolean)": "ddae63c27e07df49902c33ef00a1d0c1",
    "public.zella_billing_checkout_addon_price(uuid,text)": "e502357e2cc991ad5424017a3abb6def",
    "public.zella_stripe_after_addon_price(billing_outbox)": "b58ddbb056bdda68c4e2d3abc22a189f",
    "public.zella_stripe_failed_addon_price(billing_outbox)": "2485145a3aaee43c7f0c993a5e55365e",
    "public.zella_billing_checkout_addons_bind(billing_checkouts,jsonb)": "4a92accd70e9463aac14bbb16c57f4a3",
    "public.zella_billing_checkout_addons_grant(billing_checkouts,billing_periods)": "c66d31d7939007d7cf37bcce11241b60",
    "public.zella_owner_billing_checkout_start(uuid,text,text[],boolean,text)": "78a6c8eba502c2b0a5e47d220ec62acf",
    "public.zella_billing_invoice_attempts_clear(uuid)": "016b5d244d62683ecb79c0dd3d01be93",
    "public.zella_stripe_on_customer_updated(billing_events,jsonb)": "787f60b347bef56d98b4c40e99748295"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then
      if md5(pg_get_functiondef(to_regprocedure(s))) <> owned ->> s then raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_owner_pay.sql made', s; end if;
    end if;
  end loop;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', to_regprocedure(s)); end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_stripe_owner_pay';
end $$;

-- the two earlier entry points are the owner's again, as zella_stripe_checkout.sql and zella_stripe_packs.sql grant them
grant execute on function public.zella_owner_billing_checkout_start(uuid, text) to authenticated;
grant execute on function public.zella_owner_pack_buy(uuid, text, text) to authenticated;

alter table public.subscriptions drop column if exists desired_autopay, drop column if exists autopay_version,
  drop column if exists card_checked_pm, drop column if exists card_checked_at;
drop index if exists public.pack_purchases_one_pending_owner;
alter table public.pack_purchases drop column if exists reopen_expires_at;
alter table public.billing_checkouts drop column if exists desired_autopay, drop column if exists selection_key;
drop table if exists public.billing_owner_requests;
do $x$
declare v boolean;
begin
  -- packs sold as add ons keep their source; otherwise the constraint is exactly zella_stripe_packs.sql's again
  if not exists (select 1 from public.pack_purchases where source = 'checkout_addon') then
    alter table public.pack_purchases drop constraint if exists pack_purchases_source_check;
    alter table public.pack_purchases add constraint pack_purchases_source_check check (source in ('admin_grant', 'owner_purchase', 'auto_reload'));
  end if;
  -- the record of what owners agreed to, and of the add ons sold, is never deleted by a rollback
  if to_regclass('public.billing_checkout_addons') is not null then
    execute 'select exists (select 1 from public.billing_checkout_addons)' into v;
    if not v then drop table public.billing_checkout_addons; end if;
  end if;
  if to_regclass('public.billing_payment_consents') is not null then
    execute 'select exists (select 1 from public.billing_payment_consents)' into v;
    if not v then drop table public.billing_payment_consents; end if;
  end if;
end $x$;

commit;
