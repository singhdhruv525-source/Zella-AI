-- Undoes sql/zella_call_limits.sql: zella_call_gate and zella_assistant_for_call come back from zella_function_archive
-- (each must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes), the outcome check on
-- assistant_deliveries is put back as it was (as NOT VALID when rows with the two new outcomes exist, so that call
-- history is kept), businesses.voice_max_concurrent_calls is dropped, and the two settings are removed if they still
-- hold the values this file added. Grants are kept (same signatures). Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object('public.zella_call_gate(uuid)', '09a18d90f1138a04e5b284048f4210d1',
                                            'public.zella_assistant_for_call(text,text,text)', '6d554bec9fbc05b8c97e53f565100c04');
begin
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
  delete from public.platform_settings where (key = 'voice_max_concurrent_calls' and value = '10'::jsonb) or (key = 'auto_reload_live' and value = 'false'::jsonb);
end $$;
commit;
