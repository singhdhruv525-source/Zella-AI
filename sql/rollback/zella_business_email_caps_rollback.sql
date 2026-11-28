-- Undoes sql/zella_business_email_caps.sql exactly: zella_business_email_sender, zella_business_email_status and the
-- five argument zella_business_email_mailbox_saved come back as sql/zella_business_email.sql's versions (from
-- zella_function_archive), business_email_mailbox_caps gets back the value it had, and zella_business_email_mailbox_cap
-- and zella_business_email_paced go. Refuses (ROLLBACK_DRIFT) when a function or the setting has changed since this
-- migration (roll back sql/zella_business_email_mailbox_link.sql first: it builds on this file's status read). A
-- mailbox whose type was not known keeps a null type, which the old rules read as their default cap. The n8n
-- Email Sender and Follow up Emails must not be on a version that calls zella_business_email_paced. Safe to run twice.
begin;
do $$
declare f record; d text;
  mine constant jsonb := '{
    "public.zella_business_email_sender(uuid)": "4869cab9ec6319740667de295508c884",
    "public.zella_business_email_status(uuid)": "59e30c139362c44863045142ee98aa43",
    "public.zella_business_email_mailbox_cap(text,text)": "bdff7c09430adeeb89d57595ca12cd67",
    "public.zella_business_email_paced(text,uuid,timestamptz)": "9c86894efd14ee848702d00e15dacf76",
    "public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text,text)": "0b43ade45c628f71091efbbcdf71b73d"}';
  base constant jsonb := '{
    "public.zella_business_email_sender(uuid)": "193583411ec9519f57a68684c7ebf224",
    "public.zella_business_email_status(uuid)": "5fb484efb0cb4d193f59d1fcf7cac16b",
    "public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)": "6dc2549df6f019fa5e61ab57346ff1bc"}';
  new_caps constant jsonb := '{"gmail": 400, "google_workspace": 1600, "outlook": 240, "microsoft_365": 8000, "per_minute": 20}';
  v jsonb; a record;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_caps') then
    return;   -- not applied, or already rolled back
  end if;
  -- check everything first
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is null or md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.key;
    end if;
  end loop;
  for f in select key, value from jsonb_each_text(base) loop
    select definition, definition_md5 into a from public.zella_function_archive where migration = 'zella_business_email_caps' and signature = f.key;
    if a.definition is null or a.definition_md5 <> f.value then raise exception 'ROLLBACK_DRIFT: the archived % is missing or not the version it was', f.key; end if;
  end loop;
  select value into v from public.platform_settings where key = 'business_email_mailbox_caps';
  if exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_caps' and signature = 'setting: business_email_mailbox_caps')
     and v is distinct from new_caps then
    raise exception 'ROLLBACK_DRIFT: business_email_mailbox_caps has changed since this migration';
  end if;

  -- then put everything back
  drop function public.zella_business_email_mailbox_saved(uuid, uuid, text, text, text, text);
  drop function public.zella_business_email_paced(text, uuid, timestamptz);
  for f in select key, value from jsonb_each_text(base) loop
    execute (select definition from public.zella_function_archive where migration = 'zella_business_email_caps' and signature = f.key);
  end loop;
  -- the status read and the sender no longer call it once they are back
  drop function public.zella_business_email_mailbox_cap(text, text);
  revoke all on function public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text) from public, anon, authenticated;
  grant execute on function public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text) to service_role;
  update public.platform_settings p set value = z.definition::jsonb
    from public.zella_function_archive z
   where p.key = 'business_email_mailbox_caps' and z.migration = 'zella_business_email_caps' and z.signature = 'setting: business_email_mailbox_caps';
  for f in select key, value from jsonb_each_text(base) loop
    if md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then raise exception 'ROLLBACK_DRIFT: % did not come back as the version it was', f.key; end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_business_email_caps';
end $$;
commit;
