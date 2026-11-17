-- Rollback baseline is captured on first apply of this version, never on reruns.
-- An older deployment needs its original backup; this cannot reconstruct already-overwritten state.
create table if not exists public.zella_brand_assets_select_undo (seq bigint generated always as identity, command text not null);
revoke all on public.zella_brand_assets_select_undo from public, anon, authenticated, service_role;
do $capture$
declare f text; p oid; r record; g record; ddl text; cols text[];
begin
 if not exists (select 1 from public.zella_brand_assets_select_undo) then
  insert into public.zella_brand_assets_select_undo(command) values ('select 1');
  if to_regclass('storage.objects') is not null then
    select * into r from pg_policies where schemaname='storage' and tablename='objects' and policyname='brand_assets_select';
    insert into public.zella_brand_assets_select_undo(command) values ('drop policy if exists brand_assets_select on storage.objects');
    if found and r.policyname is not null then
      select string_agg(case when x='public' then 'public' else quote_ident(x) end, ',') into ddl from unnest(r.roles) x;
      insert into public.zella_brand_assets_select_undo(command) values ('create policy brand_assets_select on storage.objects as ' || r.permissive || ' for ' || r.cmd || ' to ' || ddl ||
        case when r.qual is null then '' else ' using (' || r.qual || ')' end || case when r.with_check is null then '' else ' with check (' || r.with_check || ')' end);
    end if;
  end if;
 end if;
end $capture$;

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
