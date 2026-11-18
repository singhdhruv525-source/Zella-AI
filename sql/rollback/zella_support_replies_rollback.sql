-- Undoes sql/zella_support_replies.sql, for a database with NO support replies yet: drops the alert trigger, the three
-- functions and support_ticket_messages, the first_response_at column and the support_business_hours setting (each
-- only when this file's mark shows it added them, and the setting only while unchanged). It refuses (DRIFT) when a
-- function or the alert trigger is no longer this migration's version, when the table or column isn't this file's,
-- and whenever replies or first response times exist: it never deletes them. If there are any, stop here; undoing then needs its own plan
-- that keeps the replies, approved by the owner. support_tickets, then the messages, are locked before the checks (the
-- order a reply writes in), so nothing can be written between the checks and the drop. Safe to run twice.
begin;
set transaction isolation level read committed;   -- each check below sees what is committed once the locks are held
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_ticket_reply(uuid,uuid,text)', '4cfcb7b1370b215f3c58ba007890aba8'),
      ('public.zella_business_ticket_reply(uuid,text,uuid)', 'c16ec58238e133a7b265ae833b114163'),
      ('public.zella_support_ticket_alert_trg()', '7c1e68b078a07f8f175eaf593ec52eb2')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_support_replies.sql; roll back by hand', f.sig;
    end if;
  end loop;
  execute 'lock table public.support_tickets in share row exclusive mode';
  if to_regclass('public.support_ticket_messages') is not null then
    execute 'lock table public.support_ticket_messages in access exclusive mode';
  end if;
end $$;
do $$
declare n boolean;
begin
  -- the alert trigger, under the tickets lock: absent, or exactly as the file creates it
  if exists (select 1 from pg_trigger g where g.tgrelid = 'public.support_tickets'::regclass and g.tgname = 'zella_support_ticket_alert'
       and not coalesce(g.tgtype = 5 and g.tgenabled = 'O' and g.tgqual is null and g.tgnargs = 0 and cardinality(g.tgattr::int2[]) = 0
         and g.tgfoid = to_regprocedure('public.zella_support_ticket_alert_trg()'), false)) then
    raise exception 'DRIFT: the zella_support_ticket_alert trigger changed after sql/zella_support_replies.sql; roll back by hand';
  end if;
  if to_regclass('public.support_ticket_messages') is not null then
    if obj_description(to_regclass('public.support_ticket_messages'), 'pg_class') is distinct from 'zella_support_replies.sql' then
      raise exception 'DRIFT: support_ticket_messages was not created by sql/zella_support_replies.sql; roll back by hand';
    end if;
    if (select string_agg(column_name || ' ' || data_type, ', ' order by column_name) from information_schema.columns
         where table_schema = 'public' and table_name = 'support_ticket_messages')
       is distinct from 'author_id uuid, author_side text, body text, business_id uuid, client_ref uuid, created_at timestamp with time zone, id uuid, ticket_id uuid' then
      raise exception 'DRIFT: support_ticket_messages is not the table sql/zella_support_replies.sql creates; roll back by hand';
    end if;
    execute 'select exists (select 1 from public.support_ticket_messages)' into n;
    if n then raise exception 'DRIFT: support_ticket_messages has replies; this rollback never deletes them'; end if;
  end if;
  if col_description('public.support_tickets'::regclass, (select attnum from pg_attribute where attrelid = 'public.support_tickets'::regclass and attname = 'first_response_at' and not attisdropped)) = 'zella_support_replies.sql' then
    execute 'select exists (select 1 from public.support_tickets where first_response_at is not null)' into n;
    if n then raise exception 'DRIFT: support_tickets has first response times; this rollback never deletes them'; end if;
  end if;
end $$;
drop trigger if exists zella_support_ticket_alert on public.support_tickets;
drop function if exists public.zella_support_ticket_alert_trg();
drop function if exists public.zella_admin_ticket_reply(uuid, uuid, text);
drop function if exists public.zella_business_ticket_reply(uuid, text, uuid);
drop table if exists public.support_ticket_messages;
do $$
begin
  -- only the column this file added (its mark); one that was there before stays
  if col_description('public.support_tickets'::regclass, (select attnum from pg_attribute where attrelid = 'public.support_tickets'::regclass and attname = 'first_response_at' and not attisdropped)) = 'zella_support_replies.sql' then
    alter table public.support_tickets drop column first_response_at;
  end if;
end $$;
-- the setting only when this file added it and it still has this file's value
delete from public.platform_settings where key = 'support_business_hours'
  and exists (select 1 from public.platform_settings where key = 'support_business_hours_origin' and value = '"zella_support_replies.sql"'::jsonb)
  and value = '{"days": [1, 2, 3, 4, 5], "start": "09:00", "end": "17:00", "timezone": "America/New_York", "first_response_hours": 4}'::jsonb;
delete from public.platform_settings where key = 'support_business_hours_origin' and value = '"zella_support_replies.sql"'::jsonb;
commit;
