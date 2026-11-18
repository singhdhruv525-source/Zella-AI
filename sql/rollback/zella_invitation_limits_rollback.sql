-- Undoes sql/zella_invitation_limits.sql exactly: zella_invite_staff and zella_resend_invitation come back from
-- zella_function_archive. Each must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes.
-- Grants are kept (same signatures). Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object('public.zella_invite_staff(uuid,text,text,text)', 'cab03bae58b60089f19b480b7f6f58ee', 'public.zella_resend_invitation(uuid)', '0bcb13389cdf949e04776f3bb7ea221f');
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_invitation_limits') then
    return;
  end if;
  for a in select signature from public.zella_function_archive where migration = 'zella_invitation_limits' loop
    if md5(pg_get_functiondef(a.signature::regprocedure)) <> mine ->> a.signature then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
    end if;
  end loop;
  for a in select definition from public.zella_function_archive where migration = 'zella_invitation_limits' loop
    execute a.definition;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_invitation_limits';
end $$;
commit;
