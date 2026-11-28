-- Undoes sql/zella_business_email_mailbox_link.sql exactly: zella_business_email_status comes back as
-- sql/zella_business_email_caps.sql's version (from zella_function_archive), and the three link functions and
-- business_email_mailbox_links go. Links still open stop working (their rows hold only a hash, a business, an owner and
-- dates; no customer data); emails already queued in the platform outbox stay as they are. A connected mailbox is not
-- touched. Refuses (ROLLBACK_DRIFT) when a function has changed since this migration (roll back
-- sql/zella_business_email_pending_domains.sql first: it builds on this file's status read). Safe to run twice.
begin;
do $$
declare f record; a record;
  mine constant jsonb := '{
    "public.zella_business_email_status(uuid)": "ba293561f9b771ea5eab89b9a22e9c85",
    "public.zella_business_email_platform_admin(uuid,uuid)": "6ae555b8484689dcd6ba4558fdbabc22",
    "public.zella_business_email_mailbox_link_issue(uuid,uuid,text)": "4024104d6eb7a859b47dc7b1319140d2",
    "public.zella_business_email_mailbox_link_redeem(text,uuid)": "5676a811d933fd9b8a3d7027bd1ccd3d"}';
begin
  if to_regclass('public.business_email_mailbox_links') is null then return; end if;   -- not applied, or already rolled back
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is null or md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.key;
    end if;
  end loop;
  select definition, definition_md5 into a from public.zella_function_archive
   where migration = 'zella_business_email_mailbox_link' and signature = 'public.zella_business_email_status(uuid)';
  if a.definition is null or a.definition_md5 <> '59e30c139362c44863045142ee98aa43' then
    raise exception 'ROLLBACK_DRIFT: the archived zella_business_email_status is missing or not the version it was';
  end if;
  execute a.definition;
  if md5(pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure)) <> '59e30c139362c44863045142ee98aa43' then
    raise exception 'ROLLBACK_DRIFT: zella_business_email_status did not come back as the version it was';
  end if;
  drop function public.zella_business_email_mailbox_link_redeem(text, uuid);
  drop function public.zella_business_email_mailbox_link_issue(uuid, uuid, text);
  drop function public.zella_business_email_platform_admin(uuid, uuid);
  drop table public.business_email_mailbox_links;
  delete from public.zella_function_archive where migration = 'zella_business_email_mailbox_link';
end $$;
commit;
