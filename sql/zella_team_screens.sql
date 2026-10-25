-- Backend for the Team access and Security log screens.
-- Invitations and audit logs are read through owner/admin-only RPCs
-- (no table grants needed, nothing sensitive such as ip/user_agent is exposed).

create or replace function public.zella_list_invitations(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'email', email, 'name', owner_name, 'role', role, 'status', status,
      'invited_at', invited_at, 'expires_at', expires_at, 'last_error', last_error) order by invited_at desc)
    from public.business_invitations
    where business_id = p_business_id and status in ('pending','sent','failed','expired')), '[]'::jsonb);
end $$;

create or replace function public.zella_security_log(p_business_id uuid, p_limit integer default 100, p_before timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'action', action, 'entity_type', entity_type, 'at', created_at,
      'who', coalesce((select u.email from auth.users u where u.id = a.user_id), 'Zella')) order by created_at desc)
    from (select * from public.audit_logs
          where business_id = p_business_id and (p_before is null or created_at < p_before)
          order by created_at desc limit least(greatest(p_limit,1),200)) a), '[]'::jsonb);
end $$;

revoke execute on function public.zella_list_invitations(uuid) from public, anon;
revoke execute on function public.zella_security_log(uuid, integer, timestamptz) from public, anon;
grant execute on function public.zella_list_invitations(uuid) to authenticated, service_role;
grant execute on function public.zella_security_log(uuid, integer, timestamptz) to authenticated, service_role;
