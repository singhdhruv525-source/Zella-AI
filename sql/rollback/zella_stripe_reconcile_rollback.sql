-- Rollback of sql/zella_stripe_reconcile.sql: drops its functions and its run log (zella_reconcile_billing_events is never touched). Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while a run is recorded: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_billing_ledger_check()": "f23bbaf0fe6825404b783b28e77773f6",
    "public.zella_billing_reconcile_objects(jsonb)": "599c5d51a2c7deb2f8f84ed27b9aa497",
    "public.zella_billing_reconcile_due()": "a12a98e3e0100d4746eb81e2c4b2499b",
    "public.zella_billing_events_cursor()": "42f52318859763d6a937dd7b13f1a5a7",
    "public.zella_billing_events_scanned(bigint,integer,boolean)": "6a7925318966aad659f5c3451b71d726"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_reconcile.sql made', s;
    end if;
  end loop;
  -- the run log is history a person may need: refuse while it holds a run (nothing is deleted)
  if to_regclass('public.billing_reconcile_runs') is not null then
    lock table public.billing_reconcile_runs in access exclusive mode;
    execute 'select exists (select 1 from public.billing_reconcile_runs)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: reconciliation runs are recorded; a person decides what to keep'; end if;
  end if;

  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop table if exists public.billing_reconcile_runs;
commit;
