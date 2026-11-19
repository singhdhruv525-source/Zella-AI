-- Undoes sql/zella_admin_contact_lookup.sql exactly: drops zella_admin_contact_lookup. Its audit rows stay. It must be
-- exactly that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier web app first. Safe to
-- run twice.
begin;
do $$
begin
  if to_regprocedure('public.zella_admin_contact_lookup(uuid,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_admin_contact_lookup(uuid,text,text)'))) <> '4ea03aaa7e28d16f4dbc2f03e0c56bff' then
    raise exception 'ROLLBACK_DRIFT: public.zella_admin_contact_lookup has changed since this migration';
  end if;
end $$;
drop function if exists public.zella_admin_contact_lookup(uuid, text, text);
commit;
