-- Undoes sql/zella_brain_safety_rules.sql exactly: zella_brain_prompt_base comes back from zella_function_archive (the
-- CASE on the industry key). It must be exactly that file's version first, otherwise ROLLBACK_DRIFT and nothing
-- changes. Safe to run twice. Live call path: needs the owner's approval like the migration.
begin;
do $$
declare a record; s constant text := 'public.zella_brain_prompt_base(uuid)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_brain_safety_rules') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '3bfb9c06c935ade77a6e2d8102f1511e' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_brain_safety_rules' loop
    execute a.definition;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_brain_safety_rules';
end $$;
commit;
