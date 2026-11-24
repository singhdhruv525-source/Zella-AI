-- Undoes sql/zella_silence_timeout.sql exactly: the one line it added to zella_assistant_config is taken out again,
-- which gives back the exact version it found, whichever of the two it was (production's, or production's with
-- sql/zella_admin_languages.sql applied, before or after this file). The function must be exactly one of this file's
-- two versions first, otherwise ROLLBACK_DRIFT and nothing changes; the result is checked against the version it maps
-- to. voice_silence_timeout_seconds is removed if the file added it; zella_silence_hooks and
-- zella_silence_timeout_seconds go. Calls then use Vapi's own silence behaviour again. Safe to run twice.
begin;
do $$
declare
  d text; v_new text; v_base text;
  sig constant text := 'public.zella_assistant_config(uuid)';
  -- this file's md5 -> the md5 it was applied to
  mine constant jsonb := jsonb_build_object(
    '7cb1c1ad81a872b2118d66db2eeba959', 'e2ae7cfcd60ebf32a7d6bd2247e39ab3',
    '36ba71051bc6382c08e782d0a9754e20', '89e090f31515920ac198874946e15780');
  edit constant text := $w$      'hooks', public.zella_silence_hooks(p_business_id),   /* zella_silence_timeout: one check, then goodbye and end */
$w$;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_silence_timeout') then
    return;   -- not applied, or already rolled back
  end if;
  d := pg_get_functiondef(sig::regprocedure);
  if not mine ? md5(d) then raise exception 'ROLLBACK_DRIFT: % has changed since this migration', sig; end if;
  v_base := mine ->> md5(d);
  v_new := replace(d, edit, '');
  if md5(v_new) <> v_base then raise exception 'ROLLBACK_DRIFT: % would not come back as the version it was', sig; end if;
  execute v_new;
  if md5(pg_get_functiondef(sig::regprocedure)) <> v_base then
    raise exception 'ROLLBACK_DRIFT: % did not come back as the version it was', sig;
  end if;
  delete from public.zella_function_archive where migration = 'zella_silence_timeout';
end $$;
do $$
begin
  if to_regclass('public.zella_migration_settings') is not null then
    delete from public.platform_settings where key in (select key from public.zella_migration_settings where migration = 'zella_silence_timeout');
    delete from public.zella_migration_settings where migration = 'zella_silence_timeout';
  end if;
end $$;
drop function if exists public.zella_silence_hooks(uuid);
drop function if exists public.zella_silence_timeout_seconds();
commit;
