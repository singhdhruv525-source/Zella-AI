-- Zella Voice: refund requests with server side eligibility, approved by the Zella Voice owner (docs/PAYMENTS_ARCHITECTURE.md
-- §6.7, REQ-BIL-38 to REQ-BIL-45, C-8), built switched off.
--   - zella_refund_options(business): what may be refunded now, decided here, never by the page:
--       guarantee     the first plan payment, plan fee only, within 30 days, once per business ever (REQ-BIL-38, 41)
--       setup_fee     the setup fee, within 48 hours of the first payment (REQ-BIL-39)
--       pack          a pack bought through Stripe, unused, within 14 days (REQ-BIL-40)
--       annual        a yearly renewal, within 7 days of the charge (REQ-BIL-42)
--     Each option says eligible or not, with a reason code, and the amount in cents.
--   - zella_owner_refund_request(business, kind, payment, key): the active owner, code verified session; eligibility is
--     checked again in the same transaction, with the payment row locked, and the amount is reserved: requested,
--     approved, sending, uncertain and processed refunds together never exceed what the payment captured.
--   - zella_admin_refund_decide(refund, approve, reason): the Zella Voice owner only (REQ-BIL-45), a reason, audited.
--     Approving checks eligibility again and queues one Stripe refund (key refund:<id>). Duplicate or wrong charges
--     (REQ-BIL-43) are raised by the owner with zella_admin_refund_raise (kind error, any amount up to the payment).
--   - refund.created / refund.updated / refund.failed (fetched): ours -> processed or failed, ledger posted once; one made
--     outside Zella Voice (the Stripe Dashboard) is recorded against its payment, audited and alerted (C-8).
-- Who: owners read their own options and requests; admins with billing.view read all; only the Zella Voice owner decides.
-- Rollback: sql/rollback/zella_stripe_refunds_rollback.sql. Tests: tests/stripe_refunds/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_refund_options(uuid)": "1a801d9fbf110d4ae1aeb640438ca9c4",
    "public.zella_refund_reserved(uuid)": "86a0e7dd8cf26483b2af5b42769221c5",
    "public.zella_owner_refund_options(uuid)": "adf719c917ac43f79dac312f3169c0a3",
    "public.zella_owner_refund_request(uuid,text,uuid,text)": "7411595c442081b93b884b8efb2a9402",
    "public.zella_admin_refunds(text,integer)": "49c1d30f43b41e0c2d0d136a59d2218f",
    "public.zella_admin_refund_decide(uuid,boolean,text)": "e8bb6744cfb16c9c5c949e40da0acb6a",
    "public.zella_admin_refund_raise(uuid,bigint,text)": "35634947680c18b9324a029c6490695e",
    "public.zella_stripe_after_refund(billing_outbox)": "5f6011231dd937b32cc627adcb7fc1a2",
    "public.zella_stripe_failed_refund(billing_outbox)": "b48f43e391d0839f1bc28933031ede34",
    "public.zella_stripe_on_refund_created(billing_events,jsonb)": "c74769d7177b2ecfdd2c7a649f85135c",
    "public.zella_stripe_on_refund_updated(billing_events,jsonb)": "02183a60f1cb3ccbb7762e163778bfd4",
    "public.zella_stripe_on_refund_failed(billing_events,jsonb)": "b7d0fffc8b7a092c37012040d3f52bae"
  }';
begin
  if to_regclass('public.billing_outbox') is null or to_regprocedure('public.zella_owner_pack_buy(uuid,text,text)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_packs.sql';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create table if not exists public.billing_refunds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  payment_id uuid not null references public.payments(id) on delete restrict,
  kind text not null check (kind in ('guarantee', 'setup_fee', 'pack', 'annual', 'error', 'outside')),
  amount_minor bigint not null check (amount_minor > 0),
  status text not null default 'requested' check (status in ('requested', 'approved', 'sending', 'processed', 'failed', 'rejected', 'uncertain')),
  reason text,
  idempotency_key text,
  requested_by uuid,
  decided_by uuid,
  decision_reason text,
  stripe_refund_id text unique,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  settled_at timestamptz,
  unique (business_id, idempotency_key)
);
create index if not exists billing_refunds_open_idx on public.billing_refunds (created_at desc) where status in ('requested', 'approved', 'sending', 'uncertain');
create index if not exists billing_refunds_payment_idx on public.billing_refunds (payment_id);
alter table public.billing_refunds enable row level security;
revoke all on public.billing_refunds from anon, authenticated;
grant select, insert, update on public.billing_refunds to service_role;

