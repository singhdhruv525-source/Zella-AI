-- Undoes sql/zella_retry_event_safe.sql exactly: the two argument zella_retry_event goes and the original comes back
-- from zella_function_archive, with its grants. Events already sent back stay where they are. Safe to run twice.
begin;
do $$
declare a record;
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_retry_event_safe') then
    drop function if exists public.zella_retry_event(uuid, text);
    for a in select definition from public.zella_function_archive where migration = 'zella_retry_event_safe' loop
      execute a.definition;
    end loop;
    revoke all on function public.zella_retry_event(uuid) from public, anon;
    grant execute on function public.zella_retry_event(uuid) to authenticated, service_role;
    delete from public.zella_function_archive where migration = 'zella_retry_event_safe';
  end if;
end $$;
commit;
