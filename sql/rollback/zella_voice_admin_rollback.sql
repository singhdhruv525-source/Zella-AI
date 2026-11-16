-- Undoes sql/zella_voice_admin.sql exactly: zella_admin_voice_overview and zella_admin_voice_alerts come back from
-- zella_function_archive, and zella_vapi_refusal_record and the vapi_refusals counter (with its counts) are removed.
-- Both functions must be exactly this file's versions first, otherwise ROLLBACK_DRIFT and nothing changes. Grants are
-- kept (same signatures). Deploy the voice-rules version without the counter call first, or it logs a failed call
-- (the 401 answer is the same either way). Safe to run twice.
begin;
do $$
declare a record; want constant jsonb := jsonb_build_object(
  'public.zella_admin_voice_overview(timestamp with time zone,timestamp with time zone)', 'beb55e2f313319dce5322d40561aab19',
  'public.zella_admin_voice_alerts()', 'f95f44a16b688f867175b5e9b4fe30fb'); s text;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_voice_admin') then
    return;   -- not applied, or already rolled back
  end if;
  for s in select jsonb_object_keys(want) loop
    if md5(pg_get_functiondef(s::regprocedure)) <> want ->> s then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
    end if;
  end loop;
  for a in select definition from public.zella_function_archive where migration = 'zella_voice_admin' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_vapi_refusal_record(text, text[], text);
  drop table if exists public.vapi_refusals;
  delete from public.zella_function_archive where migration = 'zella_voice_admin';
end $$;
commit;
