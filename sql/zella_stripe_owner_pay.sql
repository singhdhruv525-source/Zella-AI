-- Zella Voice: paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now";
-- docs/PAYMENTS_ARCHITECTURE.md §6.11, §6.4). Auto charge stays the default: Stripe charges the saved card on the
-- renewal date (unchanged). This file adds what the owner's own payments need, every one through billing-api:
--   1. zella_owner_invoices (replaced, archived first): each invoice also carries our id, the amount still due and
--      whether Pay now is offered.
--   2. zella_owner_invoice_pay_status / zella_owner_invoice_pay_start: one invoice by our id alone (the emailed Pay now
--      link). The id grants nothing: only the active owner of the invoice's business gets an answer, anyone else gets
--      NOT_FOUND. Starting needs a code verified session, payments live, and an invoice still open. Nothing is created:
--      the invoice's own PaymentIntent is confirmed in Stripe's form, so it can never be paid twice.
--   3. zella_owner_billing_access: the owner check for the card actions (the saved card's brand and last 4; Stripe's
--      Customer Portal for a card update).
--   4. zella_billing_stripe_refs (server only): the business's Stripe customer and subscription, from our own links.
--   5. zella_owner_pack_status / zella_owner_pack_act_start: a pack the bank wanted to confirm, or whose saved card was
--      declined, can be finished by the owner in Stripe's form on the SAME PaymentIntent (back to pending; granted only
--      by Stripe's payment_intent.succeeded and the binding check, unchanged).
--   6. zella_billing_address_prefill (server only): the business's own address, to prefill Stripe's billing address
--      fields in the checkout; the owner can change it there and nothing is saved back.
--   8. Auto pay (owner decision, 27 Nov 2026: "Auto pay switch, on by default"): subscriptions.desired_autopay and
--      autopay_version (the owner's latest choice); zella_owner_autopay_status / zella_owner_autopay_set (owner only,
--      audited billing.autopay_changed, email H1 held while email_live is off); server only zella_stripe_autopay_sync
--      (one Stripe command per choice, key autopay:<subscription>:<version>:<attempt>, body stored), its after send and
--      event checks, and zella_billing_autopay_next_command. customer.subscription.updated (zella_stripe_plan_change.sql's
--      version, archived first, two exact text changes) records Stripe's collection_method and days_until_due, the ONLY
--      way our record of Auto pay changes, and resends the latest choice on a mismatch.
--   7. zella_billing_email_invoice_trg (sql/zella_stripe_emails.sql's version, archived first, changed by one exact text
--      replacement): the invoice emails' data also carries our invoice id, so their Pay now link opens that invoice's own
--      page (/pay/invoice/<id>, sign in first) instead of the general Payments page.
--   9. The owner's agreement before Pay (owner decision, 27 Nov 2026: a required "I agree" box): billing_payment_consents
--      (RLS on, the business's owner reads, no client writes): the exact words, their sha256, the terms version, the
--      amount today, whether it recurs and the recurring amount. The words are rebuilt here (zella_billing_consent_text)
--      from the server's own figures; the payment starts (zella_owner_billing_checkout_start with five arguments,
--      zella_owner_invoice_pay_start, zella_owner_pack_buy with five arguments, zella_owner_pack_act_start) refuse
--      without them (CONSENT_REQUIRED) or with another sha256 (CONSENT_MISMATCH), and record each distinct agreement once.
--      The earlier two argument checkout start and three argument pack buy are server only now.
--  10. Add ons (owner decisions, 27 Nov 2026): zella_owner_addon_catalog (the packs on offer, owner only). Onboarding is
--      ONE payment: the packs ticked are billing_checkout_addons rows at catalogue prices and one time Prices on the same
--      Checkout Session (zella_billing_checkout_continue, zella_stripe_embedded_checkout.sql's version, three exact text
--      changes, archived first); the selection is in the key, so a different selection expires the open session first;
--      checkout.session.completed checks the session's add ons (one exact text change) and the first invoice's grant
--      checks every add on line against our record and the catalogue, then grants each pack once
--      (zella_stripe_grant_subscription_create, three exact text changes, archived first); any mismatch is BINDING
--      (quarantine and an alert, nothing granted). Renewals are unchanged: zella_stripe_renewals.sql's line check
--      already refuses any add on line. pack_purchases.source gains checkout_addon. Pay now charges add ons separately
--      right after the plan payment, each through the pack path with its own key, only under the owner's agreement for
--      that invoice and only once our record says it is paid.
--  11. Review fixes (round 1): Auto pay pending while any command is in flight; turning it on needs billing-api's fresh
--      check of the saved card (zella_billing_card_checked); an off choice saved after the subscription is linked is
--      applied, not lost; customer.updated (added to zella_stripe_pipeline.sql's event list, one exact text change)
--      makes a card set on Stripe's card page the subscription's default for renewals, through the outbox.
-- Needs sql/zella_stripe_invoices.sql, sql/zella_stripe_packs.sql, sql/zella_stripe_emails.sql, sql/zella_stripe_checkout.sql,
-- sql/zella_stripe_embedded_checkout.sql and sql/zella_stripe_pipeline.sql. Rollback:
-- sql/rollback/zella_stripe_owner_pay_rollback.sql (restores zella_owner_invoices exactly, drops the rest; refuses on
-- drift). Tests: tests/stripe_owner_pay/stub_run.sh, web/supabase/functions/billing-api/handle_test.ts.
begin;

do $$
declare s text; d text;
  v_from constant text := '60c0659f065c58b03dc279ffb007825c';   -- sql/zella_stripe_invoices.sql's zella_owner_invoices
  v_to constant text := 'effc5ab4a36f94ac7429909fd534849b';
  owned constant jsonb := '{
    "public.zella_owner_invoice_pay_status(uuid)": "2526a6d23b5e3e7a4958fd8f4e2a4600",
    "public.zella_owner_invoice_pay_start(uuid,boolean,jsonb,text,boolean,text)": "72d40dc65a49a4c35ac4d13bbf67787b",
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
    "public.zella_billing_consent_record(uuid,text,uuid,text,text,bigint,boolean,bigint,jsonb)": "6567947a4f7b20d20743f42281308f1e",
    "public.zella_owner_addon_catalog(uuid)": "89b1e2c913c527a6ea27377bdac1da9b",
    "public.zella_billing_card_checked(uuid,text)": "108b36e936fec7fc8b3386d9d576d87b",
    "public.zella_owner_pack_buy(uuid,text,text,text,uuid)": "5a201f7e71a40a07ffbb3eb6bb6a9d58",
    "public.zella_billing_checkout_addon_codes(uuid)": "d0ec4062ffbf554269af24efc6e08841",
    "public.zella_billing_checkout_addon_lines(uuid,boolean)": "ddae63c27e07df49902c33ef00a1d0c1",
    "public.zella_billing_checkout_addon_price(uuid,text)": "e502357e2cc991ad5424017a3abb6def",
    "public.zella_stripe_after_addon_price(billing_outbox)": "b58ddbb056bdda68c4e2d3abc22a189f",
    "public.zella_stripe_failed_addon_price(billing_outbox)": "2485145a3aaee43c7f0c993a5e55365e",
    "public.zella_billing_checkout_addons_bind(billing_checkouts,jsonb)": "4a92accd70e9463aac14bbb16c57f4a3",
    "public.zella_billing_checkout_addons_grant(billing_checkouts,billing_periods)": "c66d31d7939007d7cf37bcce11241b60",
    "public.zella_owner_billing_checkout_start(uuid,text,text[],boolean,text)": "3aec168c1c74e4fd559ad017317652ae",
    "public.zella_billing_invoice_attempts_clear(uuid,text,timestamp with time zone)": "403d3484ce63b1a0a3dd0ca388c5e209",
    "public.zella_billing_invoice_agreement(uuid)": "6a219fd47ec98c075a09226b4f33124f",
    "public.zella_billing_checkout_addon_amounts(uuid)": "be504ed6c4921b2136e334ec60618e5b",
    "public.zella_stripe_on_customer_updated(billing_events,jsonb)": "787f60b347bef56d98b4c40e99748295"
  }';
begin
  if to_regclass('public.billing_invoices') is null or to_regclass('public.pack_purchases') is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_owner_invoices(uuid)') is null or to_regprocedure('public.zella_owner_pack_buy(uuid,text,text)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_invoices.sql and zella_stripe_packs.sql';
  end if;
  if to_regclass('public.billing_plan_changes') is null or to_regprocedure('public.zella_stripe_cancel_check(billing_events,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_cancel.sql and zella_stripe_plan_change.sql';
  end if;
  if to_regclass('public.billing_checkouts') is null or to_regprocedure('public.zella_owner_billing_checkout_start(uuid,text)') is null
     or to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)') is null or to_regprocedure('public.zella_stripe_event_types()') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_checkout.sql, zella_stripe_embedded_checkout.sql and zella_stripe_pipeline.sql';
  end if;
  d := pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure);
  if md5(d) = v_from then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_stripe_owner_pay', 'public.zella_owner_invoices(uuid)', d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> v_to then
    raise exception 'VERSION_MISMATCH: public.zella_owner_invoices(uuid) is not a version this file was written for';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then
      if md5(pg_get_functiondef(to_regprocedure(s))) <> owned ->> s then raise exception 'VERSION_MISMATCH: % is not the version this file makes', s; end if;
    end if;
  end loop;
end $$;

-- Review fixes (27 Nov 2026): owner request keys, a reopened pack's expiry, the checkout's Auto pay choice, one pending
-- owner purchase per pack
create table if not exists public.billing_owner_requests (
  operation text not null check (operation ~ '^[a-z_]{3,40}$'),
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{8,100}$'),
  business_id uuid not null references public.businesses(id) on delete cascade,
  value jsonb not null,
  user_id uuid,
  created_at timestamptz not null default now(),
  primary key (operation, idempotency_key)
);
alter table public.billing_owner_requests enable row level security;   -- no policies: only the definer functions use it
revoke all on public.billing_owner_requests from anon, authenticated;
alter table public.pack_purchases add column if not exists reopen_expires_at timestamptz;
alter table public.billing_checkouts add column if not exists desired_autopay boolean;
create unique index if not exists pack_purchases_one_pending_owner on public.pack_purchases (business_id, pack_code) where source = 'owner_purchase' and status = 'pending';

-- 8. Auto pay: the owner's latest choice, versioned (Stripe's own value is kept in metadata, from its events only)
alter table public.subscriptions add column if not exists desired_autopay boolean;
alter table public.subscriptions add column if not exists autopay_version integer not null default 0;
-- the saved card billing-api last checked with Stripe (an id and a time, no card data): turning Auto pay on needs it (review)
alter table public.subscriptions add column if not exists card_checked_pm text;
alter table public.subscriptions add column if not exists card_checked_at timestamptz;

