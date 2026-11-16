-- Undoes sql/zella_draft_delete.sql exactly: zella_audit_privileged comes back from zella_function_archive and
-- zella_delete_draft_business is dropped. The audit foreign key was never changed. Deletion entries already written
-- (business_id null) stay.
-- Every changed object must be exactly that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the
-- earlier owner-provision-business first: the new one calls zella_delete_draft_business. Safe to run twice.
begin;
do $$
declare a record;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_draft_delete') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) <> '8f2909322446a24d4880c17a0bab98b9' then
    raise exception 'ROLLBACK_DRIFT: public.zella_audit_privileged() has changed since this migration';
  end if;
  if to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)'))) <> '7ba145a2acc689841606dc41a64c7fab' then
    raise exception 'ROLLBACK_DRIFT: public.zella_delete_draft_business has changed since this migration';
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_draft_delete' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_delete_draft_business(uuid, uuid, text, text);
  delete from public.zella_function_archive where migration = 'zella_draft_delete';
end $$;
commit;
