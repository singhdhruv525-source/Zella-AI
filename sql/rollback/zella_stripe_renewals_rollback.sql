-- Rollback of sql/zella_stripe_renewals.sql: drops its eight functions (the subscriptions and events it changed stay as they are). Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
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
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_renewals.sql made', s;
    end if;
  end loop;

  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;

commit;
