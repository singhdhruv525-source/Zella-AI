-- Undoes sql/zella_draft_delete.sql exactly: zella_audit_privileged comes back from zella_function_archive,
-- zella_delete_draft_business is dropped and audit_logs.business_id goes back to ON DELETE CASCADE. Audit rows of
-- businesses already deleted keep business_id null (a deleted business can't come back) and stay.
-- Every changed object must be exactly that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the
-- earlier owner-provision-business first: the new one calls zella_delete_draft_business. Safe to run twice.
begin;
do $$
declare a record; t text;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_draft_delete') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) <> '8f2909322446a24d4880c17a0bab98b9' then
    raise exception 'ROLLBACK_DRIFT: public.zella_audit_privileged() has changed since this migration';
  end if;
  if to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)'))) <> 'f41314ca882166483c8e1d8f8cbc6bae' then
    raise exception 'ROLLBACK_DRIFT: public.zella_delete_draft_business has changed since this migration';
  end if;
  select pg_get_constraintdef(oid) into t from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey';
  if t is null or t not in ('FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE SET NULL',
                            'FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE SET NULL NOT VALID') then
    raise exception 'ROLLBACK_DRIFT: audit_logs_business_id_fkey has changed since this migration';
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_draft_delete' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_delete_draft_business(uuid, uuid, text, text);
  alter table public.audit_logs drop constraint audit_logs_business_id_fkey;
  alter table public.audit_logs add constraint audit_logs_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade not valid;
  delete from public.zella_function_archive where migration = 'zella_draft_delete';
end $$;
commit;

-- After the commit, as in the file: check the rows already there without blocking audit writes. Safe to run again.
alter table public.audit_logs validate constraint audit_logs_business_id_fkey;
