-- Undoes sql/zella_incident_updates.sql: drops the four functions and platform_incident_updates. Refuses (DRIFT) when
-- a function is no longer this migration's version, and while updates exist unless the session sets
-- zella.drop_incident_updates = 'yes'. Audit rows already written stay. Safe to run twice.
begin;
do $$
declare f record; n boolean;
begin
  for f in select * from (values
      ('public.zella_incident_post_update(uuid,text,boolean)', '1ecc82de3e0ecb6f1538033985357075'),
      ('public.zella_incident_edit(uuid,text,text)', 'e0215d925eed949c81af4ee8d21ac576'),
      ('public.zella_incident_title_key(text)', '4980429f996f03a32006003ada23cad3'),
      ('public.zella_open_incident_checked(text,text,boolean)', '4e398548b0542d880d50cf8beb377d2a')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_incident_updates.sql; roll back by hand', f.sig;
    end if;
  end loop;
  if to_regclass('public.platform_incident_updates') is not null and coalesce(current_setting('zella.drop_incident_updates', true), '') <> 'yes' then
    execute 'select exists (select 1 from public.platform_incident_updates)' into n;
    if n then raise exception 'DRIFT: platform_incident_updates has updates; set zella.drop_incident_updates = yes to drop them'; end if;
  end if;
end $$;
drop function if exists public.zella_open_incident_checked(text, text, boolean);
drop function if exists public.zella_incident_post_update(uuid, text, boolean);
drop function if exists public.zella_incident_edit(uuid, text, text);
drop function if exists public.zella_incident_title_key(text);
drop table if exists public.platform_incident_updates;
commit;
