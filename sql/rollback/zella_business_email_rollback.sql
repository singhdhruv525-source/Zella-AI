-- Undoes sql/zella_business_email.sql exactly. Refuses (SENDERS_SET_UP) while any business has a domain or a mailbox
-- set up: disconnect them first (zella_business_email_disconnect, which also deletes the mailbox tokens from Vault),
-- so nothing a business set up is lost silently. Refuses (ROLLBACK_DRIFT) when a function is no longer this file's
-- version, and (IN_USE) while sql/zella_business_email_send.sql is applied (roll that back first). Then the thirteen
-- functions, the table (only rows with nothing set up are left in it), the mailbox index on email_messages and the
-- two settings this file added (only if it added them) go. Safe to run twice.
begin;
do $$
declare f record;
  mine constant jsonb := '{
    "public.zella_business_email_actor_can(uuid,uuid)": "68a21ec08372af683c9048189406b871",
    "public.zella_business_email_status(uuid)": "5fb484efb0cb4d193f59d1fcf7cac16b",
    "public.zella_business_email_domain_begin(uuid,uuid,text)": "cf389960f779ac299501dfde81bea053",
    "public.zella_business_email_domain_saved(uuid,uuid,text,text,jsonb,text)": "f5f8789b409126d56e638da22edf3ec1",
    "public.zella_business_email_domain_checked(uuid,uuid,text,text,jsonb)": "eb0c479f96b503cb5dcd5f84eda99e2c",
    "public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)": "6dc2549df6f019fa5e61ab57346ff1bc",
    "public.zella_business_email_disconnect(uuid,uuid)": "6f3dfdd9958546b9d33299cc81f473c1",
    "public.zella_business_email_sender(uuid)": "193583411ec9519f57a68684c7ebf224",
    "public.zella_business_email_mailbox_credentials(uuid)": "5b865c1980c24c489815a21505dd8be8",
    "public.zella_business_email_mailbox_refused(uuid,text)": "cd7bd8b6eaa62cbf9bc17317554e039f",
    "public.zella_business_email_records(jsonb)": "3396c6e958f49241e58729e1a499eee0",
    "public.zella_business_email_local_day(uuid)": "49f39fb2939c2bc32ff0aa61792a9ad4",
    "public.zella_business_email_mailbox_can_connect(uuid,uuid)": "dbee48e6a1a2a0742dddc286fb781b87"}';
begin
  if to_regclass('public.business_email_senders') is null then return; end if;   -- not applied, or already rolled back
  lock table public.business_email_senders in exclusive mode;
  if exists (select 1 from public.business_email_senders where route is not null or domain is not null or mailbox_secret_name is not null) then
    raise exception 'SENDERS_SET_UP: a business has its email address set up; disconnect it first';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'zella_prepare_email' and position('zella_business_email_sender' in pg_get_functiondef(p.oid)) > 0) then
    raise exception 'IN_USE: zella_prepare_email uses these rules; roll back sql/zella_business_email_send.sql first';
  end if;
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.key;
    end if;
  end loop;
end $$;
drop function if exists public.zella_business_email_mailbox_refused(uuid, text);
drop function if exists public.zella_business_email_mailbox_credentials(uuid);
drop function if exists public.zella_business_email_status(uuid);
drop function if exists public.zella_business_email_sender(uuid);
drop function if exists public.zella_business_email_disconnect(uuid, uuid);
drop function if exists public.zella_business_email_mailbox_saved(uuid, uuid, text, text, text);
drop function if exists public.zella_business_email_domain_checked(uuid, uuid, text, text, jsonb);
drop function if exists public.zella_business_email_domain_saved(uuid, uuid, text, text, jsonb, text);
drop function if exists public.zella_business_email_domain_begin(uuid, uuid, text);
drop function if exists public.zella_business_email_records(jsonb);
drop function if exists public.zella_business_email_local_day(uuid);
drop function if exists public.zella_business_email_mailbox_can_connect(uuid, uuid);
drop function if exists public.zella_business_email_actor_can(uuid, uuid);
drop table if exists public.business_email_senders;
drop index if exists public.email_messages_mailbox_day_idx;
do $$
begin
  if to_regclass('public.zella_migration_settings') is not null then
    delete from public.platform_settings where key in (select key from public.zella_migration_settings where migration = 'zella_business_email');
    delete from public.zella_migration_settings where migration = 'zella_business_email';
  end if;
end $$;
commit;
