-- Zella Voice: renewals, failed payments and the 5 day pause (docs/PAYMENTS_ARCHITECTURE.md §6.3, REQ-BIL-33), built
-- switched off. Stripe retries a failed renewal itself (Smart Retries, our schedule: days 2, 3 and 4); Zella Voice
-- never charges a renewal. This file only reacts to the verified, fetched Stripe objects:
--   - invoice.paid, billing_reason subscription_cycle (zella_stripe_grant_subscription_cycle): every line must be our
--     plan Price for this business at its own amount, or an invoice item we created at its stored amount; then the
--     subscription is active for the new period and the period opens with fresh balances and the 20% rollover
--     (zella_billing_open_period, unchanged). The first charge after a trial is the same reason.
--   - invoice.payment_failed and invoice.payment_action_required: past due (from active or a trial), with an urgent
--     notice; a later paid invoice wins, an older failure never undoes a payment.
--   - zella_billing_nonpayment_sweep (called by the worker each run): past due for 5 days -> paused_nonpayment. The
--     subscription is then not current, so zella_call_gate forwards new calls to the fallback number once the owner's
--     separate usage_enforcement.calls switch is on. Paying restores it. 30 days unpaid: an alert for a person; nothing
--     is cancelled or deleted automatically.
--   - customer.subscription.trial_will_end: the owner's in app reminder.
--   - zella_stripe_after_invoice_item: an invoice item we created is linked with its amount, so the binding check
--     knows it (the trial setup fee, later pay as you go).
-- Who: server only. Rollback: sql/rollback/zella_stripe_renewals_rollback.sql. Tests: tests/stripe_renewals/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_stripe_bind_lines(jsonb,uuid)": "c017d8779db4f747aae18d689f7b7b09",
    "public.zella_stripe_grant_subscription_cycle(jsonb,jsonb)": "073fe04eba152d2664d0a96490545b9c",
    "public.zella_stripe_payment_problem(billing_events,jsonb,text)": "656e996016f8ec5d799ceb032993affc",
    "public.zella_stripe_on_invoice_payment_failed(billing_events,jsonb)": "ea433b09813c3176bb3b408dba00794f",
    "public.zella_stripe_on_invoice_payment_action_required(billing_events,jsonb)": "8b29e15953f994f65f949e655af1c7b1",
    "public.zella_stripe_on_customer_subscription_trial_will_end(billing_events,jsonb)": "4117094051bffaf3c64c131a44216db6",
    "public.zella_stripe_after_invoice_item(billing_outbox)": "c47a6bf0884c6ce3a6c53814a2b3c1f4",
    "public.zella_billing_nonpayment_sweep()": "3c0ff3871fd640b0a5751034a1cc7473"
  }';
