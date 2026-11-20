-- Zella Voice: reconciliation of Stripe and our records (docs/PAYMENTS_ARCHITECTURE.md §10, §12), built switched off.
-- It never corrects money: every mismatch is an alert and a finance task for a person.
--   - Missed events: the worker reads Stripe's Events API from the last COMPLETED scan (a stored watermark, less an hour
--     of overlap) and stores each one exactly as the webhook does (zella_stripe_event_store: repeats are ignored). The
--     watermark moves only when a scan read every page (zella_billing_events_scanned); a scan cut short leaves it where
--     it was and raises an alert, and a longer backfill is a separate, manual step a person approves (default chosen
--     pending owner decision), so a webhook that was down loses nothing.
--   - Daily: Stripe's invoices, refunds and disputes of the last 7 days are matched to our rows by Stripe id and amount
--     (zella_billing_reconcile_objects); the ledger must balance overall and per operation (zella_billing_ledger_check).
--   - Each run is recorded in billing_reconcile_runs with what it found.
-- The live 15 minute job zella_reconcile_billing_events is not touched: its body stays exactly as applied in
-- production (md5 9f59ce3f06d391759dce9a17ff5fef77, checked by the guard and the tests).
-- Rollback: sql/rollback/zella_stripe_reconcile_rollback.sql. Tests: tests/stripe_reconcile/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_billing_ledger_check()": "f23bbaf0fe6825404b783b28e77773f6",
    "public.zella_billing_reconcile_objects(jsonb)": "599c5d51a2c7deb2f8f84ed27b9aa497",
    "public.zella_billing_reconcile_due()": "a12a98e3e0100d4746eb81e2c4b2499b",
    "public.zella_billing_events_cursor()": "42f52318859763d6a937dd7b13f1a5a7",
    "public.zella_billing_events_scanned(bigint,integer,boolean)": "6a7925318966aad659f5c3451b71d726"
  }';
begin
  if to_regprocedure('public.zella_billing_email_claim(integer)') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_emails.sql'; end if;
  if md5(pg_get_functiondef('public.zella_reconcile_billing_events(integer)'::regprocedure)) <> '9f59ce3f06d391759dce9a17ff5fef77' then
    raise exception 'VERSION_MISMATCH: zella_reconcile_billing_events is not the version applied in production';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create table if not exists public.billing_reconcile_runs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('objects', 'ledger', 'events')),
  checked integer not null default 0,
  mismatches jsonb not null default '[]'::jsonb,
  scanned_until timestamptz,   -- kind events: every Stripe event created before this was read and stored
  created_at timestamptz not null default now()
);
alter table public.billing_reconcile_runs enable row level security;
revoke all on public.billing_reconcile_runs from anon, authenticated;
grant select, insert on public.billing_reconcile_runs to service_role;

-- Every operation's lines sum to zero, and so does the whole ledger.
create or replace function public.zella_billing_ledger_check() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; n int;
begin
  select coalesce(jsonb_agg(jsonb_build_object('operation', operation_key, 'sum', s)), '[]'::jsonb), (select count(distinct operation_key) from public.money_ledger)
    into v, n from (select operation_key, sum(amount_minor) s from public.money_ledger group by operation_key having sum(amount_minor) <> 0) x;
  insert into public.billing_reconcile_runs (kind, checked, mismatches) values ('ledger', n, v);
  if jsonb_array_length(v) > 0 then
    perform public.zella_platform_alert('billing_ledger_unbalanced', 'The money ledger does not balance', jsonb_array_length(v) || ' operations', 'urgent', null, 'ledger_unbalanced');
  end if;
  return jsonb_build_object('checked', n, 'mismatches', v);
end $$;

