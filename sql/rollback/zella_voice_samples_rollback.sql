-- Undoes sql/zella_voice_samples.sql: removes the private voice-samples bucket. It refuses (SAMPLES_EXIST) while the
-- bucket still holds samples: remove them first through the storage API (the dashboard, or the server key), so no file
-- is left at the storage provider without its row. ROLLBACK_DRIFT and nothing changes if the bucket is no longer the one
-- the migration made, or a storage policy now names it. Switch the voice picker's play button off first (undeploy
-- voice-sample); until then a press answers "try again". It refuses (SAMPLES_LIVE) while voice_samples_live is on, and
-- removes that setting only if this file added it. Safe to run twice.
begin;
do $$
begin
  if to_regclass('storage.buckets') is null then return; end if;
  if exists (select 1 from storage.buckets where id = 'voice-samples'
             and (name is distinct from 'voice-samples' or public is distinct from false or file_size_limit is distinct from 1048576
                  or allowed_mime_types is distinct from array['audio/mpeg']::text[])) then
    raise exception 'ROLLBACK_DRIFT: the voice-samples bucket has changed since this migration';
  end if;
  if exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass
             and (coalesce(pg_get_expr(polqual, polrelid), '') like '%voice-samples%' or coalesce(pg_get_expr(polwithcheck, polrelid), '') like '%voice-samples%')) then
    raise exception 'ROLLBACK_DRIFT: a storage policy names voice-samples';
  end if;
  if to_regclass('public.platform_settings') is not null
     and exists (select 1 from public.platform_settings where key = 'voice_samples_live' and value is distinct from 'false'::jsonb) then
    raise exception 'SAMPLES_LIVE: switch voice_samples_live off first';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'voice-samples') then
    raise exception 'SAMPLES_EXIST: the voice-samples bucket still holds samples';
  end if;
  delete from storage.buckets where id = 'voice-samples';
  if to_regclass('public.zella_migration_settings') is not null then
    delete from public.platform_settings where key in (select key from public.zella_migration_settings where migration = 'zella_voice_samples');
    delete from public.zella_migration_settings where migration = 'zella_voice_samples';
  end if;
end $$;
commit;