-- 9. The owner's agreement before Pay (owner decision, 27 Nov 2026: a required "I agree" box). One row per distinct text
-- agreed for a payment: who, when, which business, which payment, the exact text shown and its sha256, the terms
-- version, the amount today, whether it recurs and the recurring amount, and the add ons it covers. Written only by the
-- owner functions that start a payment, after they rebuilt the text from their own figures; the owner reads their own.
create table if not exists public.billing_payment_consents (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid,
  business_id uuid not null references public.businesses(id) on delete restrict,
  payment_kind text not null check (payment_kind in ('checkout', 'invoice', 'pack', 'pack_act')),
  payment_id uuid not null,
  consent_text text not null check (length(consent_text) between 40 and 600),
  consent_sha256 text not null check (consent_sha256 ~ '^[0-9a-f]{64}$'),
  terms_version text not null,
  amount_today_minor bigint not null check (amount_today_minor >= 0),
  currency text not null default 'usd' check (currency = 'usd'),
  recurring boolean not null,
  recurring_amount_minor bigint check (recurring_amount_minor >= 0),
  addons jsonb not null default '[]'::jsonb check (jsonb_typeof(addons) = 'array'),
  -- Pay now: when this agreement went with the payment to Stripe (the Pay press); the add ons bought after the payment
  -- are those of the one submitted agreement (review round 2)
  submitted_at timestamptz,
  -- Pay now (review round 4): the PaymentIntent the Pay press confirms (billing-api read it from the invoice at Stripe);
  -- add ons are bought only under the submitted agreement for the intent that paid the invoice
  payment_intent text check (payment_intent is null or payment_intent ~ '^pi_[A-Za-z0-9_]{1,250}$')
);
alter table public.billing_payment_consents add column if not exists submitted_at timestamptz;
alter table public.billing_payment_consents add column if not exists payment_intent text check (payment_intent is null or payment_intent ~ '^pi_[A-Za-z0-9_]{1,250}$');
-- one row per agreement: the words (their sha256) AND the exact add ons, keys and prices (review round 3). The words
-- name only the add ons' total, so two selections with the same total are two agreements; the same payload again (a
-- retry, a double click) reaches its own row, and a different payload can never reuse or overwrite it.
alter table public.billing_payment_consents drop constraint if exists billing_payment_consents_payment_kind_payment_id_consent_sha256_key;
create unique index if not exists billing_payment_consents_agreement_uq on public.billing_payment_consents (payment_kind, payment_id, consent_sha256, addons);
create index if not exists billing_payment_consents_business_idx on public.billing_payment_consents (business_id, created_at desc);
alter table public.billing_payment_consents enable row level security;
revoke all on public.billing_payment_consents from anon, authenticated;
grant select on public.billing_payment_consents to authenticated;   -- rows: the business's active owner only (policy below); no client writes
drop policy if exists billing_payment_consents_owner_read on public.billing_payment_consents;
create policy billing_payment_consents_owner_read on public.billing_payment_consents for select to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = billing_payment_consents.business_id and m.user_id = auth.uid()
                  and m.role = 'owner' and m.status = 'active'));

-- 10. Add ons on the onboarding Pay step (owner decision, 27 Nov 2026: one single payment): the packs chosen for a
-- checkout, at the catalogue price when it started. Server only. Each is a line of the same Checkout Session and is
-- granted only from that checkout's verified, bound first invoice.
create table if not exists public.billing_checkout_addons (
  id uuid primary key default gen_random_uuid(),
  checkout_id uuid not null references public.billing_checkouts(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  pack_code text not null references public.billing_pack_catalog(code),
  resource text not null,
  quantity integer not null check (quantity > 0),
  price_cents bigint not null check (price_cents > 0),
  created_at timestamptz not null default now(),
  unique (checkout_id, pack_code)
);
alter table public.billing_checkout_addons enable row level security;   -- no policies: only the definer functions use it
revoke all on public.billing_checkout_addons from anon, authenticated;
alter table public.billing_checkouts add column if not exists selection_key text;
alter table public.pack_purchases drop constraint if exists pack_purchases_source_check;
alter table public.pack_purchases add constraint pack_purchases_source_check check (source in ('admin_grant', 'owner_purchase', 'auto_reload', 'checkout_addon'));

-- The owner's invoices (replaces sql/zella_stripe_invoices.sql's version): the same rows plus our invoice id, the
-- amount still due and whether Pay now is offered (open or failed, payments live).
create or replace function public.zella_owner_invoices(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);   -- the business's active owner only
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'status', status, 'total_minor', total_minor, 'amount_paid_minor', amount_paid_minor,
           'amount_due_minor', amount_due_minor, 'currency', currency, 'period_start', period_start, 'period_end', period_end, 'hosted_invoice_url', hosted_invoice_url,
           'invoice_pdf', invoice_pdf, 'paid_at', paid_at, 'created_at', coalesce(stripe_created_at, created_at),
           'payable', status in ('open', 'payment_failed') and amount_due_minor > 0 and public.zella_payments_live()) order by coalesce(stripe_created_at, created_at) desc)
    from public.billing_invoices where business_id = p_business_id and status not in ('draft', 'deleted')), '[]'::jsonb);
end $$;