-- What a payment still has free to refund: captured, less every refund that is not rejected or failed.
create or replace function public.zella_refund_reserved(p_payment_id uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount_minor), 0) from public.billing_refunds where payment_id = p_payment_id and status not in ('rejected', 'failed');
$$;

create or replace function public.zella_refund_options(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare first public.payments; inv public.billing_invoices; plan public.business_plans; v jsonb := '[]'::jsonb; r record; v_used boolean; v_fee bigint; v_plan bigint;
begin
  select p.* into first from public.payments p where p.business_id = p_business_id and p.provider = 'stripe' and p.metadata ->> 'bound' = 'true'
     and p.metadata ->> 'billing_reason' = 'subscription_create' order by p.paid_at limit 1;
  if first.id is not null then
    select * into inv from public.billing_invoices where stripe_invoice_id = first.metadata ->> 'stripe_invoice';
    select bp.* into plan from public.billing_checkouts c join public.business_plans bp on bp.id = c.business_plan_id
     where c.business_id = p_business_id and c.status = 'paid' order by c.created_at limit 1;
    v_fee := coalesce(plan.setup_fee_cents, 0); v_plan := first.amount_minor - v_fee;
    v_used := exists (select 1 from public.billing_refunds where business_id = p_business_id and kind = 'guarantee' and status not in ('rejected', 'failed'));
    v := v || jsonb_build_array(jsonb_build_object('kind', 'guarantee', 'payment_id', first.id, 'amount_minor', v_plan,
      'eligible', not v_used and first.paid_at > now() - interval '30 days' and v_plan > 0 and v_plan <= first.amount_minor - public.zella_refund_reserved(first.id),
      'reason', case when v_used then 'guarantee_used' when first.paid_at <= now() - interval '30 days' then 'after_30_days' when v_plan <= 0 then 'nothing_to_refund'
                     when v_plan > first.amount_minor - public.zella_refund_reserved(first.id) then 'already_refunded' else 'eligible' end));
    if v_fee > 0 then
      v := v || jsonb_build_array(jsonb_build_object('kind', 'setup_fee', 'payment_id', first.id, 'amount_minor', v_fee,
        'eligible', first.paid_at > now() - interval '48 hours' and v_fee <= first.amount_minor - public.zella_refund_reserved(first.id),
        'reason', case when first.paid_at <= now() - interval '48 hours' then 'onboarding_started' when v_fee > first.amount_minor - public.zella_refund_reserved(first.id) then 'already_refunded' else 'eligible' end));
    end if;
  end if;
  for r in select pp.id as purchase_id, pp.price_cents, p.id as payment_id, p.amount_minor, p.paid_at,
                  coalesce((select sum(k.used) from public.allowance_buckets k where k.pack_purchase_id = pp.id), 0) as used
             from public.pack_purchases pp join public.payments p on p.provider = 'stripe' and p.external_payment_id = pp.stripe_payment_intent
            where pp.business_id = p_business_id and pp.status = 'granted' and pp.source in ('owner_purchase', 'auto_reload') loop
    v := v || jsonb_build_array(jsonb_build_object('kind', 'pack', 'payment_id', r.payment_id, 'amount_minor', r.price_cents,
      'eligible', r.used = 0 and r.paid_at > now() - interval '14 days' and public.zella_refund_reserved(r.payment_id) = 0,
      'reason', case when r.used > 0 then 'pack_used' when r.paid_at <= now() - interval '14 days' then 'after_14_days' when public.zella_refund_reserved(r.payment_id) > 0 then 'already_refunded' else 'eligible' end));
  end loop;
  for r in select p.id, p.amount_minor, p.paid_at from public.payments p join public.billing_invoices i on i.stripe_invoice_id = p.metadata ->> 'stripe_invoice'
            where p.business_id = p_business_id and p.metadata ->> 'billing_reason' = 'subscription_cycle' and i.period_end - i.period_start > interval '300 days'
              and p.paid_at > now() - interval '7 days' loop
    v := v || jsonb_build_array(jsonb_build_object('kind', 'annual', 'payment_id', r.id, 'amount_minor', r.amount_minor,
      'eligible', public.zella_refund_reserved(r.id) = 0, 'reason', case when public.zella_refund_reserved(r.id) = 0 then 'eligible' else 'already_refunded' end));
  end loop;
  return jsonb_build_object('options', v);
end $$;

create or replace function public.zella_owner_refund_options(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);
  return public.zella_refund_options(p_business_id) || jsonb_build_object('requests', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind,
           'amount_minor', amount_minor, 'status', status, 'created_at', created_at) order by created_at desc) from public.billing_refunds where business_id = p_business_id), '[]'::jsonb));
