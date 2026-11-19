-- Undoes sql/zella_document_orphans.sql: drops zella_document_orphans, zella_document_orphans_removed, the
-- confirmation guard and its trigger, and business_document_cleanup when it is empty (its claims are kept otherwise).
-- Nothing else was changed. Objects already removed stay removed (they had no row), and the audit rows stay. Each
-- function must be exactly that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier
-- record-files function first, or its documents_cleanup action answers try_again. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_document_orphans(integer)', 'b686d9baf9d650c39508de8768ac72ae'),
      ('public.zella_document_orphans_removed(text[])', '890937d9544525d299545908d5bcbd4e'),
      ('public.zella_document_cleanup_guard()', 'd0ed54d88613d8b825a98bd773e842d7')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
end $$;
drop function if exists public.zella_document_orphans(integer);
drop function if exists public.zella_document_orphans_removed(text[]);
drop trigger if exists zella_document_cleanup_guard on public.business_verification_documents;
drop function if exists public.zella_document_cleanup_guard();
do $$ begin
  if to_regclass('public.business_document_cleanup') is not null and not exists (select 1 from public.business_document_cleanup) then
    drop table public.business_document_cleanup;
  end if;
end $$;
commit;
