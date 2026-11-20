-- Undoes sql/zella_admin_templates_manage.sql exactly: zella_admin_template_save comes back from zella_function_archive
-- (its old, case sensitive script guard), and zella_admin_template_create and _retire are dropped. Templates already
-- created or retired keep their status, and their audit rows stay. Each function must be exactly that file's version,
-- otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier web app first. Safe to run twice.
begin;
do $$
declare a record; f record;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_admin_templates_manage') then
    return;   -- not applied, or already rolled back
  end if;
  for f in select * from (values
      ('public.zella_admin_template_save(uuid,text,text,text)', 'f450f6f47333d8198151ae5c5d33523c'),
      ('public.zella_admin_template_create(text,text,uuid,text,text,text,text)', 'f28fd02113f908cd6f5fee54f274ca19'),
      ('public.zella_admin_template_retire(uuid,text)', '22bbf6bbbb86b0d57932599e220f9171')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
  for a in select definition from public.zella_function_archive where migration = 'zella_admin_templates_manage' loop
    execute a.definition;
  end loop;
  drop function if exists public.zella_admin_template_create(text, text, uuid, text, text, text, text);
  drop function if exists public.zella_admin_template_retire(uuid, text);
  delete from public.zella_function_archive where migration = 'zella_admin_templates_manage';
end $$;
commit;
