-- Regression tests for sql/zella_invitation_hardening.sql, on a restored baseline (tests/security/run.sh).
-- Each block prints PASS <name> or stops with an error. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- act as a signed-in user (or service role when p_user is null); amr = how this session signed in
create or replace function pg_temp.act(p_user uuid, p_amr text default 'password') returns void language plpgsql as $$
begin
  if p_user is null then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', false);
    reset role;
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1',
      'amr', json_build_array(json_build_object('method', p_amr, 'timestamp', extract(epoch from now())::bigint)))::text, false);
    set role authenticated;
  end if;
end $$;

-- fixture: a business with an owner and an admin, and two people to invite
insert into auth.users (id, email, email_confirmed_at, last_sign_in_at) values
  ('a0000000-0000-0000-0000-000000000001', 'owner@biz.test', now(), now()),
  ('a0000000-0000-0000-0000-000000000002', 'admin@biz.test', now(), now()),
  ('a0000000-0000-0000-0000-000000000003', 'new.person@biz.test', now(), null),
  ('a0000000-0000-0000-0000-000000000004', 'taken@biz.test', now(), now()),     -- e.g. registered by a stranger (confirmation off)
  ('a0000000-0000-0000-0000-000000000005', 'other@biz.test', now(), now());
insert into public.businesses (id, name) values ('b0000000-0000-0000-0000-000000000001', 'Test Salon'), ('b0000000-0000-0000-0000-000000000002', 'Closed Co');
update public.businesses set cancelled_at = now() where id = 'b0000000-0000-0000-0000-000000000002';
insert into public.business_members (business_id, user_id, role, status) values
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'owner', 'active'),
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'admin', 'active'),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'owner', 'active');
-- the team-size check needs a plan; this fixture has none, so it is relaxed for these tests only
create or replace function public.zella_entitlement_allows(p_business_id uuid, p_key text, p_add integer default 1) returns boolean language sql as $$ select true $$;

create or replace function pg_temp.inv(p_email text, p_role text default 'staff', p_status text default 'pending', p_biz uuid default 'b0000000-0000-0000-0000-000000000001')
returns uuid language sql as $$
  insert into public.business_invitations (business_id, email, owner_name, invited_by, status, role, invited_at, expires_at)
  values (p_biz, p_email, p_email, 'a0000000-0000-0000-0000-000000000001', p_status, p_role, now(), now() + interval '14 days') returning id $$;

-- 1. A cancellation is never overwritten by a late "sent" or "failed"
reset role;
do $$ declare v uuid := pg_temp.inv('new.person@biz.test'); r text; begin
  perform pg_temp.act('a0000000-0000-0000-0000-000000000001');
  perform public.zella_cancel_invitation(v);
  perform pg_temp.act(null);
  r := public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003', false);
  assert r = 'CLOSED', 'finalize after cancel returned ' || r;
  r := public.zella_staff_invite_fail(v, 'smtp down');
  assert r = 'CLOSED', 'fail after cancel returned ' || r;
  assert (select status from public.business_invitations where id = v) = 'revoked', 'cancelled invitation was reopened';
  raise notice 'PASS cancelled invitation stays revoked after a late send or error';
end $$;

-- 2. An accepted invitation is never reopened by a late error
reset role;
do $$ declare v uuid := pg_temp.inv('new.person@biz.test'); r text; begin
  perform pg_temp.act(null);
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003') = 'sent';
  perform pg_temp.act('a0000000-0000-0000-0000-000000000003', 'invite');
  assert (public.zella_accept_staff_invitations_v2() ->> 'accepted')::int = 1, 'accept with invite link failed';
  perform pg_temp.act(null);
  r := public.zella_staff_invite_fail(v, 'late error');
  assert r = 'CLOSED' and (select status from public.business_invitations where id = v) = 'accepted', 'accepted invitation reopened: ' || r;
  assert exists (select 1 from public.business_members where user_id = 'a0000000-0000-0000-0000-000000000003' and status = 'active' and role = 'staff');
  raise notice 'PASS accepted invitation stays accepted after a late error';
end $$;

-- 3. The inviter's rights are checked again when the send finishes
reset role;
do $$ declare v uuid := pg_temp.inv('other@biz.test'); v2 uuid := pg_temp.inv('taken@biz.test', 'admin'); begin
  perform pg_temp.act(null);
  update public.business_members set role = 'staff' where user_id = 'a0000000-0000-0000-0000-000000000002';   -- admin demoted meanwhile
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000005') = 'NOT_ALLOWED';
  update public.business_members set role = 'admin' where user_id = 'a0000000-0000-0000-0000-000000000002';
  assert public.zella_staff_invite_finalize(v2, 'a0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000004') = 'NOT_ALLOWED', 'admin could finalize an admin invitation';
  assert (select status from public.business_invitations where id = v) = 'pending';
  delete from public.business_invitations where id in (v, v2);
  raise notice 'PASS inviter role re-checked at finalize (demoted admin; admin inviting admin)';
