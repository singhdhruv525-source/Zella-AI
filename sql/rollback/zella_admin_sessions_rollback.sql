-- Undoes sql/zella_admin_sessions.sql exactly: drops zella_end_user_sessions(uuid), zella_revoke_my_other_sessions() and
-- zella_remove_mfa_factor(uuid, uuid), and the zella_keep_an_owner, zella_keep_an_owner_turn and zella_admin_mfa_added
-- triggers with their functions. Refuses (DRIFT) when any of them is no longer this migration's version (a trigger: its
-- function, timing, events, condition or kind), so a later change is never dropped by mistake. Audit rows already
-- written ('session.revoked_others', 'admin.mfa_added') stay: the audit log is never rewritten. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_end_user_sessions(uuid)', '6f2b8fb98e67992744046a81ff295d9f'),
      ('public.zella_revoke_my_other_sessions()', 'eaaba33d1c889966f9bc2c3e223f44e9'),
      ('public.zella_remove_mfa_factor(uuid,uuid)', '7a8c3d352a3c9dbecea8e94c726fede1'),
      ('public.zella_keep_an_owner_trg()', '70c818f1d3c5a06094800c067807d32b'),
      ('public.zella_keep_an_owner_turn_trg()', 'ccab7c7710e26e9dd409befbb5f25177'),
      ('public.zella_admin_mfa_added_trg()', '3268d6c69ffdb400a4354f9c0e148e80')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_admin_sessions.sql; roll back by hand', f.sig;
    end if;
    -- and its owner, the one the file installs under (the owner of public.platform_admins, as for every migration):
    -- a security definer function runs as its owner, which the definition text doesn't show
    if to_regprocedure(f.sig) is not null and (select proowner from pg_proc where oid = to_regprocedure(f.sig))
       <> (select relowner from pg_class where oid = 'public.platform_admins'::regclass) then
      raise exception 'DRIFT: % changed owner after sql/zella_admin_sessions.sql; roll back by hand', f.sig;
    end if;
  end loop;
  -- and who may run each: only the roles this file gives it to, its owner and the server roles (service_role,
  -- postgres, supabase_admin); EXECUTE for anyone else (PUBLIC included) is a change this file didn't make
  if exists (select 1 from (values
      ('public.zella_end_user_sessions(uuid)', ''), ('public.zella_revoke_my_other_sessions()', 'authenticated'),
      ('public.zella_remove_mfa_factor(uuid,uuid)', ''), ('public.zella_keep_an_owner_trg()', ''),
      ('public.zella_keep_an_owner_turn_trg()', ''), ('public.zella_admin_mfa_added_trg()', '')) v(sig, extra)
      join pg_proc p on p.oid = to_regprocedure(v.sig)
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where a.privilege_type = 'EXECUTE' and (a.grantee = 0 or pg_get_userbyid(a.grantee) not in
        (pg_get_userbyid(p.proowner), 'service_role', 'postgres', 'supabase_admin', v.extra))) then
    raise exception 'DRIFT: a function of sql/zella_admin_sessions.sql was given to another role since; roll back by hand';
  end if;
  -- and the grants this file makes are still there (a later revoke is a change too)
  if exists (select 1 from (values
      ('public.zella_end_user_sessions(uuid)', 'service_role'), ('public.zella_revoke_my_other_sessions()', 'authenticated'),
      ('public.zella_remove_mfa_factor(uuid,uuid)', 'service_role')) v(sig, grantee)
      where to_regprocedure(v.sig) is not null and not has_function_privilege(v.grantee, to_regprocedure(v.sig), 'EXECUTE')) then
    raise exception 'DRIFT: a function of sql/zella_admin_sessions.sql lost a grant since; roll back by hand';
  end if;
  if exists (select 1 from pg_trigger g where g.tgrelid in (to_regclass('public.platform_admins'), to_regclass('auth.mfa_factors'))
       and g.tgname in ('zella_keep_an_owner', 'zella_keep_an_owner_turn', 'zella_admin_mfa_added') and not coalesce(
         g.tgenabled = 'O' and g.tgconstraint = 0 and g.tgqual is null and g.tgnargs = 0 and cardinality(g.tgattr::int2[]) = 0 and (
           (g.tgname = 'zella_keep_an_owner' and g.tgrelid = 'public.platform_admins'::regclass and g.tgtype = 27 and g.tgfoid = to_regprocedure('public.zella_keep_an_owner_trg()'))
           or (g.tgname = 'zella_keep_an_owner_turn' and g.tgrelid = 'public.platform_admins'::regclass and g.tgtype = 26 and g.tgfoid = to_regprocedure('public.zella_keep_an_owner_turn_trg()'))
           or (g.tgname = 'zella_admin_mfa_added' and g.tgrelid = 'auth.mfa_factors'::regclass and g.tgtype = 21 and g.tgfoid = to_regprocedure('public.zella_admin_mfa_added_trg()'))), false)) then
    raise exception 'DRIFT: a trigger changed after sql/zella_admin_sessions.sql; roll back by hand';
  end if;
end $$;
drop function if exists public.zella_end_user_sessions(uuid);
drop function if exists public.zella_revoke_my_other_sessions();
drop function if exists public.zella_remove_mfa_factor(uuid, uuid);
drop trigger if exists zella_keep_an_owner on public.platform_admins;
drop function if exists public.zella_keep_an_owner_trg();
drop trigger if exists zella_keep_an_owner_turn on public.platform_admins;
drop function if exists public.zella_keep_an_owner_turn_trg();
drop trigger if exists zella_admin_mfa_added on auth.mfa_factors;
drop function if exists public.zella_admin_mfa_added_trg();
commit;
