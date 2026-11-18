-- Undoes sql/zella_account_deletion.sql: the two job lists come back from zella_function_archive (only if undoing this
-- file's change gives back exactly the archived definition, otherwise ROLLBACK_DRIFT and nothing changes), businesses
-- this flow froze are unfrozen, and the new functions and business_deletion_requests are dropped (open requests are
-- lost; purged businesses stay purged). Safe to run twice.
begin;
do $$
declare a record; d text;
  undo constant jsonb := jsonb_build_object(
    'public.zella_run_scheduled_job(text)', jsonb_build_array($w$'zella_retention_auto_run', 'zella_business_deletion_purge_due') then$w$, $a$'zella_retention_auto_run') then$a$),
    'public.zella_run_schedule_group(text)', jsonb_build_array($w$'zella_retention_auto_run', 'zella_business_deletion_purge_due']$w$, $a$'zella_retention_auto_run']$a$));
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_account_deletion') then
    for a in select signature, definition from public.zella_function_archive where migration = 'zella_account_deletion' loop
      d := replace(pg_get_functiondef(a.signature::regprocedure), undo -> a.signature ->> 0, undo -> a.signature ->> 1);
      if d <> a.definition then raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature; end if;
    end loop;
    for a in select definition from public.zella_function_archive where migration = 'zella_account_deletion' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_account_deletion';
  end if;
  if to_regprocedure('public.zella_business_deletion_freeze_note()') is not null then
    update public.businesses set suspended_at = null, suspension_reason = null, updated_at = now() where suspension_reason = public.zella_business_deletion_freeze_note();
  end if;
end $$;
drop function if exists public.zella_business_deletion_purge_due();
drop function if exists public.zella_admin_business_deletion_requests();
drop function if exists public.zella_admin_business_deletion_confirm(uuid, text);
drop function if exists public.zella_business_deletion_cancel(uuid);
drop function if exists public.zella_business_deletion_request(uuid, text, text);
drop function if exists public.zella_business_deletion_status(uuid);
drop function if exists public.zella_business_deletion_freeze_note();
drop table if exists public.business_deletion_requests;
commit;
