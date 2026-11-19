-- Undoes sql/zella_job_intent.sql exactly: zella_admin_scheduler_health() comes back from zella_function_archive, and
-- zella_admin_job_intent_save is removed. The scheduled_job_intents table and every intent recorded in it (reason, who,
-- when) are kept (a rollback never deletes data; the table stays server only), and applying the file again keeps them. The
-- function must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Grants are kept
-- (same signature). cron.job is never touched. Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_admin_scheduler_health()';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_job_intent') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '494ea08eb56a1e8283a828c8e0a01926' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_job_intent' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_admin_job_intent_save(text, text, text);
  delete from public.zella_function_archive where migration = 'zella_job_intent';
end $$;
commit;
