-- Undoes sql/zella_email_delivery.sql: restores zella_claim_owner_emails exactly (from zella_function_archive), gives
-- the n8n dispatcher back its Owner Emails count, unschedules the job and drops what the file added (functions, the
-- platform_emails_url setting and its Vault secret). Notifications and outbox rows are kept. Safe to run twice.
begin;
do $$ declare d text; v_def text; begin
  if to_regprocedure('public.zella_claim_owner_emails(integer)') is not null then
    d := pg_get_functiondef('public.zella_claim_owner_emails(integer)'::regprocedure);
    if position('zella_email_delivery: retired' in d) > 0 then
      select definition into v_def from public.zella_function_archive
       where migration = 'zella_email_delivery' and signature = 'public.zella_claim_owner_emails(integer)';
      if v_def is null then raise exception 'VERSION_MISMATCH: the archived zella_claim_owner_emails is missing; restore it by hand'; end if;
      execute v_def;
      delete from public.zella_function_archive where migration = 'zella_email_delivery' and signature = 'public.zella_claim_owner_emails(integer)';
    end if;
  end if;
  if to_regprocedure('public.zella_dispatch_n8n()') is not null then
    d := pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure);
    if position('owner-emails (retired)' in d) > 0 then
      execute replace(d, 'when ''owner-emails (retired)'' then (select count(*)', 'when ''owner-emails'' then (select count(*)');
    end if;
  end if;
  if to_regnamespace('cron') is not null and exists (select 1 from cron.job where jobname = 'zella_platform_emails') then
    perform cron.unschedule('zella_platform_emails');
  end if;
end $$;
drop function if exists public.zella_dispatch_platform_emails();
drop function if exists public.zella_claim_notification_emails(integer);
drop function if exists public.zella_platform_emails_check(text);
delete from public.platform_settings where key = 'platform_emails_url';
delete from vault.secrets where name = 'zella_platform_emails_secret';
commit;
