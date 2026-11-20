-- Zella Voice: billing emails, queued and held (docs/PAYMENTS_ARCHITECTURE.md §6.11, docs/BILLING_EMAILS.md), built
-- switched off. Nothing is ever sent from here: the billing worker renders each email with the existing catalogue
-- (_shared/businessEmails.js, strict: a missing fact stops that email) and puts it in the existing platform outbox
-- (zella_queue_platform_email), which stays in test mode while email_live is off.
--   - billing_email_intents: one row per notice, key email:<code>:<business object>:<occurrence> (never a Stripe event
--     id), so a repeated or doubled event can never queue a second copy.
--   - From Stripe (triggers on our own records, which only verified events change): A1 first payment received,
--     C1 invoice issued, C3 paid, C4 invoice cancelled, D1 payment failed, D2 confirm with the bank, D5 service paused,
--     D6 payment recovered, A2 trial started, F3 pack bought.
--   - Without Stripe (zella_billing_email_sweep, run by the worker): B1 plan renews in 3 days (also 7 days for yearly
--     plans), A3 trial ends in 3 days.
--   - To whom: the business's active owners (the billing contact list is not built yet).
-- Rollback: sql/rollback/zella_stripe_emails_rollback.sql. Tests: tests/stripe_emails/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_usd_text(bigint)": "fcb6c7625eb245c5908a6345fac9aa6f",
    "public.zella_billing_email(uuid,text,text,text,jsonb)": "56d6fd452ad77eb83c5548f9cdeea526",
    "public.zella_billing_email_common(uuid)": "b6f8560d7cf2999a3379d966dceb7a02",
    "public.zella_billing_email_invoice_trg()": "cc75a8987f19e2ae96c066395b79af45",
    "public.zella_billing_email_subscription_trg()": "6129b20726a9fa4e7a24940582a5943b",
    "public.zella_billing_email_pack_trg()": "160bccec10e7dd48cdd6997409cb7f38",
    "public.zella_billing_email_sweep()": "262f5799f88c3da0aa51004a712431ae",
    "public.zella_billing_email_claim(integer)": "00fe89f6414d3f17fe4bdf9e0e901e14",
    "public.zella_billing_email_done(uuid,text,text)": "708c2cd8521deaba5ab51319ee942cd1"
  }';
begin
  if to_regprocedure('public.zella_admin_disputes(integer)') is null or to_regprocedure('public.zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[])') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_disputes.sql and zella_platform_emails.sql';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create table if not exists public.billing_email_intents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  code text not null check (code ~ '^[A-I][0-9]{1,2}$'),
  dedupe_key text not null unique check (dedupe_key ~ '^email:[A-I][0-9]{1,2}:'),
  data jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'claimed', 'queued', 'held')),
  error text,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  queued_at timestamptz
);
create index if not exists billing_email_intents_due_idx on public.billing_email_intents (created_at) where status in ('pending', 'claimed');
alter table public.billing_email_intents enable row level security;
revoke all on public.billing_email_intents from anon, authenticated;
grant select, insert, update on public.billing_email_intents to service_role;

-- Integer cents to the words in an email ("$1,234.50"); integer arithmetic only.
create or replace function public.zella_usd_text(p_cents bigint) returns text
language sql immutable set search_path = '' as $$
  select case when p_cents is null then null else (case when p_cents < 0 then '-' else '' end) || '$' ||
    to_char(abs(p_cents) / 100, 'FM999,999,999,990') || '.' || lpad((abs(p_cents) % 100)::text, 2, '0') end;
$$;

