-- Zella Voice: invitations are capped per business (security audit 18 Nov 2026, 6.1, M10). zella_invite_staff and
-- zella_resend_invitation had no limit of their own, so an owner or admin (or someone in their session) could send
-- invitation emails from the Zella Voice sender to any number of addresses; only Supabase Auth's email limit stopped
-- them. Now each business can invite or resend 20 times an hour and 60 times a day (one shared counter,
-- zella_rate_limit; TOO_MANY_INVITES), and one invitation can be sent again at most every 10 minutes after its email
-- went out (RESEND_TOO_SOON; one whose send failed or never happened can be retried at once). The staff-invite edge function also caps the emails it sends.
-- Both functions are archived first and must match production (18 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_invitation_limits_rollback.sql
begin;

do $$
declare
  s text; d text;
  known constant jsonb := jsonb_build_object(
    'public.zella_invite_staff(uuid,text,text,text)', jsonb_build_array('274dd2f7697b3a25df374e8ef53693c4', 'cab03bae58b60089f19b480b7f6f58ee'),
    'public.zella_resend_invitation(uuid)',           jsonb_build_array('68c6891fc08ed88baccc98db6f079dcd', 'bc0872cbffde6dc83f1bb89943aef9bf'));
begin
  if to_regclass('public.zella_function_archive') is null or to_regprocedure('public.zella_rate_limit(text,integer,integer)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for s in select jsonb_object_keys(known) loop
    if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then          -- production's version: archive it for the rollback
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_invitation_limits', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then      -- nor this file's version (already applied)
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
end $$;

CREATE OR REPLACE FUNCTION public.zella_invite_staff(p_business_id uuid, p_email text, p_name text, p_role text DEFAULT 'staff'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_role not in ('admin', 'manager', 'staff', 'viewer') then raise exception 'BAD_ROLE'; end if;
  if p_role = 'admin' and not public.zella_has_role(p_business_id, array['owner']) then raise exception 'ONLY_OWNER_CAN_INVITE_ADMIN'; end if;
  /* zella_invitation_limits: 20 an hour and 60 a day per business, shared with zella_resend_invitation */
  if not public.zella_rate_limit('invite:business:' || p_business_id::text || ':h', 20, 3600)
     or not public.zella_rate_limit('invite:business:' || p_business_id::text || ':d', 60, 86400) then
    raise exception 'TOO_MANY_INVITES';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  if exists (select 1 from public.business_members m join auth.users u on u.id = m.user_id where m.business_id = p_business_id and lower(u.email) = v_email and m.status = 'active') then raise exception 'ALREADY_A_MEMBER'; end if;
  if exists (select 1 from public.business_invitations where business_id = p_business_id and lower(email) = v_email and status in ('pending', 'sent')) then raise exception 'ALREADY_INVITED'; end if;
  insert into public.business_invitations (business_id, email, owner_name, invited_by, status, role, invited_at, expires_at)
  values (p_business_id, v_email, left(coalesce(nullif(trim(p_name), ''), v_email), 100), auth.uid(), 'pending', p_role, now(), now() + interval '14 days') returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'staff_invited', 'business_invitation', v_id, jsonb_build_object('email', v_email, 'role', p_role));
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.zella_resend_invitation(p_invitation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare i public.business_invitations;
begin
  select * into i from public.business_invitations where id = p_invitation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(i.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if i.status not in ('pending', 'sent', 'failed', 'expired') then raise exception 'CANNOT_RESEND'; end if;
  /* zella_invitation_limits: once every 10 minutes per invitation, and the business's invitation limits */
  -- only after an email actually went out (status sent): a resend that sent nothing can be tried again at once
  if i.status = 'sent' and i.invited_at is not null and i.invited_at > now() - interval '10 minutes' then raise exception 'RESEND_TOO_SOON'; end if;
  if not public.zella_rate_limit('invite:business:' || i.business_id::text || ':h', 20, 3600)
     or not public.zella_rate_limit('invite:business:' || i.business_id::text || ':d', 60, 86400) then
    raise exception 'TOO_MANY_INVITES';
  end if;
  update public.business_invitations set status = 'pending', reminder_count = 0, last_reminded_at = null, last_error = null, invited_at = now(), expires_at = now() + interval '14 days', updated_at = now() where id = i.id;
end $function$;

commit;
