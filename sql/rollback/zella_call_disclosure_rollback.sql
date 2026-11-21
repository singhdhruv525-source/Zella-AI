-- Undoes sql/zella_call_disclosure.sql exactly: zella_language_catalog, zella_business_language_save and
-- zella_assistant_config come back from zella_function_archive (each must be exactly this file's version first,
-- otherwise ROLLBACK_DRIFT and nothing changes), then zella_call_greeting and zella_ai_disclosure are dropped.
-- Greetings saved meanwhile are kept. Grants are kept (same signatures). Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object('public.zella_language_catalog()', 'ee4cda5da339a236547506ace897a62b',
    'public.zella_business_language_save(uuid,text,text[],text)', 'cf6fd925e723c0f3cd1df07e4974a562',
    'public.zella_assistant_config(uuid)', '99666d94ffea6b2aeff3f680405b30c9');
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_call_disclosure') then
    for a in select signature from public.zella_function_archive where migration = 'zella_call_disclosure' loop
      if md5(pg_get_functiondef(a.signature::regprocedure)) <> mine ->> a.signature then
        raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
      end if;
    end loop;
    for a in select definition from public.zella_function_archive where migration = 'zella_call_disclosure' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_call_disclosure';
  end if;
end $$;
drop function if exists public.zella_call_greeting(uuid, text);
drop function if exists public.zella_ai_disclosure(text);
commit;
