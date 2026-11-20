-- Undoes sql/zella_create_business_revoke.sql exactly: execute on public.create_business(...) goes back to
-- authenticated (production's grants on 18 Nov 2026: postgres, authenticated, service_role; never anon or public).
-- Safe to run twice. Does nothing if the function no longer exists, and refuses (ROLLBACK_DRIFT) if it is no longer
-- production's version, as the forward file does.
begin;
do $$
declare s constant text := 'public.create_business(text,uuid,text,text,text,text,text,text)';
begin
  if to_regprocedure(s) is null then return; end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> '48f534603657107257216667645e90b9' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  execute format('grant execute on function %s to authenticated', s);
end $$;
commit;
