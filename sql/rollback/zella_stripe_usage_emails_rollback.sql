-- Rollback of sql/zella_stripe_usage_emails.sql: drops its trigger and function (notices already decided stay). Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_billing_usage_email_trg()": "d7655706d1a394d07f654b5f3c1f7333"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_usage_emails.sql made', s;
    end if;
  end loop;
  drop trigger if exists zella_billing_usage_email on public.usage_threshold_events;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;

commit;
