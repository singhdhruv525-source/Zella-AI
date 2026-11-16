-- Zella Voice: the Stripe event pipeline, built switched off (docs/PAYMENTS_ARCHITECTURE.md §6.0a, §6.0b, §8, §17).
--
-- Closes gaps C-1 to C-8 of §17 for the rebuilt billing-webhook and the new billing-worker:
--   C-1 the webhook only stores the event (zella_stripe_event_store); the worker fetches the object from Stripe and
--       applies it (zella_stripe_apply_event), so a stale, replayed or reordered payload never grants.
--   C-2 every event of §16.5 is stored; each type has its own handler function, zella_stripe_on_<type>, added by later
--       migrations; invoice.paid grants by billing_reason through zella_stripe_grant_<reason>.
--   C-3 a subscription status alone grants nothing: subscription events record state only, never a period.
--   C-4 the binding check (zella_stripe_bind_invoice): mode, our own stored ids, customer, currency and amount.
--   C-5 an event that can't be bound is quarantined and answered 200, never 422.
--   C-6 plans come from business_plans versions and their Stripe Prices (the links table), never the old plans slug.
--   C-7 outbox (billing_outbox), money ledger (money_ledger, ledger_operation_keys), quarantine (billing_quarantine),
--       our id mapping (billing_stripe_links) and invoices (billing_invoices).
--   C-8 a refund made outside Zella Voice (the Stripe Dashboard) is recorded, audited and alerted.
-- Order: each event waits until every earlier event for the same subscription (or object) is applied; a subscription
--   never moves backwards (zella_subscription_transition_ok, and older events are recorded only).
-- Switch: platform_settings.payments_live = false. While it is false the worker claims nothing and sends nothing; the
--   webhook stays 503 while STRIPE_WEBHOOK_SECRET is unset. zella_payments_switch(on, worker url) is the owner's switch.
-- Unchanged: zella_process_billing_event, zella_apply_billing_event and zella_reconcile_billing_events (the live 15
--   minute job) keep their exact bodies; new rows use pipeline 'stripe_v2' and never take the 'pending' or 'failed'
--   statuses that job reads, so it behaves exactly as before.
-- Who: everything here is server only (service_role); no grants to anon or authenticated; row security on, no policies.
-- Rollback: sql/rollback/zella_stripe_pipeline_rollback.sql (refuses on drift, and while any of these tables or any
--   stripe_v2 event holds a row: nothing is deleted). Tests: tests/stripe_pipeline/run.sh.
begin;

do $$
declare s text; d text;
  owned constant jsonb := '{
    "public.zella_payments_live()": "17eb6407291d5642a4f8e0f5e4a4c305",
    "public.zella_payments_switch(boolean,text)": "9f216d93b1d883dcbb79ff4a81fefd61",
    "public.zella_billing_worker_check(text)": "48bd09e5f2fa8108e15e7c197ad723af",
    "public.zella_billing_worker_kick()": "e7410c05734f53363314985e75176e30",
    "public.zella_stripe_event_types()": "38437caf891689436cc57eb3a369ae38",
    "public.zella_stripe_event_store(jsonb,boolean)": "63264b976eb9fa90992694e84fb16631",
    "public.zella_stripe_claim_events(integer)": "01d396ae1920974e24130703268cede8",
    "public.zella_stripe_apply_event(uuid,jsonb,boolean)": "b1b286473be7231542a35ba155fa58eb",
    "public.zella_stripe_event_retry(uuid,text)": "5f985866e386f4e28efbac32b17715fc",
    "public.zella_stripe_quarantine(uuid,uuid,text,jsonb)": "fb95b9bbbc4c9f48e1221f27e66fb147",
    "public.zella_stripe_link_add(text,text,uuid,boolean,text,uuid,bigint)": "fce64f6b109108f226aa0a42ae52f04c",
    "public.zella_stripe_link(text,text)": "a2600ba62f55374f5634d828085a63e0",
    "public.zella_stripe_customer(uuid)": "3675b7c435f4636d15ec227bea769fb4",
    "public.zella_ledger_post(uuid,text,jsonb)": "c19b7255a08329f229c28f6ef08faf8e",
    "public.zella_subscription_transition_ok(text,text)": "ed6b9888e76e790efeaa5d67096a05ea",
    "public.zella_stripe_invoice_upsert(uuid,jsonb,text)": "5df9fab080ab0b92cc1d9a865ccb8a1c",
    "public.zella_stripe_bind_invoice(jsonb,boolean)": "12e6b5314c0346992ea2da3803c37bae",
    "public.zella_billing_outbox_add(uuid,text,text,text,text,jsonb,text,uuid)": "d581e27cd98d3202f30deefda9d552d6",
    "public.zella_billing_outbox_claim(integer,uuid)": "8b02344a6c040927385db541dcc7d900",
    "public.zella_billing_outbox_result(uuid,boolean,text,jsonb,text,boolean,boolean)": "86ed2ed7d697632e8fbf88a2d504a9e1",
    "public.zella_stripe_on_invoice_paid(billing_events,jsonb)": "1f484a4c9319fbb2595a3677b706b6f2",
    "public.zella_stripe_on_customer_subscription_created(billing_events,jsonb)": "e150fff5538a8f20cc7c4b4e816fcb97",
    "public.zella_stripe_on_customer_subscription_updated(billing_events,jsonb)": "c02680d28b2527875d15e3ec1d8f354a",
    "public.zella_stripe_on_customer_subscription_deleted(billing_events,jsonb)": "14e87317e9337577e67b33c7ac391332",
    "public.zella_stripe_on_charge_refunded(billing_events,jsonb)": "d413820b3034990a620248bb972dbd42"
  }';
