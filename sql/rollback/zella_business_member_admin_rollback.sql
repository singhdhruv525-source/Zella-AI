-- Undoes sql/zella_business_member_admin.sql exactly: drops zella_admin_member_set_status and
-- zella_admin_invitation_cancel. Refuses (DRIFT) when either is no longer this migration's version (its definition,
-- its owner, or who may run it), so a later change is never dropped by mistake. Members' statuses, invitations and
-- audit rows those functions changed or that record them stay as they are. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamp with time zone)', 'b7eb91a80c9ae062798f8263f7ec15b0'),
      ('public.zella_admin_invitation_cancel(uuid,uuid)', 'e4df5c3f73d15ef138b68541201edbbe')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'DRIFT: % changed after sql/zella_business_member_admin.sql; roll back by hand', f.sig;
    end if;
    if to_regprocedure(f.sig) is not null and (select proowner from pg_proc where oid = to_regprocedure(f.sig))
       <> (select relowner from pg_class where oid = 'public.business_members'::regclass) then
      raise exception 'DRIFT: % changed owner after sql/zella_business_member_admin.sql; roll back by hand', f.sig;
    end if;
  end loop;
  if exists (select 1 from (values
      ('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamp with time zone)'),
      ('public.zella_admin_invitation_cancel(uuid,uuid)')) v(sig)
      join pg_proc p on p.oid = to_regprocedure(v.sig)
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where a.privilege_type = 'EXECUTE' and (a.grantee = 0 or pg_get_userbyid(a.grantee) not in
        (pg_get_userbyid(p.proowner), 'service_role', 'postgres', 'supabase_admin'))) then
    raise exception 'DRIFT: a function of sql/zella_business_member_admin.sql was given to another role since; roll back by hand';
  end if;
  if exists (select 1 from (values
      ('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamp with time zone)'),
      ('public.zella_admin_invitation_cancel(uuid,uuid)')) v(sig)
      where to_regprocedure(v.sig) is not null and not has_function_privilege('service_role', to_regprocedure(v.sig), 'EXECUTE')) then
    raise exception 'DRIFT: a function of sql/zella_business_member_admin.sql lost its grant since; roll back by hand';
  end if;
end $$;
drop function if exists public.zella_admin_member_set_status(uuid, uuid, text, text, timestamptz);
drop function if exists public.zella_admin_invitation_cancel(uuid, uuid);
commit;
