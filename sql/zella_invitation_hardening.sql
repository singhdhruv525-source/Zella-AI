-- Zella - team invitations: atomic state changes and proof of email ownership (2026-11-04). Safe to re-run.
--
-- Needs: zella_staff_invites_approvals.sql, zella_staff_invite_binding.sql. Deploy order: this file, then the
-- staff-invite edge function (it calls the functions below), then the web app.
--
-- 1. Race with cancellation. staff-invite used to read the invitation, call Supabase Auth (seconds), then set
--    status = 'sent' by id alone, and on any error set status = 'failed' by id alone. A cancellation (or an
--    acceptance) in between was overwritten and the invitation reopened. Now the edge function finishes through
--    zella_staff_invite_finalize / zella_staff_invite_fail, which lock the row and change it only from an open
--    state, re-checking the inviter's role, the invitation's expiry and the business at that moment.
--
-- 2. Email ownership. Binding used to trust "the account has signed in before" (last_sign_in_at). With email
--    confirmation off, anyone can create an account for someone else's address and sign in, so the invitation
--    could be bound to a stranger. Whether confirmation is on in production can't be assumed, so acceptance now
--    needs proof made in the current session: the person signed in with a link or code sent to that address
--    (JWT amr method otp, magiclink, invite, recovery, email/signup or email_change). A password-only session
--    can't accept; the app tells the person to open the invitation email. The account's email must also still
--    equal the invited address.
--
-- 3. Removed members. Re-inviting someone whose membership was suspended used to leave them suspended while the
--    invitation said "accepted"; acceptance now reactivates the membership with the invited role.
-- 4. Expired invitations are marked 'expired' when their person signs in, instead of staying "sent" forever.
--
-- Authorization: finalize/fail are service-role only; acceptance acts on the signed-in user's own invitations.
-- Rollback: re-run zella_staff_invite_binding.sql (acceptance) and redeploy the previous staff-invite function.

-- The current session proved control of the account's email address (see 2 above).
create or replace function public.zella_session_proved_email() returns boolean
language sql stable set search_path = '' as $$
  select coalesce((select bool_or(m ->> 'method' in ('otp', 'magiclink', 'invite', 'recovery', 'email/signup', 'email_change'))
                     from jsonb_array_elements(case when jsonb_typeof(auth.jwt() -> 'amr') = 'array' then auth.jwt() -> 'amr' else '[]'::jsonb end) m), false);
$$;
revoke execute on function public.zella_session_proved_email() from public, anon;
grant execute on function public.zella_session_proved_email() to authenticated, service_role;