begin
  if to_regprocedure('public.zella_stripe_grant_subscription_create(jsonb,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_checkout.sql';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

-- Every line of a Stripe invoice is ours, at our amount: a plan Price of this business (unit amount x quantity) or an
-- invoice item we created. Returns the plan line's period and plan version; raises BINDING otherwise.
create or replace function public.zella_stripe_bind_lines(o jsonb, p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; l public.billing_stripe_links; v_item text; v_price text; v_sum bigint := 0; v_out jsonb := '{}'::jsonb;
begin
  for x in select * from jsonb_array_elements(coalesce(o #> '{lines,data}', '[]'::jsonb)) loop
    v_item := coalesce(x #>> '{parent,invoice_item_details,invoice_item}', x ->> 'invoice_item');
    v_price := coalesce(x #>> '{pricing,price_details,price}', x #>> '{price,id}');
    if v_item is not null then
      select * into l from public.billing_stripe_links where stripe_id = v_item and kind = 'invoice_item';
      if l.stripe_id is null or l.business_id <> p_business_id or l.expected_amount_minor is distinct from abs((x ->> 'amount')::bigint) then
        raise exception 'BINDING: invoice item % is not ours at this amount', v_item;
      end if;
    elsif v_price is not null then
      select * into l from public.billing_stripe_links where stripe_id = v_price and kind = 'price';
      if l.stripe_id is null or l.business_id <> p_business_id or l.local_kind is distinct from 'plan_price'
         or (x ->> 'amount')::bigint <> l.expected_amount_minor * coalesce((x ->> 'quantity')::bigint, 1) then
        raise exception 'BINDING: line price % is not our plan price at this amount', v_price;
      end if;
      v_out := jsonb_build_object('plan_version_id', l.local_id, 'start', x #>> '{period,start}', 'end', x #>> '{period,end}');
    else
      raise exception 'BINDING: an invoice line we did not create';
    end if;
    v_sum := v_sum + (x ->> 'amount')::bigint;
  end loop;
  if coalesce((o #>> '{lines,has_more}')::boolean, false) then raise exception 'BINDING: invoice lines not complete'; end if;
  if v_sum <> (o ->> 'total')::bigint then raise exception 'BINDING: lines add up to % but the total is %', v_sum, o ->> 'total'; end if;
  return v_out;
end $$;

create or replace function public.zella_stripe_grant_subscription_cycle(o jsonb, b jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_biz uuid := (b ->> 'business_id')::uuid; s public.subscriptions; v jsonb; v_start timestamptz; v_end timestamptz; v_was text;
begin
  if b ->> 'link_kind' <> 'subscription' then raise exception 'BINDING: renewal of a subscription we did not start'; end if;
  v := public.zella_stripe_bind_lines(o, v_biz);
  if v ->> 'start' is null then raise exception 'BINDING: renewal without a plan line'; end if;
  v_start := to_timestamp((v ->> 'start')::double precision); v_end := to_timestamp((v ->> 'end')::double precision);
  select * into s from public.subscriptions where business_id = v_biz for update;
  if s.id is null or s.external_subscription_id is distinct from b ->> 'subscription' then raise exception 'BINDING: not this business''s current subscription'; end if;
  if s.current_period_start is not null and v_start < s.current_period_start then return; end if;   -- an older period's invoice: recorded, never backwards
  v_was := s.status;
  if s.status <> 'active' and not public.zella_subscription_transition_ok(s.status, 'active') then
    if s.status = 'suspended_dispute' then   -- the saved state moves on; service stays suspended (§7)
      update public.subscriptions set metadata = metadata || jsonb_build_object('saved_status', 'active'), current_period_start = v_start, current_period_end = v_end where id = s.id;
      return;
    end if;
    raise exception 'BINDING: subscription is % and cannot renew', s.status;
  end if;
  update public.subscriptions set status = 'active', current_period_start = v_start, current_period_end = v_end, past_due_since = null,
         trial_end_at = case when v_was = 'trial' then coalesce(trial_end_at, v_start) else trial_end_at end, updated_at = now() where id = s.id;
  perform public.zella_billing_open_period(v_biz, greatest(v_start, least(now(), v_end - interval '1 second')));
  if v_was in ('past_due', 'paused_nonpayment', 'grace_period') then
    perform public.zella_notify_owners(v_biz, 'payment_received', 'Payment received', 'Thank you. Your payment went through and your service is fully back on.', 'info', 'settings');
    perform public.zella_resolve_platform_alerts('billing_nonpayment', v_biz, null, 'Paid');
  end if;
end $$;

-- A failed renewal (or one waiting for the bank's check): past due once, never over a paid invoice.
create or replace function public.zella_stripe_payment_problem(e public.billing_events, o jsonb, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare b jsonb := public.zella_stripe_bind_invoice(o, false); v_biz uuid := (b ->> 'business_id')::uuid; inv public.billing_invoices; s public.subscriptions;
begin
  if o ->> 'status' = 'paid' then return 'older'; end if;   -- fetched now: it was paid meanwhile
  inv := public.zella_stripe_invoice_upsert(v_biz, o, null);
  if inv.status = 'paid' then return 'older'; end if;
  update public.billing_invoices set status = case when status in ('draft', 'open') then 'payment_failed' else status end, updated_at = now() where id = inv.id;
  update public.billing_events set business_id = v_biz where id = e.id;
  select * into s from public.subscriptions where business_id = v_biz for update;
  if b ->> 'link_kind' = 'subscription' and s.id is not null and s.status in ('active', 'trial', 'renewal_due') and o ->> 'billing_reason' in ('subscription_cycle', 'subscription_create') then
    update public.subscriptions set status = 'past_due', past_due_since = coalesce(past_due_since, now()), updated_at = now() where id = s.id;
  end if;
  perform public.zella_notify_owners(v_biz, 'payment_failed',
    case p_kind when 'action' then 'Your bank needs you to confirm a payment' else 'Your payment did not go through' end,
    case p_kind when 'action' then 'Open the payment link in Settings, Billing to confirm it with your bank. Your service stays on meanwhile.'
                else 'We will try your card again over the next few days. Please update your card in Settings, Billing so your receptionist is not paused.' end,
    'urgent', 'settings');
  return 'applied';
end $$;

create or replace function public.zella_stripe_on_invoice_payment_failed(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_payment_problem(e, o, 'failed'); $$;

create or replace function public.zella_stripe_on_invoice_payment_action_required(e public.billing_events, o jsonb) returns text
language sql security definer set search_path = public as $$ select public.zella_stripe_payment_problem(e, o, 'action'); $$;

create or replace function public.zella_stripe_on_customer_subscription_trial_will_end(e public.billing_events, o jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare l public.billing_stripe_links := public.zella_stripe_link(o ->> 'id', 'subscription');
begin
  if l.stripe_id is null then raise exception 'WAITING: subscription % is not linked yet', o ->> 'id'; end if;
  if o ->> 'status' is distinct from 'trialing' or o ->> 'trial_end' is null then return 'ignored'; end if;
  perform public.zella_notify_owners(l.business_id, 'trial_ending', 'Your trial ends soon',
    'Your trial ends on ' || to_char(to_timestamp((o ->> 'trial_end')::double precision) at time zone 'UTC', 'FMMonth FMDD') || '. Your saved card is charged then, unless you cancel before.', 'info', 'settings');
  update public.billing_events set business_id = l.business_id where id = e.id;
  return 'applied';
end $$;

create or replace function public.zella_stripe_after_invoice_item(r public.billing_outbox) returns void
language plpgsql security definer set search_path = public as $$
begin
  if abs((r.response ->> 'amount')::bigint) is distinct from abs((r.body ->> 'amount')::bigint) then raise exception 'BINDING: Stripe invoice item amount differs'; end if;
  perform public.zella_stripe_link_add(r.stripe_id, 'invoice_item', r.business_id, (r.response ->> 'livemode')::boolean, r.body #>> '{metadata,kind}', r.local_id,
                                       abs((r.body ->> 'amount')::bigint));
end $$;

-- REQ-BIL-33: 5 days overdue pauses the receptionist (calls go to the fallback number). The days are a billing rule
-- (billing_rules.pause_after_days, default 5). 30 days unpaid raises an alert for a person; nothing is cancelled here.
create or replace function public.zella_billing_nonpayment_sweep() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s record; v_days int := coalesce((public.zella_setting('billing_rules', '{}'::jsonb) ->> 'pause_after_days')::int, 5); n_pause int := 0; n_alert int := 0;
begin
  if not public.zella_payments_live() then return jsonb_build_object('paused', 0, 'alerted', 0, 'off', true); end if;
  for s in select * from public.subscriptions where provider = 'stripe' and status = 'past_due' and past_due_since < now() - make_interval(days => v_days)
            for update skip locked loop
    update public.subscriptions set status = 'paused_nonpayment', updated_at = now() where id = s.id;
    perform public.zella_notify_owners(s.business_id, 'payment_overdue', 'Your receptionist is paused',
      'Your payment is ' || v_days || ' days overdue, so new calls now go to your fallback number. Pay the open invoice in Settings, Billing to switch it back on.', 'urgent', 'settings');
    perform public.zella_platform_alert('billing_nonpayment', 'A business is paused for nonpayment', null, 'warning', s.business_id, 'billing_nonpayment');
    insert into public.audit_logs (business_id, action, entity_type, entity_id, new_data)
    values (s.business_id, 'billing.paused_nonpayment', 'subscription', s.id, jsonb_build_object('past_due_since', s.past_due_since, 'days', v_days));
    n_pause := n_pause + 1;
  end loop;
  for s in select * from public.subscriptions where provider = 'stripe' and status = 'paused_nonpayment' and past_due_since < now() - interval '30 days' loop
    perform public.zella_platform_alert('billing_unpaid_30_days', 'Unpaid for 30 days: a person decides what happens next', null, 'urgent', s.business_id, 'billing_unpaid_30:' || s.id);
    n_alert := n_alert + 1;
  end loop;
  return jsonb_build_object('paused', n_pause, 'alerted', n_alert);
end $$;

do $$ declare f text; begin
  foreach f in array array['zella_stripe_bind_lines(jsonb,uuid)', 'zella_stripe_grant_subscription_cycle(jsonb,jsonb)', 'zella_stripe_payment_problem(billing_events,jsonb,text)',
    'zella_stripe_on_invoice_payment_failed(billing_events,jsonb)', 'zella_stripe_on_invoice_payment_action_required(billing_events,jsonb)',
    'zella_stripe_on_customer_subscription_trial_will_end(billing_events,jsonb)', 'zella_stripe_after_invoice_item(billing_outbox)', 'zella_billing_nonpayment_sweep()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
