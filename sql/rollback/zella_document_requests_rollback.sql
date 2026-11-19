-- Undoes sql/zella_document_requests.sql exactly: drops zella_request_documents and zella_latest_audit_at. Audit rows and queued emails stay.
-- The function must be exactly that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier
-- owner-provision-business first (the new one falls back to its own steps without the function). Safe to run twice.
begin;
do $$
begin
  if to_regprocedure('public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)'))) <> '2d17e7456746cc5d9796f73806e6267f' then
    raise exception 'ROLLBACK_DRIFT: zella_request_documents has changed since this migration';
  end if;
  if to_regprocedure('public.zella_latest_audit_at(uuid[],text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_latest_audit_at(uuid[],text)'))) <> 'fe6dca53934f0c9b7483767a71099ed6' then
    raise exception 'ROLLBACK_DRIFT: zella_latest_audit_at has changed since this migration';
  end if;
end $$;
drop function if exists public.zella_request_documents(uuid, uuid, text[], integer, text, text, text, text);
drop function if exists public.zella_latest_audit_at(uuid[], text);
commit;
