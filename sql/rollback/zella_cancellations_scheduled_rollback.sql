-- Undoes sql/zella_cancellations_scheduled.sql exactly: all three functions come back from zella_function_archive.
-- Businesses already cancelled stay cancelled. Safe to run twice.
begin;
do $$
declare a record;
begin
  if to_regclass('public.zella_function_archive') is not null then
    for a in select definition from public.zella_function_archive where migration = 'zella_cancellations_scheduled' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_cancellations_scheduled';
  end if;
end $$;
commit;