-- Server only (review round 4): the agreement whose add ons belong to an invoice. Paid: only an agreement submitted with
-- the PaymentIntent that paid it (our record's payment_intent, from the verified invoice.paid), so add ons come from the
-- confirmed payment's agreement, never from one that was only shown or sent with another intent. Not paid yet: the
-- latest one (a preview of what Pay would buy; nothing is bought before the invoice is paid).
create or replace function public.zella_billing_invoice_agreement(p_invoice_id uuid) returns public.billing_payment_consents
language sql stable security definer set search_path = public as $$
  select k.* from public.billing_payment_consents k join public.billing_invoices i on i.id = p_invoice_id
   where k.payment_kind = 'invoice' and k.payment_id = p_invoice_id
     and (i.status <> 'paid' or (k.submitted_at is not null and k.payment_intent is not null and k.payment_intent = i.payment_intent))
   order by k.submitted_at desc nulls last, k.created_at desc, k.id desc limit 1;
$$;

-- One invoice, by our id alone (the emailed Pay now link). The id grants nothing: the caller must be the active owner
-- of the invoice's business; a missing invoice and someone else's invoice answer the same NOT_FOUND.
create or replace function public.zella_owner_invoice_pay_status(p_invoice_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i public.billing_invoices;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select * into i from public.billing_invoices where id = p_invoice_id;
  if i.id is null or i.status in ('draft', 'deleted') or not exists (select 1 from public.business_members m where m.business_id = i.business_id
       and m.user_id = auth.uid() and m.role = 'owner' and m.status = 'active') then
    raise exception 'NOT_FOUND';
  end if;
  perform public.zella_onboarding_authorize(i.business_id, false, false);
  return jsonb_build_object('invoice_id', i.id, 'business_id', i.business_id, 'business_name', (select name from public.businesses where id = i.business_id),
    'stripe_invoice_id', i.stripe_invoice_id, 'number', i.number, 'status', i.status, 'kind', i.kind, 'total_minor', i.total_minor, 'amount_due_minor', i.amount_due_minor, 'amount_paid_minor', i.amount_paid_minor,
    'currency', i.currency, 'period_start', i.period_start, 'period_end', i.period_end, 'hosted_invoice_url', i.hosted_invoice_url, 'invoice_pdf', i.invoice_pdf, 'paid_at', i.paid_at,
    'payments_live', public.zella_payments_live(),
    'payable', i.status in ('open', 'payment_failed') and i.amount_due_minor > 0 and public.zella_payments_live(),
    -- the plan's renewal price, as the agreement's words name it (the same figure zella_owner_invoice_pay_start uses)
    'renewal_minor', (select bp.price_cents from public.business_plans bp where bp.business_id = i.business_id order by bp.version desc limit 1),
    -- the add ons the owner agreed to with Pay now (owner, 27 Nov 2026: charged separately right after the plan payment),
    -- from the latest consent for this invoice, each with its own key and its purchase so far: a reload mid way resumes
    -- them with the same keys, and the invoice itself is never charged again
    'addons_consent', (public.zella_billing_invoice_agreement(i.id)).consent_sha256,
    'addons', coalesce((select jsonb_agg(jsonb_build_object('code', a ->> 'code', 'key', a ->> 'key', 'price_cents', (a ->> 'price_cents')::bigint,
        'resource', a ->> 'resource', 'quantity', (a ->> 'quantity')::int, 'purchase_id', pp.id, 'status', pp.status, 'failure_reason', pp.failure_reason,
        'can_act', pp.status = 'failed' and pp.stripe_payment_intent is not null
                   and coalesce(pp.failure_reason, '') in ('authentication_required', 'card_declined', 'expired_card', 'insufficient_funds', 'incorrect_cvc', 'processing_error'))
        order by a ->> 'code')
      from (select (public.zella_billing_invoice_agreement(i.id)).addons) k
      cross join lateral jsonb_array_elements(coalesce(k.addons, '[]'::jsonb)) a
      left join public.pack_purchases pp on pp.business_id = i.business_id and pp.idempotency_key = a ->> 'key' and pp.source = 'owner_purchase'), '[]'::jsonb));
end $$;

-- Pay now: checks the owner (code verified session), payments live and the invoice still payable, and audits the
-- start. Nothing is created here or at Stripe: the invoice's own PaymentIntent is confirmed, so a double start, a
-- second tab or the emailed link all reach the same intent, and the invoice can never be paid twice.
-- The owner's agreement (owner, 27 Nov 2026: a required "I agree" box): the text is rebuilt here from OUR figures (the
-- amount due, the add ons at catalogue prices, the plan's renewal price and the Auto pay choice) and its sha256 must be
-- the one the page showed; it is recorded once per distinct text. Add ons (owner, 27 Nov 2026): Stripe can't add items
-- to a finalized invoice, so each is bought right after the plan payment through the pack path, with its own key made
-- when Pay was pressed (kept on retry); they are named here so the consent covers them and a reload can resume them.
drop function if exists public.zella_owner_invoice_pay_start(uuid, boolean, jsonb, text, boolean);
create or replace function public.zella_owner_invoice_pay_start(p_invoice_id uuid, p_autopay boolean, p_addons jsonb, p_consent_hash text, p_submit boolean default false,
  p_payment_intent text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i public.billing_invoices; s public.subscriptions; v_on boolean; v_add jsonb; v_sum bigint; v_n int; v_codes int; v_keys int; v_known int; v_ok boolean;
  v_plan bigint; v_text text; v_row uuid;
begin
  perform public.zella_owner_invoice_pay_status(p_invoice_id);   -- NOT_FOUND for anything not this owner's
  select * into i from public.billing_invoices where id = p_invoice_id;
  perform public.zella_onboarding_authorize(i.business_id, true, true);
  if p_consent_hash is null or p_consent_hash !~ '^[0-9a-f]{64}$' then raise exception 'CONSENT_REQUIRED'; end if;
  if p_addons is null then p_addons := '[]'::jsonb; end if;
  if jsonb_typeof(p_addons) <> 'array' or jsonb_array_length(p_addons) > 20 then raise exception 'INVALID_INPUT'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  if i.status = 'paid' then raise exception 'ALREADY_PAID'; end if;
  if i.status not in ('open', 'payment_failed') or i.amount_due_minor <= 0 then raise exception 'NOT_PAYABLE'; end if;
  select count(*), count(distinct x ->> 'code'), count(distinct x ->> 'key'), count(k.code), coalesce(sum(k.price_cents), 0),
         coalesce(bool_and(jsonb_typeof(x) = 'object' and coalesce(x ->> 'key', '') ~ '^[A-Za-z0-9_-]{8,100}$'), true),
         coalesce(jsonb_agg(jsonb_build_object('code', k.code, 'key', x ->> 'key', 'price_cents', k.price_cents, 'resource', k.resource, 'quantity', k.quantity)
                            order by k.code) filter (where k.code is not null), '[]'::jsonb)
    into v_n, v_codes, v_keys, v_known, v_sum, v_ok, v_add
    from jsonb_array_elements(p_addons) x left join public.billing_pack_catalog k on k.code = x ->> 'code' and k.active;
  if not v_ok or v_codes <> v_n or v_keys <> v_n then raise exception 'INVALID_INPUT'; end if;
  if v_known <> v_n then raise exception 'UNKNOWN_PACK'; end if;
  select * into s from public.subscriptions where business_id = i.business_id and provider = 'stripe';
  v_on := coalesce(p_autopay, s.desired_autopay, coalesce(s.metadata ->> 'collection_method', 'charge_automatically') <> 'send_invoice');
  v_plan := (select bp.price_cents from public.business_plans bp where bp.business_id = i.business_id order by bp.version desc limit 1);
  if v_on and v_plan is null then raise exception 'PLAN_MISSING'; end if;   -- the renewal amount must be stated, never guessed
  v_text := public.zella_billing_consent_text('invoice', i.amount_due_minor, v_on, v_plan, v_sum);
  perform public.zella_billing_consent_check(v_text, p_consent_hash);
  perform public.zella_billing_consent_record(i.business_id, 'invoice', i.id, v_text, p_consent_hash, i.amount_due_minor + v_sum, v_on, case when v_on then v_plan end, v_add);
  -- the Pay press (review round 2): one submitted agreement at a time per invoice. Another tab's agreement with OTHER add
  -- ons, submitted in the last 10 minutes, may be paying right now: this one is refused (ADDONS_IN_PROGRESS) unless
  -- billing-api found with Stripe that the earlier attempt failed (zella_billing_invoice_attempts_clear). So the add ons
  -- bought after the payment are exactly those agreed with the attempt that was sent.
  if coalesce(p_submit, false) then
    -- the Pay press names the intent it confirms (review round 4), the invoice's own when we know it
    if p_payment_intent is null or p_payment_intent !~ '^pi_[A-Za-z0-9_]{1,250}$' then raise exception 'INVALID_INPUT'; end if;
    -- under the lock, the invoice as it is now (review round 4): paid or no longer payable meanwhile, nothing is submitted
    select * into i from public.billing_invoices where id = i.id for update;
    if i.status = 'paid' then raise exception 'ALREADY_PAID'; end if;
    if i.status not in ('open', 'payment_failed') or i.amount_due_minor <= 0 then raise exception 'NOT_PAYABLE'; end if;
    if i.payment_intent is not null and i.payment_intent <> p_payment_intent then raise exception 'NOT_PAYABLE'; end if;
    -- this payload's own agreement: these words and exactly these add ons, keys and prices (review round 3)
    select k.id into v_row from public.billing_payment_consents k where k.payment_kind = 'invoice' and k.payment_id = i.id and k.consent_sha256 = p_consent_hash and k.addons = v_add;
    if v_row is null then raise exception 'CONSENT_MISMATCH'; end if;
    if exists (select 1 from public.billing_payment_consents k where k.payment_kind = 'invoice' and k.payment_id = i.id and k.id <> v_row
                 and k.submitted_at > clock_timestamp() - interval '10 minutes'
                 and coalesce((select jsonb_agg(x ->> 'code' order by x ->> 'code') from jsonb_array_elements(k.addons) x), '[]'::jsonb)
                     is distinct from coalesce((select jsonb_agg(x ->> 'code' order by x ->> 'code') from jsonb_array_elements(v_add) x), '[]'::jsonb)) then
      raise exception 'ADDONS_IN_PROGRESS';
    end if;
    -- the moment of this statement, not the transaction's start (review round 4), and the intent it goes with
    update public.billing_payment_consents set submitted_at = clock_timestamp(), payment_intent = p_payment_intent where id = v_row;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (i.business_id, auth.uid(), 'billing.invoice_pay_started', 'billing_invoice', i.id, jsonb_build_object('amount_due_minor', i.amount_due_minor, 'addons', v_n));
  return jsonb_build_object('invoice_id', i.id, 'business_id', i.business_id, 'stripe_invoice_id', i.stripe_invoice_id, 'number', i.number,
    'amount_due_minor', i.amount_due_minor, 'currency', i.currency, 'hosted_invoice_url', i.hosted_invoice_url, 'livemode', i.livemode,
    'addons', v_add, 'addons_minor', v_sum, 'total_minor', i.amount_due_minor + v_sum, 'renewal_minor', v_plan, 'autopay', v_on);
end $$;

-- The owner check for billing-api's card actions (read: the saved card's brand and last 4; write: the card update
-- page), with the address Stripe's page returns to.
create or replace function public.zella_owner_billing_access(p_business_id uuid, p_write boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, p_write, p_write);
  if p_write and not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  return jsonb_build_object('business_id', p_business_id, 'payments_live', public.zella_payments_live(),
    'app_base_url', nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''));
end $$;

-- Server only: the business's Stripe customer and subscription (our own links), in the key's mode.
create or replace function public.zella_billing_stripe_refs(p_business_id uuid, p_livemode boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'customer', (select stripe_id from public.billing_stripe_links where business_id = p_business_id and kind = 'customer' and livemode = coalesce(p_livemode, false)),
    'subscription', (select external_subscription_id from public.subscriptions where business_id = p_business_id and provider = 'stripe'));
$$;

-- A pack the owner bought: its state, and whether the owner can finish it with Stripe's form (the bank asked to
-- confirm, or the saved card was declined: the same PaymentIntent is confirmed, never a second charge).
create or replace function public.zella_owner_pack_status(p_business_id uuid, p_purchase_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v public.pack_purchases;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  select * into v from public.pack_purchases where id = p_purchase_id and business_id = p_business_id and source = 'owner_purchase';
  if v.id is null then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('purchase_id', v.id, 'status', v.status, 'pack_code', v.pack_code, 'resource', v.resource, 'quantity', v.quantity,
    'price_cents', v.price_cents, 'currency', 'usd', 'failure_reason', v.failure_reason, 'payment_intent', v.stripe_payment_intent,
    'reopen_expired', v.status = 'pending' and v.reopen_expires_at is not null and v.reopen_expires_at < now(),
    'can_act', v.status = 'failed' and v.stripe_payment_intent is not null
               and coalesce(v.failure_reason, '') in ('authentication_required', 'card_declined', 'expired_card', 'insufficient_funds', 'incorrect_cvc', 'processing_error'));
end $$;

-- The owner asks to finish a pack with Stripe's form: only the checks (owner, code verified session, payments live, a
-- purchase the owner may finish). Nothing changes here: billing-api first verifies the PaymentIntent with Stripe, then
-- zella_billing_pack_reopen moves the purchase forward (review B1, 3).
create or replace function public.zella_owner_pack_act_start(p_business_id uuid, p_purchase_id uuid, p_consent_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.pack_purchases; st jsonb; v_text text;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_consent_hash is null or p_consent_hash !~ '^[0-9a-f]{64}$' then raise exception 'CONSENT_REQUIRED'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into v from public.pack_purchases where id = p_purchase_id and business_id = p_business_id and source = 'owner_purchase';
  if v.id is null then raise exception 'NOT_FOUND'; end if;
  if v.status = 'granted' then raise exception 'ALREADY_PAID'; end if;
  if v.status = 'failed' then
    st := public.zella_owner_pack_status(p_business_id, p_purchase_id);
    if not (st ->> 'can_act')::boolean then raise exception 'NOT_PAYABLE'; end if;
  elsif v.status <> 'pending' or v.stripe_payment_intent is null then
    raise exception 'NOT_PAYABLE';
  end if;
  -- the owner agreed to this add on's own amount (rebuilt here from the purchase; recorded once per distinct text)
  v_text := public.zella_billing_consent_text('pack', v.price_cents, null, null, 0);
  perform public.zella_billing_consent_check(v_text, p_consent_hash);
  perform public.zella_billing_consent_record(p_business_id, 'pack_act', v.id, v_text, p_consent_hash, v.price_cents, false, null,
    jsonb_build_array(jsonb_build_object('code', v.pack_code, 'price_cents', v.price_cents)));
  return jsonb_build_object('purchase_id', v.id, 'payment_intent', v.stripe_payment_intent, 'price_cents', v.price_cents, 'currency', 'usd', 'user_id', auth.uid());
end $$;

-- Server only, after billing-api verified the PaymentIntent with Stripe (ours, this purchase, the price, still open):
-- the purchase goes back to pending on the SAME PaymentIntent, now linked to it with the expected amount, so Stripe's
-- payment_intent.succeeded grants it through the usual binding check (review B1). A reopened purchase expires after a
-- day unless Stripe took the payment (zella_billing_pack_reopen_expire). Repeating it answers the same.
create or replace function public.zella_billing_pack_reopen(p_business_id uuid, p_purchase_id uuid, p_payment_intent text, p_livemode boolean, p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.pack_purchases;
begin
  select * into v from public.pack_purchases where id = p_purchase_id and business_id = p_business_id and source = 'owner_purchase' for update;
  if v.id is null then raise exception 'NOT_FOUND'; end if;
  if v.status = 'granted' then raise exception 'ALREADY_PAID'; end if;
  if v.stripe_payment_intent is distinct from p_payment_intent then raise exception 'NOT_PAYABLE'; end if;
  perform public.zella_stripe_link_add(p_payment_intent, 'payment_intent', p_business_id, p_livemode, 'pack', v.id, v.price_cents);
  if v.status = 'failed' then
    if coalesce(v.failure_reason, '') not in ('authentication_required', 'card_declined', 'expired_card', 'insufficient_funds', 'incorrect_cvc', 'processing_error') then raise exception 'NOT_PAYABLE'; end if;
    if exists (select 1 from public.pack_purchases where business_id = p_business_id and pack_code = v.pack_code and source = 'owner_purchase' and status = 'pending' and id <> v.id) then
      raise exception 'PACK_PENDING';
    end if;
    update public.pack_purchases set status = 'pending', failure_reason = null, settled_at = null, reopen_expires_at = now() + interval '1 day' where id = v.id;
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
    values (p_business_id, p_user_id, 'billing.pack_owner_action', 'pack_purchase', v.id, jsonb_build_object('failure_reason', v.failure_reason), jsonb_build_object('status', 'pending'));
  elsif v.status <> 'pending' then
    raise exception 'NOT_PAYABLE';
  end if;
  return jsonb_build_object('purchase_id', v.id, 'payment_intent', v.stripe_payment_intent, 'price_cents', v.price_cents, 'currency', 'usd');
end $$;

-- Server only: a reopened purchase whose day has passed goes back to failed, called by billing-api only after Stripe
-- says the PaymentIntent was not taken (still waiting for the owner, or cancelled). States only move forward.
create or replace function public.zella_billing_pack_reopen_expire(p_purchase_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.pack_purchases set status = 'failed', failure_reason = 'reopen_expired', settled_at = now(), reopen_expires_at = null
   where id = p_purchase_id and status = 'pending' and reopen_expires_at is not null and reopen_expires_at < now();
  return case when found then 'expired' else 'unchanged' end;
end $$;

-- Server only: the business's own address, to prefill Stripe's billing address fields in the checkout (the owner can
-- change it there; nothing is saved back here). Country as a two letter code when it is one, or "US" for the usual
-- spellings of the United States; otherwise left out (Stripe's field then defaults to the United States). Any country.
create or replace function public.zella_billing_address_prefill(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'line1', nullif(left(trim(b.address_line_1), 100), ''), 'line2', nullif(left(trim(b.address_line_2), 100), ''),
    'city', nullif(left(trim(b.city), 100), ''), 'state', nullif(left(trim(b.state), 100), ''), 'postal_code', nullif(left(trim(b.postal_code), 20), ''),
    'country', case when upper(trim(b.country)) ~ '^[A-Z]{2}$' then upper(trim(b.country))
                    when lower(trim(b.country)) in ('united states', 'united states of america', 'usa') then 'US' end))
    from public.businesses b where b.id = p_business_id;
$$;

-- Auto pay (owner decision, 27 Nov 2026: "Auto pay switch, on by default"; docs/PAYMENTS_ARCHITECTURE.md §6.11): the
-- owner's choice is a versioned desired value on the subscription (desired_autopay, autopay_version). What Stripe has
-- (collection_method) is recorded ONLY from customer.subscription.updated, never from the browser or our own command.
-- Shown to the owner: whether Auto pay is on (Stripe's word), whether a change is on its way, the renewal date.
create or replace function public.zella_owner_autopay_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; v_on boolean;
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);   -- the business's active owner only
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe';
  v_on := coalesce(s.metadata ->> 'collection_method', 'charge_automatically') <> 'send_invoice';
  return jsonb_build_object('on', v_on, 'desired', coalesce(s.desired_autopay, v_on),
    -- pending while Stripe differs from the latest choice, or while any Auto pay command is still waiting or being sent
    -- (an older one could still land and change Stripe's value, e.g. an off command in flight when the owner switched back on)
    'pending', s.external_subscription_id is not null and ((s.desired_autopay is not null and s.desired_autopay <> v_on)
               or exists (select 1 from public.billing_outbox b where b.kind = 'autopay' and b.local_id = s.id and b.status in ('pending', 'retry_wait', 'sending'))),
    'days_until_due', case when v_on then null else coalesce((s.metadata ->> 'days_until_due')::int, 3) end,
    'current_period_end', s.current_period_end, 'status', s.status, 'subscribed', s.external_subscription_id is not null,
    'has_card', coalesce(s.metadata ->> 'default_payment_method', '') <> '',
    'payments_live', public.zella_payments_live(),
    'email_live', coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false));
end $$;

-- The owner switches Auto pay on or off (code verified session, payments live). The onboarding checkout sends the
-- owner's choice once the server has confirmed the first payment, when the subscription exists. Turning it on needs a saved card (billing-api also
-- checks with Stripe that it is still usable). The same key, or the same choice again, changes nothing (a double
-- submit). Each change: a new version, one audit entry, one email (held while email_live is off), one Stripe command.
create or replace function public.zella_owner_autopay_set(p_business_id uuid, p_on boolean, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions; v_on boolean; v_due date; r public.billing_owner_requests;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);   -- active owner of THIS business, code verified session
  if p_on is null or p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then raise exception 'INVALID_INPUT'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe' for update;
  if s.id is null or s.external_subscription_id is null or s.status in ('cancelled', 'expired') then raise exception 'NO_SUBSCRIPTION'; end if;
  -- the same request again (same key): answered as it stands; the same key with the other value is refused (review m1)
  select * into r from public.billing_owner_requests where operation = 'autopay' and idempotency_key = p_idempotency_key;
  if r.idempotency_key is not null then
    if r.business_id <> p_business_id or r.value <> to_jsonb(p_on) then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return public.zella_owner_autopay_status(p_business_id);
  end if;
  insert into public.billing_owner_requests (operation, idempotency_key, business_id, value, user_id) values ('autopay', p_idempotency_key, p_business_id, to_jsonb(p_on), auth.uid());
  v_on := coalesce(s.metadata ->> 'collection_method', 'charge_automatically') <> 'send_invoice';
  if coalesce(s.desired_autopay, v_on) = p_on then return public.zella_owner_autopay_status(p_business_id); end if;
  -- on needs Stripe's saved card AND billing-api's check with Stripe, moments ago, that this same card can still be charged
  -- (zella_billing_card_checked): a stored id whose card was removed or expired never turns Auto pay on (review)
  if p_on and (coalesce(s.metadata ->> 'default_payment_method', '') = '' or s.card_checked_pm is distinct from s.metadata ->> 'default_payment_method'
               or s.card_checked_at is null or s.card_checked_at < now() - interval '10 minutes') then
    raise exception 'NO_SAVED_CARD';
  end if;
  update public.subscriptions set desired_autopay = p_on, autopay_version = autopay_version + 1, updated_at = now() where id = s.id returning * into s;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'billing.autopay_changed', 'subscription', s.id, jsonb_build_object('autopay', v_on),
          jsonb_build_object('autopay', p_on, 'version', s.autopay_version, 'key', p_idempotency_key));
  v_due := (coalesce(s.current_period_end, now()) + interval '3 days')::date;
  perform public.zella_billing_email(p_business_id, 'H1', s.id::text, s.autopay_version::text, jsonb_build_object('autoPayOn', p_on,
    'dueDate', to_char(v_due, 'FMMonth FMDD, YYYY'), 'changedBy', 'The business owner', 'time', to_char(now() at time zone 'UTC', 'FMMonth FMDD, YYYY HH24:MI "UTC"')));
  perform public.zella_stripe_autopay_sync(p_business_id, 1);
  return public.zella_owner_autopay_status(p_business_id);
end $$;

-- Server only: queues the latest choice for Stripe (key autopay:<subscription>:<version>:<attempt>, the exact body
-- stored, §8.1); older choices still waiting are never sent, so the latest always wins. Off: send_invoice, due in 3 days.
create or replace function public.zella_stripe_autopay_sync(p_business_id uuid, p_attempt integer default 1) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions; o public.billing_outbox; v_key text;
begin
  select * into s from public.subscriptions where business_id = p_business_id and provider = 'stripe' and external_subscription_id is not null for update;
  if s.id is null or s.desired_autopay is null or s.status in ('cancelled', 'expired') then return null; end if;
  v_key := 'autopay:' || s.external_subscription_id || ':' || s.autopay_version || ':' || p_attempt;
  update public.billing_outbox set status = 'cancelled', updated_at = now()
   where business_id = p_business_id and kind = 'autopay' and status in ('pending', 'retry_wait') and local_id = s.id and idempotency_key <> v_key;
  o := public.zella_billing_outbox_add(p_business_id, 'autopay', v_key, 'POST', '/v1/subscriptions/' || s.external_subscription_id,
    case when s.desired_autopay then jsonb_build_object('collection_method', 'charge_automatically')
         else jsonb_build_object('collection_method', 'send_invoice', 'days_until_due', 3) end, 'subscription', s.id);
  return o.id;
end $$;

-- The next unused attempt number for the current choice (under the subscription's row lock).
create or replace function public.zella_stripe_autopay_next_attempt(s public.subscriptions) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(max(nullif(split_part(idempotency_key, ':', 4), '')::int), 0) + 1 from public.billing_outbox
   where kind = 'autopay' and local_id = s.id and idempotency_key like 'autopay:' || s.external_subscription_id || ':' || s.autopay_version || ':%';
$$;

-- Server only: the waiting Stripe command for this business's Auto pay choice, for billing-api to send at once.
create or replace function public.zella_billing_autopay_next_command(p_business_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.billing_outbox where business_id = p_business_id and kind = 'autopay' and status in ('pending', 'retry_wait') order by created_at desc limit 1;
$$;

-- After a send: nothing is recorded from our own command (the event does that); if Stripe's answer doesn't match the
-- latest choice (an older send landed last) and nothing is waiting, the latest is sent again.
create or replace function public.zella_stripe_after_autopay(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions;
begin
  select * into s from public.subscriptions where id = r.local_id for update;
  if s.id is null or s.desired_autopay is null then return; end if;
  if (r.response ->> 'collection_method' = 'charge_automatically') is distinct from s.desired_autopay
     and not exists (select 1 from public.billing_outbox where kind = 'autopay' and local_id = s.id and status in ('pending', 'retry_wait', 'sending') and id <> r.id) and not exists (select 1 from public.billing_outbox where kind = 'autopay' and local_id = s.id and status = 'held'
                     and idempotency_key like 'autopay:' || s.external_subscription_id || ':' || s.autopay_version || ':%') then
    perform public.zella_stripe_autopay_sync(s.business_id, public.zella_stripe_autopay_next_attempt(s));
  end if;
end $$;

-- From customer.subscription.updated (fetched): Stripe's collection method against the latest choice; a mismatch with
-- nothing waiting is sent again. Called by the event handler after it recorded Stripe's value.
create or replace function public.zella_stripe_autopay_check(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions;
begin
  if l.stripe_id is null then return 'ignored'; end if;
  select * into s from public.subscriptions where business_id = l.business_id and provider = 'stripe' for update;
  if s.id is null or s.desired_autopay is null or o ->> 'status' in ('canceled', 'incomplete_expired') then return 'ignored'; end if;
  if s.external_subscription_id is distinct from o ->> 'id' then return 'ignored'; end if;
  if (o ->> 'collection_method' = 'charge_automatically') is distinct from s.desired_autopay
     and not exists (select 1 from public.billing_outbox where kind = 'autopay' and local_id = s.id and status in ('pending', 'retry_wait', 'sending')) and not exists (select 1 from public.billing_outbox where kind = 'autopay' and local_id = s.id and status = 'held'
                     and idempotency_key like 'autopay:' || s.external_subscription_id || ':' || s.autopay_version || ':%') then
    perform public.zella_stripe_autopay_sync(s.business_id, public.zella_stripe_autopay_next_attempt(s));
    return 'applied';
  end if;
  return 'ignored';
end $$;

-- Server only: the Auto pay choice made in the onboarding checkout, kept with that checkout on the server when the payment
-- starts (review M2), so a closed tab can't lose it. Once Stripe's subscription is linked (the trigger below already
-- ran), an off choice saved now goes straight to the subscription and its command, so it is never silently lost (review).
create or replace function public.zella_billing_checkout_autopay(p_business_id uuid, p_checkout_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare c public.billing_checkouts;
begin
  update public.billing_checkouts set desired_autopay = p_on, updated_at = now() where id = p_checkout_id and business_id = p_business_id returning * into c;
  if c.id is not null and c.stripe_subscription_id is not null and p_on is false then
    update public.subscriptions set desired_autopay = false, autopay_version = autopay_version + 1, updated_at = now()
     where business_id = c.business_id and provider = 'stripe' and external_subscription_id = c.stripe_subscription_id and desired_autopay is distinct from false;
    if found then
      insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
      values (c.business_id, coalesce(auth.uid(), c.created_by), 'billing.autopay_changed', 'billing_checkout', c.id, jsonb_build_object('autopay', false, 'from', 'checkout'));
      perform public.zella_stripe_autopay_sync(c.business_id, 1);
    end if;
  end if;
end $$;

-- When the checkout's Stripe subscription is linked (checkout.session.completed), a choice of "off" becomes the
-- subscription's desired value and is sent to Stripe (the usual versioned command; the event check resends if needed).
create or replace function public.zella_billing_checkout_autopay_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.desired_autopay is false and new.stripe_subscription_id is not null and new.stripe_subscription_id is distinct from old.stripe_subscription_id then
    update public.subscriptions set desired_autopay = false, autopay_version = autopay_version + 1, updated_at = now()
     where business_id = new.business_id and provider = 'stripe' and external_subscription_id = new.stripe_subscription_id and desired_autopay is distinct from false;
    if found then
      insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
      values (new.business_id, new.created_by, 'billing.autopay_changed', 'billing_checkout', new.id, jsonb_build_object('autopay', false, 'from', 'checkout'));
      perform public.zella_stripe_autopay_sync(new.business_id, 1);
    end if;
  end if;
  return null;
end $$;

-- 6. the invoice emails carry our invoice id (one exact text replacement on a known version, archived first)
do $x$
declare d text;
  v_from constant text := 'cc75a8987f19e2ae96c066395b79af45';   -- sql/zella_stripe_emails.sql's version
  v_to constant text := 'e71bf72e22f1e906f1022c5e94f44f5e';
  v_old constant text := $r$jsonb_build_object('invoice', new.number,$r$;
  v_new constant text := $r$jsonb_build_object('invoiceId', new.id, 'invoice', new.number,$r$;
begin
  if to_regprocedure('public.zella_billing_email_invoice_trg()') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_emails.sql'; end if;
  d := pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure);
  if md5(d) = v_to then return; end if;
  if md5(d) <> v_from then raise exception 'VERSION_MISMATCH: public.zella_billing_email_invoice_trg() is not a version this file was written for'; end if;
  if (length(d) - length(replace(d, v_old, ''))) / length(v_old) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_stripe_owner_pay', 'public.zella_billing_email_invoice_trg()', d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, v_old, v_new);
  if md5(pg_get_functiondef('public.zella_billing_email_invoice_trg()'::regprocedure)) <> v_to then raise exception 'VERSION_MISMATCH: the changed trigger function is not the expected version'; end if;
end $x$;

-- 8. customer.subscription.updated records Stripe's collection method (two exact text changes, archived first)
do $x$
declare d text;
  o0 constant text := $r$'stripe_item', o #>> '{items,data,0,id}',$r$;
  n0 constant text := $r$'collection_method', o ->> 'collection_method', 'days_until_due', (o ->> 'days_until_due')::int, 'stripe_item', o #>> '{items,data,0,id}',$r$;
  o1 constant text := $r$  perform public.zella_stripe_cancel_check(e, o);   -- the owner's latest cancel choice against Stripe's
$r$;
  n1 constant text := $r$  perform public.zella_stripe_cancel_check(e, o);   -- the owner's latest cancel choice against Stripe's
  perform public.zella_stripe_autopay_check(e, o);   -- the owner's latest Auto pay choice against Stripe's
$r$;
begin
  d := pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure);
  if md5(d) = 'a803f166b2a317d4b061ef01de4a3a04' then return; end if;
  if md5(d) <> 'c9b70ddd6dfdf324e93d3f2aa79d7ab4' then raise exception 'VERSION_MISMATCH: public.zella_stripe_on_customer_subscription_updated is not a version this file was written for'; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_stripe_owner_pay', 'public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)', d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(replace(d, o0, n0), o1, n1);
  if md5(pg_get_functiondef('public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)'::regprocedure)) <> 'a803f166b2a317d4b061ef01de4a3a04' then raise exception 'VERSION_MISMATCH: the changed event handler is not the expected version'; end if;
end $x$;

-- Review fixes: a pack payment with no link is held for a person (B1); one pending owner purchase per pack (M1)
do $x$
declare d text;
  o0 constant text := $q$    return 'ignored';   -- a plan invoice's payment: invoice.paid handles it
$q$;
  n0 constant text := $q$    -- one of our packs' payments with no link: never dropped (money may have been taken); a person checks it
    if coalesce(o #>> '{metadata,purchase_id}', '') <> '' then raise exception 'BINDING: pack payment % has no link to its purchase', o ->> 'id'; end if;
    return 'ignored';   -- a plan invoice's payment: invoice.paid handles it
$q$;
begin
  d := pg_get_functiondef('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)'::regprocedure);
  if md5(d) = 'aa9d3e91554cb0a8286017c849a982c1' then return; end if;
  if md5(d) <> 'e7a39b17547fe5eefda25aa12c7fc0d2' then raise exception 'VERSION_MISMATCH: public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb) is not a version this file was written for'; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_stripe_owner_pay', 'public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)', d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, o0, n0);
  if md5(pg_get_functiondef('public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb)'::regprocedure)) <> 'aa9d3e91554cb0a8286017c849a982c1' then raise exception 'VERSION_MISMATCH: public.zella_stripe_on_payment_intent_succeeded(billing_events,jsonb) did not change to the expected version'; end if;
end $x$;
do $x$
declare d text;
  o0 constant text := $q$  select * into c from public.billing_pack_catalog where code = p_pack_code and active;
$q$;
  n0 constant text := $q$  -- one owner purchase of a pack at a time (review M1, double payment cases 3, 6, 12): a second tab, or a retry with a new
  -- key while the first is still being paid, is answered with THAT purchase and never charges twice; an automatic
  -- reload of the same resource still being paid refuses it
  select * into v from public.pack_purchases where business_id = p_business_id and pack_code = p_pack_code and source = 'owner_purchase' and status = 'pending'
   order by purchased_at desc limit 1;
  if v.id is not null then return jsonb_build_object('purchase_id', v.id, 'status', v.status, 'price_cents', v.price_cents); end if;
  if exists (select 1 from public.pack_purchases x join public.billing_pack_catalog k on k.code = p_pack_code
              where x.business_id = p_business_id and x.source = 'auto_reload' and x.status = 'pending' and x.resource = k.resource) then
    raise exception 'PACK_PENDING';
  end if;
  select * into c from public.billing_pack_catalog where code = p_pack_code and active;
$q$;
begin
  d := pg_get_functiondef('public.zella_owner_pack_buy(uuid,text,text)'::regprocedure);
  if md5(d) = 'd10a9c769091f776da0989ecff14ccde' then return; end if;
  if md5(d) <> 'ce968b09b251a2192c48fefd2de0cb52' then raise exception 'VERSION_MISMATCH: public.zella_owner_pack_buy(uuid,text,text) is not a version this file was written for'; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_stripe_owner_pay', 'public.zella_owner_pack_buy(uuid,text,text)', d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, o0, n0);
  if md5(pg_get_functiondef('public.zella_owner_pack_buy(uuid,text,text)'::regprocedure)) <> 'd10a9c769091f776da0989ecff14ccde' then raise exception 'VERSION_MISMATCH: public.zella_owner_pack_buy(uuid,text,text) did not change to the expected version'; end if;
end $x$;

-- ---------------------------------------------------------------------------------------------------------------
-- 9. The owner's agreement before Pay (owner decision, 27 Nov 2026)
-- ---------------------------------------------------------------------------------------------------------------
-- Money in the agreement's words: whole dollars without cents ("$249"), otherwise two decimals ("$29.50"), thousands with
-- commas, exactly as the page writes it (web/supabase/functions/_shared/paymentConsent.js formatConsentMoney).
create or replace function public.zella_billing_consent_money(p_minor bigint) returns text
language sql immutable set search_path = '' as $$
  select '$' || case when p_minor % 100 = 0 then to_char(p_minor / 100, 'FM999,999,999,990') else to_char(p_minor / 100.0, 'FM999,999,999,990.00') end;
$$;

-- The terms version recorded with each agreement. A constant until the legal documents are published and versioned
-- (docs/MEMORY.md, open item).
create or replace function public.zella_billing_terms_version() returns text
language sql immutable set search_path = '' as $$ select 'terms-draft-2026-11-27'::text; $$;

-- The exact words of the agreement, rebuilt by the server from its own figures (the page shows the same words, made by
-- paymentConsent.js; a test keeps the two the same). p_kind 'plan': the onboarding payment (p_today: the plan, the setup
-- fee and the add ons) or Pay now without add ons; 'invoice': Pay now with add ons (p_today: the invoice on this card,
-- p_addons_minor: the add ons on the saved card right after); 'pack': one add on. With Auto pay on, the plan's renewal
-- price recurs; add ons never do, and the words say so.
create or replace function public.zella_billing_consent_text(p_kind text, p_today bigint, p_autopay boolean, p_renewal bigint, p_addons_minor bigint) returns text
language sql immutable set search_path = '' as $$
  select case
    when p_kind = 'pack' then 'I agree to the Terms and Privacy Policy and authorize Zella Voice to charge ' || public.zella_billing_consent_money(p_today) || ' today for this add on.'
    else
      case when p_kind = 'invoice' and coalesce(p_addons_minor, 0) > 0
           then 'I agree to the Terms and Privacy Policy and authorize Zella Voice to charge ' || public.zella_billing_consent_money(p_today) || ' to this card and '
                || public.zella_billing_consent_money(p_addons_minor) || ' for add ons to my saved card today' || case when p_autopay then ',' else '' end
           else 'I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card ' || public.zella_billing_consent_money(p_today) || ' today' end
      || case when p_autopay then ' and ' || public.zella_billing_consent_money(p_renewal) || ' each renewal until I cancel.' else '.' end
      || case when coalesce(p_addons_minor, 0) > 0 then ' Add ons are one time.' else '' end
  end;
$$;

-- The page's sha256 of the words it showed must be the sha256 of the words rebuilt here; otherwise nothing starts.
create or replace function public.zella_billing_consent_check(p_text text, p_hash text) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then raise exception 'CONSENT_REQUIRED'; end if;
  -- no words (a figure missing) never passes
  if p_text is null or encode(sha256(convert_to(p_text, 'UTF8')), 'hex') <> p_hash then raise exception 'CONSENT_MISMATCH'; end if;
end $$;

-- Server only (called by the owner functions above and below after the check): one row per distinct text agreed for a
-- payment; the same agreement again (a double click, a retry, a reload) writes nothing.
create or replace function public.zella_billing_consent_record(p_business_id uuid, p_kind text, p_payment_id uuid, p_text text, p_hash text, p_today bigint,
  p_recurring boolean, p_recurring_minor bigint, p_addons jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.billing_payment_consents (user_id, business_id, payment_kind, payment_id, consent_text, consent_sha256, terms_version, amount_today_minor,
    recurring, recurring_amount_minor, addons)
  values (auth.uid(), p_business_id, p_kind, p_payment_id, p_text, p_hash, public.zella_billing_terms_version(), p_today, coalesce(p_recurring, false),
    p_recurring_minor, coalesce(p_addons, '[]'::jsonb))
  on conflict (payment_kind, payment_id, consent_sha256, addons) do nothing;
$$;

-- The packs on offer, from the server's catalogue (the page never prices anything): the business's active owner only.
create or replace function public.zella_owner_addon_catalog(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  return coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'resource', c.resource, 'quantity', c.quantity, 'price_cents', c.price_cents, 'currency', 'usd')
                   order by case c.resource when 'minutes' then 1 when 'texts' then 2 else 3 end, c.quantity)
                   from public.billing_pack_catalog c where c.active), '[]'::jsonb);
end $$;

-- Server only (review round 2): billing-api found with Stripe that the invoice's payment attempt failed (the intent has a
-- payment error, or was cancelled): the earlier submitted agreements no longer hold the add ons. Bound to that attempt
-- (review round 3): p_payment_intent is the intent billing-api read (it must be the invoice's own when we know it), and
-- p_failed_at is when Stripe says it failed (the failed charge's time, or when it was cancelled). Only agreements
-- submitted up to that moment are cleared: a Pay pressed after the failure (a retry that may be paying now) stays, and
-- nothing is cleared once the invoice is paid.
drop function if exists public.zella_billing_invoice_attempts_clear(uuid);
create or replace function public.zella_billing_invoice_attempts_clear(p_invoice_id uuid, p_payment_intent text, p_failed_at timestamptz) returns integer
language plpgsql security definer set search_path = public as $$
declare i public.billing_invoices; n integer;
begin
  if p_payment_intent is null or p_payment_intent !~ '^pi_[A-Za-z0-9_]{1,250}$' or p_failed_at is null then raise exception 'INVALID_INPUT'; end if;
  select * into i from public.billing_invoices where id = p_invoice_id for update;
  if i.id is null or i.status = 'paid' then return 0; end if;
  if i.payment_intent is not null and i.payment_intent <> p_payment_intent then return 0; end if;
  update public.billing_payment_consents set submitted_at = null
   where payment_kind = 'invoice' and payment_id = p_invoice_id and submitted_at is not null and submitted_at <= p_failed_at;
  get diagnostics n = row_count;
  return n;
end $$;

-- Server only: billing-api checked with Stripe, moments ago, that the subscription's saved card can still be charged
-- (a card, not expired). Turning Auto pay on needs this for the same card (review).
create or replace function public.zella_billing_card_checked(p_business_id uuid, p_payment_method text) returns boolean
language sql security definer set search_path = public as $$
  update public.subscriptions set card_checked_pm = p_payment_method, card_checked_at = now()
   where business_id = p_business_id and provider = 'stripe' and p_payment_method ~ '^pm_[A-Za-z0-9_]{1,250}$'
     and metadata ->> 'default_payment_method' = p_payment_method
  returning true;
$$;

-- A pack bought by the owner, with their agreement (replaces direct calls to the three argument version, which is now
-- server only). On the pack page: the words for this add on at the catalogue price. As an add on agreed with Pay now
-- (p_invoice_id): bought only once OUR record says that invoice is paid, under the agreement the owner gave for it, which
-- named this pack and this key (the key made when Pay was pressed, kept on retry). Either way recorded once.
create or replace function public.zella_owner_pack_buy(p_business_id uuid, p_pack_code text, p_idempotency_key text, p_consent_hash text, p_invoice_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.billing_pack_catalog; i public.billing_invoices; k public.billing_payment_consents; v_text text; r jsonb;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_consent_hash is null or p_consent_hash !~ '^[0-9a-f]{64}$' then raise exception 'CONSENT_REQUIRED'; end if;
  if p_invoice_id is null then
    select * into c from public.billing_pack_catalog where code = p_pack_code and active for share;
    if c.code is null then raise exception 'UNKNOWN_PACK'; end if;
    v_text := public.zella_billing_consent_text('pack', c.price_cents, null, null, 0);
    perform public.zella_billing_consent_check(v_text, p_consent_hash);
  else
    select * into i from public.billing_invoices where id = p_invoice_id and business_id = p_business_id;
    if i.id is null then raise exception 'NOT_FOUND'; end if;
    if i.status <> 'paid' then raise exception 'INVOICE_NOT_PAID'; end if;
    -- only the agreement that went with the payment to Stripe (another tab's agreement never buys anything; review
    -- round 2), with these words, and naming this pack, this key and the price charged now (review round 3)
    -- the agreement tied to the confirmed payment: submitted with the intent that paid this invoice (review round 4)
    k := public.zella_billing_invoice_agreement(i.id);
    -- the price is held until this purchase is made (review round 4), as the checkout start does
    select * into c from public.billing_pack_catalog where code = p_pack_code and active for share;
    if k.id is null or k.submitted_at is null or k.business_id <> p_business_id or k.consent_sha256 <> p_consent_hash or c.code is null
       or not k.addons @> jsonb_build_array(jsonb_build_object('code', p_pack_code, 'key', p_idempotency_key, 'price_cents', c.price_cents)) then
      raise exception 'CONSENT_MISMATCH';
    end if;
    v_text := k.consent_text;
  end if;
  r := public.zella_owner_pack_buy(p_business_id, p_pack_code, p_idempotency_key);
  perform public.zella_billing_consent_record(p_business_id, 'pack', (r ->> 'purchase_id')::uuid, v_text, p_consent_hash, (r ->> 'price_cents')::bigint, false, null,
    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('code', p_pack_code, 'key', p_idempotency_key, 'price_cents', (r ->> 'price_cents')::bigint, 'invoice_id', p_invoice_id))));
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 10. Add ons on the onboarding Pay step: one single payment (owner decision, 27 Nov 2026)
-- ---------------------------------------------------------------------------------------------------------------
-- The checkout's add ons, sorted (null when there are none).
create or replace function public.zella_billing_checkout_addon_codes(p_checkout_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(pack_code, ',' order by pack_code) from public.billing_checkout_addons where checkout_id = p_checkout_id;
$$;

-- The checkout's add ons with their recorded prices, sorted ("minutes_100=2900,texts_500=1800"; null when none): a
-- checkout is reused only while these are the catalogue's prices (review round 4).
create or replace function public.zella_billing_checkout_addon_amounts(p_checkout_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(pack_code || '=' || price_cents, ',' order by pack_code) from public.billing_checkout_addons where checkout_id = p_checkout_id;
$$;

-- The Checkout Session's add on lines: the one time Prices we made for THIS checkout, in the key's mode.
create or replace function public.zella_billing_checkout_addon_lines(p_checkout_id uuid, p_livemode boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('price', l.stripe_id, 'quantity', 1) order by a.pack_code), '[]'::jsonb)
    from public.billing_checkout_addons a
    join public.billing_stripe_links l on l.kind = 'price' and l.local_kind = 'addon_price' and l.local_id = a.id and l.livemode = coalesce(p_livemode, false)
   where a.checkout_id = p_checkout_id;
$$;

-- Queues the one time Price of the checkout's next add on still without one (key price:addon:<add on id>, body stored).
create or replace function public.zella_billing_checkout_addon_price(p_checkout_id uuid, p_product text) returns public.billing_outbox
language plpgsql security definer set search_path = public as $$
declare a public.billing_checkout_addons;
begin
  select * into a from public.billing_checkout_addons x where x.checkout_id = p_checkout_id
     and not exists (select 1 from public.billing_stripe_links l where l.kind = 'price' and l.local_kind = 'addon_price' and l.local_id = x.id)
   order by x.pack_code limit 1;
  if a.id is null then raise exception 'NO_ADDON_TO_PRICE'; end if;
  return public.zella_billing_outbox_add(a.business_id, 'addon_price', 'price:addon:' || a.id, 'POST', '/v1/prices',
    jsonb_build_object('product', p_product, 'currency', 'usd', 'unit_amount', a.price_cents,
      'metadata', jsonb_build_object('business_id', a.business_id, 'checkout_id', a.checkout_id, 'addon_id', a.id, 'pack_code', a.pack_code, 'kind', 'addon_price')),
    'checkout', a.checkout_id);
end $$;

-- After Stripe made it: linked with its amount (Stripe's must be ours), then the checkout's next command.
create or replace function public.zella_stripe_after_addon_price(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (r.response ->> 'unit_amount')::bigint is distinct from (r.body ->> 'unit_amount')::bigint then raise exception 'BINDING: Stripe add on price amount differs'; end if;
  perform public.zella_stripe_link_add(r.stripe_id, 'price', r.business_id, (r.response ->> 'livemode')::boolean, 'addon_price',
                                       (r.body #>> '{metadata,addon_id}')::uuid, (r.body ->> 'unit_amount')::bigint);
  if r.local_kind = 'checkout' then perform public.zella_billing_checkout_continue(r.local_id, (r.response ->> 'livemode')::boolean); end if;
end $$;

-- Stripe refused it for good: the checkout that waited for it fails, so the owner can start again.
create or replace function public.zella_stripe_failed_addon_price(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_checkouts set status = 'failed', updated_at = now() where id = r.local_id and r.local_kind = 'checkout' and status = 'preparing';
$$;

-- The binding check for the add ons on the first invoice (§6.0a), on the invoice fetched from Stripe: every add on we
-- recorded for this checkout is on it exactly once, quantity 1, at the price we recorded, through a Price we made for it,
-- and that price is still the catalogue's for the same pack. Anything else raises BINDING: quarantined with an alert,
-- nothing granted, never guessed.
create or replace function public.zella_billing_checkout_addons_bind(c public.billing_checkouts, o jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare a record; n int;
begin
  for a in select x.*, k.code as cat_code, k.resource as cat_resource, k.quantity as cat_quantity, k.price_cents as cat_price, k.active as cat_active
             from public.billing_checkout_addons x left join public.billing_pack_catalog k on k.code = x.pack_code where x.checkout_id = c.id loop
    if a.cat_code is null or not a.cat_active or a.cat_resource <> a.resource or a.cat_quantity <> a.quantity then
      raise exception 'BINDING: add on % is not in the catalogue as recorded', a.pack_code;
    end if;
    if a.cat_price <> a.price_cents then raise exception 'BINDING: add on % costs % in the catalogue but % was recorded', a.pack_code, a.cat_price, a.price_cents; end if;
    select count(*) into n from jsonb_array_elements(coalesce(o #> '{lines,data}', '[]'::jsonb)) x
      join public.billing_stripe_links l on l.kind = 'price' and l.stripe_id = coalesce(x #>> '{pricing,price_details,price}', x #>> '{price,id}')
     where l.local_kind = 'addon_price' and l.local_id = a.id and l.business_id = c.business_id and l.expected_amount_minor = a.price_cents
       and coalesce((x ->> 'quantity')::bigint, 1) = 1 and (x ->> 'amount')::bigint = a.price_cents;
    if n <> 1 then raise exception 'BINDING: add on % is not on the invoice once at its price', a.pack_code; end if;
  end loop;
end $$;

-- The grant, in the same transaction as the plan's: each add on once (key addon-<add on id>), until the end of the first
-- period, as a granted pack of source checkout_addon. A replayed event finds them granted and adds nothing.
create or replace function public.zella_billing_checkout_addons_grant(c public.billing_checkouts, per public.billing_periods) returns void
language plpgsql security definer set search_path = public as $$
declare a public.billing_checkout_addons; v uuid; n int := 0;
begin
  for a in select * from public.billing_checkout_addons where checkout_id = c.id order by pack_code loop
    if per.id is null then raise exception 'BINDING: no period for the add ons'; end if;
    v := null;
    insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key, created_by, settled_at)
    values (c.business_id, a.pack_code, a.resource, a.quantity, a.price_cents, 'granted', 'checkout_addon', 'Added with the first payment', per.id, 'addon-' || a.id, c.created_by, now())
    on conflict (business_id, idempotency_key) do nothing returning id into v;
    if v is not null then
      insert into public.allowance_buckets (business_id, period_id, resource, kind, pack_purchase_id, granted, expires_at)
      values (c.business_id, per.id, a.resource, 'pack', v, a.quantity, per.period_end);
      n := n + 1;
    end if;
  end loop;
  if n > 0 then
    insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
    values (c.business_id, 'billing.checkout_addons_granted', 'billing_checkout', c.id, jsonb_build_object('addons', n));
  end if;
end $$;

-- The onboarding Pay step's start (replaces the two argument version, which is now server only): the plan, the add ons
-- chosen (codes only; prices from the catalogue), the Auto pay choice and the owner's agreement. The key is
-- deterministic from the page's attempt key and the sorted selection, so the same selection gets the same checkout (a
-- double click, a second tab, a reload). A different selection while a session is open: that session is expired at
-- Stripe first (status expiring; billing-api sends the expiry and asks again), never two open sessions. The agreement's
-- words are rebuilt here from OUR amounts; a mismatch starts nothing.
create or replace function public.zella_owner_billing_checkout_start(p_business_id uuid, p_idempotency_key text, p_packs text[], p_autopay boolean, p_consent_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.owner_onboarding; p public.business_plans; c public.billing_checkouts; v_trial boolean; s jsonb := public.zella_billing_settings();
  v_codes text[]; v_sel text; v_key text; v_known int; v_addons bigint; v_text text; v_attempt int; v_snap jsonb; v_amounts text;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' or p_autopay is null or cardinality(coalesce(p_packs, '{}'::text[])) > 20 then
    raise exception 'INVALID_INPUT';
  end if;
  if p_consent_hash is null or p_consent_hash !~ '^[0-9a-f]{64}$' then raise exception 'CONSENT_REQUIRED'; end if;
  if not public.zella_payments_live() then raise exception 'PAYMENTS_NOT_LIVE'; end if;
  perform 1 from public.businesses where id = p_business_id for update;   -- one start at a time per business
  if public.zella_onboarding_payment_confirmed_at(p_business_id) is not null then raise exception 'ALREADY_PAID'; end if;
  select * into o from public.owner_onboarding where business_id = p_business_id;
  if o.current_step is distinct from 'payment' then raise exception 'STEP_LOCKED'; end if;
  select * into p from public.business_plans where business_id = p_business_id order by version desc limit 1;
  if p.id is null then raise exception 'PLAN_MISSING'; end if;
  if p.version is distinct from o.plan_accepted_version then raise exception 'PLAN_CHANGED'; end if;
  -- the selection: known packs on offer, each once, sorted
  v_codes := array(select distinct x from unnest(coalesce(p_packs, '{}'::text[])) x where x is not null order by x);
  if cardinality(v_codes) <> cardinality(array_remove(coalesce(p_packs, '{}'::text[]), null)) then raise exception 'INVALID_INPUT'; end if;
  -- the selected packs read once (review round 3), held against a price change until this transaction ends: the total,
  -- the agreement's words and the add on lines all come from this one snapshot
  v_snap := coalesce((select jsonb_agg(jsonb_build_object('code', k.code, 'resource', k.resource, 'quantity', k.quantity, 'price_cents', k.price_cents) order by k.code)
                        from (select * from public.billing_pack_catalog where active and code = any (v_codes) order by code for share) k), '[]'::jsonb);
  select count(*), coalesce(sum((x ->> 'price_cents')::bigint), 0) into v_known, v_addons from jsonb_array_elements(v_snap) x;
  -- each pack at its price now: a checkout is reused only while its recorded add on amounts are these (review round 4)
  v_amounts := (select string_agg((x ->> 'code') || '=' || (x ->> 'price_cents'), ',' order by x ->> 'code') from jsonb_array_elements(v_snap) x);
  if v_known <> cardinality(v_codes) then raise exception 'UNKNOWN_PACK'; end if;
  v_trial := p.trial_enabled and public.zella_onboarding_rules() ->> 'first_payment' = 'trial_with_card';
  if v_trial and cardinality(v_codes) > 0 then raise exception 'ADDONS_NOT_IN_TRIAL'; end if;   -- a trial charges nothing today
  v_sel := array_to_string(v_codes, ',');
  v_key := 'k' || md5(p_idempotency_key || '|' || v_sel);
  -- the same key and selection: the same checkout (an expired or failed one is followed by a new attempt)
  select * into c from public.billing_checkouts where business_id = p_business_id and selection_key = v_key order by created_at desc limit 1;
  -- an open one past its expiry, or one priced differently from the catalogue now, goes through the replacement below
  -- (marked expired, or expired at Stripe first) (review round 4)
  if c.id is not null and (c.status in ('expired', 'failed') or (c.status = 'open' and c.expires_at <= now())
      or (c.status in ('preparing', 'open') and coalesce(public.zella_billing_checkout_addon_amounts(c.id), '') <> coalesce(v_amounts, ''))) then c := null; end if;
  if c.id is null then
    -- locked, so a session answer that opens it meanwhile is seen before the replacement decision
    select * into c from public.billing_checkouts where business_id = p_business_id and status in ('preparing', 'open', 'expiring', 'completed') order by created_at desc limit 1 for update;
    if c.id is not null and c.status in ('preparing', 'open')
       and (c.business_plan_id <> p.id or coalesce(public.zella_billing_checkout_addon_codes(c.id), '') <> v_sel
            or coalesce(public.zella_billing_checkout_addon_amounts(c.id), '') <> coalesce(v_amounts, '') or (c.status = 'open' and c.expires_at <= now())) then
      if c.status = 'open' and c.expires_at > now() and c.stripe_session_id is not null then
        -- the old session could still be paid at Stripe: Stripe expires it first; a new one is offered only after Stripe
        -- confirms (zella_stripe_after_checkout_expire). If it was paid meanwhile, that payment is processed as usual,
        -- with the add ons recorded for THAT checkout.
        update public.billing_checkouts set status = 'expiring', url = null, updated_at = now() where id = c.id;
        perform public.zella_billing_outbox_add(p_business_id, 'checkout_expire', 'checkoutexpire:' || c.id, 'POST',
          '/v1/checkout/sessions/' || c.stripe_session_id || '/expire', '{}'::jsonb, 'checkout', c.id);
        select * into c from public.billing_checkouts where id = c.id;
      else
        update public.billing_checkouts set status = 'expired', updated_at = now() where id = c.id;
        c := null;
      end if;
    end if;
  end if;
  -- the earlier session is being expired at Stripe: nothing to agree to yet; billing-api sends the expiry and asks again
  if c.id is not null and c.status = 'expiring' then
    return jsonb_build_object('checkout_id', c.id, 'status', c.status, 'mode', c.mode, 'amount_minor', c.first_amount_minor, 'currency', 'usd');
  end if;
  if c.id is null then
    v_attempt := (select count(*) from public.billing_checkouts where business_id = p_business_id and selection_key = v_key) + 1;
    insert into public.billing_checkouts (business_id, business_plan_id, mode, first_amount_minor, setup_fee_minor, trial_end_at, idempotency_key, selection_key, desired_autopay, created_by)
    values (p_business_id, p.id, case when v_trial then 'trial' else 'pay' end, case when v_trial then 0 else p.price_cents + p.setup_fee_cents + v_addons end,
            p.setup_fee_cents, case when v_trial then now() + make_interval(days => (s ->> 'trial_days')::int) end, v_key || '-' || v_attempt, v_key, p_autopay, auth.uid())
    returning * into c;
    insert into public.billing_checkout_addons (checkout_id, business_id, pack_code, resource, quantity, price_cents)
    select c.id, p_business_id, x ->> 'code', x ->> 'resource', (x ->> 'quantity')::integer, (x ->> 'price_cents')::bigint from jsonb_array_elements(v_snap) x;
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
    values (p_business_id, auth.uid(), 'billing.checkout_started', 'billing_checkout', c.id,
            jsonb_build_object('mode', c.mode, 'amount_minor', c.first_amount_minor, 'plan_version', p.version, 'addons', to_jsonb(v_codes)));
  elsif c.status in ('preparing', 'open') then
    perform public.zella_billing_checkout_autopay(p_business_id, c.id, p_autopay);   -- the owner's latest Auto pay choice
  end if;
  -- the agreement, for what THIS checkout charges (Stripe already taking a payment needs none)
  if c.status <> 'completed' then
    v_text := public.zella_billing_consent_text('plan', c.first_amount_minor, p_autopay, p.price_cents,
      (select coalesce(sum(a.price_cents), 0)::bigint from public.billing_checkout_addons a where a.checkout_id = c.id));
    perform public.zella_billing_consent_check(v_text, p_consent_hash);
    perform public.zella_billing_consent_record(p_business_id, 'checkout', c.id, v_text, p_consent_hash, c.first_amount_minor, p_autopay,
      case when p_autopay then p.price_cents end,
      coalesce((select jsonb_agg(jsonb_build_object('code', a.pack_code, 'price_cents', a.price_cents) order by a.pack_code) from public.billing_checkout_addons a where a.checkout_id = c.id), '[]'::jsonb));
  end if;
  return jsonb_build_object('checkout_id', c.id, 'status', c.status, 'mode', c.mode, 'amount_minor', c.first_amount_minor, 'currency', 'usd',
                            'renewal_minor', p.price_cents, 'autopay', p_autopay,
                            'addons_minor', (select coalesce(sum(a.price_cents), 0) from public.billing_checkout_addons a where a.checkout_id = c.id),
                            'addons', coalesce((select jsonb_agg(a.pack_code order by a.pack_code) from public.billing_checkout_addons a where a.checkout_id = c.id), '[]'::jsonb),
                            'url', case when c.status = 'open' and c.expires_at > now() then c.url end);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 11. A card changed on Stripe's card page becomes the subscription's card for renewals (review)
-- ---------------------------------------------------------------------------------------------------------------
-- The Customer Portal's payment_method_update sets the CUSTOMER's invoice_settings.default_payment_method; whether it
-- also changes the subscription's own default_payment_method (which wins for renewals when set) is a sandbox proof
-- (§16.8). So we don't rely on it: customer.updated (fetched from Stripe) with a new default card on OUR customer queues
-- one command making it the subscription's default (key defaultpm:<subscription>:<payment method>, body stored, §8.1).
-- Our record of the saved card still changes only from customer.subscription.updated.
create or replace function public.zella_stripe_on_customer_updated(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'customer'); s public.subscriptions;
  v_pm text := coalesce(o #>> '{invoice_settings,default_payment_method,id}', o #>> '{invoice_settings,default_payment_method}');
begin
  if l.stripe_id is null then return 'ignored'; end if;   -- not our customer
  if v_pm is null or v_pm !~ '^pm_[A-Za-z0-9_]{1,250}$' then return 'ignored'; end if;
  select * into s from public.subscriptions where business_id = l.business_id and provider = 'stripe' for update;
  if s.id is null or s.external_subscription_id is null or s.status in ('cancelled', 'expired') then return 'ignored'; end if;
  if s.metadata ->> 'default_payment_method' is not distinct from v_pm then return 'ignored'; end if;   -- already the subscription's card
  -- this card is already on its way: nothing more (two events for one change)
  if exists (select 1 from public.billing_outbox b where b.kind = 'default_pm' and b.local_id = s.id and b.status in ('pending', 'retry_wait', 'sending')
               and b.body ->> 'default_payment_method' = v_pm) then return 'ignored'; end if;
  -- the latest card wins: an older one still waiting is never sent
  update public.billing_outbox set status = 'cancelled', updated_at = now()
   where kind = 'default_pm' and local_id = s.id and status in ('pending', 'retry_wait') and body ->> 'default_payment_method' is distinct from v_pm;
  -- keyed by the customer event (review round 2): card A, then B, then A again sends three commands; the same event
  -- delivered again reaches the same command
  perform public.zella_billing_outbox_add(l.business_id, 'default_pm', 'defaultpm:' || s.external_subscription_id || ':' || e.id, 'POST',
    '/v1/subscriptions/' || s.external_subscription_id, jsonb_build_object('default_payment_method', v_pm), 'subscription', s.id);
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

-- 10a. The first invoice grants the add ons recorded for its checkout, only after their binding check (exact text
-- changes of zella_stripe_checkout.sql's grant, archived first)
do $x$
declare d text;
  s constant text := 'public.zella_stripe_grant_subscription_create(jsonb,jsonb)';
  o0 constant text := $q$count(*) filter (where l.business_id = v_biz and l.local_id = p.id)$q$;
  n0 constant text := $q$count(*) filter (where l.business_id = v_biz and (l.local_id = p.id or (l.local_kind = 'addon_price' and l.local_id in (select a.id from public.billing_checkout_addons a where a.checkout_id = c.id))))$q$;
  o1 constant text := $q$  if v_lines = 0 or v_ours <> v_lines then raise exception 'BINDING: invoice lines are not our prices for this plan'; end if;
$q$;
  n1 constant text := $q$  if v_lines = 0 or v_ours <> v_lines then raise exception 'BINDING: invoice lines are not our prices for this plan'; end if;
  perform public.zella_billing_checkout_addons_bind(c, o);   -- every add on recorded for this checkout, once, at its price (owner, 27 Nov 2026)
$q$;
  o2 constant text := $q$  per := public.zella_billing_open_period(v_biz, greatest(v_start, least(now(), v_end - interval '1 second')));
$q$;
  n2 constant text := $q$  per := public.zella_billing_open_period(v_biz, greatest(v_start, least(now(), v_end - interval '1 second')));
  perform public.zella_billing_checkout_addons_grant(c, per);   -- the add ons, once, in the same transaction
$q$;
begin
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = '29290a1596d10b6e9bd9a83acc886ef9' then return; end if;
  if md5(d) <> '617d28551ada05a996984777eae97aa2' then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 or (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1
     or (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_owner_pay', s, d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(replace(replace(d, o0, n0), o1, n1), o2, n2);
  if md5(pg_get_functiondef(s::regprocedure)) <> '29290a1596d10b6e9bd9a83acc886ef9' then raise exception 'VERSION_MISMATCH: % did not change to the expected version', s; end if;
end $x$;

-- 10b. The Checkout Session carries the add ons (one time Prices made first), the selection in its metadata, and is
-- queued only once the owner's agreement is recorded (exact text changes of zella_stripe_embedded_checkout.sql's
-- version, archived first)
do $x$
declare d text;
  s constant text := 'public.zella_billing_checkout_continue(uuid,boolean)';
  o0 constant text := $q$  else
    v_app := nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), '');
$q$;
  n0 constant text := $q$  elsif exists (select 1 from public.billing_checkout_addons a where a.checkout_id = c.id and not exists (select 1 from public.billing_stripe_links l
                 where l.kind = 'price' and l.local_kind = 'addon_price' and l.local_id = a.id and l.livemode = v_live)) then
    -- each add on the owner chose (owner, 27 Nov 2026): a one time Price at its catalogue amount, made once for this checkout
    o := public.zella_billing_checkout_addon_price(c.id, v_prod);
  else
    -- nothing is offered to pay before the owner's agreement to these exact amounts is recorded (owner, 27 Nov 2026)
    if not exists (select 1 from public.billing_payment_consents k where k.payment_kind = 'checkout' and k.payment_id = c.id) then raise exception 'CONSENT_REQUIRED'; end if;
    v_app := nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), '');
$q$;
  o1 constant text := $q$else jsonb_build_array(jsonb_build_object('price', v_price, 'quantity', 1)) end,$q$;
  n1 constant text := $q$else jsonb_build_array(jsonb_build_object('price', v_price, 'quantity', 1)) end || public.zella_billing_checkout_addon_lines(c.id, v_live),$q$;
  o2 constant text := $q$'metadata', jsonb_build_object('business_id', c.business_id, 'checkout_id', c.id, 'plan_version_id', c.business_plan_id),$q$;
  n2 constant text := $q$'metadata', jsonb_build_object('business_id', c.business_id, 'checkout_id', c.id, 'plan_version_id', c.business_plan_id, 'addons', public.zella_billing_checkout_addon_codes(c.id)),$q$;
begin
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'ddb4d65d201aca53f66b55d52180eced' then return; end if;
  if md5(d) <> '9b3ed39a3089059057a2ef7c36a96a19' then raise exception 'VERSION_MISMATCH: % is not a version this file was written for (apply zella_stripe_embedded_checkout.sql first)', s; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 or (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1
     or (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_owner_pay', s, d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(replace(replace(d, o0, n0), o1, n1), o2, n2);
  if md5(pg_get_functiondef(s::regprocedure)) <> 'ddb4d65d201aca53f66b55d52180eced' then raise exception 'VERSION_MISMATCH: % did not change to the expected version', s; end if;
end $x$;

-- 10c. checkout.session.completed: the add ons in Stripe's fetched session metadata are the ones we recorded (one exact
-- text change of zella_stripe_checkout.sql's version, archived first)
do $x$
declare d text;
  s constant text := 'public.zella_stripe_on_checkout_session_completed(billing_events,jsonb)';
  o0 constant text := $q$  select * into c from public.billing_checkouts where id = l.local_id for update;
$q$;
  n0 constant text := $q$  select * into c from public.billing_checkouts where id = l.local_id for update;
  -- the add ons on Stripe's session are exactly the ones we recorded for this checkout (owner, 27 Nov 2026)
  if coalesce(o #>> '{metadata,addons}', '') is distinct from coalesce(public.zella_billing_checkout_addon_codes(c.id), '') then raise exception 'BINDING: checkout add ons differ from our record'; end if;
$q$;
begin
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = '02e0e712449f8c36e35777ba760ea618' then return; end if;
  if md5(d) <> 'f73812ee1419833c6ec08db5011e5a2a' then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_owner_pay', s, d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, o0, n0);
  if md5(pg_get_functiondef(s::regprocedure)) <> '02e0e712449f8c36e35777ba760ea618' then raise exception 'VERSION_MISMATCH: % did not change to the expected version', s; end if;
end $x$;

-- 11a. customer.updated is one of the events we take (one exact text change of zella_stripe_pipeline.sql's list, archived first)
do $x$
declare d text;
  s constant text := 'public.zella_stripe_event_types()';
  o0 constant text := $q$'customer.subscription.pending_update_expired',$q$;
  n0 constant text := $q$'customer.subscription.pending_update_expired', 'customer.updated',$q$;
begin
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = '1a4b6e49cbb33ef2925eb62e9405d29f' then return; end if;
  if md5(d) <> '72349917704935916bf10c4cbe7f7be1' then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s; end if;
  if (length(d) - length(replace(d, o0, ''))) / length(o0) <> 1 then raise exception 'VERSION_MISMATCH: the text to change is not there exactly once'; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_owner_pay', s, d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, o0, n0);
  if md5(pg_get_functiondef(s::regprocedure)) <> '1a4b6e49cbb33ef2925eb62e9405d29f' then raise exception 'VERSION_MISMATCH: % did not change to the expected version', s; end if;
end $x$;

drop trigger if exists zella_billing_checkout_autopay on public.billing_checkouts;
create trigger zella_billing_checkout_autopay after update of stripe_subscription_id on public.billing_checkouts
  for each row execute function public.zella_billing_checkout_autopay_trg();

do $$ declare f text; begin
  foreach f in array array['zella_owner_invoices(uuid)', 'zella_owner_invoice_pay_status(uuid)', 'zella_owner_invoice_pay_start(uuid,boolean,jsonb,text,boolean,text)',
    'zella_owner_billing_access(uuid,boolean)', 'zella_owner_pack_status(uuid,uuid)', 'zella_owner_pack_act_start(uuid,uuid,text)',
    'zella_owner_autopay_status(uuid)', 'zella_owner_autopay_set(uuid,boolean,text)', 'zella_owner_addon_catalog(uuid)',
    'zella_owner_billing_checkout_start(uuid,text,text[],boolean,text)', 'zella_owner_pack_buy(uuid,text,text,text,uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  revoke execute on function public.zella_billing_stripe_refs(uuid, boolean) from public, anon, authenticated;
  grant execute on function public.zella_billing_stripe_refs(uuid, boolean) to service_role;
  revoke execute on function public.zella_billing_address_prefill(uuid) from public, anon, authenticated;
  grant execute on function public.zella_billing_address_prefill(uuid) to service_role;
  foreach f in array array['zella_billing_pack_reopen(uuid,uuid,text,boolean,uuid)', 'zella_billing_pack_reopen_expire(uuid)',
    'zella_billing_checkout_autopay(uuid,uuid,boolean)', 'zella_billing_checkout_autopay_trg()', 'zella_stripe_autopay_sync(uuid,integer)', 'zella_stripe_autopay_next_attempt(subscriptions)', 'zella_billing_autopay_next_command(uuid)',
    'zella_stripe_after_autopay(billing_outbox)', 'zella_stripe_autopay_check(billing_events,jsonb)',
    'zella_billing_consent_money(bigint)', 'zella_billing_terms_version()', 'zella_billing_consent_text(text,bigint,boolean,bigint,bigint)',
    'zella_billing_consent_check(text,text)', 'zella_billing_consent_record(uuid,text,uuid,text,text,bigint,boolean,bigint,jsonb)',
    'zella_billing_card_checked(uuid,text)', 'zella_billing_checkout_addon_codes(uuid)', 'zella_billing_checkout_addon_amounts(uuid)', 'zella_billing_checkout_addon_lines(uuid,boolean)',
    'zella_billing_checkout_addon_price(uuid,text)', 'zella_stripe_after_addon_price(billing_outbox)', 'zella_stripe_failed_addon_price(billing_outbox)',
    'zella_billing_checkout_addons_bind(billing_checkouts,jsonb)', 'zella_billing_checkout_addons_grant(billing_checkouts,billing_periods)',
    'zella_stripe_on_customer_updated(billing_events,jsonb)', 'zella_billing_invoice_attempts_clear(uuid,text,timestamptz)', 'zella_billing_invoice_agreement(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  -- the earlier entry points are server only now: a payment starts only through the versions that take the agreement
  revoke execute on function public.zella_owner_billing_checkout_start(uuid, text) from public, anon, authenticated;
  revoke execute on function public.zella_owner_pack_buy(uuid, text, text) from public, anon, authenticated;
end $$;

-- what this file made is exactly what it says it makes
do $$
declare s text;
  made constant jsonb := '{
    "public.zella_owner_invoices(uuid)": "effc5ab4a36f94ac7429909fd534849b",
    "public.zella_owner_invoice_pay_status(uuid)": "2526a6d23b5e3e7a4958fd8f4e2a4600",
    "public.zella_owner_invoice_pay_start(uuid,boolean,jsonb,text,boolean,text)": "72d40dc65a49a4c35ac4d13bbf67787b",
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
    "public.zella_billing_consent_record(uuid,text,uuid,text,text,bigint,boolean,bigint,jsonb)": "6567947a4f7b20d20743f42281308f1e",
    "public.zella_owner_addon_catalog(uuid)": "89b1e2c913c527a6ea27377bdac1da9b",
    "public.zella_billing_card_checked(uuid,text)": "108b36e936fec7fc8b3386d9d576d87b",
    "public.zella_owner_pack_buy(uuid,text,text,text,uuid)": "5a201f7e71a40a07ffbb3eb6bb6a9d58",
    "public.zella_billing_checkout_addon_codes(uuid)": "d0ec4062ffbf554269af24efc6e08841",
    "public.zella_billing_checkout_addon_lines(uuid,boolean)": "ddae63c27e07df49902c33ef00a1d0c1",
    "public.zella_billing_checkout_addon_price(uuid,text)": "e502357e2cc991ad5424017a3abb6def",
    "public.zella_stripe_after_addon_price(billing_outbox)": "b58ddbb056bdda68c4e2d3abc22a189f",
    "public.zella_stripe_failed_addon_price(billing_outbox)": "2485145a3aaee43c7f0c993a5e55365e",
    "public.zella_billing_checkout_addons_bind(billing_checkouts,jsonb)": "4a92accd70e9463aac14bbb16c57f4a3",
    "public.zella_billing_checkout_addons_grant(billing_checkouts,billing_periods)": "c66d31d7939007d7cf37bcce11241b60",
    "public.zella_owner_billing_checkout_start(uuid,text,text[],boolean,text)": "3aec168c1c74e4fd559ad017317652ae",
    "public.zella_billing_invoice_attempts_clear(uuid,text,timestamp with time zone)": "403d3484ce63b1a0a3dd0ca388c5e209",
    "public.zella_billing_invoice_agreement(uuid)": "6a219fd47ec98c075a09226b4f33124f",
    "public.zella_billing_checkout_addon_amounts(uuid)": "be504ed6c4921b2136e334ec60618e5b",
    "public.zella_stripe_on_customer_updated(billing_events,jsonb)": "787f60b347bef56d98b4c40e99748295"
  }';
begin
  for s in select jsonb_object_keys(made) loop
    if md5(pg_get_functiondef(to_regprocedure(s))) <> made ->> s then raise exception 'VERSION_MISMATCH: % differs from this file''s version', s; end if;
  end loop;
end $$;

commit;