end $$;

create or replace function public.zella_owner_refund_request(p_business_id uuid, p_kind text, p_payment_id uuid, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o jsonb; r public.billing_refunds; p public.payments;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, true);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' or p_kind not in ('guarantee', 'setup_fee', 'pack', 'annual') then raise exception 'INVALID_INPUT'; end if;
  select * into r from public.billing_refunds where business_id = p_business_id and idempotency_key = p_idempotency_key;
  if r.id is not null then
    if r.kind <> p_kind or r.payment_id <> p_payment_id then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return jsonb_build_object('refund_id', r.id, 'status', r.status, 'amount_minor', r.amount_minor);
  end if;
  select * into p from public.payments where id = p_payment_id and business_id = p_business_id for update;   -- serialises requests on one payment
  if p.id is null then raise exception 'NOT_ELIGIBLE'; end if;
  select x into o from jsonb_array_elements(public.zella_refund_options(p_business_id) -> 'options') x
   where x ->> 'kind' = p_kind and (x ->> 'payment_id')::uuid = p_payment_id limit 1;
  if o is null or not (o ->> 'eligible')::boolean then raise exception 'NOT_ELIGIBLE' using detail = coalesce(o ->> 'reason', 'no_such_option'); end if;
  insert into public.billing_refunds (business_id, payment_id, kind, amount_minor, idempotency_key, requested_by)
  values (p_business_id, p_payment_id, p_kind, (o ->> 'amount_minor')::bigint, p_idempotency_key, auth.uid()) returning * into r;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'billing.refund_requested', 'billing_refund', r.id, jsonb_build_object('kind', r.kind, 'amount_minor', r.amount_minor));
  perform public.zella_platform_alert('refund_requested', 'A refund is waiting for the owner''s approval', r.kind, 'warning', p_business_id, 'refund:' || r.id);
  return jsonb_build_object('refund_id', r.id, 'status', r.status, 'amount_minor', r.amount_minor);
end $$;

create or replace function public.zella_admin_refunds(p_status text default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_admin_can('billing.view') then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'business_id', r.business_id, 'business_name', b.name, 'kind', r.kind, 'amount_minor', r.amount_minor,
           'status', r.status, 'created_at', r.created_at, 'decided_at', r.decided_at, 'decision_reason', r.decision_reason) order by r.created_at desc)
    from (select * from public.billing_refunds where p_status is null or status = p_status order by created_at desc limit greatest(1, least(p_limit, 500))) r
    join public.businesses b on b.id = r.business_id), '[]'::jsonb);
end $$;

