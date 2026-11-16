-- Undoes sql/zella_document_orphans.sql exactly: drops zella_document_orphans and zella_document_orphans_removed.
-- Nothing else was changed. Objects already removed stay removed (they had no row), and the audit rows stay. Each
-- function must be exactly that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier
-- record-files function first, or its documents_cleanup action answers try_again. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_document_orphans(integer)', '7370e94f2bca0d050f71fc3e47ec7023'),
      ('public.zella_document_orphans_removed(text[])', 'd10ffd0adc3d04a3cb2077334edd057b')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
end $$;
drop function if exists public.zella_document_orphans(integer);
drop function if exists public.zella_document_orphans_removed(text[]);
commit;
