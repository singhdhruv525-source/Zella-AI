-- Zella Voice: an admin's changes to one business's members and owner invitation, each in one transaction
-- (docs/ADMIN_AUDIT_2026-11-16.md UI-06 part c, BIZ-21 part b; lane E review).
--   1. zella_admin_member_set_status(business, user, status, expected, seen_at): server only (owner-provision-business
--      member_set_status, which checks businesses.manage, the reason and audits). Deactivates or reactivates one
--      membership. It holds the business row while it works, so two such changes to one business run one at a time:
--      the "another active owner is left" check and the write can't interleave (LAST_OWNER). It refuses (STALE) when
--      the member's status isn't the one the page showed, or when the member's status was changed after the page
--      read it (a member.suspended or member.reactivated entry newer than seen_at).
--   2. zella_admin_invitation_cancel(business, invitation): server only (invitation_cancel). Revokes the owner
--      invitation the page showed (STALE when a newer one exists or it is no longer open; ACCEPTED when accepted) and
--      removes its invited owner seat in the same transaction, so a failure leaves both as they were.
-- Both are new. Each is checked first: it must be absent or exactly this file's version, with the owner this file
-- installs under and no EXECUTE for anyone but the server roles, otherwise the file stops with VERSION_MISMATCH.
-- Running the file twice changes nothing.
-- Rollback: sql/rollback/zella_business_member_admin_rollback.sql (drops both, refusing if either changed since).
begin;

do $$
declare f record;
begin
  if to_regclass('public.business_members') is null or to_regclass('public.business_invitations') is null
     or to_regclass('public.businesses') is null or to_regclass('public.audit_logs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamp with time zone)', 'b7eb91a80c9ae062798f8263f7ec15b0'),
      ('public.zella_admin_invitation_cancel(uuid,uuid)', 'e4df5c3f73d15ef138b68541201edbbe')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in a version this file was not written for', f.sig;
    end if;
    -- the owner this file installs under (the owner of public.business_members, as for every migration)
    if to_regprocedure(f.sig) is not null and (select proowner from pg_proc where oid = to_regprocedure(f.sig))
       <> (select relowner from pg_class where oid = 'public.business_members'::regclass) then
      raise exception 'VERSION_MISMATCH: % already exists with another owner', f.sig;
    end if;
  end loop;
  -- who may run them: their owner and the server roles only; EXECUTE for anyone else (PUBLIC included) is a change
  -- this file didn't make
  if exists (select 1 from (values
      ('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamp with time zone)'),
      ('public.zella_admin_invitation_cancel(uuid,uuid)')) v(sig)
      join pg_proc p on p.oid = to_regprocedure(v.sig)
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where a.privilege_type = 'EXECUTE' and (a.grantee = 0 or pg_get_userbyid(a.grantee) not in
        (pg_get_userbyid(p.proowner), 'service_role', 'postgres', 'supabase_admin'))) then
    raise exception 'VERSION_MISMATCH: a function of this file can be run by a role this file does not give it to';
  end if;
  -- and the grant this file makes is still there
  if exists (select 1 from (values
      ('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamp with time zone)'),
      ('public.zella_admin_invitation_cancel(uuid,uuid)')) v(sig)
      where to_regprocedure(v.sig) is not null and not has_function_privilege('service_role', to_regprocedure(v.sig), 'EXECUTE')) then
    raise exception 'VERSION_MISMATCH: a function of this file lost the grant this file gives it';
  end if;
end $$;

create or replace function public.zella_admin_member_set_status(p_business_id uuid, p_user_id uuid, p_status text,
  p_expected text, p_seen_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m record; n integer;
begin
  if p_status is null or p_status not in ('active', 'suspended') then raise exception 'BAD_INPUT'; end if;
  -- one change to this business's members at a time
  perform 1 from public.businesses where id = p_business_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select user_id, role, status into m from public.business_members
   where business_id = p_business_id and user_id = p_user_id for update;
  if not found then raise exception 'NOT_MEMBER'; end if;
  -- only from what the page showed
  if m.status is distinct from p_expected then raise exception 'STALE'; end if;
  if p_seen_at is not null and exists (select 1 from public.audit_logs a
       where a.business_id = p_business_id and a.action in ('member.suspended', 'member.reactivated')
         and a.created_at > p_seen_at and a.new_data ->> 'user_id' = p_user_id::text) then
    raise exception 'STALE';
  end if;
  if m.status = p_status then raise exception 'UNCHANGED'; end if;
  if p_status = 'active' and m.status <> 'suspended' then raise exception 'NOT_SUSPENDED'; end if;
  if p_status = 'suspended' and m.role = 'owner' and m.status = 'active' then
    select count(*) into n from public.business_members
     where business_id = p_business_id and role = 'owner' and status = 'active' and user_id <> p_user_id;
    if n = 0 then raise exception 'LAST_OWNER'; end if;
  end if;
  update public.business_members set status = p_status where business_id = p_business_id and user_id = p_user_id;
  return jsonb_build_object('role', m.role, 'before', m.status);
end $$;
revoke all on function public.zella_admin_member_set_status(uuid, uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.zella_admin_member_set_status(uuid, uuid, text, text, timestamptz) to service_role;

create or replace function public.zella_admin_invitation_cancel(p_business_id uuid, p_invitation_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare inv record; latest uuid; seats integer := 0;
begin
  select id, email, status, auth_user_id into inv from public.business_invitations
   where id = p_invitation_id and business_id = p_business_id and role = 'owner' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  -- only the invitation the page showed, while it is still the business's latest
  select id into latest from public.business_invitations
   where business_id = p_business_id and role = 'owner' and status <> 'revoked' order by created_at desc, id desc limit 1;
  if inv.status = 'accepted' then raise exception 'ACCEPTED'; end if;
  if latest is distinct from inv.id or inv.status not in ('pending', 'failed', 'expired', 'sent') then raise exception 'STALE'; end if;
  update public.business_invitations set status = 'revoked', updated_at = now() where id = inv.id;
  if inv.auth_user_id is not null then
    delete from public.business_members
     where business_id = p_business_id and user_id = inv.auth_user_id and role = 'owner' and status = 'invited';
    get diagnostics seats = row_count;
  end if;
  return jsonb_build_object('before', inv.status, 'seat_removed', seats > 0, 'email', inv.email);
end $$;
revoke all on function public.zella_admin_invitation_cancel(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_admin_invitation_cancel(uuid, uuid) to service_role;

commit;
