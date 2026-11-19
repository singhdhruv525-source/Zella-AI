-- Undoes sql/zella_dispatch_response.sql exactly: zella_dispatch_n8n() comes back from zella_function_archive (the
-- production version), zella_admin_dispatch_responses goes, and the six answer columns are dropped from
-- n8n_dispatch_state (the other columns and their values stay). Open n8n_dispatch_refused alerts are left for an admin
-- to resolve. The function must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes.
-- Grants are kept (same signature). Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_dispatch_n8n()';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_dispatch_response') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '808738aa69ac598aa952842e41114608' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_dispatch_response' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_admin_dispatch_responses();
  alter table public.n8n_dispatch_state drop column if exists last_request_id, drop column if exists response_request_id,
    drop column if exists last_status_code, drop column if exists last_response_at, drop column if exists last_error,
    drop column if exists pending_request_ids;
  delete from public.zella_function_archive where migration = 'zella_dispatch_response';
end $$;
commit;
