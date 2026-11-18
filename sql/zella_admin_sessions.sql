-- Zella Voice: end an admin's sessions when they are removed or their role changes, and let anyone sign out their
-- other devices with an audit entry (docs/ADMIN_AUDIT_2026-11-16.md ACC-18, ACC-30; ARCHITECTURE "session revocation
-- on role change").
--   1. zella_end_user_sessions(p_user_id): server only (service role). Deletes every auth.sessions row of that person,
--      which also ends their refresh tokens, so no device can get a new access token. owner-provision-business calls
--      it from admin_update when an admin is deactivated or given another role; the count goes into the admin.updated
--      audit entry. An access token already issued keeps working until it expires (one hour by default), but the
--      function reads the admin's role again on every call, so a removed admin is refused there at once.
--   2. zella_revoke_my_other_sessions(): for the signed in person. Deletes their sessions except the one making the
--      call (the session_id claim) and writes audit 'session.revoked_others' with the count.
-- Both are new. Each is checked first: it must be absent or exactly this file's version, otherwise the file stops
-- with VERSION_MISMATCH. Running the file twice changes nothing.
-- Rollback: sql/rollback/zella_admin_sessions_rollback.sql (drops both, refusing if either was changed since).
begin;

do $$
declare f record;
begin
  if to_regclass('auth.sessions') is null or to_regclass('public.audit_logs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_end_user_sessions(uuid)', '6f2b8fb98e67992744046a81ff295d9f'),
      ('public.zella_revoke_my_other_sessions()', 'e3773f5cab852656cc8d834f5a660302')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in a version this file was not written for', f.sig;
    end if;
  end loop;
end $$;

create or replace function public.zella_end_user_sessions(p_user_id uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_user_id is null then raise exception 'BAD_INPUT'; end if;
  delete from auth.sessions where user_id = p_user_id;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.zella_end_user_sessions(uuid) from public, anon, authenticated;
grant execute on function public.zella_end_user_sessions(uuid) to service_role;

create or replace function public.zella_revoke_my_other_sessions() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_sid text := auth.jwt() ->> 'session_id'; n integer;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN'; end if;
  if v_sid is null or v_sid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'NO_SESSION'; end if;
  -- the calling session must be one of this person's live sessions, or nothing is ended
  if not exists (select 1 from auth.sessions where id = v_sid::uuid and user_id = v_uid) then raise exception 'NO_SESSION'; end if;
  delete from auth.sessions where user_id = v_uid and id <> v_sid::uuid;
  get diagnostics n = row_count;
  insert into public.audit_logs (user_id, action, entity_type, new_data)
  values (v_uid, 'session.revoked_others', 'session', jsonb_build_object('ended', n, 'kept', v_sid));
  return n;
end $$;
revoke all on function public.zella_revoke_my_other_sessions() from public, anon;
grant execute on function public.zella_revoke_my_other_sessions() to authenticated;

commit;
