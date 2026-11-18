-- Undoes sql/zella_support_replies.sql: drops the alert trigger and the three functions, the first_response_at column
-- and support_ticket_messages. Refuses (DRIFT) when a function is no longer this migration's version, when the table
-- is not exactly the one the migration creates, and whenever replies exist (they are never deleted here: remove them
-- by hand first, with approval). The table is locked before it is checked, so no reply can be written between the
-- check and the drop. The support_business_hours setting is kept: the migration only adds it when it is missing, so
-- the rollback can't tell whether someone set it. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_ticket_reply(uuid,uuid,text)', '4cfcb7b1370b215f3c58ba007890aba8'),
      ('public.zella_business_ticket_reply(uuid,text)', '74292f8c7c40bb7035c6606a86fc6d89'),
      ('public.zella_support_ticket_alert_trg()', '7c1e68b078a07f8f175eaf593ec52eb2')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_support_replies.sql; roll back by hand', f.sig;
    end if;
  end loop;
  if to_regclass('public.support_ticket_messages') is not null then
    execute 'lock table public.support_ticket_messages in access exclusive mode';
    if (select string_agg(column_name || ' ' || data_type, ', ' order by column_name) from information_schema.columns
         where table_schema = 'public' and table_name = 'support_ticket_messages')
       is distinct from 'author_id uuid, author_side text, body text, business_id uuid, created_at timestamp with time zone, id uuid, ticket_id uuid' then
      raise exception 'DRIFT: support_ticket_messages is not the table sql/zella_support_replies.sql creates; roll back by hand';
    end if;
    declare n boolean; begin
      execute 'select exists (select 1 from public.support_ticket_messages)' into n;
      if n then raise exception 'DRIFT: support_ticket_messages has replies; they are not deleted by this rollback'; end if;
    end;
  end if;
end $$;
drop trigger if exists zella_support_ticket_alert on public.support_tickets;
drop function if exists public.zella_support_ticket_alert_trg();
drop function if exists public.zella_admin_ticket_reply(uuid, uuid, text);
drop function if exists public.zella_business_ticket_reply(uuid, text);
drop table if exists public.support_ticket_messages;
alter table public.support_tickets drop column if exists first_response_at;
commit;
