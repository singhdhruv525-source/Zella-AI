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
--   3. zella_remove_mfa_factor(p_user_id, p_factor_id): server only. Removes one of a person's authenticators while
--      holding a lock on that person, so the "another verified one is left" check and the delete can't interleave with
--      a second removal (ACC-01, ACC-30): LAST_FACTOR when it is the only verified one, NOT_FOUND when it isn't theirs.
--      owner-provision-business me_mfa_remove uses it; Supabase Auth's own delete has no such rule.
--   4. A trigger on platform_admins (zella_keep_an_owner_trg): a change or removal that would leave no active Zella Voice
--      owner is refused (LAST_OWNER). It locks the other active owners' rows first, so two owners removing each other
--      at the same moment can't both pass (the second waits, then sees the first change). A statement trigger
--      (zella_keep_an_owner_turn_trg) takes one turn for every change to platform_admins before any row is locked, so
--      two such changes can't deadlock either. admin_update keeps its own check for a clear message; this makes it
--      hold in the database too.
--   5. A trigger on auth.mfa_factors (zella_admin_mfa_added_trg): when an active platform admin's authenticator
--      becomes verified, admin.mfa_added is written in the same transaction, once per authenticator.
-- All six functions and the three triggers are new. Each is checked first: it must be absent or exactly this file's
-- version, otherwise the file stops with VERSION_MISMATCH. Running the file twice changes nothing.
-- Rollback: sql/rollback/zella_admin_sessions_rollback.sql (drops them all, refusing if any was changed since).
begin;

do $$
declare f record;
begin
  if to_regclass('auth.sessions') is null or to_regclass('public.audit_logs') is null or to_regclass('auth.mfa_factors') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_end_user_sessions(uuid)', '6f2b8fb98e67992744046a81ff295d9f'),
      ('public.zella_revoke_my_other_sessions()', 'eaaba33d1c889966f9bc2c3e223f44e9'),
      ('public.zella_remove_mfa_factor(uuid,uuid)', '7a8c3d352a3c9dbecea8e94c726fede1'),
      ('public.zella_keep_an_owner_trg()', '70c818f1d3c5a06094800c067807d32b'),
      ('public.zella_keep_an_owner_turn_trg()', 'ccab7c7710e26e9dd409befbb5f25177'),
      ('public.zella_admin_mfa_added_trg()', '3268d6c69ffdb400a4354f9c0e148e80')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in a version this file was not written for', f.sig;
    end if;
  end loop;
  -- the two triggers too: each absent, or exactly as this file creates it (its function, timing, events, no condition)
  if exists (select 1 from pg_trigger g where g.tgrelid in (to_regclass('public.platform_admins'), to_regclass('auth.mfa_factors'))
       and g.tgname in ('zella_keep_an_owner', 'zella_keep_an_owner_turn', 'zella_admin_mfa_added') and not coalesce(
         g.tgenabled = 'O' and g.tgconstraint = 0 and g.tgqual is null and g.tgnargs = 0 and cardinality(g.tgattr::int2[]) = 0 and (
           (g.tgname = 'zella_keep_an_owner' and g.tgrelid = 'public.platform_admins'::regclass and g.tgtype = 27 and g.tgfoid = to_regprocedure('public.zella_keep_an_owner_trg()'))
           or (g.tgname = 'zella_keep_an_owner_turn' and g.tgrelid = 'public.platform_admins'::regclass and g.tgtype = 26 and g.tgfoid = to_regprocedure('public.zella_keep_an_owner_turn_trg()'))
           or (g.tgname = 'zella_admin_mfa_added' and g.tgrelid = 'auth.mfa_factors'::regclass and g.tgtype = 21 and g.tgfoid = to_regprocedure('public.zella_admin_mfa_added_trg()'))), false)) then
    raise exception 'VERSION_MISMATCH: a trigger of this file already exists in a version this file was not written for';
  end if;
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
  -- one sign out at a time per person: a second request waits, then finds its own session gone (NO_SESSION)
  perform pg_advisory_xact_lock(hashtext('zella_revoke_my_other_sessions:' || v_uid::text));
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

