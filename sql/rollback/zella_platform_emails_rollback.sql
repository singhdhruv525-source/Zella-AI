-- Undoes sql/zella_platform_emails.sql: drops the four functions and the outbox. Refuses if any email was already
-- sent or is being sent (that history must be kept or exported by a person first). Safe to run twice.
begin;
do $$ begin
  if to_regclass('public.platform_emails') is not null then
    if not exists (select 1 from pg_description where objoid = to_regclass('public.platform_emails') and objsubid = 0 and description like 'Zella Voice platform outbox%') then
      raise exception 'VERSION_MISMATCH: platform_emails was not made by this migration';
    end if;
    if exists (select 1 from public.platform_emails where status in ('sent', 'sending')) then
      raise exception 'HAS_HISTORY: emails were already sent; keep or export them before rolling back';
    end if;
  end if;
end $$;
drop function if exists public.zella_admin_platform_emails(uuid,text,text,integer,integer);
drop function if exists public.zella_finish_platform_email(uuid,boolean,text,text);
drop function if exists public.zella_claim_platform_emails(integer);
drop function if exists public.zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[]);
drop table if exists public.platform_emails;
commit;
