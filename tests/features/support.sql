-- Staging only: production helpers the voice-reliability staging copy (zvoice) doesn't include. Bodies match
-- production (md5 of prosrc checked 2026-10-28).
create or replace function public.zella_can_manage(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'admin', 'manager'));
$$;
revoke all on function public.zella_can_manage(uuid) from public, anon;
grant execute on function public.zella_can_manage(uuid) to authenticated, service_role;
