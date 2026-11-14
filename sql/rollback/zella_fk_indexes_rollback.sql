-- Undoes sql/zella_fk_indexes.sql: drops only the indexes it created, recognised by the comment it put on each one.
-- An index that already existed (under any name, even one of ours) has no such comment and is left alone. No data is
-- touched. Safe to run again.
begin;
do $$
declare r record;
begin
  if to_regprocedure('public.zella_fk_index_list()') is null then return; end if;
  for r in select l.index_name from public.zella_fk_index_list() l
           where obj_description(to_regclass('public.' || l.index_name), 'pg_class') = 'created by sql/zella_fk_indexes.sql' loop
    execute format('drop index public.%I', r.index_name);
  end loop;
end $$;
drop function if exists public.zella_fk_index_list();
commit;
