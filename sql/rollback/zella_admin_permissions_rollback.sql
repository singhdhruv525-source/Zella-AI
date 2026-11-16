-- Undoes sql/zella_admin_permissions.sql exactly: every changed function comes back from zella_function_archive, the
-- incident read policy and the two audit triggers go. Audit rows already written stay (they are a record). Safe to run twice.
begin;
do $$
declare a record;
begin
  if to_regclass('public.zella_function_archive') is not null then
    for a in select signature, definition from public.zella_function_archive where migration = 'zella_admin_permissions' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_admin_permissions';
  end if;
end $$;
drop policy if exists platform_incidents_admin_view on public.platform_incidents;
drop trigger if exists zella_audit_admin_incident on public.platform_incidents;
drop trigger if exists zella_audit_admin_alert on public.platform_alerts;
drop function if exists public.zella_audit_admin_incident_trg();
drop function if exists public.zella_audit_admin_alert_trg();
commit;
