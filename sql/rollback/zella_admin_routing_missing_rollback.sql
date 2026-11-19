-- Undoes sql/zella_admin_routing_missing.sql: drops zella_admin_routing_missing(integer, integer), only if it is exactly
-- this file's version (otherwise ROLLBACK_DRIFT and nothing changes). Safe to run twice.
begin;
do $$ begin
  if to_regprocedure('public.zella_admin_routing_missing(integer,integer)') is null then return; end if;
  if md5(pg_get_functiondef(to_regprocedure('public.zella_admin_routing_missing(integer,integer)'))) <> 'e3b06eca2cfa77abdcd6d998197e95f8' then
    raise exception 'ROLLBACK_DRIFT: zella_admin_routing_missing has changed since this migration';
  end if;
  drop function public.zella_admin_routing_missing(integer, integer);
end $$;
commit;
