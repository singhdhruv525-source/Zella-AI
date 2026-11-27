-- Rollback of sql/zella_stripe_owner_pay.sql. Restores zella_owner_invoices exactly as archived (the version
-- sql/zella_stripe_invoices.sql makes) and drops the six functions the file added. Refuses with ROLLBACK_DRIFT if any of
-- them differs from what the file made. Data is untouched: a pack an owner reopened stays as it is (pending until
-- Stripe's event settles it). Safe to run twice.
begin;

do $$
declare s text; d text;
  v_orig constant text := '60c0659f065c58b03dc279ffb007825c';
  v_made constant text := 'effc5ab4a36f94ac7429909fd534849b';
  owned constant jsonb := '{
    "public.zella_owner_invoice_pay_status(uuid)": "af72ce9f98b7f08a29cdf8c15de727c1",
    "public.zella_owner_invoice_pay_start(uuid)": "cb72de188cfae050d77a29bc3d627fd7",
    "public.zella_owner_billing_access(uuid,boolean)": "5738697783e8f82adc1872bea88bbf86",
    "public.zella_billing_stripe_refs(uuid,boolean)": "f850df5700bfb546c084e41d4267fab9",
    "public.zella_owner_pack_status(uuid,uuid)": "4d8eb9c51dd987c4f49b6e71877d8dc0",
    "public.zella_owner_pack_act_start(uuid,uuid)": "078d951809d38ead0c747863259fe7b7"
  }';
begin
  if md5(pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure)) not in (v_orig, v_made) then
    raise exception 'ROLLBACK_DRIFT: public.zella_owner_invoices(uuid) is not the version zella_stripe_owner_pay.sql made';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then
      if md5(pg_get_functiondef(to_regprocedure(s))) <> owned ->> s then raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_owner_pay.sql made', s; end if;
    end if;
  end loop;
  if md5(pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure)) = v_made then
    select definition into d from public.zella_function_archive
     where migration = 'zella_stripe_owner_pay' and signature = 'public.zella_owner_invoices(uuid)' and definition_md5 = v_orig;
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived zella_owner_invoices is missing'; end if;
    execute d;
    if md5(pg_get_functiondef('public.zella_owner_invoices(uuid)'::regprocedure)) <> v_orig then raise exception 'ROLLBACK_DRIFT: zella_owner_invoices did not restore exactly'; end if;
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', to_regprocedure(s)); end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_stripe_owner_pay';
end $$;

commit;