create or replace function public.zella_remove_mfa_factor(p_user_id uuid, p_factor_id uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_user_id is null or p_factor_id is null then raise exception 'BAD_INPUT'; end if;
  -- one removal at a time per person: the person's row is held until this transaction ends
  perform 1 from auth.users where id = p_user_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists (select 1 from auth.mfa_factors where id = p_factor_id and user_id = p_user_id and status = 'verified') then raise exception 'NOT_FOUND'; end if;
  select count(*) into n from auth.mfa_factors where user_id = p_user_id and status = 'verified';
  if n < 2 then raise exception 'LAST_FACTOR'; end if;
  delete from auth.mfa_factors where id = p_factor_id and user_id = p_user_id;
  return n - 1;
end $$;
revoke all on function public.zella_remove_mfa_factor(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_remove_mfa_factor(uuid, uuid) to service_role;

create or replace function public.zella_keep_an_owner_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  -- only when an active owner stops being one
  if not (old.role = 'zella_owner' and coalesce(old.is_active, false)) then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and new.role = 'zella_owner' and coalesce(new.is_active, false) then return new; end if;
  -- lock every other active owner (waiting for a change in progress), then count those still active owners
  select count(*) into n from (
    select 1 from public.platform_admins
     where role = 'zella_owner' and coalesce(is_active, false) and user_id <> old.user_id
     for update) o;
  if n = 0 then raise exception 'LAST_OWNER' using hint = 'Zella Voice must keep at least one active owner'; end if;
  return coalesce(new, old);
end $$;
revoke all on function public.zella_keep_an_owner_trg() from public, anon, authenticated;
drop trigger if exists zella_keep_an_owner on public.platform_admins;
create trigger zella_keep_an_owner before update or delete on public.platform_admins
  for each row execute function public.zella_keep_an_owner_trg();

-- one change to platform_admins at a time, taken before the statement locks any row: otherwise two owners removing
-- each other could each hold their own row and wait for the other's (a deadlock) instead of one being refused
create or replace function public.zella_keep_an_owner_turn_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('zella_keep_an_owner'));
  return null;
end $$;
revoke all on function public.zella_keep_an_owner_turn_trg() from public, anon, authenticated;
drop trigger if exists zella_keep_an_owner_turn on public.platform_admins;
create trigger zella_keep_an_owner_turn before update or delete on public.platform_admins
  for each statement execute function public.zella_keep_an_owner_turn_trg();

-- an active admin's new authenticator is on record from the moment it is verified, in the same transaction (ACC-30):
-- a lost answer in the browser, a later role change or a later removal can't leave it without an admin.mfa_added
-- entry. Once per authenticator; owner-provision-business me_mfa_added then finds it and writes nothing more.
create or replace function public.zella_admin_mfa_added_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'verified' and (tg_op = 'INSERT' or old.status is distinct from 'verified')
     and exists (select 1 from public.platform_admins pa where pa.user_id = new.user_id and coalesce(pa.is_active, false))
     and not exists (select 1 from public.audit_logs a where a.action = 'admin.mfa_added' and a.user_id = new.user_id and a.entity_id = new.id) then
    insert into public.audit_logs (user_id, action, entity_type, entity_id, new_data)
    values (new.user_id, 'admin.mfa_added', 'mfa_factor', new.id, jsonb_build_object('friendly_name', new.friendly_name, 'recorded_by', 'database'));
  end if;
  return null;
end $$;
revoke all on function public.zella_admin_mfa_added_trg() from public, anon, authenticated;
drop trigger if exists zella_admin_mfa_added on auth.mfa_factors;
create trigger zella_admin_mfa_added after insert or update on auth.mfa_factors
  for each row execute function public.zella_admin_mfa_added_trg();

commit;
