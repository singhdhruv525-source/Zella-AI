-- Lead pipeline support: who can a lead be assigned to, plan the next
-- follow-up and priority, and add a dated note. The browser calls these
-- functions; they check that the caller belongs to the business.

-- The business's active logins with display names, for "Assigned to" pickers.
create or replace function public.zella_team_roster(p_business_id uuid)
returns table (user_id uuid, name text, role text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return query
    select m.user_id,
           coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), 'Team member'),
           m.role::text
      from public.business_members m
      left join public.profiles p on p.id = m.user_id
     where m.business_id = p_business_id and m.status = 'active'
     order by 2;
end $$;

-- Set a lead's priority and/or next follow-up. Pass p_clear_follow_up to remove the date.
create or replace function public.zella_set_lead_plan(
  p_customer_id uuid, p_priority text default null, p_next_follow_up_at timestamptz default null, p_clear_follow_up boolean default false
) returns boolean
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from public.customers where id = p_customer_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_priority is not null and p_priority not in ('normal', 'high', 'urgent') then raise exception 'BAD_PRIORITY'; end if;
  update public.customers
     set priority = coalesce(p_priority, priority),
         next_follow_up_at = case when p_clear_follow_up then null else coalesce(p_next_follow_up_at, next_follow_up_at) end,
         updated_at = now()
   where id = p_customer_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (c.business_id, auth.uid(), 'lead.plan_changed', 'customer', p_customer_id,
          jsonb_build_object('priority', c.priority, 'next_follow_up_at', c.next_follow_up_at),
          jsonb_build_object('priority', coalesce(p_priority, c.priority),
                             'next_follow_up_at', case when p_clear_follow_up then null else coalesce(p_next_follow_up_at, c.next_follow_up_at) end));
  return true;
end $$;

-- Add a dated, signed note to a person's notes. Existing notes are kept.
create or replace function public.zella_add_lead_note(p_customer_id uuid, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
declare c record; v_name text;
begin
  select * into c from public.customers where id = p_customer_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  select coalesce(nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Team member')
    into v_name from public.profiles where id = auth.uid();
  update public.customers
     set notes = to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI') || ' UTC, ' || coalesce(v_name, 'Team member') || ': ' || trim(p_note)
                 || case when c.notes is null or c.notes = '' then '' else E'\n\n' || c.notes end,
         updated_at = now()
   where id = p_customer_id;
  return true;
end $$;

revoke all on function public.zella_team_roster(uuid) from public, anon;
revoke all on function public.zella_set_lead_plan(uuid, text, timestamptz, boolean) from public, anon;
revoke all on function public.zella_add_lead_note(uuid, text) from public, anon;
grant execute on function public.zella_team_roster(uuid) to authenticated, service_role;
grant execute on function public.zella_set_lead_plan(uuid, text, timestamptz, boolean) to authenticated, service_role;
grant execute on function public.zella_add_lead_note(uuid, text) to authenticated, service_role;
