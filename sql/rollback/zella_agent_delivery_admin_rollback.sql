-- Undoes sql/zella_agent_delivery_admin.sql exactly: drops the two admin readers it added (nothing else was changed).
-- Each must be exactly that file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Safe to run twice.
-- Run it only after owner-provision-business no longer calls them (deploy the earlier function first).
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_agent_deliveries_summary(uuid[])', '39670a0a9cf1cc2c70d8002f30bd5e98'),
      ('public.zella_admin_agent_deliveries(uuid,integer)', '48bd7fce72f915cc351b705ed218a0bf')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
  drop function if exists public.zella_admin_agent_deliveries_summary(uuid[]);
  drop function if exists public.zella_admin_agent_deliveries(uuid, integer);
end $$;
commit;
