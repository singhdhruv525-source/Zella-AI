-- Undoes sql/zella_account_deletion.sql: the two job lists come back from zella_function_archive (only if undoing this
-- file's change gives back exactly the archived definition, otherwise ROLLBACK_DRIFT and nothing changes), businesses
-- this flow froze are unfrozen, and the new functions are dropped. business_deletion_requests and its rows stay (the
-- owners' requests and the record of every purge are never deleted; applying the file again reuses them). Safe to run twice.
begin;
do $$
declare a record; d text;
  undo constant jsonb := jsonb_build_object(
    'public.zella_run_scheduled_job(text)', jsonb_build_array($w$  if p_job not in ('zella_retention_auto_run', 'zella_business_deletion_purge_due', '$w$, $a$  if p_job not in ('zella_retention_auto_run', '$a$),
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
  if to_regprocedure('public.zella_business_deletion_freeze_note()') is not null and to_regclass('public.business_deletion_requests') is not null then
    update public.businesses b set suspended_at = null, suspension_reason = null, updated_at = now()
      from public.business_deletion_requests r
     where r.business_id = b.id and r.froze_business and r.status in ('confirmed', 'blocked')
       and b.suspension_reason = public.zella_business_deletion_freeze_note();
  end if;
end $$;
drop function if exists public.zella_business_deletion_purge_due();
drop function if exists public.zella_admin_business_deletion_requests();
drop function if exists public.zella_admin_business_deletion_confirm(uuid, text);
drop function if exists public.zella_business_deletion_cancel(uuid);
drop function if exists public.zella_business_deletion_request(uuid, text, text);
drop function if exists public.zella_business_deletion_status(uuid);
drop function if exists public.zella_business_deletion_freeze_note();
commit;
