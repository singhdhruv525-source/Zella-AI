-- Undoes sql/zella_admin_sessions.sql exactly: drops zella_end_user_sessions(uuid), zella_revoke_my_other_sessions() and
-- zella_remove_mfa_factor(uuid, uuid). Refuses (DRIFT) when any of them is no longer this migration's version, so a later change is never dropped by
-- mistake. Audit rows already written ('session.revoked_others') stay: the audit log is never rewritten. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_end_user_sessions(uuid)', '6f2b8fb98e67992744046a81ff295d9f'),
      ('public.zella_revoke_my_other_sessions()', 'eaaba33d1c889966f9bc2c3e223f44e9'),
      ('public.zella_remove_mfa_factor(uuid,uuid)', '7a8c3d352a3c9dbecea8e94c726fede1')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_admin_sessions.sql; roll back by hand', f.sig;
    end if;
  end loop;
end $$;
drop function if exists public.zella_end_user_sessions(uuid);
drop function if exists public.zella_revoke_my_other_sessions();
drop function if exists public.zella_remove_mfa_factor(uuid, uuid);
commit;
