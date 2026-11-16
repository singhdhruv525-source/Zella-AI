-- Rollback of sql/zella_number_orders.sql: removes the number_orders table, its functions and the
-- number_orders_enabled setting. Safe to run twice. Refuses (ROLLBACK_DRIFT) if any function differs from that file's
-- version, if number orders are switched on, or while an order is being placed or waits for a check at Telnyx (its
-- record would be lost). Every step of every order stays in audit_logs.
begin;

do $$
declare
  f record;
  busy boolean := false;
  mine constant jsonb := '{
    "public.zella_actor_role(uuid)": "6f620081a6b3d0196982c2ded1e226ac",
    "public.zella_actor_can(uuid,text)": "22a35fae85afbe6926c8bda79f4d0a80",
    "public.zella_actor_audit(uuid,text,text,uuid,uuid,jsonb,jsonb)": "d825b1a4c346740b752802896e7656c9",
    "public.zella_number_order_request(uuid,text,text,uuid,text,text,uuid)": "6b077df156b56b6b2f12e89b926ff295",
    "public.zella_number_order_decide(uuid,uuid,boolean,text)": "6bed4bb76fb04d690d6dba0bcf878556",
    "public.zella_number_order_claim(uuid,uuid)": "4e834df823bcadf56698873a1221778b",
    "public.zella_number_order_finish(uuid,uuid,text,text,text,text,text)": "2f70695a5cb57a24e454d0c19fbc99ed",
    "public.zella_number_order_cancel(uuid,uuid,text)": "2e3996e7bc6f13664d73e5a476c1abc9",
    "public.zella_number_orders_list(uuid,integer)": "2bfd73dc45d808eb281915eef75bf426"
  }';
begin
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since zella_number_orders.sql', f.sig;
    end if;
  end loop;
  -- the zella_actor_* helpers are shared with later migrations (recording policy, retention): roll those back first
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosrc like '%zella_actor_%' and not (mine ? ('public.' || p.oid::regprocedure::text))) then
    raise exception 'ROLLBACK_DRIFT: other functions use the zella_actor helpers; roll back the later migrations first';
  end if;
  if exists (select 1 from public.platform_settings where key = 'number_orders_enabled' and value <> 'false'::jsonb) then
    raise exception 'ROLLBACK_DRIFT: number orders are switched on; switch them off first';
  end if;
  if to_regclass('public.number_orders') is not null then
    execute 'select exists (select 1 from public.number_orders where status in (''placing'', ''needs_check''))' into busy;
  end if;
  if busy then
    raise exception 'ROLLBACK_DRIFT: an order is being placed or needs a check at Telnyx; record its outcome first';
  end if;
end $$;

drop function if exists public.zella_number_orders_list(uuid, integer);
drop function if exists public.zella_number_order_cancel(uuid, uuid, text);
drop function if exists public.zella_number_order_finish(uuid, uuid, text, text, text, text, text);
drop function if exists public.zella_number_order_claim(uuid, uuid);
drop function if exists public.zella_number_order_decide(uuid, uuid, boolean, text);
drop function if exists public.zella_number_order_request(uuid, text, text, uuid, text, text, uuid);
drop function if exists public.zella_actor_audit(uuid, text, text, uuid, uuid, jsonb, jsonb);
drop function if exists public.zella_actor_can(uuid, text);
drop function if exists public.zella_actor_role(uuid);
drop table if exists public.number_orders;
delete from public.platform_settings where key = 'number_orders_enabled' and value = 'false'::jsonb;

commit;
