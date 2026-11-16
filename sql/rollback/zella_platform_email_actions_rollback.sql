-- Undoes sql/zella_platform_email_actions.sql exactly: drops zella_admin_platform_email_detail, _release and _discard.
-- Nothing else was changed, so nothing comes back from the archive. Emails already released stay queued, discarded
-- ones stay failed (both statuses the outbox always allowed), and their audit rows stay. Each function must be exactly
-- that file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier web app first, or the
-- Release and Discard buttons answer that the function is missing. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_platform_email_detail(uuid)', '94b421aa140fc4c0642d6366b02b3c5d'),
      ('public.zella_admin_platform_email_release(uuid,text)', 'c0fe74e7fde7d1f56e97991dc7022b74'),
      ('public.zella_admin_platform_email_discard(uuid,text)', '7dd8e3e18e0f6c032a229a7c55dc3fb9')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
end $$;
drop function if exists public.zella_admin_platform_email_detail(uuid);
drop function if exists public.zella_admin_platform_email_release(uuid, text);
drop function if exists public.zella_admin_platform_email_discard(uuid, text);
commit;
