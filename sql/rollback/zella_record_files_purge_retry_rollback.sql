-- Rollback for sql/zella_record_files_purge_retry.sql: puts zella_record_file_cleanup back exactly as
-- sql/zella_record_files.sql defines it (removed and rejected files listed only while their storage object exists).
-- Deletes no data. Version-guarded; one transaction.
begin;
do $guard$ declare v text; begin
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_record_file_cleanup(integer)');
  if v is null or v not in ('8c843c6af7c172211c6f746dd9b514a5', 'b0c161cc8f0073090c0f244f149945e5') then
    raise exception 'VERSION_MISMATCH: public.zella_record_file_cleanup(integer) is not the version this rollback was written against';
  end if;
end $guard$;
create or replace function public.zella_record_file_cleanup(p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  -- uploads nobody finished within a day are let go
  update public.crm_record_files set status = 'removed', removed_at = now(), check_result = coalesce(check_result, 'abandoned')
   where status in ('pending', 'checking') and created_at < now() - interval '1 day';
  return coalesce((select jsonb_agg(path) from (
      select f.path from public.crm_record_files f
       where f.status in ('removed', 'rejected') and f.purged_at is null
         and exists (select 1 from storage.objects o where o.bucket_id = 'record-files' and o.name = f.path)
      union
      select o.name from storage.objects o
       where o.bucket_id = 'record-files' and o.created_at < now() - interval '1 day'
         and not exists (select 1 from public.crm_record_files f where f.path = o.name)
      limit greatest(1, least(coalesce(p_limit, 200), 1000))) x), '[]'::jsonb);
end $$;
commit;
