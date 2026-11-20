-- Undoes sql/zella_admin_pause_sticky.sql exactly: the three admin functions come back from zella_function_archive, and the
-- guard trigger, its function and automations.paused_by_admin are dropped. Automations staff paused stay paused (their
-- status is not changed), but a manager can turn them back on again, as before. Each function must be exactly this
-- file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Grants are kept (same signatures).
-- Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object(
    'public.zella_admin_business_automations_pause(uuid,text)', '80fc3ae370fda10aab743a23aef4624d',
    'public.zella_admin_automation_set_status(uuid,text,text)',  'e9790abcd9bd30a51ef180caa0444739',
    'public.zella_admin_business_automations_resume(uuid,text)', 'f54e8b67f946cd489599224baa3364b9');
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_admin_pause_sticky') then
    for a in select signature, definition from public.zella_function_archive where migration = 'zella_admin_pause_sticky' loop
      if md5(pg_get_functiondef(a.signature::regprocedure)) <> mine ->> a.signature then
        raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
      end if;
    end loop;
    for a in select definition from public.zella_function_archive where migration = 'zella_admin_pause_sticky' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_admin_pause_sticky';
  end if;
end $$;
drop trigger if exists zella_automations_admin_pause_guard_trg on public.automations;
drop function if exists public.zella_automations_admin_pause_guard();
alter table public.automations drop column if exists paused_by_admin;
commit;
