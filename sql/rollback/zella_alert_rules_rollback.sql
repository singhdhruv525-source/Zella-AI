-- Undoes sql/zella_alert_rules.sql exactly: zella_platform_alert comes back from zella_function_archive (production's
-- body, same signature and grants), and the rule functions and platform_alert_rules (with every rule in it) are
-- removed. zella_platform_alert must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing
-- changes. Roll back sql/zella_alert_rules_email.sql first if it is applied (it needs the rules table). Safe to run twice.
begin;
do $$
declare a record; s constant text := 'public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_alert_rules') then
    return;   -- not applied, or already rolled back
  end if;
  if exists (select 1 from public.zella_function_archive where migration = 'zella_alert_rules_email') then
    raise exception 'ROLLBACK_ORDER: roll back sql/zella_alert_rules_email.sql first';
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> 'a4d850dbfe1be1b404f97623e8a63c8e' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_alert_rules' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_admin_alert_rule_save(text, jsonb, text);
  drop function if exists public.zella_admin_alert_rules();
  drop function if exists public.zella_alert_protected_kinds();
  drop table if exists public.platform_alert_rules;
  delete from public.zella_function_archive where migration = 'zella_alert_rules';
end $$;
commit;
