-- Undoes sql/zella_support_replies.sql: drops the alert trigger and the three functions, the first_response_at column,
-- the support_business_hours setting (only while it still has the value this migration wrote) and
-- support_ticket_messages. Refuses (DRIFT) when a function is no longer this migration's version. Replies already
-- written would be lost, so it also refuses while support_ticket_messages has rows unless the session sets
-- zella.drop_support_messages = 'yes'. Safe to run twice.
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
  if to_regclass('public.support_ticket_messages') is not null and coalesce(current_setting('zella.drop_support_messages', true), '') <> 'yes' then
    declare n boolean; begin
      execute 'select exists (select 1 from public.support_ticket_messages)' into n;
      if n then raise exception 'DRIFT: support_ticket_messages has replies; set zella.drop_support_messages = yes to drop them'; end if;
    end;
  end if;
end $$;
drop trigger if exists zella_support_ticket_alert on public.support_tickets;
drop function if exists public.zella_support_ticket_alert_trg();
drop function if exists public.zella_admin_ticket_reply(uuid, uuid, text);
drop function if exists public.zella_business_ticket_reply(uuid, text);
drop table if exists public.support_ticket_messages;
alter table public.support_tickets drop column if exists first_response_at;
delete from public.platform_settings where key = 'support_business_hours'
  and value = '{"days": [1, 2, 3, 4, 5], "start": "09:00", "end": "17:00", "timezone": "America/New_York", "first_response_hours": 4}'::jsonb;
commit;
