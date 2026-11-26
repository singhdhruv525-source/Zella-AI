-- Undoes sql/zella_event_dispatch.sql exactly: drops the zella_kick_dispatch trigger from the eight tables (switched
-- on or off), drops zella_kick_dispatch(), and deletes the '_kick' bookkeeping row from n8n_dispatch_state (the
-- kick's own 2 second timer, created by the first kick; production had no such row before, 26 Nov 2026). No other row,
-- table, setting, secret or job changes; zella_dispatch_n8n() is not touched (the migration never changed it).
-- The function must be exactly the migration's version, and every zella_kick_dispatch trigger must call it, otherwise
-- ROLLBACK_DRIFT and nothing changes. Safe to run twice. Run with sql/rollback/run.sh, with the owner's approval.
begin;
set local lock_timeout = '5s';
do $$
declare k constant text := 'public.zella_kick_dispatch()'; tg record;
begin
  if to_regprocedure(k) is null then
    if exists (select 1 from pg_trigger where tgname = 'zella_kick_dispatch' and not tgisinternal) then
      raise exception 'ROLLBACK_DRIFT: a zella_kick_dispatch trigger exists without the function';
    end if;
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(k::regprocedure)) <> 'a1ac376f047ba05dee027c34d05f6aa1' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', k;
  end if;
  for tg in select tgrelid::regclass::text rel, tgfoid from pg_trigger where tgname = 'zella_kick_dispatch' and not tgisinternal loop
    if tg.tgfoid <> to_regprocedure(k)::oid then
      raise exception 'ROLLBACK_DRIFT: trigger zella_kick_dispatch on % does not call %', tg.rel, k;
    end if;
    execute format('drop trigger zella_kick_dispatch on %s', tg.rel);
  end loop;
  drop function public.zella_kick_dispatch();
  if to_regclass('public.n8n_dispatch_state') is not null then
    delete from public.n8n_dispatch_state where workflow = '_kick';
  end if;
end $$;
commit;
