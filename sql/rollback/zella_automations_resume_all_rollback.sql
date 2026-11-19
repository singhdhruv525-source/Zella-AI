-- Undoes sql/zella_automations_resume_all.sql exactly: zella_admin_business_automations_pause comes back from
-- zella_function_archive, and the resume function, the trigger and automations.bulk_paused_at are removed (paused
-- automations stay paused). The pause function must be exactly this file's version first, otherwise ROLLBACK_DRIFT and
-- nothing changes. Grants are kept (same signature). Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_admin_business_automations_pause(uuid,text)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_automations_resume_all') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> 'ff8907607f62387511208ac1ae03ce70' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_automations_resume_all' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_admin_business_automations_resume(uuid, text);
  drop trigger if exists zella_automation_bulk_mark on public.automations;
  drop function if exists public.zella_automation_bulk_mark_trg();
  alter table public.automations drop column if exists bulk_paused_at;
  delete from public.zella_function_archive where migration = 'zella_automations_resume_all';
end $$;
commit;
