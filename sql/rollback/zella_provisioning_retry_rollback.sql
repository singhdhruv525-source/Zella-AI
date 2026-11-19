-- Undoes sql/zella_provisioning_retry.sql exactly: unschedules the zella_provisioning_retry timed job, drops
-- zella_retry_provisioning, zella_retry_provisioning_due, zella_provisioning_begin and zella_provisioning_end, and
-- provisioning_steps.attempt_id (only attempt ids: every step's status and error stay). Rows a retry added (modules, a disabled receptionist) and
-- the audit rows stay: they are what a new draft gets anyway. Each function must be exactly that file's version,
-- otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier owner-provision-business first. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_retry_provisioning(uuid,text,uuid)', 'b5b05c27d48b7c001a8f6b453c484b78'),
      ('public.zella_retry_provisioning_due()', '1504ba6ce453432daccbe72f67f59000'),
      ('public.zella_provisioning_begin(uuid,text)', 'ea7cafd97b8324ddcc36a1d6fa174c42'),
      ('public.zella_provisioning_end(uuid,text,uuid,text,text,text,text)', '29d2bd7fd0e7e11fd3c7254b20ed42b7')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
  if to_regnamespace('cron') is not null and exists (select 1 from cron.job where jobname = 'zella_provisioning_retry') then
    perform cron.unschedule('zella_provisioning_retry');
  end if;
end $$;
drop function if exists public.zella_retry_provisioning_due();
drop function if exists public.zella_retry_provisioning(uuid, text, uuid);
drop function if exists public.zella_provisioning_begin(uuid, text);
drop function if exists public.zella_provisioning_end(uuid, text, uuid, text, text, text, text);
alter table public.provisioning_steps drop column if exists attempt_id;
commit;
