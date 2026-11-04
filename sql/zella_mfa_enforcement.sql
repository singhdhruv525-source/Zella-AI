-- Zella - two-step sign-in enforced by the database, not only by the app (2026-11-04). Safe to re-run.
--
-- Finding: the admin edge function refused sessions without the authenticator code (aal1) for people who set one up,
-- but the same session could call database functions and tables directly through the API: is_platform_admin(),
-- zella_admin_role() and every membership check look only at auth.uid(). (0 verified factors in production when
-- written, so not exploitable yet; it becomes a bypass the moment someone turns two-step sign-in on.)
--
-- Fix, two layers:
--   1. zella_pre_request() runs before every API request (PostgREST db-pre-request). A signed-in user with a verified
--      authenticator factor whose session is not aal2 gets "MFA_REQUIRED" for every table and function call.
--   2. A RESTRICTIVE policy on every public table with row security (and on storage.objects) requires the same, for
--      paths that don't pass through the API layer (Realtime, Storage).
-- Not affected: service role and server code (no user in the token), anonymous visitors, and users without a factor.
-- Signing in and completing the code use Supabase Auth, not these paths, so they keep working.
--
-- After applying on Supabase: NOTIFY pgrst, 'reload config';  (done at the end of this file)
-- Rollback: alter role authenticator reset pgrst.db_pre_request; drop policy zella_mfa_required on each table.

create or replace function public.zella_mfa_satisfied() returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when auth.uid() is null then true                                        -- server code, service role, anonymous
    when coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' then true
    else not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
  end;
$$;
revoke execute on function public.zella_mfa_satisfied() from public;
grant execute on function public.zella_mfa_satisfied() to anon, authenticated, service_role;

create or replace function public.zella_pre_request() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.zella_mfa_satisfied() then
    raise exception 'MFA_REQUIRED' using hint = 'Enter the code from your authenticator app to continue.', errcode = '42501';
  end if;
end $$;
revoke execute on function public.zella_pre_request() from public;
grant execute on function public.zella_pre_request() to anon, authenticated, service_role, authenticator;

do $$
declare t record;
begin
  -- layer 1: every API request
  execute 'alter role authenticator set pgrst.db_pre_request = ''public.zella_pre_request''';
  -- layer 2: every table that has row security
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relrowsecurity loop
    execute format('drop policy if exists zella_mfa_required on public.%I', t.relname);
    execute format('create policy zella_mfa_required on public.%I as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())', t.relname);
  end loop;
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists zella_mfa_required on storage.objects';
    execute 'create policy zella_mfa_required on storage.objects as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
  end if;
end $$;

notify pgrst, 'reload config';
