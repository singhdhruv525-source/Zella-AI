-- Undoes sql/zella_status_honest.sql exactly: zella_public_status() comes back from zella_function_archive. It must be
-- exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Grants are kept (same signature).
-- Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_public_status()';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_status_honest') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '9bace44cf5ad3c2b7790650a54e48b98' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_status_honest' loop
    execute a.definition;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_status_honest';
end $$;
commit;
