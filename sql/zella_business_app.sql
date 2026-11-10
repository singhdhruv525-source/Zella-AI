-- =========================================================
-- Zella: business owner app access
-- Run once in Supabase → SQL Editor.
--
-- Owners are added as 'invited' members. Row Level Security only lets
-- 'active' members see their business's data, so accepting the
-- invitation activates the membership. These functions only ever act
-- on the signed-in user's own memberships.
-- =========================================================

-- Called after an invited owner sets their password (and on every sign-in;
-- it does nothing if there is nothing to accept).
create or replace function public.zella_accept_my_invitations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then
    raise exception 'NOT_SIGNED_IN';
  end if;

  with activated as (
    update business_members m
    set status = 'active'
    from businesses b
    where m.business_id = b.id
      and m.user_id = v_user
      and m.status = 'invited'
      and b.cancelled_at is null
    returning m.business_id
  ),
  accepted as (
    update business_invitations i
    set status = 'accepted', accepted_at = now(), updated_at = now()
    where i.auth_user_id = v_user
      and i.status in ('pending', 'sent')
      and i.business_id in (select business_id from activated)
    returning i.business_id, i.email
  ),
  logged as (
    insert into audit_logs (user_id, action, business_id, entity_type, new_data)
    select v_user, 'invitation.accepted', a.business_id, 'business_invitation',
           jsonb_build_object('email', a.email)
    from accepted a
    returning 1
  )
  select count(*) into v_count from activated;

  return v_count;
end;
$$;

-- The signed-in user's businesses, with the terminology and modules the
-- app needs. Terminology = industry defaults overlaid with the business's own words.
create or replace function public.zella_my_workspaces()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(w order by w->>'name'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', b.id,
      'name', b.name,
      'timezone', coalesce(b.timezone, 'America/New_York'),
      'industry', i.name,
      'role', m.role,
      'is_active', b.is_active,
      'onboarding_status', b.onboarding_status,
      'suspended_at', b.suspended_at,
      'cancel_at', b.cancel_at,
      'cancelled_at', b.cancelled_at,
      'terminology', coalesce(ic.terminology, '{}'::jsonb)
                     || coalesce(b.terminology_overrides, '{}'::jsonb),
      'modules', coalesce((
        select jsonb_agg(im.slug order by im.slug)
        from business_modules bm
        join industry_modules im on im.id = bm.module_id
        where bm.business_id = b.id and bm.enabled
      ), '[]'::jsonb),
      'receptionist', (
        select jsonb_build_object('name', a.name, 'status', a.status)
        from ai_agents a
        where a.business_id = b.id and a.agent_type = 'receptionist'
        order by a.is_default desc, a.created_at
        limit 1
      ),
      'phone_connected', exists (
        select 1 from integrations x
        where x.business_id = b.id and lower(x.provider) = 'telnyx' and x.status = 'active'
      ),
      'voice_connected', exists (
        select 1 from integrations x
        where x.business_id = b.id and lower(x.provider) = 'vapi' and x.status = 'active'
      )
    ) as w
    from business_members m
    join businesses b on b.id = m.business_id
    left join industries i on i.id = b.industry_id
    left join industry_configurations ic on ic.industry_id = b.industry_id
    where m.user_id = auth.uid()
      and m.status = 'active'
  ) workspaces;
$$;

-- An owner keeps their plan from inside the app (same effect as the
-- "Continue my plan" email link).
create or replace function public.zella_owner_continue_plan(p_business_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_cancel_at timestamptz;
begin
  if not exists (
    select 1 from business_members
    where business_id = p_business_id and user_id = v_user
      and status = 'active' and role = 'owner'
  ) then
    raise exception 'NOT_OWNER';
  end if;

  update businesses
  set cancel_at = null, cancel_requested_at = null, cancellation_reason = null, updated_at = now()
  where id = p_business_id and cancel_at is not null and cancelled_at is null
  returning cancel_at into v_cancel_at;

  if not found then
    return false;
  end if;

  insert into audit_logs (user_id, action, business_id, entity_type, entity_id, new_data)
  values (v_user, 'business.continued_by_owner', p_business_id, 'business', p_business_id,
          jsonb_build_object('via', 'business app'));
  return true;
end;
$$;

revoke all on function public.zella_accept_my_invitations() from public, anon;
revoke all on function public.zella_my_workspaces() from public, anon;
revoke all on function public.zella_owner_continue_plan(uuid) from public, anon;
grant execute on function public.zella_accept_my_invitations() to authenticated;
grant execute on function public.zella_my_workspaces() to authenticated;
grant execute on function public.zella_owner_continue_plan(uuid) to authenticated;
