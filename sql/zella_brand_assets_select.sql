-- Zella - brand-assets: let signed-in people see their own files through the storage API (2026-10-28). Safe to re-run.
-- Needs sql/zella_settings_system.sql (the bucket, zella_can_write_brand_asset and the insert/update/delete policies).
--
-- Why: Supabase Storage looks a file up (SELECT) before it deletes, moves or replaces it, so without a select policy
-- every delete quietly does nothing. Replacing a background picture, profile picture or logo left the old file behind.
-- The bucket is public, so anyone with a file's exact link could already open it; this only lets the API list and
-- find the files a person may write anyway: their own user/<id>/ folder, their business's folder (owners and admins),
-- and platform/ (admins with platform.configure).
-- Rollback: drop policy brand_assets_select on storage.objects;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'brand_assets_select') then
    create policy brand_assets_select on storage.objects for select to authenticated
      using (bucket_id = 'brand-assets' and public.zella_can_write_brand_asset(name));
  end if;
end $$;
