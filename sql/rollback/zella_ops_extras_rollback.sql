-- Undo the ops extras API without deleting customer/audit/approval data.
-- Run as the migration owner. RESTRICT intentionally refuses unknown dependencies.
-- The shared zella_has_role helper is retained with its hardened definition:
-- later migrations and policies depend on it. Grants remain restricted.
-- sensitive_approvals is retained as an archive with RLS enabled and no policy;
-- ordinary API roles cannot read/write it. Reapply the migration to restore use.
begin;
drop function if exists public.zella_decide_approval(uuid,boolean);
drop function if exists public.zella_request_approval(uuid,text,uuid,jsonb);
drop function if exists public.zella_get_call_recording(uuid);
drop function if exists public.zella_erase_customer(uuid,uuid);
drop function if exists public.zella_export_customer_data(uuid,uuid);
drop function if exists public.zella_set_contact_preferences(uuid,uuid,text,boolean,boolean,boolean);
drop function if exists public.zella_post_callback_digests();
drop function if exists public.zella_cancel_callback(uuid,text);
drop function if exists public.zella_reschedule_callback(uuid,timestamptz);
drop function if exists public.zella_reassign_callback(uuid,uuid);
drop function if exists public.zella_tenant_leak_check();
do $$ begin
  if to_regclass('public.sensitive_approvals') is not null then
    drop policy if exists sensitive_approvals_read on public.sensitive_approvals;
    alter table public.sensitive_approvals enable row level security;
    revoke all on public.sensitive_approvals from public, anon, authenticated;
  end if;
end $$;
create or replace function public.zella_has_role(p_business_id uuid, p_roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then coalesce(auth.jwt() ->> 'role', '') not in ('anon', 'authenticated')
    else exists (select 1 from public.business_members m
                  where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role = any (p_roles))
  end;
$$;
revoke execute on function public.zella_has_role(uuid,text[]) from public, anon;
grant execute on function public.zella_has_role(uuid,text[]) to authenticated, service_role;
commit;
