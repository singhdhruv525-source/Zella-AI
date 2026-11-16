-- Undoes sql/zella_alert_rules_email.sql exactly: zella_claim_admin_alert_email comes back from zella_function_archive
-- (production's body, same signature and grants) and zella_alert_quiet_now goes. It must be exactly this file's version
-- first, otherwise ROLLBACK_DRIFT and nothing changes. Alerts already marked bell only keep that mark. Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_claim_admin_alert_email(integer)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_alert_rules_email') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '098de63ccdfe5d723ce9d20ea8b1b801' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_alert_rules_email' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_alert_quiet_now(time, time, text);
  delete from public.zella_function_archive where migration = 'zella_alert_rules_email';
end $$;
commit;
