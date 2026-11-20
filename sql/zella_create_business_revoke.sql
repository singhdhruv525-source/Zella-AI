-- Zella Voice: signed in people can no longer create a business for themselves (security audit 18 Nov 2026, 3.6, M6).
-- The legacy public.create_business(...) is SECURITY DEFINER and was granted to authenticated (sql/baseline/
-- 12_function_grants.sql:5), so any signed in person (any staff member, or anyone who could register) could create a
-- business with themselves as its active owner, every module of the industry on and a default receptionist,
-- skipping invite only onboarding. Nothing calls it any more: the web app, the edge functions and n8n create
-- businesses through owner-provision-business (zella_create_business_draft), so execute is revoked from public,
-- anon and authenticated. The server key (service_role) keeps it; the function body is unchanged.
-- The function must be production's version (18 Nov 2026), otherwise VERSION_MISMATCH. If it no longer exists the
-- file does nothing.
-- Owner item (outside the database): turn off "Allow new users to sign up" in Supabase Auth, and sign up for every
-- social provider.
-- Rollback: sql/rollback/zella_create_business_revoke_rollback.sql
begin;

do $$
declare s constant text := 'public.create_business(text,uuid,text,text,text,text,text,text)';
begin
  if to_regprocedure(s) is null then return; end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '48f534603657107257216667645e90b9' then
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  execute format('revoke all on function %s from public, anon, authenticated', s);
  execute format('grant execute on function %s to service_role', s);
end $$;

commit;
