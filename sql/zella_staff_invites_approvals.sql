-- Zella - staff invitations and the approval queue (checklist 184, 162). Safe to run more than once. Run AFTER zella_ops_extras.sql and zella_run_all.sql.
--   184 owners and admins invite team members by email and role; the person signs up with that email and is added automatically;
--       an invitation can be cancelled or sent again; the inviter is told when it is accepted
--   162 approval requests expire, approvers get a nudge after a day, the requester is told the decision, and a list feeds the app
alter table public.business_invitations add column if not exists role text not null default 'owner';
alter table public.business_invitations drop constraint if exists business_invitations_status_check;
alter table public.business_invitations add constraint business_invitations_status_check check (status in ('pending', 'sent', 'accepted', 'expired', 'failed', 'revoked'));

create or replace function public.zella_invite_staff(p_business_id uuid, p_email text, p_name text, p_role text default 'staff')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_role not in ('admin', 'manager', 'staff', 'viewer') then raise exception 'BAD_ROLE'; end if;
  if p_role = 'admin' and not public.zella_has_role(p_business_id, array['owner']) then raise exception 'ONLY_OWNER_CAN_INVITE_ADMIN'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  if exists (select 1 from public.business_members m join auth.users u on u.id = m.user_id where m.business_id = p_business_id and lower(u.email) = v_email and m.status = 'active') then raise exception 'ALREADY_A_MEMBER'; end if;
  if exists (select 1 from public.business_invitations where business_id = p_business_id and lower(email) = v_email and status in ('pending', 'sent')) then raise exception 'ALREADY_INVITED'; end if;
  insert into public.business_invitations (business_id, email, owner_name, invited_by, status, role, invited_at, expires_at)
  values (p_business_id, v_email, left(coalesce(nullif(trim(p_name), ''), v_email), 100), auth.uid(), 'pending', p_role, now(), now() + interval '14 days') returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'staff_invited', 'business_invitation', v_id, jsonb_build_object('email', v_email, 'role', p_role));
  return v_id;
end $$;
revoke execute on function public.zella_invite_staff(uuid, text, text, text) from public, anon;
grant execute on function public.zella_invite_staff(uuid, text, text, text) to authenticated, service_role;

create or replace function public.zella_cancel_invitation(p_invitation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.business_invitations;
begin
  select * into i from public.business_invitations where id = p_invitation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(i.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if i.status not in ('pending', 'sent', 'failed', 'expired') then raise exception 'CANNOT_CANCEL'; end if;
  update public.business_invitations set status = 'revoked', updated_at = now() where id = i.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (i.business_id, auth.uid(), 'invitation_revoked', 'business_invitation', i.id, jsonb_build_object('email', i.email));
end $$;
revoke execute on function public.zella_cancel_invitation(uuid) from public, anon;
grant execute on function public.zella_cancel_invitation(uuid) to authenticated, service_role;

create or replace function public.zella_resend_invitation(p_invitation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.business_invitations;
begin
  select * into i from public.business_invitations where id = p_invitation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(i.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if i.status not in ('pending', 'sent', 'failed', 'expired') then raise exception 'CANNOT_RESEND'; end if;
  update public.business_invitations set status = 'pending', reminder_count = 0, last_reminded_at = null, last_error = null, invited_at = now(), expires_at = now() + interval '14 days', updated_at = now() where id = i.id;
end $$;
revoke execute on function public.zella_resend_invitation(uuid) from public, anon;
grant execute on function public.zella_resend_invitation(uuid) to authenticated, service_role;

-- the signed-in person joins every business that invited their email
create or replace function public.zella_accept_staff_invitations() returns integer
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_email text; i record; n integer := 0;
begin
  if v_user is null then raise exception 'NOT_SIGNED_IN'; end if;
  select lower(email) into v_email from auth.users where id = v_user;
  for i in select * from public.business_invitations where lower(email) = v_email and status in ('pending', 'sent') and role <> 'owner'
                and (expires_at is null or expires_at > now()) for update loop
    if exists (select 1 from public.businesses where id = i.business_id and cancelled_at is not null) then continue; end if;
    insert into public.business_members (business_id, user_id, role, status) values (i.business_id, v_user, i.role, 'active')
    on conflict do nothing;
    update public.business_invitations set status = 'accepted', accepted_at = now(), auth_user_id = v_user, updated_at = now() where id = i.id;
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

-- 162
create or replace function public.zella_pending_approvals(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'action', action, 'details', details, 'requested_by', requested_by, 'created_at', created_at, 'expires_at', expires_at,
                     'mine', requested_by = auth.uid()) order by created_at) from public.sensitive_approvals where business_id = p_business_id and status = 'pending' and expires_at > now()), '[]'::jsonb);
end $$;
revoke execute on function public.zella_pending_approvals(uuid) from public, anon;
grant execute on function public.zella_pending_approvals(uuid) to authenticated, service_role;

create or replace function public.zella_approval_decided_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('approved', 'rejected', 'expired') and old.status = 'pending' and new.requested_by is not null then
    perform public.zella_notify(new.business_id, 'approval_' || new.status,
      case new.status when 'approved' then 'Approved: ' when 'rejected' then 'Not approved: ' else 'Expired, ask again: ' end || left(new.action, 80),
      null, 'info', 'settings', new.id, new.requested_by);
  end if;
  return new;
end $$;
drop trigger if exists zella_approval_decided_trg on public.sensitive_approvals;
create trigger zella_approval_decided_trg after update of status on public.sensitive_approvals for each row execute function public.zella_approval_decided_trigger();

-- hourly: expire old requests, nudge approvers once after a day
create or replace function public.zella_sweep_approvals() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  update public.sensitive_approvals set status = 'expired' where status = 'pending' and expires_at < now();
  get diagnostics n = row_count;
  for r in select id, business_id, action from public.sensitive_approvals
            where status = 'pending' and created_at < now() - interval '1 day' and coalesce(details ->> 'nudged', '') = '' loop
    perform public.zella_notify_owners(r.business_id, 'approval_waiting', 'Still waiting for your approval', left(r.action, 80) || ' has been waiting over a day. It expires soon.', 'warning', 'settings');
    update public.sensitive_approvals set details = details || '{"nudged": true}'::jsonb where id = r.id;
  end loop;
  return n;
end $$;
revoke all on function public.zella_sweep_approvals() from public, anon, authenticated;
grant execute on function public.zella_sweep_approvals() to service_role;
