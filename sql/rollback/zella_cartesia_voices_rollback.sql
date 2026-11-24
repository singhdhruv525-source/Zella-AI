-- Undoes sql/zella_cartesia_voices.sql exactly: zella_voice_choices, zella_business_voice_save and zella_assistant_config
-- come back from zella_function_archive (each must be exactly that file's version first, otherwise ROLLBACK_DRIFT and
-- nothing changes); voice_tts_choices goes back to the list it found (only while it is still the list the file wrote,
-- otherwise ROLLBACK_DRIFT); voice_cartesia_model is removed if the file added it; the three new functions, the
-- provider check and column go. Every business_voice row is kept: a business that chose a Cartesia voice keeps its
-- voice_id, which is no longer on the approved list, so its calls use the platform default voice (as for any voice
-- removed from the list) until the file is applied again. Grants are kept (same signatures). Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object('public.zella_voice_choices()', '30751307dabbaf6d28214d76d67f57ff',
    'public.zella_business_voice_save(uuid,text)', '59eb19efa4867a2b37abb13cc312cbb5',
    'public.zella_assistant_config(uuid)', 'e2ae7cfcd60ebf32a7d6bd2247e39ab3');
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_cartesia_voices') then
    for a in select signature from public.zella_function_archive where migration = 'zella_cartesia_voices' loop
      if md5(pg_get_functiondef(a.signature::regprocedure)) <> mine ->> a.signature then
        raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
      end if;
    end loop;
  end if;
  if to_regclass('public.zella_migration_values') is not null
     and exists (select 1 from public.zella_migration_values where migration = 'zella_cartesia_voices' and key = 'voice_tts_choices_after')
     and (select value from public.platform_settings where key = 'voice_tts_choices') is distinct from
         (select value from public.zella_migration_values where migration = 'zella_cartesia_voices' and key = 'voice_tts_choices_after') then
    raise exception 'ROLLBACK_DRIFT: voice_tts_choices has changed since this migration';
  end if;
  if to_regclass('public.zella_function_archive') is not null then
    for a in select definition from public.zella_function_archive where migration = 'zella_cartesia_voices' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_cartesia_voices';
  end if;
  if to_regclass('public.zella_migration_values') is not null then
    update public.platform_settings s set value = v.value, updated_at = now()
    from public.zella_migration_values v
    where v.migration = 'zella_cartesia_voices' and v.key = 'voice_tts_choices' and v.value is not null and s.key = 'voice_tts_choices';
    -- the file made the list: it goes again
    delete from public.platform_settings s using public.zella_migration_values v
    where v.migration = 'zella_cartesia_voices' and v.key = 'voice_tts_choices' and v.value is null and s.key = 'voice_tts_choices';
    delete from public.zella_migration_values where migration = 'zella_cartesia_voices';
  end if;
  if to_regclass('public.zella_migration_settings') is not null then
    delete from public.platform_settings where key in (select key from public.zella_migration_settings where migration = 'zella_cartesia_voices');
    delete from public.zella_migration_settings where migration = 'zella_cartesia_voices';
  end if;
end $$;
drop function if exists public.zella_setup_voice_apply(uuid, text, uuid);
drop function if exists public.zella_cartesia_voice(uuid, text, text);
drop function if exists public.zella_business_voice_choice(uuid);
alter table public.business_voice drop constraint if exists business_voice_provider_check;
alter table public.business_voice drop column if exists provider;
commit;
