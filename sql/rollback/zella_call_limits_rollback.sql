-- Undoes sql/zella_call_limits.sql: zella_call_gate and zella_assistant_for_call come back from zella_function_archive
-- (each must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes), the outcome check on
-- assistant_deliveries is put back as it was (as NOT VALID when rows with the two new outcomes exist, so that call
-- history is kept), businesses.voice_max_concurrent_calls is dropped, and the setting this file inserted (recorded in
-- zella_migration_settings) is removed. If any business has its own limit saved, nothing changes (OVERRIDES_SET): clear
-- them first, so no value is lost without someone deciding it. Grants are kept (same signatures). Safe to run twice.
begin;
do $$
declare a record; v_over boolean := false;
  mine constant jsonb := jsonb_build_object('public.zella_call_gate(uuid)', '6afc3f110b731620a5ffc5fc9cab0dca',
                                            'public.zella_assistant_for_call(text,text,text)', '03ee44c36607ca56782820a30bffee82');
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'businesses' and column_name = 'voice_max_concurrent_calls') then
    execute 'select exists (select 1 from public.businesses where voice_max_concurrent_calls is not null)' into v_over;
  end if;
  if v_over then
    raise exception 'OVERRIDES_SET: some businesses have their own limit on calls at the same time; clear them first';
  end if;
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_call_limits') then
    return;
  end if;
  for a in select signature from public.zella_function_archive where migration = 'zella_call_limits' loop
    if md5(pg_get_functiondef(a.signature::regprocedure)) <> mine ->> a.signature then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
    end if;
  end loop;
  for a in select definition from public.zella_function_archive where migration = 'zella_call_limits' loop
    execute a.definition;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_call_limits';
  alter table public.assistant_deliveries drop constraint if exists assistant_deliveries_outcome_check;
  if exists (select 1 from public.assistant_deliveries where outcome in ('closed_usage', 'over_call_limit')) then
    alter table public.assistant_deliveries add constraint assistant_deliveries_outcome_check
      check (outcome in ('served', 'not_ready', 'unknown_number', 'forwarded_usage')) not valid;
  else
    alter table public.assistant_deliveries add constraint assistant_deliveries_outcome_check
      check (outcome in ('served', 'not_ready', 'unknown_number', 'forwarded_usage'));
  end if;
  alter table public.businesses drop column if exists voice_max_concurrent_calls;
  if to_regclass('public.zella_migration_settings') is not null then
    delete from public.platform_settings where key in (select key from public.zella_migration_settings where migration = 'zella_call_limits');
    delete from public.zella_migration_settings where migration = 'zella_call_limits';
    if not exists (select 1 from public.zella_migration_settings) then drop table public.zella_migration_settings; end if;
  end if;
end $$;
commit;
