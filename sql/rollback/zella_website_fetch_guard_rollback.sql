-- Undoes sql/zella_website_fetch_guard.sql exactly: zella_website_url_ok comes back from zella_function_archive. It
-- must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Grants are kept.
-- Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_website_url_ok(text)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_website_fetch_guard') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '23c362d28709b0567a7427d2f253009e' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_website_fetch_guard' loop
    execute a.definition;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_website_fetch_guard';
end $$;
commit;
