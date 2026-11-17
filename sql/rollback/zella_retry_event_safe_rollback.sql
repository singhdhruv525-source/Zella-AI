-- Undoes sql/zella_retry_event_safe.sql exactly: the two argument zella_retry_event goes and the original comes back
-- from zella_function_archive with its grants, and zella_start_execution comes back from the archive. Both must be
-- exactly this file's versions first, otherwise ROLLBACK_DRIFT and nothing changes. Events already sent back stay
-- where they are. Safe to run twice.
begin;
do $$
declare a record; s2 constant text := 'public.zella_retry_event(uuid,text)'; s3 constant text := 'public.zella_start_execution(text,uuid,uuid,text,uuid)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_retry_event_safe') then
    return;   -- not applied, or already rolled back
  end if;
  if to_regprocedure(s2) is not null and md5(pg_get_functiondef(s2::regprocedure)) <> '7684599b2e92746009cba061d7e034d4' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s2;
  end if;
  if exists (select 1 from public.zella_function_archive where migration = 'zella_retry_event_safe' and signature = s3)
     and md5(pg_get_functiondef(s3::regprocedure)) <> '94c6e7a74bd9068c3d1aa785ca69b18d' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s3;
  end if;
  drop function if exists public.zella_retry_event(uuid, text);
  for a in select signature, definition from public.zella_function_archive where migration = 'zella_retry_event_safe' loop
    execute a.definition;
  end loop;
  if to_regprocedure('public.zella_retry_event(uuid)') is not null then
    revoke all on function public.zella_retry_event(uuid) from public, anon;
    grant execute on function public.zella_retry_event(uuid) to authenticated, service_role;
  end if;
  delete from public.zella_function_archive where migration = 'zella_retry_event_safe';
end $$;
commit;
