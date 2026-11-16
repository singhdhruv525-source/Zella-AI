-- Zella Voice: two step sign in for every platform admin, in the database too (docs/ADMIN_AUDIT_2026-11-16.md ACC-01;
-- REQ-LC-04, ARCHITECTURE "MFA required for platform staff").
-- zella_mfa_satisfied() (used by the request check zella_pre_request and by the restrictive policy on every table)
-- asked for the authenticator code only from people who had set one up. Now an active platform admin always needs a
-- session verified with a code (aal2), set up or not; everyone else is unchanged. Server code (service role) and
-- anonymous requests are unchanged.
-- Order at go live: deploy the web app and owner-provision-business first (they walk an admin without an authenticator
-- through setting one up), then apply this file. Applied first, an admin without an authenticator could still sign in
-- and set one up, but every page would be refused until then.
-- The function is archived first and must be one of the two known versions (production's, and the same text with a
-- comment from sql/zella_mfa_enforcement.sql), otherwise the file stops with VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_admin_mfa_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_mfa_satisfied()'; d text;
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.platform_admins') is null or to_regprocedure(s) is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = '2a448f1e76356f4cf38478127cc83ce3' then return; end if;   -- already applied: exactly this file's version
  if md5(d) not in ('f1cc1bb5a6e141a27c6643fa387dee63', '85766438a927da4a59619130c7bcba7e') then
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_admin_mfa', s, d, md5(d)) on conflict (migration, signature) do nothing;
end $$;

create or replace function public.zella_mfa_satisfied() returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when auth.uid() is null then true                                        -- server code, service role, anonymous
    when coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' then true
    -- every active platform admin needs a session verified with a code, whether or not they have set one up yet
    when exists (select 1 from public.platform_admins pa where pa.user_id = auth.uid() and pa.is_active) then false
    else not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
  end;
$$;

commit;
