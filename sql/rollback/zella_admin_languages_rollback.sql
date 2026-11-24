-- Undoes sql/zella_admin_languages.sql exactly: the eight changed functions come back from zella_function_archive
-- (each must be exactly that file's version first, otherwise ROLLBACK_DRIFT and nothing changes), and the six new
-- functions go. Saved languages, voices and audit rows are kept. Owners can then change languages again in Settings
-- (the rule before this file), and voices are no longer filtered by language. Grants are kept (same signatures).
-- Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object(
    'public.zella_business_language_save(uuid,text,text[],text)', '14a58fa33813daa316c70688a36c88a2',
    'public.zella_business_language_get(uuid)', 'd48d06c07deb0a2c9b2c67e454a63c9f',
    'public.zella_setup_language_apply(uuid,text,text)', '3ff63339ea34147dcbe4eb1ba775f8ac',
    'public.zella_business_voice_get(uuid)', '63955f816a465e4042f6a3849044bc56',
    'public.zella_business_voice_save(uuid,text)', 'cd7cd28898995846a156fa1c5c31dab9',
    'public.zella_setup_voice_apply(uuid,text,uuid)', 'b2b29c7f4aa337003b0854235e73ce6b',
    'public.zella_business_voice_choice(uuid)', '580de72ac835968c0ed83b2ef2c3aca5',
    'public.zella_assistant_config(uuid)', '89e090f31515920ac198874946e15780');
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_admin_languages') then
    return;   -- not applied, or already rolled back
  end if;
  for a in select signature from public.zella_function_archive where migration = 'zella_admin_languages' loop
    if to_regprocedure(a.signature) is null or md5(pg_get_functiondef(a.signature::regprocedure)) is distinct from mine ->> a.signature then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
    end if;
  end loop;
  for a in select definition from public.zella_function_archive where migration = 'zella_admin_languages' loop
    execute a.definition;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_admin_languages';
end $$;
drop function if exists public.zella_business_voice_unfit(uuid);
drop function if exists public.zella_voice_fits(uuid, jsonb);
drop function if exists public.zella_business_voice_languages(uuid);
drop function if exists public.zella_language_plan_refusal(uuid, text, text[]);
drop function if exists public.zella_language_plan_info(uuid);
drop function if exists public.zella_language_family(text);
commit;