begin
  if to_regclass('public.billing_events') is null or to_regclass('public.business_plans') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'billing_events' and column_name = 'args')
     or to_regprocedure('public.zella_reconcile_billing_events(integer)') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_billing_hardening.sql and zella_billing_allowances.sql';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then
      d := pg_get_functiondef(s::regprocedure);
      if md5(d) <> owned ->> s then raise exception 'VERSION_MISMATCH: % is not the version this file makes', s; end if;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------------------------
alter table public.billing_events add column if not exists pipeline text;
alter table public.billing_events add column if not exists livemode boolean;
alter table public.billing_events add column if not exists object_type text;
alter table public.billing_events add column if not exists object_id text;
alter table public.billing_events add column if not exists ordering_key text;
alter table public.billing_events add column if not exists payload jsonb;
create index if not exists billing_events_v2_due_idx on public.billing_events (ordering_key, event_created_at, received_at)
  where pipeline = 'stripe_v2' and status = 'received';

-- Our own mapping from Stripe ids to businesses, written only when WE create (or first learn from our own object) a
-- Stripe object. The binding check reads only this, never Stripe metadata or the browser.
create table if not exists public.billing_stripe_links (
  stripe_id text primary key check (stripe_id ~ '^[A-Za-z0-9_]{3,255}$'),
  kind text not null check (kind in ('customer', 'product', 'price', 'checkout_session', 'subscription', 'invoice',
                                     'payment_intent', 'refund', 'dispute', 'invoice_item', 'schedule')),
  business_id uuid not null references public.businesses(id) on delete restrict,
  livemode boolean not null,
  local_kind text,
  local_id uuid,
  expected_amount_minor bigint check (expected_amount_minor >= 0),
  created_at timestamptz not null default now()
);
create unique index if not exists billing_stripe_links_customer_uidx on public.billing_stripe_links (business_id, livemode) where kind = 'customer';
create index if not exists billing_stripe_links_business_idx on public.billing_stripe_links (business_id, kind);
create index if not exists billing_stripe_links_local_idx on public.billing_stripe_links (local_id) where local_id is not null;

-- Commands to Stripe (§8 outbox): the exact body and key are stored before the first send.
create table if not exists public.billing_outbox (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  kind text not null check (kind ~ '^[a-z_]{3,40}$'),
  idempotency_key text not null unique check (idempotency_key ~ '^[\x21-\x7e]{1,255}$'),
  method text not null check (method in ('POST', 'DELETE')),
  path text not null check (path ~ '^/v1/[A-Za-z0-9_/]+$'),
  body jsonb not null default '{}'::jsonb check (jsonb_typeof(body) = 'object'),
  local_kind text,
  local_id uuid,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'retry_wait', 'held', 'cancelled')),
  attempts integer not null default 0,
  lease_until timestamptz,
  next_attempt_at timestamptz not null default now(),
  stripe_id text,
  response jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists billing_outbox_due_idx on public.billing_outbox (next_attempt_at) where status in ('pending', 'retry_wait', 'sending');
create index if not exists billing_outbox_business_idx on public.billing_outbox (business_id, created_at desc);

create table if not exists public.billing_quarantine (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references public.billing_events(id) on delete restrict,
  business_id uuid references public.businesses(id) on delete restrict,
  reason text not null check (length(reason) between 3 and 80),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid,
  resolution text
);
create index if not exists billing_quarantine_open_idx on public.billing_quarantine (created_at desc) where resolved_at is null;
create unique index if not exists billing_quarantine_event_uidx on public.billing_quarantine (event_id) where event_id is not null;

-- Every Stripe invoice we hear about, from the fetched object (never the payload). Filled by the invoice events.
create table if not exists public.billing_invoices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  stripe_invoice_id text not null unique,
  stripe_subscription_id text,
  kind text not null default 'other' check (kind in ('first', 'renewal', 'upgrade', 'final', 'manual', 'other')),
  status text not null check (status in ('draft', 'open', 'paid', 'payment_failed', 'void', 'uncollectible', 'deleted')),
  billing_reason text,
  number text,
  currency text not null default 'usd' check (currency = 'usd'),
  total_minor bigint not null default 0,
  amount_due_minor bigint not null default 0,
  amount_paid_minor bigint not null default 0 check (amount_paid_minor >= 0),
  period_start timestamptz,
  period_end timestamptz,
  hosted_invoice_url text,
  invoice_pdf text,
  payment_intent text,
  lines jsonb not null default '[]'::jsonb,
  livemode boolean not null,
  stripe_created_at timestamptz,
  finalized_at timestamptz,
  paid_at timestamptz,
  voided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists billing_invoices_business_idx on public.billing_invoices (business_id, created_at desc);

-- Double entry money ledger (§4): each operation posts lines that sum to zero, once (ledger_operation_keys).
create table if not exists public.ledger_operation_keys (
  operation_key text primary key check (length(operation_key) between 3 and 255),
  business_id uuid references public.businesses(id) on delete restrict,
  created_at timestamptz not null default now()
);
create table if not exists public.money_ledger (
  id bigint generated always as identity primary key,
  business_id uuid references public.businesses(id) on delete restrict,
  operation_key text not null references public.ledger_operation_keys(operation_key) on delete restrict,
  account text not null check (account in ('cash', 'receivable', 'revenue', 'refunds', 'disputes', 'credits', 'fees')),
  amount_minor bigint not null,
  currency text not null default 'usd' check (currency = 'usd'),
  created_at timestamptz not null default now()
);
create index if not exists money_ledger_business_idx on public.money_ledger (business_id, created_at);

do $$ declare t text; begin
  foreach t in array array['billing_stripe_links', 'billing_outbox', 'billing_quarantine', 'billing_invoices', 'ledger_operation_keys', 'money_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update on public.%I to service_role', t);
  end loop;
end $$;

