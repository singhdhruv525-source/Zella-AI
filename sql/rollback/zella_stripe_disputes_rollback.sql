-- Rollback of sql/zella_stripe_disputes.sql: drops its table and functions. Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
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
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_disputes.sql made', s;
    end if;
  end loop;
  if to_regclass('public.billing_disputes') is not null then
    lock table public.billing_disputes in access exclusive mode;   -- held until commit: no row can be added before the drop
    execute 'select exists (select 1 from public.billing_disputes)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: disputes exist; a person decides what to keep'; end if;
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop table if exists public.billing_disputes;
commit;
