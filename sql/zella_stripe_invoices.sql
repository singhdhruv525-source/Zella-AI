-- Zella Voice: invoices from Stripe invoice events, and who can read them (docs/PAYMENTS_ARCHITECTURE.md §4, §6.11,
-- §16.5), built switched off.
--   - invoice.created, invoice.finalized: the fetched invoice is recorded in billing_invoices (number, status, totals in
--     cents, lines, hosted page and PDF links); status moves forward only. An invoice of a subscription not linked yet
--     waits; one that isn't ours is quarantined.
--   - invoice.voided (fetched): recorded as void, never over a paid invoice.
--   - invoice.deleted (not retrievable): acts only if OUR row for it is still a draft and the event says draft;
--     otherwise it is held for a person (quarantine), as §16.5 says.
--   - zella_admin_invoices(business, status, limit): admins with billing.view; zella_owner_invoices(business): the
--     business's active owner only (TEN-9). Both read only, no card data (there is none).
-- Rollback: sql/rollback/zella_stripe_invoices_rollback.sql. Tests: tests/stripe_invoices/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_stripe_invoice_record(billing_events,jsonb)": "35c46ded9e0baed03e3813110916d474",
    "public.zella_stripe_on_invoice_created(billing_events,jsonb)": "21d2191ce3dff56c6d3106ee650b2c01",
    "public.zella_stripe_on_invoice_finalized(billing_events,jsonb)": "a29576fea4f7918890ccaf38d3acdbf8",
    "public.zella_stripe_on_invoice_voided(billing_events,jsonb)": "d633358dfb23f09444a34ecc148775dd",
    "public.zella_stripe_on_invoice_deleted(billing_events,jsonb)": "836c54f35b313bb2d79427186e83e786",
    "public.zella_admin_invoices(uuid,text,integer)": "e7affec96da12dde01160738f8d80fb9",
    "public.zella_owner_invoices(uuid)": "60c0659f065c58b03dc279ffb007825c"
  }';
begin
  if to_regclass('public.billing_invoices') is null or to_regprocedure('public.zella_stripe_cancel_sync(uuid,integer)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_cancel.sql';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create or replace function public.zella_stripe_invoice_record(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare b jsonb := public.zella_stripe_bind_invoice(o, false); inv public.billing_invoices;
begin
  inv := public.zella_stripe_invoice_upsert((b ->> 'business_id')::uuid, o, null);
  update public.billing_events set business_id = inv.business_id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_invoice_created(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_invoice_record(e, o); $$;
create or replace function public.zella_stripe_on_invoice_finalized(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_invoice_record(e, o); $$;

create or replace function public.zella_stripe_on_invoice_voided(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
begin
  if o ->> 'status' = 'paid' then return 'older'; end if;   -- fetched now: paid, so the void never happened or was undone
  if o ->> 'status' <> 'void' then raise exception 'BINDING: voided event for an invoice that is %', o ->> 'status'; end if;
  return public.zella_stripe_invoice_record(e, o);
end $$;

create or replace function public.zella_stripe_on_invoice_deleted(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare inv public.billing_invoices;
begin
  select * into inv from public.billing_invoices where stripe_invoice_id = o ->> 'id' for update;
  if inv.id is null or inv.status <> 'draft' or coalesce(o ->> 'status', e.payload ->> 'status') is distinct from 'draft' then
    raise exception 'BINDING: deleted event for an invoice we do not hold as a draft';
  end if;
  update public.billing_invoices set status = 'deleted', updated_at = now() where id = inv.id;
  update public.billing_events set business_id = inv.business_id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_admin_invoices(p_business_id uuid default null, p_status text default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_admin_can('billing.view') then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'business_id', i.business_id, 'business_name', b.name, 'number', i.number, 'kind', i.kind,
           'status', i.status, 'total_minor', i.total_minor, 'amount_paid_minor', i.amount_paid_minor, 'currency', i.currency, 'period_start', i.period_start,
           'period_end', i.period_end, 'hosted_invoice_url', i.hosted_invoice_url, 'invoice_pdf', i.invoice_pdf, 'paid_at', i.paid_at, 'created_at', coalesce(i.stripe_created_at, i.created_at),
           'livemode', i.livemode) order by coalesce(i.stripe_created_at, i.created_at) desc)
    from (select * from public.billing_invoices where (p_business_id is null or business_id = p_business_id) and (p_status is null or status = p_status) and status <> 'deleted'
           order by coalesce(stripe_created_at, created_at) desc limit greatest(1, least(p_limit, 500))) i
    join public.businesses b on b.id = i.business_id), '[]'::jsonb);
end $$;

create or replace function public.zella_owner_invoices(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_onboarding_authorize(p_business_id, false, false);   -- the business's active owner only
  return coalesce((select jsonb_agg(jsonb_build_object('number', number, 'status', status, 'total_minor', total_minor, 'amount_paid_minor', amount_paid_minor,
           'currency', currency, 'period_start', period_start, 'period_end', period_end, 'hosted_invoice_url', hosted_invoice_url, 'invoice_pdf', invoice_pdf,
           'paid_at', paid_at, 'created_at', coalesce(stripe_created_at, created_at)) order by coalesce(stripe_created_at, created_at) desc)
    from public.billing_invoices where business_id = p_business_id and status not in ('draft', 'deleted')), '[]'::jsonb);
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_stripe_invoice_record(billing_events,jsonb)', 'zella_stripe_on_invoice_created(billing_events,jsonb)', 'zella_stripe_on_invoice_finalized(billing_events,jsonb)',
    'zella_stripe_on_invoice_voided(billing_events,jsonb)', 'zella_stripe_on_invoice_deleted(billing_events,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_admin_invoices(uuid,text,integer)', 'zella_owner_invoices(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

commit;
