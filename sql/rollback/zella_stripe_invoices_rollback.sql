-- Rollback of sql/zella_stripe_invoices.sql: drops its seven functions (the invoice rows stay). Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
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
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_invoices.sql made', s;
    end if;
  end loop;

  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;

commit;
