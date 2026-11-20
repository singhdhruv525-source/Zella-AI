-- Rollback of sql/zella_retention_purge.sql: removes the purge run functions. The retention_purge_runs table and every
-- run in it are kept (a rollback never deletes data; the table stays server only) and applying the file again uses
-- them. Safe to run twice. Refuses (ROLLBACK_DRIFT) if any function differs from that file's version, while the
-- business purge migration uses these tables, or once any run has been executed. The table is locked against writes
-- first, so a run can't start between the check and the removal. The audit trail stays in audit_logs.
begin;

do $$
declare
  f record;
  busy boolean := false;
    mine constant jsonb := '{
    "public.zella_retention_run_request(uuid,text,text)": "5b7a202c8301b7bc61b91027a0a4df21",
    "public.zella_retention_run_approve(uuid,uuid,text)": "eb2ce3685d80968db535e35930b93a93",
    "public.zella_retention_run_execute(uuid,uuid,text)": "ba48c56b8077b51afb6e7b17f6150fd4",
    "public.zella_retention_run_files_done(uuid,uuid,text[],text)": "238c9507f4c3c93b17b3e9cada94b459",
    "public.zella_retention_run_cancel(uuid,uuid,text)": "f7808954fe2da8c900c77f9c1827fb29",
    "public.zella_retention_runs(uuid,integer)": "64a8d562f80cdf654e0cc185804c58ac",
    "public.zella_retention_run_files_resume(uuid,uuid)": "b52344801014c6525f10d7b47965ebe5"
  }';
begin
  if to_regclass('public.retention_purge_runs') is not null then
    execute 'lock table public.retention_purge_runs in share row exclusive mode';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since zella_retention_purge.sql', f.sig;
    end if;
  end loop;
  if to_regclass('public.retention_purge_runs') is not null then
    execute 'select exists (select 1 from public.retention_purge_runs where executed_at is not null)' into busy;
  end if;
  if busy then raise exception 'ROLLBACK_DRIFT: a purge has run; its record stays, but nothing could list it or finish its files'; end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
              and p.prosrc like '%retention_purge_runs%'
              -- the legal hold check in zella_data_retention.sql reads the runs only when the table exists (to_regclass)
              and p.oid is distinct from to_regprocedure('public.zella_legal_hold_place(uuid,uuid,text)')::oid
              and not (p.oid = any (array(select to_regprocedure(k)::oid from jsonb_object_keys(mine) k where to_regprocedure(k) is not null)))) then
    raise exception 'ROLLBACK_DRIFT: other functions use the purge runs; roll back sql/zella_business_purge.sql first';
  end if;
end $$;

drop function if exists public.zella_retention_run_files_resume(uuid, uuid);
drop function if exists public.zella_retention_runs(uuid, integer);
drop function if exists public.zella_retention_run_cancel(uuid, uuid, text);
drop function if exists public.zella_retention_run_files_done(uuid, uuid, text[], text);
drop function if exists public.zella_retention_run_execute(uuid, uuid, text);
drop function if exists public.zella_retention_run_approve(uuid, uuid, text);
drop function if exists public.zella_retention_run_request(uuid, text, text);

commit;