create or replace function public.zella_billing_email(p_business_id uuid, p_code text, p_object text, p_occurrence text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  insert into public.billing_email_intents (business_id, code, dedupe_key, data)
  values (p_business_id, p_code, 'email:' || p_code || ':' || p_object || ':' || coalesce(p_occurrence, '1'), public.zella_billing_email_common(p_business_id) || coalesce(p_data, '{}'::jsonb))
  on conflict (dedupe_key) do nothing returning id into v;
  return v;
end $$;

-- The facts every billing email may use: the business, the plan, the fallback number.
create or replace function public.zella_billing_email_common(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('business', b.name, 'plan', initcap(p.tier),
    'fallbackPhone', (select cfg.escalation_rules ->> 'fallback_number' from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id
                       where ag.business_id = b.id and ag.is_default limit 1)))
    from public.businesses b left join lateral (select * from public.business_plans x where x.business_id = b.id order by x.version desc limit 1) p on true
   where b.id = p_business_id;
$$;

create or replace function public.zella_billing_email_invoice_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  d := jsonb_strip_nulls(jsonb_build_object('invoice', new.number, 'total', public.zella_usd_text(new.total_minor), 'amount', public.zella_usd_text(coalesce(nullif(new.amount_paid_minor, 0), new.total_minor)),
         'period', case when new.period_start is not null then to_char(new.period_start at time zone 'UTC', 'FMDD Mon') || ' to ' || to_char(new.period_end at time zone 'UTC', 'FMDD Mon YYYY') end,
         'date', to_char(coalesce(new.paid_at, now()) at time zone 'UTC', 'FMDD Mon YYYY'),
         'lines', (select jsonb_agg(jsonb_build_array(coalesce(l ->> 'description', 'Plan'), public.zella_usd_text((l ->> 'amount')::bigint))) from jsonb_array_elements(new.lines) l)));
  if new.status = 'open' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform public.zella_billing_email(new.business_id, 'C1', new.stripe_invoice_id, '1', d);
  elsif new.status = 'paid' then
    perform public.zella_billing_email(new.business_id, case when new.kind = 'first' then 'A1' else 'C3' end, new.stripe_invoice_id, '1', d);
  elsif new.status = 'payment_failed' then
    perform public.zella_billing_email(new.business_id, 'D1', new.stripe_invoice_id, '1', d || jsonb_build_object('reason', 'Your bank declined the payment.'));
  elsif new.status = 'void' and tg_op = 'UPDATE' and old.status in ('open', 'payment_failed') then
    perform public.zella_billing_email(new.business_id, 'C4', new.stripe_invoice_id, '1', d);
  end if;
  return null;
end $$;
drop trigger if exists zella_billing_email_invoice on public.billing_invoices;
create trigger zella_billing_email_invoice after insert or update of status on public.billing_invoices for each row execute function public.zella_billing_email_invoice_trg();

create or replace function public.zella_billing_email_subscription_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.provider is distinct from 'stripe' or new.status is not distinct from old.status then return null; end if;
  if new.status = 'paused_nonpayment' then
    perform public.zella_billing_email(new.business_id, 'D5', new.id::text, to_char(coalesce(new.past_due_since, now()), 'YYYYMMDD'), '{}');
  elsif new.status = 'active' and old.status in ('past_due', 'paused_nonpayment', 'grace_period') then
    perform public.zella_billing_email(new.business_id, 'D6', new.id::text, to_char(coalesce(new.current_period_start, now()), 'YYYYMMDD'), '{}');
  elsif new.status = 'trial' and old.status = 'pending_payment' then
    perform public.zella_billing_email(new.business_id, 'A2', new.id::text, '1', jsonb_strip_nulls(jsonb_build_object('trialEnd', to_char(new.trial_end_at at time zone 'UTC', 'FMDD Mon YYYY'))));
  end if;
  return null;
end $$;
drop trigger if exists zella_billing_email_subscription on public.subscriptions;
create trigger zella_billing_email_subscription after update of status on public.subscriptions for each row execute function public.zella_billing_email_subscription_trg();

create or replace function public.zella_billing_email_pack_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'granted' and old.status = 'pending' then
    perform public.zella_billing_email(new.business_id, 'F3', new.id::text, '1', jsonb_build_object('packMinutes', new.quantity, 'packPrice', public.zella_usd_text(new.price_cents),
      'date', to_char(now() at time zone 'UTC', 'FMDD Mon YYYY')));
  end if;
  return null;
end $$;
drop trigger if exists zella_billing_email_pack on public.pack_purchases;
create trigger zella_billing_email_pack after update of status on public.pack_purchases for each row execute function public.zella_billing_email_pack_trg();

-- Notices that need no Stripe event: renewal coming (3 days, and 7 days for yearly plans), trial ending (3 days).
create or replace function public.zella_billing_email_sweep() returns integer
language plpgsql security definer set search_path = public as $$
declare s record; n int := 0; v_days int;
begin
  if not public.zella_payments_live() then return 0; end if;
  for s in select x.*, p.price_cents, p.billing_interval as plan_interval from public.subscriptions x
             left join lateral (select * from public.business_plans b where b.business_id = x.business_id order by b.version desc limit 1) p on true
            where x.provider = 'stripe' and x.status = 'active' and coalesce((x.metadata ->> 'cancel_at_period_end')::boolean, false) = false
              and x.current_period_end between now() and now() + interval '7 days 1 hour' loop
    foreach v_days in array case when s.plan_interval = 'yearly' then array[7, 3] else array[3] end loop
      if s.current_period_end <= now() + make_interval(days => v_days) then
        if public.zella_billing_email(s.business_id, 'B1', s.id::text || ':' || to_char(s.current_period_end, 'YYYYMMDD'), 'd' || v_days,
             jsonb_build_object('renewDate', to_char(s.current_period_end at time zone 'UTC', 'FMDD Mon YYYY'), 'amount', public.zella_usd_text(s.price_cents))) is not null then n := n + 1; end if;
      end if;
    end loop;
  end loop;
  for s in select x.*, p.price_cents from public.subscriptions x left join lateral (select * from public.business_plans b where b.business_id = x.business_id order by b.version desc limit 1) p on true
            where x.provider = 'stripe' and x.status = 'trial' and x.trial_end_at between now() and now() + interval '3 days' loop
    if public.zella_billing_email(s.business_id, 'A3', s.id::text, 'd3', jsonb_build_object('trialEnd', to_char(s.trial_end_at at time zone 'UTC', 'FMDD Mon YYYY'),
         'amount', public.zella_usd_text(s.price_cents))) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- The worker takes due notices with their recipients (the business's active owners), renders and queues them.
create or replace function public.zella_billing_email_claim(p_limit integer default 20)
returns table (id uuid, business_id uuid, code text, dedupe_key text, data jsonb, recipients jsonb)
language plpgsql security definer set search_path = public as $$
declare v_app text := nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), '');
begin
  return query
  with due as (select i.id from public.billing_email_intents i
                where i.status = 'pending' or (i.status = 'claimed' and i.claimed_at < now() - interval '10 minutes')
                order by i.created_at limit greatest(1, least(p_limit, 100)) for update skip locked)
  update public.billing_email_intents i set status = 'claimed', claimed_at = now() from due where i.id = due.id
  returning i.id, i.business_id, i.code, i.dedupe_key, i.data || jsonb_strip_nulls(jsonb_build_object('appUrl', v_app)),
    coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email, 'owner', coalesce(u.raw_user_meta_data ->> 'first_name', split_part(u.email, '@', 1))))
                from public.business_members m join auth.users u on u.id = m.user_id
               where m.business_id = i.business_id and m.role = 'owner' and m.status = 'active' and u.email is not null), '[]'::jsonb);
end $$;

create or replace function public.zella_billing_email_done(p_id uuid, p_status text, p_error text) returns void
language sql security definer set search_path = public as $$
  update public.billing_email_intents set status = case when p_status in ('queued', 'held') then p_status else 'pending' end, error = left(p_error, 300),
         queued_at = case when p_status = 'queued' then now() end where id = p_id and status = 'claimed';
$$;

do $$ declare f text; begin
  foreach f in array array['zella_billing_email(uuid,text,text,text,jsonb)', 'zella_billing_email_common(uuid)', 'zella_billing_email_invoice_trg()', 'zella_billing_email_subscription_trg()',
    'zella_billing_email_pack_trg()', 'zella_billing_email_sweep()', 'zella_billing_email_claim(integer)', 'zella_billing_email_done(uuid,text,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
grant execute on function public.zella_usd_text(bigint) to authenticated, service_role;

commit;
