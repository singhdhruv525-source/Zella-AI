-- Undoes sql/zella_business_email_pending_domains.sql exactly: zella_business_email_status comes back as
-- sql/zella_business_email_mailbox_link.sql's version (from zella_function_archive); the trigger, the eight functions,
-- the three columns on business_email_senders and their index go; and the daily job, business_email_url and the Vault
-- secret zella_business_email_jobs_secret go only if this file made them. Refuses (REMOVALS_WAITING) while a Resend
-- domain removal is pending or in progress (let it finish, or mark it done in Resend by hand first), so nothing is left
-- in Resend without a record; finished removals are kept nowhere else, so the rollback refuses (REMOVALS_RECORDED) while
-- the table holds any row, unless they are first copied out. Refuses (ROLLBACK_DRIFT) when a function has changed since
-- this migration. Pending domains still set up stay set up (only their 7 day clock and reminders go). Safe to run twice.
begin;
do $$
declare f record; a record;
  mine constant jsonb := '{
    "public.zella_business_email_status(uuid)": "15745e93ec89f04f6fa22fa20b85228c",
    "public.zella_business_email_pending_since_trg()": "9b6d336ce14a5096cf1f075b7a983e54",
    "public.zella_business_email_domain_drop(uuid,uuid,text,text)": "736448d25dcc36634b65ad38966df151",
    "public.zella_business_email_pending_domains_run()": "d3c7164ac643a4b61ba892f8a9725ac0",
    "public.zella_business_email_domain_remove_pending(uuid,uuid,text)": "cd1a655a0a4352d4bfd3a8028f1dc835",
    "public.zella_business_email_domain_removals_claim(integer,uuid)": "a55adc87ab3c6d8028e1ed1fbfbb2dc9",
    "public.zella_business_email_domain_removal_done(uuid,uuid,boolean,integer)": "a56206c0579942e97c17f7d6c7eb7464",
    "public.zella_business_email_kick_removals()": "efe4579b0295168604861a7b7dd91803",
    "public.zella_business_email_jobs_check(text)": "d4e517045a0bbd94a2dedaedb6315c0f"}';
begin
  if to_regclass('public.business_email_domain_removals') is null then return; end if;   -- not applied, or already rolled back
  lock table public.business_email_domain_removals in exclusive mode;
  if exists (select 1 from public.business_email_domain_removals where status in ('pending', 'sending')) then
    raise exception 'REMOVALS_WAITING: a Resend domain removal is still waiting; let it finish first';
  end if;
  if exists (select 1 from public.business_email_domain_removals) then
    raise exception 'REMOVALS_RECORDED: business_email_domain_removals holds finished removals; copy them out (and empty it) first';
  end if;
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is null or md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.key;
    end if;
  end loop;
  select definition, definition_md5 into a from public.zella_function_archive
   where migration = 'zella_business_email_pending_domains' and signature = 'public.zella_business_email_status(uuid)';
  if a.definition is null or a.definition_md5 <> 'ba293561f9b771ea5eab89b9a22e9c85' then
    raise exception 'ROLLBACK_DRIFT: the archived zella_business_email_status is missing or not the version it was';
  end if;

  execute a.definition;
  if md5(pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure)) <> 'ba293561f9b771ea5eab89b9a22e9c85' then
    raise exception 'ROLLBACK_DRIFT: zella_business_email_status did not come back as the version it was';
  end if;
  if exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_pending_domains' and signature = 'created: cron zella_business_email_pending_domains')
     and to_regnamespace('cron') is not null and exists (select 1 from cron.job where jobname = 'zella_business_email_pending_domains') then
    perform cron.unschedule('zella_business_email_pending_domains');
  end if;
  if exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_pending_domains' and signature = 'created: platform_settings.business_email_url') then
    delete from public.platform_settings where key = 'business_email_url';
  end if;
  if exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_pending_domains' and signature = 'created: vault zella_business_email_jobs_secret') then
    delete from vault.secrets where name = 'zella_business_email_jobs_secret';
  end if;
  drop trigger if exists zella_business_email_pending_since on public.business_email_senders;
  drop function public.zella_business_email_pending_since_trg();
  drop function public.zella_business_email_pending_domains_run();
  drop function public.zella_business_email_domain_remove_pending(uuid, uuid, text);
  drop function public.zella_business_email_domain_drop(uuid, uuid, text, text);
  drop function public.zella_business_email_domain_removals_claim(integer, uuid);
  drop function public.zella_business_email_domain_removal_done(uuid, uuid, boolean, integer);
  drop function public.zella_business_email_kick_removals();
  drop function public.zella_business_email_jobs_check(text);
  drop table public.business_email_domain_removals;
  drop index if exists public.business_email_senders_pending_idx;
  alter table public.business_email_senders drop column if exists domain_reminded_day5_at;
  alter table public.business_email_senders drop column if exists domain_reminded_day2_at;
  alter table public.business_email_senders drop column if exists domain_pending_since;
  delete from public.zella_function_archive where migration = 'zella_business_email_pending_domains';
end $$;
commit;
