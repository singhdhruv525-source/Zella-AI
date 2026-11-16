-- Rollback of sql/zella_stripe_refunds.sql: drops its table and functions. Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
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
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_refunds.sql made', s;
    end if;
  end loop;
  if to_regclass('public.billing_refunds') is not null then
    execute 'select exists (select 1 from public.billing_refunds)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: refunds exist; a person decides what to keep'; end if;
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop table if exists public.billing_refunds;
commit;
