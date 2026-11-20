-- Undoes sql/zella_go_live_reads.sql: drops zella_admin_email_triggers(), only if it is exactly this file's version
-- (otherwise ROLLBACK_DRIFT and nothing changes). The triggers themselves are never touched. Safe to run twice.
begin;
do $$ begin
  if to_regprocedure('public.zella_admin_email_triggers()') is null then return; end if;
  if md5(pg_get_functiondef('public.zella_admin_email_triggers()'::regprocedure)) <> '6c0046b47d6440d8f2a52b08dd088bec' then
    raise exception 'ROLLBACK_DRIFT: zella_admin_email_triggers has changed since this migration';
  end if;
  drop function public.zella_admin_email_triggers();
end $$;
commit;
