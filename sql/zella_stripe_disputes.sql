-- Zella Voice: disputes (chargebacks), recorded and shown to admins (docs/PAYMENTS_ARCHITECTURE.md §6.8, §7,
-- REQ-BIL-37), built switched off.
--   - charge.dispute.created (fetched): one billing_disputes row per Stripe dispute; the account is suspended while any
--     dispute is open: the subscription moves to suspended_dispute and the state it came from is saved on the
--     subscription once (a second dispute never overwrites it); an urgent alert with the respond by date. A dispute on a
--     cancelled subscription is recorded only.
--   - charge.dispute.updated: Stripe's status recorded. funds_withdrawn / funds_reinstated: ledger postings, once each.
--   - charge.dispute.closed: won (or warning_closed, an inquiry closed with no chargeback) -> closed; the saved state
--     comes back only when no other dispute is open and no lost one waits for a person. Lost -> a ledger posting for
--     the loss; the account stays suspended until a person settles it (settled_at set by that person).
--   - zella_admin_disputes (billing.view) for the admin Payments panel. Evidence is submitted by a person in Stripe.
-- Rollback: sql/rollback/zella_stripe_disputes_rollback.sql. Tests: tests/stripe_disputes/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_stripe_dispute_record(billing_events,jsonb)": "76437d76896444c4f72afe8a05966ea9",
    "public.zella_stripe_on_charge_dispute_created(billing_events,jsonb)": "0f74a1c3ef1d39166484910db5f789f3",
    "public.zella_stripe_on_charge_dispute_updated(billing_events,jsonb)": "eba8a07a7b0d6695637fffebbdfaec93",
    "public.zella_stripe_on_charge_dispute_closed(billing_events,jsonb)": "45a0c24e0c5304f088f8d9349c241cd4",
    "public.zella_stripe_on_charge_dispute_funds_withdrawn(billing_events,jsonb)": "bb010998c378707f9a21215f374a4879",
    "public.zella_stripe_on_charge_dispute_funds_reinstated(billing_events,jsonb)": "fc13098a88196ad37db3e7f46280ba82",
    "public.zella_admin_disputes(integer)": "0000613f03e350d055a7665b628c9bc1"
  }';
begin
  if to_regprocedure('public.zella_admin_invoices(uuid,text,integer)') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_invoices.sql'; end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create table if not exists public.billing_disputes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  payment_id uuid not null references public.payments(id) on delete restrict,
  stripe_dispute_id text not null unique,
  amount_minor bigint not null check (amount_minor >= 0),
  reason text,
  stripe_status text,
  outcome text not null default 'open' check (outcome in ('open', 'won', 'lost', 'warning_closed')),
  respond_by timestamptz,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  settled_at timestamptz   -- a lost dispute: when a person settled it (until then the account stays suspended)
);
alter table public.billing_disputes add column if not exists settled_at timestamptz;
create index if not exists billing_disputes_open_idx on public.billing_disputes (business_id) where outcome = 'open';
alter table public.billing_disputes enable row level security;
revoke all on public.billing_disputes from anon, authenticated;
grant select, insert, update on public.billing_disputes to service_role;

