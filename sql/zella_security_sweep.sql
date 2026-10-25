-- Zella - security sweep (2026-10-25). Safe to re-run.
-- 1. Trigger functions never need to be callable from the API. (Triggers fire without the caller's EXECUTE right.)
-- 2. zella_business_open is only used inside other database functions.
-- 3. Four helper functions get a fixed search_path.
-- 4. New functions are closed to anon by default; each file already grants what the app needs explicitly.
-- Left open on purpose: zella_unsubscribe_email and zella_unsubscribe_lookup (the unsubscribe link works without signing in, and needs the secret token).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prorettype = 'trigger'::regtype loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke execute on function public.zella_business_open(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.zella_business_open(uuid, timestamptz) to service_role;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname in ('zella_classify_email', 'zella_website_same_site', 'zella_brain_tool_defs', 'zella_valid_email') loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
  end loop;
end $$;

alter default privileges in schema public revoke execute on functions from public, anon;
