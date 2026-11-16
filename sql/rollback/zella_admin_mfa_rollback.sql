-- Undoes sql/zella_admin_mfa.sql exactly: zella_mfa_satisfied() comes back from zella_function_archive. Safe to run twice.
begin;
do $$
declare a record;
begin
  if to_regclass('public.zella_function_archive') is not null then
    for a in select definition from public.zella_function_archive where migration = 'zella_admin_mfa' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_admin_mfa';
  end if;
end $$;
commit;
