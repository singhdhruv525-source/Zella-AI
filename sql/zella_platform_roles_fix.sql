-- Restricted platform roles (2026-11-04 review). zella_settings_system.sql added five restricted roles
-- (platform_operations, billing_admin, support_admin, security_admin, read_only_admin) with a permission matrix
-- (platform_role_permissions, zella_admin_can) that the admin dashboard offers and owner-provision-business enforces.
-- An older trigger, zella_platform_admin_trigger (zella_workflows.sql), still refuses every role except super_admin and
-- zella_owner, so inviting or changing anyone to a restricted role fails with INVALID_ADMIN_ROLE (live as of 2026-11-04).
--
-- After this, the trigger accepts exactly the roles the table's check constraint allows. Nothing else changes:
--   is_platform_admin() stays true only for zella_owner and super_admin, so restricted roles get no direct database
--   tools; zella_admin_can() gives them only what the matrix lists; making someone zella_owner still needs a zella_owner
--   (owner-provision-business, admins.manage). Safe to run twice. Needs the owner's approval before it is applied.
create or replace function public.zella_platform_admin_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    if new.role not in ('zella_owner', 'super_admin', 'platform_operations', 'billing_admin', 'support_admin', 'security_admin', 'read_only_admin') then
      raise exception 'INVALID_ADMIN_ROLE';
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.zella_platform_admin_trigger() from public, anon, authenticated;
