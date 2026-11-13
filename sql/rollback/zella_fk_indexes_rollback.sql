-- Undoes sql/zella_fk_indexes.sql: drops only the indexes it created, by their exact names. An index that already
-- existed under another name was never created by that file and is left alone. No data is touched. Safe to run again.
begin;
do $$
declare r record;
begin
  if to_regprocedure('public.zella_fk_index_list()') is null then return; end if;
  for r in select * from public.zella_fk_index_list() loop
    execute format('drop index if exists public.%I', r.index_name);
  end loop;
end $$;
drop function if exists public.zella_fk_index_list();
commit;
