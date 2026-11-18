-- Undoes sql/zella_incident_updates.sql, for a database with NO incident updates yet: drops the four functions and
-- platform_incident_updates. It refuses (DRIFT) when a function is no longer this migration's version, when the table
-- isn't this file's (its mark) or not exactly its shape, and whenever updates exist: it never deletes them. If there
-- are any, stop here; undoing then needs its own plan that keeps the timeline, approved by the owner. The table is
-- locked before it is checked, so no update can be written between the check and the drop. Audit rows already
-- written stay. Safe to run twice.
begin;
set transaction isolation level read committed;   -- the check below sees what is committed once the lock is held
do $$
declare f record; n boolean;
begin
  for f in select * from (values
      ('public.zella_incident_post_update(uuid,text,boolean)', 'f5a3726b3ffdc5ae3578e28fb9547098'),
      ('public.zella_incident_edit(uuid,text,text)', 'e0215d925eed949c81af4ee8d21ac576'),
      ('public.zella_incident_title_key(text)', '4980429f996f03a32006003ada23cad3'),
      ('public.zella_open_incident_checked(text,text,boolean)', '60baa4d2414a8001635ead319ee6b4e2')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_incident_updates.sql; roll back by hand', f.sig;
    end if;
  end loop;
  if to_regclass('public.platform_incident_updates') is not null then
    execute 'lock table public.platform_incident_updates in access exclusive mode';
  end if;
end $$;
do $$
declare n boolean;
begin
  if to_regclass('public.platform_incident_updates') is not null then
    if obj_description(to_regclass('public.platform_incident_updates'), 'pg_class') is distinct from 'zella_incident_updates.sql' then
      raise exception 'DRIFT: platform_incident_updates was not created by sql/zella_incident_updates.sql; roll back by hand';
    end if;
    if (select string_agg(column_name || ' ' || data_type, ', ' order by column_name) from information_schema.columns
         where table_schema = 'public' and table_name = 'platform_incident_updates')
       is distinct from 'body text, created_at timestamp with time zone, created_by uuid, id uuid, incident_id uuid, notified_businesses integer' then
      raise exception 'DRIFT: platform_incident_updates is not the table sql/zella_incident_updates.sql creates; roll back by hand';
    end if;
    execute 'select exists (select 1 from public.platform_incident_updates)' into n;
    if n then raise exception 'DRIFT: platform_incident_updates has updates; this rollback never deletes them'; end if;
  end if;
end $$;
drop function if exists public.zella_open_incident_checked(text, text, boolean);
drop function if exists public.zella_incident_post_update(uuid, text, boolean);
drop function if exists public.zella_incident_edit(uuid, text, text);
drop function if exists public.zella_incident_title_key(text);
drop table if exists public.platform_incident_updates;
commit;
