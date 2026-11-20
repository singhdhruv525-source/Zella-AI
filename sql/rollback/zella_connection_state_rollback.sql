-- Undoes sql/zella_connection_state.sql exactly: drops the three functions it added (nothing else was changed). Each
-- must be exactly that file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Safe to run twice.
-- Run it only after owner-provision-business no longer calls them (deploy the earlier function first).
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_business_connections(uuid[])', 'adcf308f2984282e34b03ee2d72d125b'),
      ('public.zella_connection_counts()', '0124fe13da3e43dd57ff6c1b37742fc6'),
      ('public.zella_connection_state(uuid[])', 'f03b127e562815f7cf5c7897e283f46d')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
  drop function if exists public.zella_business_connections(uuid[]);
  drop function if exists public.zella_connection_counts();
  drop function if exists public.zella_connection_state(uuid[]);
end $$;
commit;