end $$;

-- 4. Expired, closed business, wrong account, already a member
reset role;
do $$ declare v uuid; begin
  perform pg_temp.act(null);
  v := pg_temp.inv('other@biz.test'); update public.business_invitations set expires_at = now() - interval '1 minute' where id = v;
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005') = 'EXPIRED';
  delete from public.business_invitations where id = v;
  v := pg_temp.inv('other@biz.test', 'staff', 'pending', 'b0000000-0000-0000-0000-000000000002');
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005') = 'BUSINESS_CLOSED';
  delete from public.business_invitations where id = v;
  v := pg_temp.inv('other@biz.test');
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004') = 'EMAIL_MISMATCH', 'bound to an account with another address';
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002') = 'EMAIL_MISMATCH';
  delete from public.business_invitations where id = v;
  v := pg_temp.inv('admin@biz.test');
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002') = 'ALREADY_MEMBER';
  delete from public.business_invitations where id = v;
  raise notice 'PASS finalize refuses expired, closed business, wrong account and existing member';
end $$;

-- 5. Email ownership: a password-only session can't accept, even for an account holding the invited address
reset role;
do $$ declare v uuid := pg_temp.inv('taken@biz.test'); r jsonb; begin
  perform pg_temp.act(null);
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004', true) = 'sent';
  perform pg_temp.act('a0000000-0000-0000-0000-000000000004', 'password');
  r := public.zella_accept_staff_invitations_v2();
  assert (r ->> 'accepted')::int = 0 and (r ->> 'needs_email_link')::int = 1, 'password session accepted: ' || r::text;
  assert not exists (select 1 from public.business_members where user_id = 'a0000000-0000-0000-0000-000000000004'), 'joined without email proof';
  perform pg_temp.act('a0000000-0000-0000-0000-000000000004', 'oauth');
  assert (public.zella_accept_staff_invitations_v2() ->> 'accepted')::int = 0, 'oauth session accepted';
  perform pg_temp.act('a0000000-0000-0000-0000-000000000004', 'magiclink');
  r := public.zella_accept_staff_invitations_v2();
  assert (r ->> 'accepted')::int = 1, 'magic link session not accepted: ' || r::text;
  raise notice 'PASS acceptance needs a session signed in through an email link (password and oauth refused)';
end $$;

-- 6. The account's address changed after binding: not accepted
reset role;
do $$ declare v uuid := pg_temp.inv('other@biz.test'); r jsonb; begin
  perform pg_temp.act(null);
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005') = 'sent';
  update auth.users set email = 'changed@elsewhere.test' where id = 'a0000000-0000-0000-0000-000000000005';
  perform pg_temp.act('a0000000-0000-0000-0000-000000000005', 'otp');
  r := public.zella_accept_staff_invitations_v2();
  assert (r ->> 'accepted')::int = 0 and r -> 'errors' -> 0 ->> 'reason' = 'EMAIL_CHANGED', r::text;
  perform pg_temp.act(null);
  update auth.users set email = 'other@biz.test' where id = 'a0000000-0000-0000-0000-000000000005';
  delete from public.business_invitations where id = v;
  raise notice 'PASS changed account email blocks acceptance';
end $$;

-- 7. A removed (suspended) member who is invited again comes back with the invited role
reset role;
do $$ declare v uuid; r jsonb; begin
  perform pg_temp.act(null);
  update public.business_members set status = 'suspended', role = 'staff' where user_id = 'a0000000-0000-0000-0000-000000000003';
  v := pg_temp.inv('new.person@biz.test', 'manager');
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003') = 'sent';
  perform pg_temp.act('a0000000-0000-0000-0000-000000000003', 'otp');
  r := public.zella_accept_staff_invitations_v2();
  assert (r ->> 'accepted')::int = 1, r::text;
  perform pg_temp.act(null);
  assert (select status || '/' || role from public.business_members where user_id = 'a0000000-0000-0000-0000-000000000003'
           and business_id = 'b0000000-0000-0000-0000-000000000001') = 'active/manager', 'removed member not reactivated';
  raise notice 'PASS re-invited removed member is reactivated with the invited role';
end $$;