-- p_objects: Stripe's own list (fetched by the worker): [{type: invoice|refund|dispute, id, amount, status, livemode}].
-- Matched by Stripe id and amount against our rows; only objects we know about (linked to a business) are expected.
create or replace function public.zella_billing_reconcile_objects(p_objects jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o jsonb; v jsonb := '[]'::jsonb; n int := 0; v_ours bigint; v_status text; v_known boolean;
begin
  for o in select * from jsonb_array_elements(coalesce(p_objects, '[]'::jsonb)) loop
    n := n + 1; v_ours := null; v_status := null;
    if o ->> 'type' = 'invoice' then
      select amount_paid_minor, status into v_ours, v_status from public.billing_invoices where stripe_invoice_id = o ->> 'id';
      v_known := found or exists (select 1 from public.billing_stripe_links l where l.kind = 'customer' and l.stripe_id = o ->> 'customer');
      -- paid, void and uncollectible are final at Stripe: ours must say the same (a failed payment while Stripe still
      -- shows the invoice open is expected and not a difference)
      if v_known and (v_status is null or (o ->> 'status' = 'paid' and (v_status <> 'paid' or v_ours <> (o ->> 'amount')::bigint))
                      or (o ->> 'status' in ('void', 'uncollectible') and v_status is distinct from o ->> 'status')) then
        v := v || jsonb_build_array(jsonb_build_object('type', 'invoice', 'id', o ->> 'id', 'stripe', o -> 'amount', 'ours', v_ours, 'our_status', v_status, 'stripe_status', o ->> 'status'));
      end if;
    elsif o ->> 'type' = 'refund' then
      select amount_minor, status into v_ours, v_status from public.billing_refunds where stripe_refund_id = o ->> 'id';
      if v_ours is null or v_ours <> (o ->> 'amount')::bigint or (o ->> 'status' = 'succeeded' and v_status <> 'processed') then
        if exists (select 1 from public.payments p where p.provider = 'stripe' and p.external_payment_id = o ->> 'payment_intent') then
          v := v || jsonb_build_array(jsonb_build_object('type', 'refund', 'id', o ->> 'id', 'stripe', o -> 'amount', 'ours', v_ours, 'our_status', v_status));
        end if;
      end if;
    elsif o ->> 'type' = 'dispute' then
      select amount_minor into v_ours from public.billing_disputes where stripe_dispute_id = o ->> 'id';
      if (v_ours is null and exists (select 1 from public.payments p where p.provider = 'stripe' and p.external_payment_id = o ->> 'payment_intent')) or v_ours <> (o ->> 'amount')::bigint then
        v := v || jsonb_build_array(jsonb_build_object('type', 'dispute', 'id', o ->> 'id', 'stripe', o -> 'amount', 'ours', v_ours));
      end if;
    end if;
  end loop;
  insert into public.billing_reconcile_runs (kind, checked, mismatches) values ('objects', n, v);
  if jsonb_array_length(v) > 0 then
    perform public.zella_platform_alert('billing_reconcile_mismatch', 'Stripe and Zella Voice disagree: a person checks', jsonb_array_length(v) || ' differences', 'urgent', null, 'reconcile:' || to_char(now(), 'YYYYMMDD'));
  end if;
  return jsonb_build_object('checked', n, 'mismatches', v);
end $$;

-- Is the daily object check due? (the worker runs every minute; the check runs once a day)
create or replace function public.zella_billing_reconcile_due() returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_payments_live() and not exists (select 1 from public.billing_reconcile_runs where kind = 'objects' and created_at > now() - interval '1 day');
$$;

-- Where the Events API catch up starts: the last completed scan, minus an hour of overlap (repeats are ignored); before
-- the first completed scan, 3 days back. Never the newest stored event: a webhook event that arrived doesn't prove the
-- older ones did.
create or replace function public.zella_billing_events_cursor() returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(extract(epoch from max(scanned_until) - interval '1 hour')::bigint, extract(epoch from now() - interval '3 days')::bigint)
    from public.billing_reconcile_runs where kind = 'events';
$$;

-- The worker's scan finished: complete (every page read, has_more false) moves the watermark to when the scan started;
-- cut short, nothing moves and a person is told (a longer backfill is a manual, approved step).
create or replace function public.zella_billing_events_scanned(p_started bigint, p_stored integer, p_complete boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_complete then
    insert into public.billing_reconcile_runs (kind, checked, scanned_until) values ('events', coalesce(p_stored, 0), to_timestamp(p_started));
  else
    perform public.zella_platform_alert('billing_events_scan_incomplete', 'Missed Stripe events could not all be read: a person runs the backfill',
      coalesce(p_stored, 0) || ' stored this run', 'urgent', null, 'events_scan:' || to_char(now(), 'YYYYMMDD'));
  end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_billing_ledger_check()', 'zella_billing_reconcile_objects(jsonb)', 'zella_billing_reconcile_due()', 'zella_billing_events_cursor()',
    'zella_billing_events_scanned(bigint,integer,boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