insert into public.platform_settings (key, value) values ('payments_live', 'false'::jsonb), ('billing_worker_url', '""'::jsonb)
on conflict (key) do nothing;
insert into vault.secrets (name, secret, description)
select 'zella_billing_worker_secret', encode(extensions.gen_random_bytes(32), 'hex'), 'Zella Voice billing worker: the cron job sends it, the worker checks it'
 where not exists (select 1 from vault.secrets where name = 'zella_billing_worker_secret');

-- ---------------------------------------------------------------------------------------------------------------
-- The switch and the worker's schedule
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_payments_live() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'payments_live'), false);
$$;

-- The owner's switch (run in the SQL editor with approval). Turning on needs the worker's https address.
create or replace function public.zella_payments_switch(p_on boolean, p_worker_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job bigint;
begin
  if p_on and (p_worker_url is null or p_worker_url !~ '^https://[A-Za-z0-9.-]+/functions/v1/billing-worker$') then raise exception 'WORKER_URL_REQUIRED'; end if;
  update public.platform_settings set value = to_jsonb(p_on), updated_at = now() where key = 'payments_live';
  if p_on then update public.platform_settings set value = to_jsonb(p_worker_url), updated_at = now() where key = 'billing_worker_url'; end if;
  select jobid into v_job from cron.job where jobname = 'zella_billing_worker';
  if v_job is not null and to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null then perform cron.alter_job(job_id := v_job, active := p_on);
  elsif v_job is not null then update cron.job set active = p_on where jobid = v_job; end if;
  insert into public.audit_logs (action, entity_type, new_data) values ('billing.payments_switch', 'platform_setting', jsonb_build_object('payments_live', p_on));
  return jsonb_build_object('payments_live', p_on, 'job', v_job is not null);
end $$;

create or replace function public.zella_billing_worker_check(p_secret text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'zella_billing_worker_secret' limit 1;
  return v is not null and length(v) >= 32 and p_secret is not null and p_secret = v;
end $$;

create or replace function public.zella_billing_worker_kick() returns text
language plpgsql security definer set search_path = public as $$
declare v_url text := nullif(trim(public.zella_setting('billing_worker_url', '""'::jsonb) #>> '{}'), ''); v_secret text;
begin
  if not public.zella_payments_live() then return 'off'; end if;
  if v_url is null or v_url !~ '^https://' then return 'not_set_up'; end if;
  if not exists (select 1 from public.billing_outbox where status in ('pending', 'retry_wait', 'sending') and next_attempt_at <= now())
     and not exists (select 1 from public.billing_events where pipeline = 'stripe_v2' and status = 'received' and next_attempt_at <= now()) then
    return 'nothing_due';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_billing_worker_secret' limit 1;
  perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'X-Zella-Secret', v_secret),
                        body := '{}'::jsonb, timeout_milliseconds := 25000);
  return 'called';
end $$;

-- created switched OFF; zella_payments_switch turns it on (cron.alter_job, or the direct update on an older pg_cron)
do $$ declare v_id bigint; begin
  if to_regnamespace('cron') is not null and not exists (select 1 from cron.job where jobname = 'zella_billing_worker') then
    v_id := cron.schedule('zella_billing_worker', '* * * * *', 'select public.zella_billing_worker_kick()');
    if to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null then perform cron.alter_job(job_id := v_id, active := false);
    else update cron.job set active = false where jobid = v_id; end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Inbox: store once (webhook), claim in order (worker), apply the fetched object (worker)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_stripe_event_types() returns text[]
language sql immutable set search_path = '' as $$
  select array['checkout.session.completed', 'checkout.session.expired',
    'customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted', 'customer.subscription.trial_will_end',
    'invoice.created', 'invoice.finalized', 'invoice.paid', 'invoice.payment_failed', 'invoice.payment_action_required', 'invoice.voided', 'invoice.deleted',
    'payment_intent.succeeded', 'payment_intent.payment_failed', 'payment_intent.requires_action',
    'refund.created', 'refund.updated', 'refund.failed', 'charge.refunded',
    'charge.dispute.created', 'charge.dispute.updated', 'charge.dispute.closed', 'charge.dispute.funds_withdrawn', 'charge.dispute.funds_reinstated'];
$$;

-- The webhook's only call. Returns stored | duplicate | ignored | mode_mismatch | bad_event. Stores a few ids only,
-- never the whole payload (§9 data minimisation); the worker fetches the object from Stripe before acting.
create or replace function public.zella_stripe_event_store(p_event jsonb, p_key_livemode boolean) returns text
language plpgsql security definer set search_path = public as $$
declare o jsonb := p_event #> '{data,object}'; v_type text := p_event ->> 'type'; v_obj text; v_sub text; v_id uuid;
begin
  if jsonb_typeof(p_event) <> 'object' or coalesce(p_event ->> 'id', '') !~ '^evt_[A-Za-z0-9_]{1,200}$' or v_type is null
     or jsonb_typeof(o) <> 'object' or coalesce(o ->> 'id', '') !~ '^[A-Za-z0-9_]{3,255}$' then
    return 'bad_event';
  end if;
  if p_key_livemode is null or jsonb_typeof(p_event -> 'livemode') <> 'boolean' or (p_event ->> 'livemode')::boolean <> p_key_livemode then
    return 'mode_mismatch';   -- a sandbox event can never reach live, nor the reverse
  end if;
  if not (v_type = any (public.zella_stripe_event_types())) then return 'ignored'; end if;
  v_obj := o ->> 'id';
  v_sub := case when o ->> 'object' = 'subscription' then v_obj
                else coalesce(o #>> '{parent,subscription_details,subscription}', o ->> 'subscription') end;
  insert into public.billing_events (provider, external_event_id, type, status, pipeline, livemode, object_type, object_id, ordering_key,
                                     event_created_at, data, payload, next_attempt_at)
  values ('stripe', p_event ->> 'id', left(v_type, 60), 'received', 'stripe_v2', p_key_livemode, left(o ->> 'object', 40), v_obj,
          coalesce(v_sub, v_obj), to_timestamp((p_event ->> 'created')::double precision), '{}'::jsonb,
          jsonb_strip_nulls(jsonb_build_object('status', o ->> 'status', 'customer', o ->> 'customer', 'subscription', v_sub,
                                               'billing_reason', o ->> 'billing_reason')), now())
  on conflict (provider, external_event_id) do nothing returning id into v_id;
  return case when v_id is null then 'duplicate' else 'stored' end;
end $$;

-- The worker claims the oldest stored event of each subscription or object, so events are applied in order. An
-- older event that is waiting for its parent (WAITING) doesn't hold the others back: the parent is often among them
-- (checkout.session.completed links the subscription its invoice.paid needs).
create or replace function public.zella_stripe_claim_events(p_limit integer default 20)
returns table (id uuid, type text, object_type text, object_id text, livemode boolean, payload jsonb)
language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_payments_live() then return; end if;
  return query
  with due as (
    select e.id from public.billing_events e
     where e.pipeline = 'stripe_v2' and e.status = 'received' and e.next_attempt_at <= now()
       and not exists (select 1 from public.billing_events o
                        where o.pipeline = 'stripe_v2' and o.status = 'received' and o.ordering_key = e.ordering_key and o.id <> e.id
                          and coalesce(o.error, '') not like 'WAITING:%'
                          and (o.event_created_at, o.received_at) < (e.event_created_at, e.received_at))
     order by e.event_created_at, e.received_at limit greatest(1, least(p_limit, 100)) for update skip locked)
  update public.billing_events e set next_attempt_at = now() + interval '2 minutes', attempts = e.attempts + 1
    from due where e.id = due.id
  returning e.id, e.type, e.object_type, e.object_id, e.livemode, e.payload;
end $$;

-- Waiting or failing: kept as 'received' with a back-off (never 'pending'/'failed', which the old job reads).
create or replace function public.zella_stripe_event_retry(p_event_id uuid, p_error text) returns text
language plpgsql security definer set search_path = public as $$
declare e public.billing_events;
begin
  select * into e from public.billing_events where id = p_event_id and pipeline = 'stripe_v2' for update;
  if e.id is null or e.status <> 'received' then return 'not_waiting'; end if;
  if e.received_at < now() - interval '7 days' then
    perform public.zella_stripe_quarantine(e.id, e.business_id, 'unresolved_after_7_days', jsonb_build_object('last_error', left(p_error, 200)));
    return 'quarantined';
  end if;
  update public.billing_events set error = left(p_error, 300),
         next_attempt_at = now() + least(interval '6 hours', interval '1 minute' * power(2, least(attempts, 9))) where id = e.id;
  if e.attempts >= 5 and coalesce(p_error, '') not like 'WAITING:%' then
    perform public.zella_platform_alert('billing_event_failed', 'A Stripe event keeps failing', left(p_error, 200), 'urgent', e.business_id, 'stripe_event:' || e.id);
  end if;
  return 'retry';
end $$;

create or replace function public.zella_stripe_quarantine(p_event_id uuid, p_business_id uuid, p_reason text, p_detail jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.billing_quarantine (event_id, business_id, reason, detail) values (p_event_id, p_business_id, left(p_reason, 80), coalesce(p_detail, '{}'::jsonb))
  on conflict (event_id) where event_id is not null do update set detail = billing_quarantine.detail || excluded.detail returning id into v_id;
  if p_event_id is not null then
    update public.billing_events set status = 'ignored', processed_at = now(), error = left('quarantined: ' || p_reason, 300), business_id = coalesce(p_business_id, business_id)
     where id = p_event_id;
  end if;
  perform public.zella_platform_alert('billing_quarantine', 'A payment event was held for a person to check', p_reason, 'urgent', p_business_id, 'billing_quarantine:' || v_id);
  return v_id;
end $$;

-- Applies one claimed event to the object the worker fetched from Stripe with our key. Returns applied | ignored |
-- older | waiting | quarantined | retry | duplicate. A handler raises 'BINDING: ...' (quarantine, nothing kept) or
-- 'WAITING: ...' (its parent isn't known yet; kept and tried again), and is rolled back either way.
create or replace function public.zella_stripe_apply_event(p_event_id uuid, p_object jsonb, p_key_livemode boolean) returns text
language plpgsql security definer set search_path = public as $$
declare e public.billing_events; v_fn text; v_res text; v_err text;
begin
  select * into e from public.billing_events where id = p_event_id and pipeline = 'stripe_v2' for update;
  if e.id is null then return 'ignored'; end if;
  if e.status <> 'received' then return 'duplicate'; end if;
  if not public.zella_payments_live() then return 'retry'; end if;
  if p_object is null or p_object ->> 'id' is distinct from e.object_id or jsonb_typeof(p_object -> 'livemode') <> 'boolean'
     or (p_object ->> 'livemode')::boolean <> e.livemode or e.livemode <> p_key_livemode then
    perform public.zella_stripe_quarantine(e.id, null, 'object_or_mode_mismatch', jsonb_build_object('type', e.type));
    return 'quarantined';
  end if;
  v_fn := 'zella_stripe_on_' || replace(e.type, '.', '_');
  if to_regprocedure(format('public.%I(public.billing_events,jsonb)', v_fn)) is null then
    update public.billing_events set status = 'ignored', processed_at = now(), error = 'no_handler' where id = e.id;
    return 'ignored';
  end if;
  begin
    execute format('select public.%I($1, $2)', v_fn) into v_res using e, p_object;
  exception when others then
    v_err := sqlerrm;
    if v_err like 'BINDING:%' then
      perform public.zella_stripe_quarantine(e.id, null, trim(substr(v_err, 9)), jsonb_build_object('type', e.type, 'object', e.object_id));
      return 'quarantined';
    end if;
    perform public.zella_stripe_event_retry(e.id, v_err);
    return case when v_err like 'WAITING:%' then 'waiting' else 'retry' end;
  end;
  update public.billing_events set status = case when v_res in ('applied', 'older') then 'processed' else 'ignored' end,
         processed_at = now(), error = case when v_res = 'applied' then null else v_res end where id = e.id;
  return v_res;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Links, ledger, state rules
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_stripe_link_add(p_stripe_id text, p_kind text, p_business_id uuid, p_livemode boolean,
  p_local_kind text default null, p_local_id uuid default null, p_expected_amount_minor bigint default null) returns public.billing_stripe_links
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links;
begin
  insert into public.billing_stripe_links (stripe_id, kind, business_id, livemode, local_kind, local_id, expected_amount_minor)
  values (p_stripe_id, p_kind, p_business_id, p_livemode, p_local_kind, p_local_id, p_expected_amount_minor)
  on conflict (stripe_id) do nothing;
  select * into l from public.billing_stripe_links where stripe_id = p_stripe_id;
  if l.business_id <> p_business_id or l.kind <> p_kind or l.livemode <> p_livemode then raise exception 'BINDING: stripe id already belongs elsewhere'; end if;
  return l;
end $$;

create or replace function public.zella_stripe_link(p_stripe_id text, p_kind text) returns public.billing_stripe_links
language sql stable security definer set search_path = public as $$
  select * from public.billing_stripe_links where stripe_id = p_stripe_id and kind = p_kind;
$$;

create or replace function public.zella_stripe_customer(p_business_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select stripe_id from public.billing_stripe_links where business_id = p_business_id and kind = 'customer' order by created_at limit 1;
$$;

-- Posts balancing lines once per operation key. Returns false when the operation was already posted.
create or replace function public.zella_ledger_post(p_business_id uuid, p_key text, p_lines jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare l jsonb; v_sum bigint := 0;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then raise exception 'LEDGER_LINES'; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    if jsonb_typeof(l -> 'amount') <> 'number' or (l ->> 'amount') !~ '^-?\d+$' then raise exception 'LEDGER_NOT_INTEGER'; end if;
    v_sum := v_sum + (l ->> 'amount')::bigint;
  end loop;
  if v_sum <> 0 then raise exception 'LEDGER_UNBALANCED'; end if;
  insert into public.ledger_operation_keys (operation_key, business_id) values (p_key, p_business_id) on conflict do nothing;
  if not found then return false; end if;
  insert into public.money_ledger (business_id, operation_key, account, amount_minor)
  select p_business_id, p_key, x ->> 'account', (x ->> 'amount')::bigint from jsonb_array_elements(p_lines) x;
  return true;
end $$;

-- The allowed moves (§7). Anything else is recorded and ignored, so an older event never moves a subscription back.
create or replace function public.zella_subscription_transition_ok(p_from text, p_to text) returns boolean
language sql immutable set search_path = '' as $$
  select p_from = p_to or (p_from, p_to) in (
    ('pending_payment', 'trial'), ('pending_payment', 'active'), ('trial', 'active'), ('trial', 'cancelled'), ('trial', 'past_due'),
    ('active', 'past_due'), ('renewal_due', 'past_due'), ('renewal_due', 'active'), ('past_due', 'active'), ('past_due', 'paused_nonpayment'),
    ('grace_period', 'active'), ('grace_period', 'paused_nonpayment'), ('paused_nonpayment', 'active'), ('paused_nonpayment', 'cancelled'),
    ('active', 'cancelled'), ('past_due', 'cancelled'), ('grace_period', 'cancelled'),
    ('active', 'suspended_dispute'), ('past_due', 'suspended_dispute'), ('paused_nonpayment', 'suspended_dispute'), ('trial', 'suspended_dispute'),
    ('suspended_dispute', 'cancelled'));
$$;

alter table public.subscriptions drop constraint if exists subscriptions_status_check;
alter table public.subscriptions add constraint subscriptions_status_check check (status in ('trial', 'active', 'renewal_due', 'past_due',
  'grace_period', 'cancelled', 'expired', 'pending_payment', 'paused_nonpayment', 'suspended_dispute'));

-- Records the fetched invoice (never the payload). Status moves forward only.
create or replace function public.zella_stripe_invoice_upsert(p_business_id uuid, p_inv jsonb, p_kind text default null) returns public.billing_invoices
language plpgsql security definer set search_path = public as $$
declare r public.billing_invoices; v_status text := case p_inv ->> 'status' when 'open' then 'open' when 'paid' then 'paid' when 'void' then 'void'
                                                       when 'uncollectible' then 'uncollectible' when 'draft' then 'draft' else 'open' end;
  v_rank constant jsonb := '{"draft":0,"open":1,"payment_failed":2,"uncollectible":2,"paid":3,"void":3,"deleted":3}';
  v_ts timestamptz := to_timestamp(nullif(p_inv ->> 'created', '')::double precision);
begin
  insert into public.billing_invoices (business_id, stripe_invoice_id, stripe_subscription_id, kind, status, billing_reason, number, total_minor, amount_due_minor,
    amount_paid_minor, period_start, period_end, hosted_invoice_url, invoice_pdf, lines, livemode, stripe_created_at)
  values (p_business_id, p_inv ->> 'id', coalesce(p_inv #>> '{parent,subscription_details,subscription}', p_inv ->> 'subscription'),
    coalesce(p_kind, case p_inv ->> 'billing_reason' when 'subscription_create' then 'first' when 'subscription_cycle' then 'renewal'
                                                     when 'subscription_update' then 'upgrade' when 'manual' then 'manual' else 'other' end),
    v_status, p_inv ->> 'billing_reason', p_inv ->> 'number', coalesce((p_inv ->> 'total')::bigint, 0), coalesce((p_inv ->> 'amount_due')::bigint, 0),
    coalesce((p_inv ->> 'amount_paid')::bigint, 0), to_timestamp(nullif(p_inv ->> 'period_start', '')::double precision),
    to_timestamp(nullif(p_inv ->> 'period_end', '')::double precision), p_inv ->> 'hosted_invoice_url', p_inv ->> 'invoice_pdf',
    coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('amount', (l ->> 'amount')::bigint, 'description', left(l ->> 'description', 200),
              'price', coalesce(l #>> '{pricing,price_details,price}', l #>> '{price,id}'), 'kind', l #>> '{metadata,kind}'))) from jsonb_array_elements(p_inv #> '{lines,data}') l), '[]'::jsonb),
    (p_inv ->> 'livemode')::boolean, v_ts)
  on conflict (stripe_invoice_id) do nothing;
  select * into r from public.billing_invoices where stripe_invoice_id = p_inv ->> 'id' for update;
  if r.business_id <> p_business_id then raise exception 'BINDING: invoice belongs to another business'; end if;
  if (v_rank ->> v_status)::int >= (v_rank ->> r.status)::int then
    update public.billing_invoices set status = v_status, number = coalesce(p_inv ->> 'number', number), total_minor = coalesce((p_inv ->> 'total')::bigint, total_minor),
           amount_due_minor = coalesce((p_inv ->> 'amount_due')::bigint, amount_due_minor), amount_paid_minor = coalesce((p_inv ->> 'amount_paid')::bigint, amount_paid_minor),
           hosted_invoice_url = coalesce(p_inv ->> 'hosted_invoice_url', hosted_invoice_url), invoice_pdf = coalesce(p_inv ->> 'invoice_pdf', invoice_pdf),
           lines = case when v_status = 'draft' or r.status = 'draft' then coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('amount', (l ->> 'amount')::bigint,
              'description', left(l ->> 'description', 200), 'price', coalesce(l #>> '{pricing,price_details,price}', l #>> '{price,id}'), 'kind', l #>> '{metadata,kind}')))
              from jsonb_array_elements(p_inv #> '{lines,data}') l), lines) else lines end,
           finalized_at = case when v_status <> 'draft' then coalesce(finalized_at, now()) end,
           paid_at = case when v_status = 'paid' then coalesce(paid_at, now()) end, voided_at = case when v_status = 'void' then coalesce(voided_at, now()) end,
           updated_at = now()
     where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- The binding check for an invoice (§6.0a), on the object fetched with our key. Returns the business and our link,
-- or raises BINDING (quarantine). Business comes only from our own links: the subscription we linked at checkout, or
-- an invoice we created ourselves; the customer must be that business's customer.
create or replace function public.zella_stripe_bind_invoice(p_inv jsonb, p_require_paid boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sub text := coalesce(p_inv #>> '{parent,subscription_details,subscription}', p_inv ->> 'subscription');
  l public.billing_stripe_links; c text;
begin
  if p_inv ->> 'object' is distinct from 'invoice' then raise exception 'BINDING: not an invoice'; end if;
  if lower(coalesce(p_inv ->> 'currency', '')) <> 'usd' then raise exception 'BINDING: currency is not usd'; end if;
  if p_require_paid and (p_inv ->> 'status' is distinct from 'paid' or (p_inv ->> 'amount_paid')::bigint is distinct from (p_inv ->> 'amount_due')::bigint) then
    raise exception 'BINDING: invoice is not fully paid';
  end if;
  select * into l from public.billing_stripe_links where stripe_id = p_inv ->> 'id' and kind = 'invoice';
  if l.stripe_id is null and v_sub is not null then
    select * into l from public.billing_stripe_links where stripe_id = v_sub and kind = 'subscription';
    if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', v_sub; end if;
  end if;
  if l.stripe_id is null then raise exception 'BINDING: invoice is not ours'; end if;
  if l.livemode <> (p_inv ->> 'livemode')::boolean then raise exception 'BINDING: mode differs from our link'; end if;
  select stripe_id into c from public.billing_stripe_links where business_id = l.business_id and kind = 'customer' and stripe_id = p_inv ->> 'customer';
  if c is null then raise exception 'BINDING: customer is not this business''s customer'; end if;
  return jsonb_build_object('business_id', l.business_id, 'link_kind', l.kind, 'link_id', l.stripe_id, 'local_kind', l.local_kind,
                            'local_id', l.local_id, 'expected_amount_minor', l.expected_amount_minor, 'subscription', v_sub);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Outbox (§8 sending protocol)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_billing_outbox_add(p_business_id uuid, p_kind text, p_key text, p_method text, p_path text, p_body jsonb,
  p_local_kind text default null, p_local_id uuid default null) returns public.billing_outbox
language plpgsql security definer set search_path = public as $$
declare r public.billing_outbox;
begin
  insert into public.billing_outbox (business_id, kind, idempotency_key, method, path, body, local_kind, local_id)
  values (p_business_id, p_kind, p_key, p_method, p_path, coalesce(p_body, '{}'::jsonb), p_local_kind, p_local_id)
  on conflict (idempotency_key) do nothing;
  select * into r from public.billing_outbox where idempotency_key = p_key;
  if r.business_id <> p_business_id or r.body <> coalesce(p_body, '{}'::jsonb) or r.path <> p_path then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return r;
end $$;

-- Claims rows to send. A row whose lease lapsed mid-send (the reply was lost) is sent again with the SAME body and
-- key while Stripe still remembers the key (within 23 hours), so Stripe returns the first result; later it is held.
create or replace function public.zella_billing_outbox_claim(p_limit integer default 10, p_id uuid default null) returns setof public.billing_outbox
language plpgsql security definer set search_path = public as $$
declare r public.billing_outbox;
begin
  if not public.zella_payments_live() then return; end if;
  for r in select * from public.billing_outbox o
            where (p_id is null or o.id = p_id) and o.next_attempt_at <= now()
              and (o.status in ('pending', 'retry_wait') or (o.status = 'sending' and o.lease_until < now()))
            order by o.created_at limit greatest(1, least(p_limit, 50)) for update skip locked loop
    if r.created_at < now() - interval '23 hours' and r.status = 'sending' then
      update public.billing_outbox set status = 'held', error = 'reply lost after Stripe''s idempotency window', updated_at = now() where id = r.id;
      perform public.zella_platform_alert('billing_outbox_held', 'A Stripe command needs a person to check it', r.kind, 'urgent', r.business_id, 'billing_outbox:' || r.id);
      continue;
    end if;
    update public.billing_outbox set status = 'sending', attempts = attempts + 1, lease_until = now() + interval '2 minutes', updated_at = now()
     where id = r.id returning * into r;
    return next r;
  end loop;
end $$;

-- Records the result of one send, then runs the kind's after-send step (zella_stripe_after_<kind>) if there is one.
create or replace function public.zella_billing_outbox_result(p_id uuid, p_ok boolean, p_stripe_id text, p_response jsonb, p_error text,
  p_retryable boolean default false, p_conflict boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare r public.billing_outbox; v_fn text;
begin
  select * into r from public.billing_outbox where id = p_id for update;
  if r.id is null or r.status <> 'sending' then return 'not_sending'; end if;
  if p_ok then
    update public.billing_outbox set status = 'sent', stripe_id = left(p_stripe_id, 255), response = p_response, error = null, lease_until = null, updated_at = now()
     where id = r.id returning * into r;
    v_fn := 'zella_stripe_after_' || r.kind;
    if to_regprocedure(format('public.%I(public.billing_outbox)', v_fn)) is not null then execute format('select public.%I($1)', v_fn) using r; end if;
    return 'sent';
  end if;
  if p_retryable and not p_conflict and r.attempts < 8 then
    update public.billing_outbox set status = 'retry_wait', error = left(p_error, 300), lease_until = null, updated_at = now(),
           next_attempt_at = now() + least(interval '1 hour', interval '30 seconds' * power(2, least(r.attempts, 7))) where id = r.id;
    return 'retry_wait';
  end if;
  update public.billing_outbox set status = 'held', error = left(p_error, 300), response = p_response, lease_until = null, updated_at = now() where id = r.id returning * into r;
  v_fn := 'zella_stripe_failed_' || r.kind;
  if to_regprocedure(format('public.%I(public.billing_outbox)', v_fn)) is not null then execute format('select public.%I($1)', v_fn) using r; end if;
  perform public.zella_platform_alert('billing_outbox_held', case when p_conflict then 'A Stripe command was refused as a repeat with other values' else 'A Stripe command was refused' end,
                                      r.kind || ': ' || left(p_error, 150), 'urgent', r.business_id, 'billing_outbox:' || r.id);
  return 'held';
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Handlers present from the start (later migrations add the rest, one function per event type or billing reason)
-- ---------------------------------------------------------------------------------------------------------------
-- invoice.paid: binding check, the invoice and payment recorded once, ledger postings, then the grant for its reason.
create or replace function public.zella_stripe_on_invoice_paid(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare b jsonb := public.zella_stripe_bind_invoice(o, true); v_biz uuid := (b ->> 'business_id')::uuid; inv public.billing_invoices;
  v_pi text; v_amount bigint := (o ->> 'amount_paid')::bigint; v_reason text := coalesce(o ->> 'billing_reason', 'none'); v_fn text; v_sub public.subscriptions;
begin
  v_fn := 'zella_stripe_grant_' || v_reason;
  if v_reason !~ '^[a-z_]{1,40}$' or to_regprocedure(format('public.%I(jsonb,jsonb)', v_fn)) is null then raise exception 'BINDING: billing reason % is not handled', v_reason; end if;
  inv := public.zella_stripe_invoice_upsert(v_biz, o, null);
  v_pi := coalesce(o ->> 'payment_intent', (select p #>> '{payment,payment_intent}' from jsonb_array_elements(o #> '{payments,data}') p where p ->> 'status' = 'paid' limit 1));
  update public.billing_invoices set payment_intent = coalesce(v_pi, payment_intent) where id = inv.id;
  select * into v_sub from public.subscriptions where business_id = v_biz;
  if v_amount > 0 then
    insert into public.payments (business_id, subscription_id, amount, amount_minor, currency, status, provider, external_payment_id, paid_at, metadata)
    values (v_biz, v_sub.id, public.zella_minor_to_amount(v_amount, 'usd'), v_amount, 'usd', 'succeeded', 'stripe', coalesce(v_pi, o ->> 'id'), now(),
            jsonb_build_object('stripe_invoice', o ->> 'id', 'billing_reason', v_reason, 'bound', true))
    on conflict (provider, external_payment_id) where external_payment_id is not null do update set status = 'succeeded', paid_at = coalesce(payments.paid_at, now()),
       amount_minor = excluded.amount_minor, amount = excluded.amount, metadata = payments.metadata || excluded.metadata, updated_at = now()
     where payments.status in ('pending', 'processing', 'failed');
    perform public.zella_ledger_post(v_biz, 'invoice:' || (o ->> 'id'), jsonb_build_array(jsonb_build_object('account', 'receivable', 'amount', v_amount), jsonb_build_object('account', 'revenue', 'amount', -v_amount)));
    perform public.zella_ledger_post(v_biz, 'payment:' || coalesce(v_pi, o ->> 'id'), jsonb_build_array(jsonb_build_object('account', 'cash', 'amount', v_amount), jsonb_build_object('account', 'receivable', 'amount', -v_amount)));
  end if;
  update public.billing_events set business_id = v_biz, subscription_id = v_sub.id where id = e.id;
  execute format('select public.%I($1, $2)', v_fn) using o, b || jsonb_build_object('invoice_row', inv.id, 'payment_intent', v_pi, 'event_created', e.event_created_at);
  return 'applied';
end $$;

-- Subscription events record state only (C-3): Stripe's status, cancel at period end and the trial end. A period or
-- balance is only ever opened by a bound paid invoice (or, for a trial, by the checkout grant).
create or replace function public.zella_stripe_on_customer_subscription_updated(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions; v_to text;
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null then raise exception 'WAITING: no local subscription'; end if;
  if s.billing_event_at is not null and e.event_created_at < s.billing_event_at then return 'older'; end if;
  update public.subscriptions set metadata = metadata || jsonb_strip_nulls(jsonb_build_object('stripe_status', o ->> 'status',
           'cancel_at_period_end', (o ->> 'cancel_at_period_end')::boolean, 'stripe_trial_end', o ->> 'trial_end')),
         billing_event_at = greatest(coalesce(billing_event_at, e.event_created_at), e.event_created_at), updated_at = now()
   where id = s.id;
  v_to := case o ->> 'status' when 'past_due' then 'past_due' when 'unpaid' then 'past_due' else null end;   -- active comes only from a paid invoice
  if v_to is not null and s.status <> v_to and public.zella_subscription_transition_ok(s.status, v_to) then
    update public.subscriptions set status = v_to, past_due_since = coalesce(past_due_since, now()) where id = s.id;
  end if;
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_customer_subscription_created(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$
  select public.zella_stripe_on_customer_subscription_updated(e, o);
$$;

create or replace function public.zella_stripe_on_customer_subscription_deleted(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription'); s public.subscriptions;
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  if o ->> 'status' is distinct from 'canceled' then raise exception 'BINDING: deleted event for a subscription that is not canceled'; end if;
  select * into s from public.subscriptions where business_id = l.business_id for update;
  if s.id is null then raise exception 'WAITING: no local subscription'; end if;
  if s.status <> 'cancelled' and public.zella_subscription_transition_ok(s.status, 'cancelled') then
    update public.subscriptions set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()), billing_event_at = greatest(coalesce(billing_event_at, e.event_created_at), e.event_created_at) where id = s.id;
    perform public.zella_notify_owners(l.business_id, 'subscription_cancelled', 'Your plan has ended', 'Your Zella Voice plan has ended. Contact support if this is a mistake.', 'warning', 'settings');
  end if;
  update public.billing_events set business_id = l.business_id, subscription_id = s.id where id = e.id;
  return 'applied';
end $$;

-- C-8: any refund on a payment of ours, made in Zella Voice or in the Stripe Dashboard, is recorded and audited; one
-- without an approved request in Zella Voice raises an urgent alert (REQ-BIL-45). The refunds flow adds the matching.
create or replace function public.zella_stripe_on_charge_refunded(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare p public.payments;
begin
  select * into p from public.payments where provider = 'stripe' and external_payment_id = o ->> 'payment_intent' for update;
  if p.id is null then raise exception 'WAITING: payment % not recorded yet', o ->> 'payment_intent'; end if;
  update public.payments set metadata = metadata || jsonb_build_object('refunded_minor', (o ->> 'amount_refunded')::bigint),
         status = case when (o ->> 'refunded')::boolean then 'refunded' else status end, updated_at = now() where id = p.id;
  insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
  values (p.business_id, 'billing.refund_seen', 'payment', p.id, jsonb_build_object('refunded_minor', (o ->> 'amount_refunded')::bigint, 'charge', o ->> 'id'));
  if to_regclass('public.billing_refunds') is null then
    perform public.zella_platform_alert('refund_outside_zella', 'A refund was made outside Zella Voice', 'Charge ' || (o ->> 'id'), 'urgent', p.business_id, 'refund_outside:' || (o ->> 'id'));
  end if;
  update public.billing_events set business_id = p.business_id where id = e.id;
  return 'applied';
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_payments_live()', 'zella_payments_switch(boolean,text)', 'zella_billing_worker_check(text)', 'zella_billing_worker_kick()',
    'zella_stripe_event_store(jsonb,boolean)', 'zella_stripe_claim_events(integer)', 'zella_stripe_apply_event(uuid,jsonb,boolean)', 'zella_stripe_event_retry(uuid,text)',
    'zella_stripe_quarantine(uuid,uuid,text,jsonb)', 'zella_stripe_link_add(text,text,uuid,boolean,text,uuid,bigint)', 'zella_stripe_link(text,text)', 'zella_stripe_customer(uuid)',
    'zella_ledger_post(uuid,text,jsonb)', 'zella_stripe_invoice_upsert(uuid,jsonb,text)', 'zella_stripe_bind_invoice(jsonb,boolean)',
    'zella_billing_outbox_add(uuid,text,text,text,text,jsonb,text,uuid)', 'zella_billing_outbox_claim(integer,uuid)',
    'zella_billing_outbox_result(uuid,boolean,text,jsonb,text,boolean,boolean)', 'zella_stripe_on_invoice_paid(billing_events,jsonb)',
    'zella_stripe_on_customer_subscription_created(billing_events,jsonb)', 'zella_stripe_on_customer_subscription_updated(billing_events,jsonb)',
    'zella_stripe_on_customer_subscription_deleted(billing_events,jsonb)', 'zella_stripe_on_charge_refunded(billing_events,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
