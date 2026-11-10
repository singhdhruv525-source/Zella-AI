-- Restricted platform roles: can be stored after zella_platform_roles_fix.sql, and grant only their matrix.
\set ON_ERROR_STOP on
begin;
-- the live matrix (same rows as zella_settings_system.sql, checked against production 2026-11-04)
insert into public.platform_role_permissions (role, permission) values
  ('platform_operations', 'businesses.view'), ('platform_operations', 'businesses.manage'), ('platform_operations', 'integrations.manage'),
  ('platform_operations', 'telephony.manage'), ('platform_operations', 'ai.configure'), ('platform_operations', 'support.manage'),
  ('platform_operations', 'analytics.view'), ('platform_operations', 'comms.manage'),
  ('billing_admin', 'businesses.view'), ('billing_admin', 'billing.view'), ('billing_admin', 'billing.manage'), ('billing_admin', 'plans.manage'),
  ('billing_admin', 'analytics.view'),
  ('support_admin', 'businesses.view'), ('support_admin', 'support.manage'), ('support_admin', 'analytics.view'),
  ('security_admin', 'businesses.view'), ('security_admin', 'security.view'), ('security_admin', 'security.manage'), ('security_admin', 'audit.view'),
  ('read_only_admin', 'businesses.view'), ('read_only_admin', 'billing.view'), ('read_only_admin', 'security.view'), ('read_only_admin', 'audit.view'),
  ('read_only_admin', 'analytics.view')
on conflict do nothing;
insert into auth.users (id, email, email_confirmed_at) values ('e0000000-0000-0000-0000-000000000001', 'ro@zella.test', now());
insert into public.platform_admins (user_id, role) values ('e0000000-0000-0000-0000-000000000001', 'read_only_admin');
do $$ begin
  begin insert into public.platform_admins (user_id, role) values ('e0000000-0000-0000-0000-000000000001', 'made_up_role');
        raise exception 'unknown role was accepted';
  exception when others then if sqlerrm not like '%INVALID_ADMIN_ROLE%' and sqlerrm not like '%platform_admins_role_check%' then raise; end if; end;
end $$;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert public.zella_admin_role() = 'read_only_admin', 'role stored';
  assert not public.is_platform_admin(), 'read-only admin must not get full platform admin';
  assert public.zella_admin_can('businesses.view'), 'matrix permission granted';
  assert not public.zella_admin_can('businesses.manage'), 'permission outside the matrix refused';
  assert not public.zella_admin_can('admins.manage'), 'cannot manage admins';
end $$;
select 'PASS restricted platform roles can be stored; read-only admin gets its matrix only, not is_platform_admin';
rollback;
