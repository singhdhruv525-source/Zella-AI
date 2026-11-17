-- Undoes sql/zella_admin_sessions.sql exactly: drops zella_end_user_sessions(uuid) and zella_revoke_my_other_sessions().
-- Refuses (DRIFT) when either function is no longer this migration's version, so a later change is never dropped by
-- mistake. Audit rows already written ('session.revoked_others') stay: the audit log is never rewritten. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_end_user_sessions(uuid)', '6f2b8fb98e67992744046a81ff295d9f'),
      ('public.zella_revoke_my_other_sessions()', 'c69e201b64008fc9ecb967b83d537738')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_admin_sessions.sql; roll back by hand', f.sig;
    end if;
  end loop;
end $$;
drop function if exists public.zella_end_user_sessions(uuid);
drop function if exists public.zella_revoke_my_other_sessions();
commit;
