-- Zella - role check hardening (2026-10-26). Safe to re-run.
--
-- Purpose
--   zella_has_role(business, roles) answered TRUE whenever auth.uid() was null. That is meant for the server
--   (pg_cron jobs, n8n and edge functions using the server key), but a request made with only the public key
--   (role "anon") also has no user, so it passed every role check too. Today no function that uses this check
--   is open to anon, so nothing leaks, but one wrong grant later would expose business data.
--   Now: no user AND the request is not an anon/authenticated API request.
--
-- Needs: zella_ops_extras.sql (the original zella_has_role).
--
-- Authorization implications
--   Signed-in users: unchanged (they always have a user id).
--   Server key, pg_cron, SQL editor: unchanged (their request role is service_role, or there is no request at all).
--   Anonymous API requests: now FALSE instead of TRUE.
--
-- Rollback: re-run the zella_has_role definition from zella_ops_extras.sql.
--
-- Validation (rolled back):
--   do $$ begin
--     perform set_config('request.jwt.claims', '{"role":"anon"}', true);
--     raise exception 'RESULT anon=%', public.zella_has_role(gen_random_uuid(), array['owner']);   -- expect false
--   end $$;
--   do $$ begin
--     raise exception 'RESULT server=%', public.zella_has_role(gen_random_uuid(), array['owner']); -- expect true
--   end $$;

create or replace function public.zella_has_role(p_business_id uuid, p_roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then coalesce(auth.jwt() ->> 'role', '') not in ('anon', 'authenticated')
    else exists (select 1 from public.business_members m
                  where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role = any (p_roles))
  end;
$$;