-- Called by staff-invite after the email went out. Changes the invitation only if it is still open, the inviter
-- may still invite this role, it hasn't expired, the business is open, and the target account has the invited
-- address. Returns 'sent' or a reason: NOT_FOUND, CLOSED, EXPIRED, NOT_ALLOWED, BUSINESS_CLOSED, EMAIL_MISMATCH,
-- ALREADY_MEMBER.
create or replace function public.zella_staff_invite_finalize(p_invitation_id uuid, p_actor uuid, p_auth_user_id uuid, p_existing_account boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare i public.business_invitations; v_actor_role text; v_email text;
begin
  select * into i from public.business_invitations where id = p_invitation_id for update;
  if not found then return 'NOT_FOUND'; end if;
  if i.status not in ('pending', 'sent', 'failed') then return 'CLOSED'; end if;
  if i.expires_at is not null and i.expires_at <= now() then return 'EXPIRED'; end if;
  select m.role into v_actor_role from public.business_members m
   where m.business_id = i.business_id and m.user_id = p_actor and m.status = 'active';
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') or i.role = 'owner'
     or (i.role = 'admin' and v_actor_role <> 'owner') then return 'NOT_ALLOWED'; end if;
  if exists (select 1 from public.businesses b where b.id = i.business_id and b.cancelled_at is not null) then return 'BUSINESS_CLOSED'; end if;
  select lower(u.email) into v_email from auth.users u where u.id = p_auth_user_id;
  if v_email is null or v_email <> lower(i.email) then return 'EMAIL_MISMATCH'; end if;
  if exists (select 1 from public.business_members m where m.business_id = i.business_id and m.user_id = p_auth_user_id and m.status = 'active') then
    return 'ALREADY_MEMBER';
  end if;
  update public.business_invitations set status = 'sent', auth_user_id = p_auth_user_id, last_error = null, updated_at = now() where id = i.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (i.business_id, p_actor, 'staff_invitation.sent', 'business_invitation', i.id,
          jsonb_build_object('email', lower(i.email), 'role', i.role, 'existing_account', coalesce(p_existing_account, false)));
  return 'sent';
end $$;
revoke execute on function public.zella_staff_invite_finalize(uuid, uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.zella_staff_invite_finalize(uuid, uuid, uuid, boolean) to service_role;

-- Called by staff-invite when sending failed. Only an open invitation becomes 'failed': a cancelled or accepted one
-- is never reopened by a late error. Returns 'failed' or 'CLOSED'.
create or replace function public.zella_staff_invite_fail(p_invitation_id uuid, p_error text) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.business_invitations set status = 'failed', last_error = left(coalesce(p_error, ''), 300), updated_at = now()
   where id = p_invitation_id and status in ('pending', 'sent', 'failed');
  return case when found then 'failed' else 'CLOSED' end;
end $$;
revoke execute on function public.zella_staff_invite_fail(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_staff_invite_fail(uuid, text) to service_role;

-- The signed-in person's team invitations: accepts what may be accepted and says what is waiting.
-- { accepted, needs_email_link, expired, errors }  (errors: invitations that could not be applied, with a reason)
create or replace function public.zella_accept_staff_invitations_v2() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid(); v_email text; v_proved boolean := public.zella_session_proved_email();
  i record; n_ok integer := 0; n_wait integer := 0; n_exp integer := 0; v_errors jsonb := '[]'::jsonb;
begin
  if v_user is null then raise exception 'NOT_SIGNED_IN'; end if;
  select lower(u.email) into v_email from auth.users u where u.id = v_user;

  -- invitations that ran out while waiting are closed, so the inviter sees "expired" and can send again
  with x as (
    update public.business_invitations set status = 'expired', updated_at = now()
     where auth_user_id = v_user and status in ('pending', 'sent') and role <> 'owner' and expires_at is not null and expires_at <= now()
    returning 1)
  select count(*) into n_exp from x;

  for i in select * from public.business_invitations
            where auth_user_id = v_user and status in ('pending', 'sent') and role <> 'owner'
              and (expires_at is null or expires_at > now())
            order by created_at for update loop
    if v_email is null or v_email <> lower(i.email) then
      v_errors := v_errors || jsonb_build_object('invitation_id', i.id, 'reason', 'EMAIL_CHANGED');
      continue;
    end if;
    if exists (select 1 from public.businesses where id = i.business_id and cancelled_at is not null) then
      v_errors := v_errors || jsonb_build_object('invitation_id', i.id, 'reason', 'BUSINESS_CLOSED');
      continue;
    end if;
    if not v_proved then n_wait := n_wait + 1; continue; end if;

    begin
      insert into public.business_members (business_id, user_id, role, status) values (i.business_id, v_user, i.role, 'active')
      on conflict (business_id, user_id) do update set status = 'active', role = excluded.role
        where public.business_members.status <> 'active';   -- a removed member comes back with the invited role
      update public.business_invitations set status = 'accepted', accepted_at = now(), updated_at = now() where id = i.id;
      insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
      values (i.business_id, v_user, 'invitation.accepted', 'business_invitation', i.id, jsonb_build_object('email', i.email, 'role', i.role));
      if i.invited_by is not null then
        perform public.zella_notify(i.business_id, 'staff_joined', i.owner_name || ' joined your team', 'They signed in as ' || i.role || '.', 'info', 'settings', null, i.invited_by);
      end if;
      n_ok := n_ok + 1;
    exception when others then
      -- e.g. the team is full (zella_team_capacity_trg): this invitation stays open, the others still apply
      v_errors := v_errors || jsonb_build_object('invitation_id', i.id, 'reason', left(sqlerrm, 120));
    end;
  end loop;
  -- owner seats waiting on the same proof (zella_accept_my_invitations activates them) are reported too
  if not v_proved then
    n_wait := n_wait + (select count(*) from public.business_members m join public.businesses b on b.id = m.business_id
                         where m.user_id = v_user and m.status = 'invited' and b.cancelled_at is null);
  end if;
  return jsonb_build_object('accepted', n_ok, 'needs_email_link', n_wait, 'expired', n_exp, 'errors', v_errors);
end $$;
revoke execute on function public.zella_accept_staff_invitations_v2() from public, anon;
grant execute on function public.zella_accept_staff_invitations_v2() to authenticated, service_role;

-- The old entry point keeps working for anything still calling it.
create or replace function public.zella_accept_staff_invitations() returns integer
language sql security definer set search_path = public as $$
  select (public.zella_accept_staff_invitations_v2() ->> 'accepted')::integer;
$$;
revoke execute on function public.zella_accept_staff_invitations() from public, anon;
grant execute on function public.zella_accept_staff_invitations() to authenticated, service_role;

-- Owner seats (2026-11-04). zella_accept_my_invitations turned every 'invited' owner membership of the caller into an
-- active one for ANY session: a password sign-in on an account whose address was never proved, and with no expiry
-- check. Now it needs the same proof as team invitations (a session from an email link at the invited address), an
-- open, unexpired owner invitation at the account's current address when one exists, and an open business.
create or replace function public.zella_accept_my_invitations() returns integer
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_email text; v_count integer;
begin
  if v_user is null then raise exception 'NOT_SIGNED_IN'; end if;
  if not public.zella_session_proved_email() then return 0; end if;   -- reported as needs_email_link by _v2
  select lower(u.email) into v_email from auth.users u where u.id = v_user;

  with activated as (
    update business_members m set status = 'active'
      from businesses b
     where m.business_id = b.id and m.user_id = v_user and m.status = 'invited' and b.cancelled_at is null
       -- if the seat came from an owner invitation, one must still be open, unexpired and for this address
       and (not exists (select 1 from business_invitations i where i.business_id = m.business_id and i.auth_user_id = v_user and i.role = 'owner')
            or exists (select 1 from business_invitations i where i.business_id = m.business_id and i.auth_user_id = v_user and i.role = 'owner'
                         and i.status in ('pending', 'sent') and (i.expires_at is null or i.expires_at > now()) and lower(i.email) = v_email))
    returning m.business_id),
  accepted as (
    update business_invitations i set status = 'accepted', accepted_at = now(), updated_at = now()
     where i.auth_user_id = v_user and i.status in ('pending', 'sent') and i.business_id in (select business_id from activated)
    returning i.business_id, i.email),
  logged as (
    insert into audit_logs (user_id, action, business_id, entity_type, new_data)
    select v_user, 'invitation.accepted', a.business_id, 'business_invitation', jsonb_build_object('email', a.email) from accepted a
    returning 1)
  select count(*) into v_count from activated;
  return v_count;
end $$;
revoke execute on function public.zella_accept_my_invitations() from public, anon;
grant execute on function public.zella_accept_my_invitations() to authenticated, service_role;

-- Platform admins (2026-11-04). owner-provision-business (adminInvite) granted admin straight to an existing account
-- that had signed in, without checking that the account ever proved its address. Enforced here so every path is
-- covered: admin access is granted (or reactivated) only to an account that confirmed its email, or to one that was
-- just invited and has never signed in (it can only be used through the invitation link, which proves the address).
create or replace function public.zella_platform_admin_email_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare u record;
begin
  if not new.is_active then return new; end if;
  if tg_op = 'UPDATE' and old.is_active and old.user_id = new.user_id then return new; end if;   -- unchanged grant
  select email_confirmed_at, last_sign_in_at into u from auth.users where id = new.user_id;
  if not found then raise exception 'ADMIN_ACCOUNT_NOT_FOUND' using errcode = '23503'; end if;
  if u.email_confirmed_at is null and u.last_sign_in_at is not null then
    raise exception 'ADMIN_EMAIL_NOT_CONFIRMED' using errcode = '42501',
      hint = 'This account''s email address was never confirmed, so it can''t be made an admin.';
  end if;
  return new;
end $$;
revoke execute on function public.zella_platform_admin_email_check() from public, anon, authenticated;
drop trigger if exists zella_platform_admin_email_check on public.platform_admins;
create trigger zella_platform_admin_email_check before insert or update of is_active, user_id on public.platform_admins
  for each row execute function public.zella_platform_admin_email_check();
