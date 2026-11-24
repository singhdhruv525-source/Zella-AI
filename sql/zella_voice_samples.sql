-- Zella Voice: the private storage bucket for receptionist voice samples (the voice-sample edge function).
--
-- The voice picker's play button asks voice-sample for a sample of an approved voice. The function makes it once with
-- the provider (Cartesia or ElevenLabs), keeps it here as <provider>/<voice id>-<hash of the line>.mp3, and hands the
-- browser a signed link that lives 5 minutes. The bucket is private: no policy on storage.objects names it, so only
-- the server key (the function) reads or writes it; signed in people and anonymous visitors can't list, read or add
-- files. MP3 only, at most 1 MB a file. No table, function or row of any business changes.
--
-- New setting voice_samples_live = false: while it is false the function only plays samples already stored and never
-- asks a provider for a new one (each new sample is a small paid request). The owner switches it on.
--
-- Guarded: storage must exist, and a voice-samples bucket that is already there must be exactly this one (private, 1 MB,
-- audio/mpeg) with no policy naming it, otherwise VERSION_MISMATCH and nothing changes. Safe to run twice.
-- Rollback: sql/rollback/zella_voice_samples_rollback.sql
begin;

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null
     or to_regclass('public.platform_settings') is null or to_regclass('public.zella_migration_settings') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (storage, platform_settings, zella_migration_settings)';
  end if;
  if exists (select 1 from storage.buckets where id = 'voice-samples'
             and (name is distinct from 'voice-samples' or public is distinct from false or file_size_limit is distinct from 1048576
                  or allowed_mime_types is distinct from array['audio/mpeg']::text[])) then
    raise exception 'VERSION_MISMATCH: a different voice-samples bucket already exists';
  end if;
  if exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass
             and (coalesce(pg_get_expr(polqual, polrelid), '') like '%voice-samples%' or coalesce(pg_get_expr(polwithcheck, polrelid), '') like '%voice-samples%')) then
    raise exception 'VERSION_MISMATCH: a storage policy already names voice-samples';
  end if;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-samples', 'voice-samples', false, 1048576, array['audio/mpeg']::text[])
on conflict (id) do nothing;

-- off until the owner switches it on; an existing value is kept, and only a value this file added is removed on rollback
with i as (
  insert into public.platform_settings (key, value) values ('voice_samples_live', 'false'::jsonb)
  on conflict (key) do nothing returning key
)
insert into public.zella_migration_settings (migration, key) select 'zella_voice_samples', key from i on conflict do nothing;

commit;