-- 8. An invitation that expired before acceptance is marked expired, not accepted
reset role;
do $$ declare v uuid; r jsonb; begin
  perform pg_temp.act(null);
  v := pg_temp.inv('other@biz.test');
  assert public.zella_staff_invite_finalize(v, 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005') = 'sent';
  update public.business_invitations set expires_at = now() - interval '1 second' where id = v;
  perform pg_temp.act('a0000000-0000-0000-0000-000000000005', 'otp');
  r := public.zella_accept_staff_invitations_v2();
  assert (r ->> 'accepted')::int = 0 and (r ->> 'expired')::int = 1, r::text;
  perform pg_temp.act(null);
  assert (select status from public.business_invitations where id = v) = 'expired';
  raise notice 'PASS expired invitation is closed as expired';
end $$;

-- 9. Grants: finalize and fail are for the server only
reset role;
do $$ begin
  assert not has_function_privilege('authenticated', 'public.zella_staff_invite_finalize(uuid, uuid, uuid, boolean)', 'execute');
  assert not has_function_privilege('authenticated', 'public.zella_staff_invite_fail(uuid, text)', 'execute');
  assert not has_function_privilege('anon', 'public.zella_accept_staff_invitations_v2()', 'execute');
  assert has_function_privilege('authenticated', 'public.zella_accept_staff_invitations_v2()', 'execute');
  raise notice 'PASS finalize/fail are service-role only; acceptance is for signed-in users';
end $$;

-- Owner seats: zella_accept_my_invitations
reset role;
insert into auth.users (id, email, email_confirmed_at) values ('f0000000-0000-0000-0000-000000000001', 'newowner@biz.test', null);
insert into public.businesses (id, name) values ('b3000000-0000-0000-0000-000000000001', 'Owner Co'), ('b3000000-0000-0000-0000-000000000002', 'Owner Co 2');
insert into public.business_members (business_id, user_id, role, status) values
  ('b3000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'owner', 'invited'),
  ('b3000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000001', 'owner', 'invited');
insert into public.business_invitations (business_id, email, owner_name, invited_by, role, status, auth_user_id, expires_at) values
  ('b3000000-0000-0000-0000-000000000001', 'newowner@biz.test', 'New Owner', 'f0000000-0000-0000-0000-000000000001', 'owner', 'sent', 'f0000000-0000-0000-0000-000000000001', now() + interval '7 days'),
  ('b3000000-0000-0000-0000-000000000002', 'newowner@biz.test', 'New Owner', 'f0000000-0000-0000-0000-000000000001', 'owner', 'sent', 'f0000000-0000-0000-0000-000000000001', now() - interval '1 day');
do $$ declare n int; r jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated","amr":[{"method":"password"}]}', false);
  set role authenticated;
  n := public.zella_accept_my_invitations();
  r := public.zella_accept_staff_invitations_v2();
  reset role;
  assert n = 0, 'password session activated an owner seat';
  assert (r ->> 'needs_email_link')::int = 2, 'owner seats waiting not reported: ' || r;
  assert (select count(*) from public.business_members where user_id = 'f0000000-0000-0000-0000-000000000001' and status = 'active') = 0;
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated","amr":[{"method":"invite"}]}', false);
  set role authenticated;
  n := public.zella_accept_my_invitations();
  reset role;
  assert n = 1, 'invite-link session should activate exactly the unexpired seat, got ' || n;
  assert (select status from public.business_members where business_id = 'b3000000-0000-0000-0000-000000000002' and user_id = 'f0000000-0000-0000-0000-000000000001') = 'invited', 'expired owner invitation activated';
  assert (select status from public.business_invitations where business_id = 'b3000000-0000-0000-0000-000000000001') = 'accepted';
  raise notice 'PASS owner seats: password session refused and reported as waiting; invite link activates only the unexpired invitation';
end $$;

-- Platform admins need a confirmed email (or a fresh, never-used invitation)
reset role;
insert into auth.users (id, email, email_confirmed_at, last_sign_in_at) values
  ('f1000000-0000-0000-0000-000000000001', 'squatter@x.test', null, now()),
  ('f1000000-0000-0000-0000-000000000002', 'fresh@x.test', null, null),
  ('f1000000-0000-0000-0000-000000000003', 'real@x.test', now(), now());
do $$ begin
  begin insert into public.platform_admins (user_id, role, is_active) values ('f1000000-0000-0000-0000-000000000001', 'super_admin', true);
    assert false, 'unconfirmed signed-in account was made admin';
  exception when insufficient_privilege then null; end;
  insert into public.platform_admins (user_id, role, is_active) values ('f1000000-0000-0000-0000-000000000002', 'super_admin', true);
  insert into public.platform_admins (user_id, role, is_active) values ('f1000000-0000-0000-0000-000000000003', 'super_admin', false);
  update public.platform_admins set is_active = true where user_id = 'f1000000-0000-0000-0000-000000000003';
  raise notice 'PASS platform admins: unconfirmed signed-in account refused; fresh invite and confirmed account allowed';
end $$;
