-- Money the team records (2026-11-04 industry work, batch 3).
--
-- Estimates, invoices, deposits, no-show fees and gift cards, and the payments, refunds and gift card redemptions
-- against them. This is a record of money handled elsewhere (cash, a card terminal, a bank transfer, a payment provider):
--   * Zella never takes or stores card details and never charges anyone. There is no automatic fee: a no-show fee is a
--     record someone on the team chose to make.
--   * Every payment says where it came from: 'manual' (typed by the team) or 'provider' (confirmed by a payment
--     provider, server code only, with the provider's reference). Estimates are proposals, not money owed.
--   * Amounts are whole minor units (cents) in the charge's currency; the currency's own decimals decide display
--     (zella_currency_exponent, from zella_billing_hardening.sql). No floating point.
--   * Who: staff and above record estimates, invoices, deposits, fees and gift cards; managers and above record
--     payments, redemptions and estimate decisions, and void; only owners and admins refund. View-only members and other
--     businesses see nothing. Links to customers, records and appointments must be this business's own.
--   * Every write is audited; a repeated request with the same key returns the first result instead of a duplicate.
-- Needs the "money" capability (zella_capabilities.sql). Safe to run twice. Needs the owner's approval before it is applied.

create table if not exists public.customer_charges (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null check (kind in ('estimate', 'invoice', 'deposit', 'no_show_fee', 'gift_card')),
  number text,
  description text,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 100000000000),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  status text not null check (status in ('proposed', 'accepted', 'declined', 'open', 'partially_paid', 'paid', 'refunded', 'void')),
  customer_id uuid references public.customers(id) on delete set null,
  record_id uuid references public.crm_records(id) on delete set null,
  appointment_id uuid references public.appointments(id) on delete set null,
  due_on date,
  idempotency_key text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists customer_charges_idem on public.customer_charges (business_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists customer_charges_number on public.customer_charges (business_id, kind, number) where number is not null;
create index if not exists customer_charges_business on public.customer_charges (business_id, status, created_at desc);
create index if not exists customer_charges_customer on public.customer_charges (customer_id) where customer_id is not null;
create index if not exists customer_charges_record on public.customer_charges (record_id) where record_id is not null;

create table if not exists public.customer_charge_payments (
  id uuid primary key default gen_random_uuid(),
  charge_id uuid not null references public.customer_charges(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null check (kind in ('payment', 'refund', 'redemption')),
  amount_minor bigint not null check (amount_minor > 0),
  method text not null check (method in ('cash', 'card_terminal', 'bank_transfer', 'check', 'gift_card', 'provider', 'other')),
  source text not null check (source in ('manual', 'provider')),
  provider_ref text,
  note text,
  idempotency_key text,
  recorded_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists customer_charge_payments_idem on public.customer_charge_payments (business_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists customer_charge_payments_provider on public.customer_charge_payments (business_id, provider_ref) where provider_ref is not null;
create index if not exists customer_charge_payments_charge on public.customer_charge_payments (charge_id);

alter table public.customer_charges enable row level security;
alter table public.customer_charge_payments enable row level security;
revoke all on public.customer_charges, public.customer_charge_payments from anon, authenticated;
grant select on public.customer_charges, public.customer_charge_payments to authenticated;
grant select, insert, update, delete on public.customer_charges, public.customer_charge_payments to service_role;
drop policy if exists customer_charges_read on public.customer_charges;
create policy customer_charges_read on public.customer_charges for select to authenticated using (public.zella_can_edit(business_id));
drop policy if exists customer_charge_payments_read on public.customer_charge_payments;
create policy customer_charge_payments_read on public.customer_charge_payments for select to authenticated using (public.zella_can_edit(business_id));
do $$ begin
  if exists (select 1 from pg_proc where proname = 'zella_mfa_satisfied') then
    if not exists (select 1 from pg_policies where tablename = 'customer_charges' and policyname = 'zella_mfa_required') then
      execute 'create policy zella_mfa_required on public.customer_charges as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
    end if;
    if not exists (select 1 from pg_policies where tablename = 'customer_charge_payments' and policyname = 'zella_mfa_required') then
      execute 'create policy zella_mfa_required on public.customer_charge_payments as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
    end if;
  end if;
end $$;

-- The business's currency: chosen in setup, or from its country.
create or replace function public.zella_business_currency(p_business_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(upper(nullif(b.setup_data #>> '{billing,currency}', '')), case upper(coalesce(b.country, 'US'))
    when 'AU' then 'AUD' when 'GB' then 'GBP' when 'UK' then 'GBP' when 'CA' then 'CAD' when 'NZ' then 'NZD' when 'IN' then 'INR'
    when 'IE' then 'EUR' when 'DE' then 'EUR' when 'FR' then 'EUR' when 'ES' then 'EUR' when 'IT' then 'EUR' when 'NL' then 'EUR'
    when 'SG' then 'SGD' when 'AE' then 'AED' when 'ZA' then 'ZAR' when 'JP' then 'JPY' else 'USD' end)
  from public.businesses b where b.id = p_business_id;
$$;

-- Balance and status from the payments (never typed).
create or replace function public.zella_charge_balance(p_charge_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_biz uuid; v_out jsonb;
begin
  select business_id into v_biz from public.customer_charges where id = p_charge_id;
  if v_biz is null or (auth.uid() is not null and not public.zella_can_edit(v_biz)) then raise exception 'NOT_ALLOWED'; end if;
  select jsonb_build_object(
    'amount_minor', c.amount_minor,
    'paid_minor', coalesce(sum(p.amount_minor) filter (where p.kind in ('payment', 'redemption')), 0),
    'refunded_minor', coalesce(sum(p.amount_minor) filter (where p.kind = 'refund'), 0),
    'balance_minor', c.amount_minor - coalesce(sum(p.amount_minor) filter (where p.kind in ('payment', 'redemption')), 0)
                     + coalesce(sum(p.amount_minor) filter (where p.kind = 'refund'), 0),
    'manual_minor', coalesce(sum(p.amount_minor) filter (where p.kind = 'payment' and p.source = 'manual'), 0),
    'provider_minor', coalesce(sum(p.amount_minor) filter (where p.kind = 'payment' and p.source = 'provider'), 0)) into v_out
  from public.customer_charges c left join public.customer_charge_payments p on p.charge_id = c.id
  where c.id = p_charge_id group by c.id, c.amount_minor;
  return v_out;
end $$;

create or replace function public.zella_charge_refresh_status(p_charge_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c record; b jsonb; v text;
begin
  select * into c from public.customer_charges where id = p_charge_id;
  if c.kind = 'estimate' or c.status = 'void' then return c.status; end if;
  b := public.zella_charge_balance(p_charge_id);
  v := case when (b ->> 'paid_minor')::bigint = 0 then 'open'
            when (b ->> 'refunded_minor')::bigint >= (b ->> 'paid_minor')::bigint then 'refunded'
            when (b ->> 'balance_minor')::bigint <= 0 then 'paid'
            else 'partially_paid' end;
  -- a gift card is "paid" when sold; redemptions use it up
  if c.kind = 'gift_card' and exists (select 1 from public.customer_charge_payments where charge_id = c.id and kind = 'payment') then
    v := case when (b ->> 'refunded_minor')::bigint > 0 and not exists (select 1 from public.customer_charge_payments where charge_id = c.id and kind = 'redemption') then 'refunded' else 'paid' end;
  end if;
  update public.customer_charges set status = v, updated_at = now() where id = p_charge_id and status is distinct from v;
  return v;
end $$;

create or replace function public.zella_create_charge(p_business_id uuid, p_kind text, p_amount_minor bigint, p_description text default null,
  p_customer_id uuid default null, p_record_id uuid default null, p_appointment_id uuid default null, p_due_on date default null,
  p_currency text default null, p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_cur text; v_num text;
begin
  if not public.zella_can_edit(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  perform public.zella_require_capability(p_business_id, 'money');
  if p_idempotency_key is not null then
    select id into v_id from public.customer_charges where business_id = p_business_id and idempotency_key = p_idempotency_key;
    if v_id is not null then return jsonb_build_object('id', v_id, 'repeat', true); end if;
  end if;
  if p_kind not in ('estimate', 'invoice', 'deposit', 'no_show_fee', 'gift_card') then raise exception 'NOT_VALID'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor > 100000000000 then raise exception 'BAD_AMOUNT'; end if;
  v_cur := upper(coalesce(nullif(trim(p_currency), ''), public.zella_business_currency(p_business_id)));
  if v_cur !~ '^[A-Z]{3}$' then raise exception 'BAD_CURRENCY'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_record_id is not null and not exists (select 1 from public.crm_records where id = p_record_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_appointment_id is not null and not exists (select 1 from public.appointments where id = p_appointment_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  -- per-business running number for each kind (E-1001, INV-1001 ...); the lock keeps numbers unique under concurrency
  perform pg_advisory_xact_lock(hashtext('zella_charge_number:' || p_business_id || ':' || p_kind));
  select case p_kind when 'estimate' then 'E-' when 'invoice' then 'INV-' when 'deposit' then 'D-' when 'no_show_fee' then 'F-' else 'GC-' end
         || (1000 + count(*) + 1) into v_num from public.customer_charges where business_id = p_business_id and kind = p_kind;
  insert into public.customer_charges (business_id, kind, number, description, amount_minor, currency, status, customer_id, record_id, appointment_id,
                                       due_on, idempotency_key, created_by)
  values (p_business_id, p_kind, v_num, left(nullif(trim(coalesce(p_description, '')), ''), 500), p_amount_minor, v_cur,
          case when p_kind = 'estimate' then 'proposed' else 'open' end, p_customer_id, p_record_id, p_appointment_id, p_due_on, p_idempotency_key, auth.uid())
  returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'charge_created', 'customer_charge', v_id, jsonb_build_object('kind', p_kind, 'amount_minor', p_amount_minor, 'currency', v_cur, 'number', v_num));
  return jsonb_build_object('id', v_id, 'number', v_num, 'repeat', false);
end $$;

-- Estimate decisions and voiding: managers and above.
create or replace function public.zella_set_charge_status(p_charge_id uuid, p_status text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from public.customer_charges where id = p_charge_id for update;
  if not found or not public.zella_has_role(c.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_status in ('accepted', 'declined') and (c.kind <> 'estimate' or c.status not in ('proposed', 'accepted', 'declined')) then raise exception 'NOT_VALID'; end if;
  if p_status = 'void' and exists (select 1 from public.customer_charge_payments where charge_id = c.id) then raise exception 'HAS_PAYMENTS'; end if;
  if p_status not in ('accepted', 'declined', 'void') then raise exception 'NOT_VALID'; end if;
  update public.customer_charges set status = p_status, updated_at = now() where id = c.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (c.business_id, auth.uid(), 'charge_status', 'customer_charge', c.id, jsonb_build_object('status', c.status),
          jsonb_build_object('status', p_status, 'reason', left(p_reason, 300)));
  return jsonb_build_object('id', c.id, 'status', p_status);
end $$;

-- One write path for payments, refunds and redemptions.
create or replace function public.zella_charge_payment_write(p_actor uuid, p_source text, p_charge_id uuid, p_kind text, p_amount_minor bigint,
  p_method text, p_note text, p_idempotency_key text, p_provider_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; b jsonb; v_id uuid; v_status text;
begin
  select * into c from public.customer_charges where id = p_charge_id for update;
  if not found then raise exception 'NOT_ALLOWED'; end if;
  if p_idempotency_key is not null then
    select id into v_id from public.customer_charge_payments where business_id = c.business_id and idempotency_key = p_idempotency_key;
    if v_id is not null then return jsonb_build_object('id', v_id, 'repeat', true, 'status', c.status); end if;
  end if;
  if p_provider_ref is not null then
    select id into v_id from public.customer_charge_payments where business_id = c.business_id and provider_ref = p_provider_ref;
    if v_id is not null then return jsonb_build_object('id', v_id, 'repeat', true, 'status', c.status); end if;
  end if;
  if c.kind = 'estimate' or c.status = 'void' then raise exception 'NOT_PAYABLE'; end if;
  if p_kind not in ('payment', 'refund', 'redemption') then raise exception 'NOT_VALID'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 then raise exception 'BAD_AMOUNT'; end if;
  if p_kind = 'redemption' and c.kind <> 'gift_card' then raise exception 'NOT_VALID'; end if;
  if c.kind = 'gift_card' and p_kind = 'redemption' and not exists (select 1 from public.customer_charge_payments where charge_id = c.id and kind = 'payment') then
    raise exception 'NOT_PAID';
  end if;
  b := public.zella_charge_balance(c.id);
  if p_kind = 'payment' and c.kind <> 'gift_card' and p_amount_minor > (b ->> 'balance_minor')::bigint then raise exception 'MORE_THAN_OWED'; end if;
  if p_kind = 'payment' and c.kind = 'gift_card' and exists (select 1 from public.customer_charge_payments where charge_id = c.id and kind = 'payment') then raise exception 'ALREADY_PAID'; end if;
  if p_kind = 'payment' and c.kind = 'gift_card' and p_amount_minor <> c.amount_minor then raise exception 'BAD_AMOUNT'; end if;
  if p_kind = 'redemption' then
    -- what's left on the card: value minus redemptions plus refunds of redemptions isn't modelled; refunds return money, not card value
    if p_amount_minor > c.amount_minor - coalesce((select sum(amount_minor) from public.customer_charge_payments where charge_id = c.id and kind = 'redemption'), 0) then
      raise exception 'MORE_THAN_OWED';
    end if;
  end if;
  if p_kind = 'refund' and p_amount_minor > (b ->> 'paid_minor')::bigint - (b ->> 'refunded_minor')::bigint
     - (case when c.kind = 'gift_card' then coalesce((select sum(amount_minor) from public.customer_charge_payments where charge_id = c.id and kind = 'redemption'), 0) else 0 end) then
    raise exception 'MORE_THAN_PAID';
  end if;
  insert into public.customer_charge_payments (charge_id, business_id, kind, amount_minor, method, source, provider_ref, note, idempotency_key, recorded_by)
  values (c.id, c.business_id, p_kind, p_amount_minor, coalesce(p_method, 'other'), p_source, p_provider_ref, left(nullif(trim(coalesce(p_note, '')), ''), 500),
          p_idempotency_key, p_actor)
  returning id into v_id;
  v_status := public.zella_charge_refresh_status(c.id);
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (c.business_id, p_actor, 'charge_' || p_kind, 'customer_charge', c.id,
          jsonb_build_object('amount_minor', p_amount_minor, 'currency', c.currency, 'source', p_source, 'method', p_method, 'status', v_status));
  return jsonb_build_object('id', v_id, 'repeat', false, 'status', v_status);
end $$;

-- Team: managers and above record payments and redemptions; owners and admins refund.
create or replace function public.zella_record_charge_payment(p_charge_id uuid, p_kind text, p_amount_minor bigint, p_method text,
  p_note text default null, p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz uuid;
begin
  select business_id into v_biz from public.customer_charges where id = p_charge_id;
  if v_biz is null then raise exception 'NOT_ALLOWED'; end if;
  if p_kind = 'refund' and not public.zella_has_role(v_biz, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_has_role(v_biz, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  perform public.zella_require_capability(v_biz, 'money');
  if p_method = 'provider' then raise exception 'NOT_VALID'; end if; -- provider-confirmed money comes only from server code
  return public.zella_charge_payment_write(auth.uid(), 'manual', p_charge_id, p_kind, p_amount_minor, p_method, p_note, p_idempotency_key, null);
end $$;

-- Server code only: a payment a provider confirmed (webhook), keyed by the provider's own reference.
create or replace function public.zella_provider_charge_payment(p_charge_id uuid, p_kind text, p_amount_minor bigint, p_provider_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if nullif(trim(coalesce(p_provider_ref, '')), '') is null then raise exception 'NOT_VALID'; end if;
  return public.zella_charge_payment_write(null, 'provider', p_charge_id, p_kind, p_amount_minor, 'provider', null, null, p_provider_ref);
end $$;

revoke execute on function public.zella_business_currency(uuid), public.zella_charge_balance(uuid), public.zella_charge_refresh_status(uuid),
  public.zella_create_charge(uuid, text, bigint, text, uuid, uuid, uuid, date, text, text), public.zella_set_charge_status(uuid, text, text),
  public.zella_charge_payment_write(uuid, text, uuid, text, bigint, text, text, text, text),
  public.zella_record_charge_payment(uuid, text, bigint, text, text, text), public.zella_provider_charge_payment(uuid, text, bigint, text) from public, anon;
revoke execute on function public.zella_charge_refresh_status(uuid), public.zella_charge_payment_write(uuid, text, uuid, text, bigint, text, text, text, text),
  public.zella_provider_charge_payment(uuid, text, bigint, text) from authenticated;
grant execute on function public.zella_business_currency(uuid), public.zella_charge_balance(uuid),
  public.zella_create_charge(uuid, text, bigint, text, uuid, uuid, uuid, date, text, text), public.zella_set_charge_status(uuid, text, text),
  public.zella_record_charge_payment(uuid, text, bigint, text, text, text) to authenticated, service_role;
grant execute on function public.zella_charge_refresh_status(uuid), public.zella_charge_payment_write(uuid, text, uuid, text, bigint, text, text, text, text),
  public.zella_provider_charge_payment(uuid, text, bigint, text) to service_role;
