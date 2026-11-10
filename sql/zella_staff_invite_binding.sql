-- Zella - team invitations are tied to one account (2026-10-26). Safe to re-run.
--
-- Purpose
--   zella_accept_staff_invitations() let any signed-in account whose email matched a pending invitation join the
--   business. With public sign-up on and email confirmation off, a stranger could register that email address
--   first and take the place. Invitations made in the business app were also never emailed.
--   Now the staff-invite edge function sends the email and records which account it went to (auth_user_id), and
--   only that account can accept. Invitations that were never sent wait until someone presses "Send again".
--
-- Needs: zella_staff_invites_approvals.sql, the staff-invite edge function deployed.
--
-- Authorization implications
--   Accepting needs auth_user_id = the signed-in user. Owner invitations (role 'owner') keep using
--   zella_accept_my_invitations(), which already matches on the user id.
--
-- Rollback: re-run the zella_accept_staff_invitations definition in zella_staff_invites_approvals.sql.
--
-- Validation (rolled back): as a user with a sent invitation, select public.zella_accept_staff_invitations();  -> 1
--   as a different user with the same email in a pending invitation that has no auth_user_id                -> 0

create or replace function public.zella_accept_staff_invitations() returns integer
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); i record; n integer := 0;
begin
  if v_user is null then raise exception 'NOT_SIGNED_IN'; end if;
  for i in select * from public.business_invitations
            where auth_user_id = v_user and status in ('pending', 'sent') and role <> 'owner'
              and (expires_at is null or expires_at > now()) for update loop
    if exists (select 1 from public.businesses where id = i.business_id and cancelled_at is not null) then continue; end if;
    insert into public.business_members (business_id, user_id, role, status) values (i.business_id, v_user, i.role, 'active')
    on conflict do nothing;
    update public.business_invitations set status = 'accepted', accepted_at = now(), updated_at = now() where id = i.id;
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (i.business_id, v_user, 'invitation.accepted', 'business_invitation', i.id, jsonb_build_object('email', i.email, 'role', i.role));
    if i.invited_by is not null then
      perform public.zella_notify(i.business_id, 'staff_joined', i.owner_name || ' joined your team', 'They signed in as ' || i.role || '.', 'info', 'settings', null, i.invited_by);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_accept_staff_invitations() from public, anon;
grant execute on function public.zella_accept_staff_invitations() to authenticated, service_role;
