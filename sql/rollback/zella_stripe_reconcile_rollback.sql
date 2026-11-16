-- Rollback of sql/zella_stripe_reconcile.sql: drops its functions and its run log (zella_reconcile_billing_events is never touched). Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_billing_ledger_check()": "f23bbaf0fe6825404b783b28e77773f6",
    "public.zella_billing_reconcile_objects(jsonb)": "b9e5178f5ddcb614e5848fe350944e56",
    "public.zella_billing_reconcile_due()": "a12a98e3e0100d4746eb81e2c4b2499b",
    "public.zella_billing_events_cursor()": "b80032ca7a7304b805075deabd623908"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_reconcile.sql made', s;
    end if;
  end loop;

  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop table if exists public.billing_reconcile_runs;
commit;
