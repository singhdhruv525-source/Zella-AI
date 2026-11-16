-- Rollback of sql/zella_retention_purge.sql: removes purge runs and their functions. Safe to run twice. Refuses
-- (ROLLBACK_DRIFT) if any function differs from that file's version, while the business purge migration uses these
-- tables, or once any run has been executed (the record of what was removed would be lost). Runs only asked for or
-- approved are removed with it. The audit trail stays in audit_logs.
begin;

do $$
declare
  f record;
  busy boolean := false;
    mine constant jsonb := '{
    "public.zella_retention_run_request(uuid,text,text)": "5b7a202c8301b7bc61b91027a0a4df21",
    "public.zella_retention_run_approve(uuid,uuid,text)": "eb2ce3685d80968db535e35930b93a93",
    "public.zella_retention_run_execute(uuid,uuid,text)": "09a572fd21245ac0be0d63ff5e5607dc",
    "public.zella_retention_run_files_done(uuid,uuid,text[],text)": "77d43f6e7b9907bf50f84584dc5471ac",
    "public.zella_retention_run_cancel(uuid,uuid,text)": "f7808954fe2da8c900c77f9c1827fb29",
    "public.zella_retention_runs(uuid,integer)": "a18b49a1b6d24526ab152d9f4d272f13"
  }';
begin
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since zella_retention_purge.sql', f.sig;
    end if;
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
              and p.prosrc like '%retention_purge_runs%' and not (mine ? ('public.' || p.oid::regprocedure::text))) then
    raise exception 'ROLLBACK_DRIFT: other functions use the purge runs; roll back sql/zella_business_purge.sql first';
  end if;
  if to_regclass('public.retention_purge_runs') is not null then
    execute 'select exists (select 1 from public.retention_purge_runs where executed_at is not null)' into busy;
  end if;
  if busy then raise exception 'ROLLBACK_DRIFT: a purge has run; the record of what it removed would be lost'; end if;
end $$;

drop function if exists public.zella_retention_runs(uuid, integer);
drop function if exists public.zella_retention_run_cancel(uuid, uuid, text);
drop function if exists public.zella_retention_run_files_done(uuid, uuid, text[], text);
drop function if exists public.zella_retention_run_execute(uuid, uuid, text);
drop function if exists public.zella_retention_run_approve(uuid, uuid, text);
drop function if exists public.zella_retention_run_request(uuid, text, text);
drop table if exists public.retention_purge_runs;

commit;