-- The dispute row for a fetched dispute (created on first sight, whatever event comes first). Returns it locked.
create or replace function public.zella_stripe_dispute_record(e public.billing_events, o jsonb) returns public.billing_disputes
language plpgsql security definer set search_path = public as $$
declare p public.payments; d public.billing_disputes; s public.subscriptions;
begin
  if lower(coalesce(o ->> 'currency', 'usd')) <> 'usd' then raise exception 'BINDING: dispute currency is not usd'; end if;
  select * into p from public.payments where provider = 'stripe' and external_payment_id = o ->> 'payment_intent';
  if p.id is null then raise exception 'WAITING: payment % not recorded yet', o ->> 'payment_intent'; end if;
  insert into public.billing_disputes (business_id, payment_id, stripe_dispute_id, amount_minor, reason, stripe_status, respond_by)
  values (p.business_id, p.id, o ->> 'id', (o ->> 'amount')::bigint, left(o ->> 'reason', 80), o ->> 'status', to_timestamp(nullif(o #>> '{evidence_details,due_by}', '')::double precision))
  on conflict (stripe_dispute_id) do nothing returning * into d;
  if d.id is not null then   -- first sight: suspend (REQ-BIL-37), saving the state once
    select * into s from public.subscriptions where business_id = p.business_id for update;
    if s.id is not null and s.status not in ('cancelled', 'expired', 'suspended_dispute') then
      update public.subscriptions set metadata = metadata || jsonb_build_object('saved_status', s.status), status = 'suspended_dispute', updated_at = now() where id = s.id;
    end if;
    perform public.zella_platform_alert('payment_disputed', 'A payment is disputed (chargeback)', 'Respond by ' || coalesce(to_char(d.respond_by at time zone 'UTC', 'FMMonth FMDD'), 'the date in Stripe'),
                                        'urgent', p.business_id, 'dispute:' || d.stripe_dispute_id);
    insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
    values (p.business_id, 'billing.dispute_opened', 'billing_dispute', d.id, jsonb_build_object('amount_minor', d.amount_minor, 'reason', d.reason));
  end if;
  select * into d from public.billing_disputes where stripe_dispute_id = o ->> 'id' for update;
  update public.billing_disputes set stripe_status = o ->> 'status' where id = d.id;
  update public.billing_events set business_id = d.business_id where id = e.id;
  return d;
end $$;

create or replace function public.zella_stripe_on_charge_dispute_created(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$ begin perform public.zella_stripe_dispute_record(e, o); return 'applied'; end $$;
create or replace function public.zella_stripe_on_charge_dispute_updated(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$ begin perform public.zella_stripe_dispute_record(e, o); return 'applied'; end $$;

create or replace function public.zella_stripe_on_charge_dispute_funds_withdrawn(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare d public.billing_disputes := public.zella_stripe_dispute_record(e, o);
begin
  perform public.zella_ledger_post(d.business_id, 'dispute:' || d.stripe_dispute_id || ':withdrawn',
    jsonb_build_array(jsonb_build_object('account', 'disputes', 'amount', d.amount_minor), jsonb_build_object('account', 'cash', 'amount', -d.amount_minor)));
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_charge_dispute_funds_reinstated(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare d public.billing_disputes := public.zella_stripe_dispute_record(e, o);
begin
  perform public.zella_ledger_post(d.business_id, 'dispute:' || d.stripe_dispute_id || ':reinstated',
    jsonb_build_array(jsonb_build_object('account', 'cash', 'amount', d.amount_minor), jsonb_build_object('account', 'disputes', 'amount', -d.amount_minor)));
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_charge_dispute_closed(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare d public.billing_disputes := public.zella_stripe_dispute_record(e, o); s public.subscriptions; v_out text;
begin
  v_out := case o ->> 'status' when 'won' then 'won' when 'lost' then 'lost' when 'warning_closed' then 'warning_closed' else null end;
  if v_out is null then raise exception 'BINDING: closed dispute with status %', o ->> 'status'; end if;
  if d.outcome <> 'open' then return 'applied'; end if;
  update public.billing_disputes set outcome = v_out, closed_at = now() where id = d.id;
  insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
  values (d.business_id, 'billing.dispute_' || v_out, 'billing_dispute', d.id, jsonb_build_object('amount_minor', d.amount_minor));
  if v_out in ('won', 'warning_closed') then
    select * into s from public.subscriptions where business_id = d.business_id for update;
    if s.status = 'suspended_dispute' and not exists (select 1 from public.billing_disputes where business_id = d.business_id
                                                       and (outcome = 'open' or (outcome = 'lost' and settled_at is null))) then
      update public.subscriptions set status = coalesce(metadata ->> 'saved_status', 'active'), metadata = metadata - 'saved_status', updated_at = now() where id = s.id;
      perform public.zella_resolve_platform_alerts('payment_disputed', d.business_id, null, case when v_out = 'won' then 'Won' else 'Closed' end);
    end if;
  else
    perform public.zella_ledger_post(d.business_id, 'dispute:' || d.stripe_dispute_id || ':lost',
      jsonb_build_array(jsonb_build_object('account', 'refunds', 'amount', d.amount_minor), jsonb_build_object('account', 'disputes', 'amount', -d.amount_minor)));
    perform public.zella_platform_alert('dispute_lost', 'A dispute was lost: a person settles it', null, 'urgent', d.business_id, 'dispute_lost:' || d.stripe_dispute_id);
  end if;
  return 'applied';
end $$;

create or replace function public.zella_admin_disputes(p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_admin_can('billing.view') then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'business_id', d.business_id, 'business_name', b.name, 'amount_minor', d.amount_minor,
           'reason', d.reason, 'outcome', d.outcome, 'stripe_status', d.stripe_status, 'respond_by', d.respond_by, 'created_at', d.created_at, 'closed_at', d.closed_at)
           order by (d.outcome = 'open') desc, d.created_at desc)
    from (select * from public.billing_disputes order by (outcome = 'open') desc, created_at desc limit greatest(1, least(p_limit, 500))) d join public.businesses b on b.id = d.business_id), '[]'::jsonb);
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_stripe_dispute_record(billing_events,jsonb)', 'zella_stripe_on_charge_dispute_created(billing_events,jsonb)', 'zella_stripe_on_charge_dispute_updated(billing_events,jsonb)',
    'zella_stripe_on_charge_dispute_closed(billing_events,jsonb)', 'zella_stripe_on_charge_dispute_funds_withdrawn(billing_events,jsonb)', 'zella_stripe_on_charge_dispute_funds_reinstated(billing_events,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  revoke execute on function public.zella_admin_disputes(integer) from public, anon;
  grant execute on function public.zella_admin_disputes(integer) to authenticated, service_role;
end $$;

commit;
