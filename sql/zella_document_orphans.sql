-- Zella Voice: uploads to business-documents that were never confirmed can be found and removed
-- (docs/ADMIN_AUDIT_2026-11-16.md BIZ-18a).
-- A verification document is uploaded to a fresh path with a signed upload link before any row exists
-- (owner-provision-business onboarding.ts, and the owner onboarding function, which uses the same bucket and paths). If
-- the confirm step never runs, the object stays in the private bucket forever with nothing pointing at it.
-- Now, server only, following the record-files cleanup:
--   * zella_document_orphans(p_limit): claims and returns the names of business-documents objects older than 24 hours
--     with no business_verification_documents row for that path (any status: a replaced or rejected copy has a row and
--     is not an orphan; keeping or removing those is a retention question, BIZ-18b). Each claim is kept in
--     business_document_cleanup (server only) until its removal is recorded, so a run whose audit failed is listed
--     again next time and is never lost;
--   * a confirmation and a cleanup can't both win for one path: both take the same per path lock, the claim checks for
--     a confirmation row after taking it, and a new or moved confirmation row for a claimed path is refused
--     (FILE_REMOVED: upload it again);
--   * zella_document_orphans_removed(p_paths): after the storage delete succeeded, marks those claims removed and
--     records the run in the audit log (how many, which paths).
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
      ('public.zella_document_orphans(integer)', 'b686d9baf9d650c39508de8768ac72ae'),
      ('public.zella_document_orphans_removed(text[])', '890937d9544525d299545908d5bcbd4e'),
      ('public.zella_document_cleanup_guard()', 'd0ed54d88613d8b825a98bd773e842d7')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

-- One row per path a cleanup run claimed; removed_at is set once the delete is recorded. Server only.
create table if not exists public.business_document_cleanup (
  path text primary key check (length(path) between 3 and 500),
  claimed_at timestamptz not null default now(),
  removed_at timestamptz
);
alter table public.business_document_cleanup enable row level security;
revoke all on public.business_document_cleanup from public, anon, authenticated;
grant select on public.business_document_cleanup to service_role;

drop function if exists public.zella_document_orphans(integer);
CREATE OR REPLACE FUNCTION public.zella_document_orphans(p_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n integer := greatest(1, least(coalesce(p_limit, 500), 1000)); v_out text[]; r record;
begin
  -- claimed by an earlier run whose removal was never recorded: listed again first (deleting again is harmless)
  select coalesce(array_agg(path order by claimed_at, path), '{}') into v_out
    from (select path, claimed_at from public.business_document_cleanup where removed_at is null order by claimed_at, path limit v_n) x;
  for r in select o.name from storage.objects o
            where o.bucket_id = 'business-documents' and o.created_at < now() - interval '24 hours'
              and not exists (select 1 from public.business_verification_documents d where d.file_path = o.name)
              and not exists (select 1 from public.business_document_cleanup c where c.path = o.name)
            order by o.created_at limit greatest(v_n - cardinality(v_out), 0) loop
    -- the same lock a confirmation takes (zella_document_cleanup_guard); a path being confirmed right now is skipped
    continue when not pg_try_advisory_xact_lock(hashtext('business-document:' || r.name));
    continue when exists (select 1 from public.business_verification_documents d where d.file_path = r.name);
    insert into public.business_document_cleanup (path) values (r.name) on conflict (path) do nothing;
    v_out := v_out || r.name;
  end loop;
  return to_jsonb(v_out);
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_document_orphans_removed(p_paths text[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with done as (update public.business_document_cleanup set removed_at = now()
                 where path = any (coalesce(p_paths, '{}')) and removed_at is null returning path)
  insert into public.audit_logs (business_id, user_id, action, entity_type, new_data)
  select null, null, 'platform.document_orphans_removed', 'storage_object',
         jsonb_build_object('count', cardinality(p_paths), 'paths', to_jsonb(p_paths[1:100]), 'claims_closed', (select count(*) from done))
   where cardinality(coalesce(p_paths, '{}')) > 0
$function$;

-- A confirmation row for a path a cleanup run claimed is refused, under the same per path lock the claim takes, so a
-- confirmation and a cleanup can't both win for one file.
CREATE OR REPLACE FUNCTION public.zella_document_cleanup_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.file_path is not null and (tg_op = 'INSERT' or new.file_path is distinct from old.file_path) then
    perform pg_advisory_xact_lock(hashtext('business-document:' || new.file_path));
    if exists (select 1 from public.business_document_cleanup where path = new.file_path) then
      raise exception 'FILE_REMOVED: this upload was removed as never confirmed; upload the document again';
    end if;
  end if;
  return new;
end
$function$;
drop trigger if exists zella_document_cleanup_guard on public.business_verification_documents;
create trigger zella_document_cleanup_guard before insert or update of file_path on public.business_verification_documents
  for each row execute function public.zella_document_cleanup_guard();

revoke all on function public.zella_document_orphans(integer) from public, anon, authenticated;
revoke all on function public.zella_document_orphans_removed(text[]) from public, anon, authenticated;
revoke all on function public.zella_document_cleanup_guard() from public, anon, authenticated;
grant execute on function public.zella_document_orphans(integer) to service_role;
grant execute on function public.zella_document_orphans_removed(text[]) to service_role;

commit;
