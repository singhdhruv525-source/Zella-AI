-- Undoes sql/zella_create_business_revoke.sql exactly: execute on public.create_business(...) goes back to
-- authenticated (production's grants on 18 Nov 2026: postgres, authenticated, service_role; never anon or public).
-- Safe to run twice. Does nothing if the function no longer exists.
begin;
do $$
declare s constant text := 'public.create_business(text,uuid,text,text,text,text,text,text)';
begin
  if to_regprocedure(s) is null then return; end if;
  execute format('grant execute on function %s to authenticated', s);
end $$;
commit;