-- Queues the Stripe refund for an approved request.
create or replace function public.zella_admin_refund_decide(p_refund_id uuid, p_approve boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.billing_refunds; p public.payments;
begin
  if auth.uid() is null or public.zella_admin_role() is distinct from 'zella_owner' or not public.zella_admin_can('billing.manage') then raise exception 'NOT_ALLOWED'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into r from public.billing_refunds where id = p_refund_id for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'requested' then return jsonb_build_object('refund_id', r.id, 'status', r.status, 'changed', false); end if;
  select * into p from public.payments where id = r.payment_id for update;
  if p_approve and r.kind <> 'error' then   -- a stale screen never refunds what the policy no longer allows: the rules again, this request aside
    if p.amount_minor - (public.zella_refund_reserved(p.id) - r.amount_minor) < r.amount_minor
       or (r.kind = 'guarantee' and (p.paid_at <= now() - interval '30 days'
            or exists (select 1 from public.billing_refunds x where x.business_id = r.business_id and x.kind = 'guarantee' and x.id <> r.id and x.status not in ('rejected', 'failed'))))
       or (r.kind = 'setup_fee' and p.paid_at <= now() - interval '48 hours')
       or (r.kind = 'annual' and p.paid_at <= now() - interval '7 days')
       or (r.kind = 'pack' and (p.paid_at <= now() - interval '14 days' or exists (select 1 from public.pack_purchases pp join public.allowance_buckets k on k.pack_purchase_id = pp.id
            where pp.stripe_payment_intent = p.external_payment_id and k.used > 0))) then
      raise exception 'NOT_ELIGIBLE';
    end if;
  end if;
  update public.billing_refunds set status = case when p_approve then 'sending' else 'rejected' end, decided_by = auth.uid(), decision_reason = left(trim(p_reason), 500), decided_at = now()
   where id = r.id returning * into r;
  if p_approve then
    perform public.zella_billing_outbox_add(r.business_id, 'refund', 'refund:' || r.id, 'POST', '/v1/refunds',
      jsonb_build_object('payment_intent', p.external_payment_id, 'amount', r.amount_minor, 'metadata', jsonb_build_object('refund_id', r.id, 'business_id', r.business_id)), 'refund', r.id);
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (r.business_id, auth.uid(), case when p_approve then 'billing.refund_approved' else 'billing.refund_rejected' end, 'billing_refund', r.id,
          jsonb_build_object('status', 'requested'), jsonb_build_object('status', r.status, 'amount_minor', r.amount_minor, 'reason', r.decision_reason));
  perform public.zella_resolve_platform_alerts('refund_requested', r.business_id, 'refund:' || r.id, r.status);
  return jsonb_build_object('refund_id', r.id, 'status', r.status, 'changed', true);
end $$;

-- REQ-BIL-43: a duplicate or wrong charge, raised by the Zella Voice owner after checking; then decided as above.
create or replace function public.zella_admin_refund_raise(p_payment_id uuid, p_amount_minor bigint, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p public.payments; v uuid;
begin
  if auth.uid() is null or public.zella_admin_role() is distinct from 'zella_owner' then raise exception 'NOT_ALLOWED'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into p from public.payments where id = p_payment_id and provider = 'stripe' for update;
  if p.id is null or p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor > p.amount_minor - public.zella_refund_reserved(p.id) then raise exception 'NOT_ELIGIBLE'; end if;
  insert into public.billing_refunds (business_id, payment_id, kind, amount_minor, reason, requested_by) values (p.business_id, p.id, 'error', p_amount_minor, left(trim(p_reason), 500), auth.uid()) returning id into v;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p.business_id, auth.uid(), 'billing.refund_raised', 'billing_refund', v, jsonb_build_object('amount_minor', p_amount_minor, 'reason', left(trim(p_reason), 500)));
  return v;
end $$;

create or replace function public.zella_stripe_after_refund(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (r.response ->> 'amount')::bigint is distinct from (r.body ->> 'amount')::bigint then raise exception 'BINDING: Stripe refund amount differs'; end if;
  perform public.zella_stripe_link_add(r.stripe_id, 'refund', r.business_id, (r.response ->> 'livemode')::boolean, 'refund', r.local_id, (r.body ->> 'amount')::bigint);
  update public.billing_refunds set stripe_refund_id = r.stripe_id where id = r.local_id;
end $$;

create or replace function public.zella_stripe_failed_refund(r public.billing_outbox) returns void
language sql security definer set search_path = public as $$
  update public.billing_refunds set status = 'failed', settled_at = now() where id = r.local_id and status = 'sending';
$$;

-- A refund from Stripe (fetched). Ours: processed or failed, posted once. Not ours (the Stripe Dashboard): recorded
-- against its payment, audited, urgent alert (REQ-BIL-45 says every refund needs the owner's approval in Zella Voice).
create or replace function public.zella_stripe_on_refund_created(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'refund'); r public.billing_refunds; p public.payments; v_amount bigint := (o ->> 'amount')::bigint;
begin
  select * into p from public.payments where provider = 'stripe' and external_payment_id = o ->> 'payment_intent' for update;
  if p.id is null then raise exception 'WAITING: payment % not recorded yet', o ->> 'payment_intent'; end if;
  if lower(o ->> 'currency') <> 'usd' then raise exception 'BINDING: refund currency is not usd'; end if;
  if l.stripe_id is not null then
    select * into r from public.billing_refunds where id = l.local_id for update;
    if r.payment_id <> p.id or r.amount_minor <> v_amount then raise exception 'BINDING: refund differs from the approved request'; end if;
  else
    select * into r from public.billing_refunds where stripe_refund_id = o ->> 'id' for update;
    if r.id is null then
      insert into public.billing_refunds (business_id, payment_id, kind, amount_minor, status, reason, stripe_refund_id)
      values (p.business_id, p.id, 'outside', v_amount, 'sending', 'Made outside Zella Voice', o ->> 'id') returning * into r;
      insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
      values (p.business_id, 'billing.refund_outside_zella', 'billing_refund', r.id, jsonb_build_object('amount_minor', v_amount, 'stripe_refund', o ->> 'id'));
      perform public.zella_platform_alert('refund_outside_zella', 'A refund was made outside Zella Voice', (v_amount::numeric / 100)::text || ' USD', 'urgent', p.business_id, 'refund_outside:' || (o ->> 'id'));
    end if;
  end if;
  if o ->> 'status' = 'succeeded' and r.status <> 'processed' then
    update public.billing_refunds set status = 'processed', settled_at = now() where id = r.id;
    perform public.zella_ledger_post(p.business_id, 'refund:' || (o ->> 'id'), jsonb_build_array(jsonb_build_object('account', 'refunds', 'amount', v_amount), jsonb_build_object('account', 'cash', 'amount', -v_amount)));
    update public.payments set status = case when public.zella_refund_reserved(p.id) >= p.amount_minor then 'refunded' else status end,
           metadata = metadata || jsonb_build_object('refunded_minor', (select coalesce(sum(amount_minor), 0) from public.billing_refunds where payment_id = p.id and status = 'processed')), updated_at = now()
     where id = p.id;
    if r.kind = 'pack' then
      update public.allowance_buckets set granted = used where pack_purchase_id = (select id from public.pack_purchases where stripe_payment_intent = p.external_payment_id);
    end if;
    perform public.zella_notify_owners(p.business_id, 'refund_processed', 'Refund on its way', 'Your refund was sent to your card. It usually arrives in 5 to 10 business days.', 'info', 'settings');
  elsif o ->> 'status' in ('failed', 'canceled') and r.status not in ('processed', 'failed') then
    update public.billing_refunds set status = 'failed', settled_at = now() where id = r.id;
    perform public.zella_platform_alert('refund_failed', 'A refund failed at Stripe', o ->> 'failure_reason', 'urgent', p.business_id, 'refund_failed:' || r.id);
  end if;
  update public.billing_events set business_id = p.business_id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_refund_updated(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_on_refund_created(e, o); $$;
create or replace function public.zella_stripe_on_refund_failed(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_on_refund_created(e, o); $$;

do $$ declare f text; begin
  foreach f in array array['zella_refund_options(uuid)', 'zella_refund_reserved(uuid)', 'zella_stripe_after_refund(billing_outbox)', 'zella_stripe_failed_refund(billing_outbox)',
    'zella_stripe_on_refund_created(billing_events,jsonb)', 'zella_stripe_on_refund_updated(billing_events,jsonb)', 'zella_stripe_on_refund_failed(billing_events,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_owner_refund_options(uuid)', 'zella_owner_refund_request(uuid,text,uuid,text)', 'zella_admin_refunds(text,integer)',
    'zella_admin_refund_decide(uuid,boolean,text)', 'zella_admin_refund_raise(uuid,bigint,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

commit;
