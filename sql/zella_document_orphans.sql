-- Zella Voice: uploads to business-documents that were never confirmed can be found and removed
-- (docs/ADMIN_AUDIT_2026-11-16.md BIZ-18a).
-- A verification document is uploaded to a fresh path with a signed upload link before any row exists
-- (owner-provision-business onboarding.ts, and the owner onboarding function, which uses the same bucket and paths). If
-- the confirm step never runs, the object stays in the private bucket forever with nothing pointing at it.
-- Now, server only, following the record-files cleanup:
--   * zella_document_orphans(p_limit): names of business-documents objects older than 24 hours with no
--     business_verification_documents row for that path (any status: a replaced or rejected copy has a row and is not
--     an orphan; keeping or removing those is a retention question, BIZ-18b);
--   * zella_document_orphans_removed(p_paths): records a cleanup run in the audit log (how many, which paths).
-- The cleanup itself is the record-files function's server only "documents_cleanup" action, which deletes the listed
-- objects through the storage API. Nothing schedules it: running it on a timer is the owner's switch.
-- Nothing existing is replaced. Each new function must be absent or exactly this file's version, otherwise
-- VERSION_MISMATCH. Rollback: sql/rollback/zella_document_orphans_rollback.sql
begin;

do $$
declare f record;
begin
  if to_regclass('public.business_verification_documents') is null or to_regclass('storage.objects') is null or to_regclass('public.audit_logs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_document_orphans(integer)', '7370e94f2bca0d050f71fc3e47ec7023'),
      ('public.zella_document_orphans_removed(text[])', 'd10ffd0adc3d04a3cb2077334edd057b')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

CREATE OR REPLACE FUNCTION public.zella_document_orphans(p_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from (
    select o.name from storage.objects o
     where o.bucket_id = 'business-documents' and o.created_at < now() - interval '24 hours'
       and not exists (select 1 from public.business_verification_documents d where d.file_path = o.name)
     order by o.created_at
     limit greatest(1, least(coalesce(p_limit, 500), 1000))) x
$function$;

CREATE OR REPLACE FUNCTION public.zella_document_orphans_removed(p_paths text[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into public.audit_logs (business_id, user_id, action, entity_type, new_data)
  select null, null, 'platform.document_orphans_removed', 'storage_object',
         jsonb_build_object('count', cardinality(p_paths), 'paths', to_jsonb(p_paths[1:100]))
   where cardinality(coalesce(p_paths, '{}')) > 0
$function$;

revoke all on function public.zella_document_orphans(integer) from public, anon, authenticated;
revoke all on function public.zella_document_orphans_removed(text[]) from public, anon, authenticated;
grant execute on function public.zella_document_orphans(integer) to service_role;
grant execute on function public.zella_document_orphans_removed(text[]) to service_role;

commit;
