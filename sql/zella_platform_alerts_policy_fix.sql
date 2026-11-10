-- Admin alerts bell (2026-11-04 review). The read policy on platform_alerts looked platform_admins up directly, but
-- signed-in users have no SELECT grant on platform_admins (correctly: who is an admin is not public), so every read
-- of platform_alerts failed with "permission denied for table platform_admins" and the bell in the admin dashboard
-- never loaded. Reproduced read-only on production 2026-11-04 (rolled back).
-- The policy now asks zella_admin_role() (security definer, returns the caller's own active platform role), so any
-- active platform admin can read alerts, as the bell intends, without being able to read platform_admins itself.
-- Safe to run twice. Needs the owner's approval before it is applied.
drop policy if exists platform_alerts_admin_select on public.platform_alerts;
create policy platform_alerts_admin_select on public.platform_alerts for select to authenticated
  using ((select public.zella_admin_role()) is not null);
