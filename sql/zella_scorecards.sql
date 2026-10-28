-- Zella - per-staff scorecards (2026-10-28). Safe to re-run. Read-only: adds one function, changes no rows.
-- Needs the callbacks, callback_attempts, crm_tasks, customers (leads), appointments, business_members, profiles and
-- staff_members tables (sql/zella_run_all.sql and the files it lists).
--
-- For a period (up to 366 days), for each person who signs in:
--   callbacks   - given to them, completed by them, time to first call attempt (median minutes), overdue right now
--   leads       - assigned to them, won, lost, time to first contact (median hours)
--   tasks       - completed, overdue right now
-- and for each bookable team member (staff_members): completed visits, no-shows, cancellations.
-- Owners, admins and managers see everyone; anyone else sees only their own row.
-- Rollback: drop function public.zella_staff_scorecards(uuid, timestamptz, timestamptz).

create or replace function public.zella_staff_scorecards(p_business_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_all boolean; v_me uuid := auth.uid(); v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now());
begin
  if v_me is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_to <= v_from or v_to - v_from > interval '366 days' then raise exception 'INVALID_PERIOD'; end if;
  v_all := public.zella_can_manage(p_business_id);
  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'everyone', v_all,
    'people', coalesce((select jsonb_agg(person order by (person ->> 'name')) from (
      select jsonb_build_object(
        'user_id', m.user_id, 'role', m.role, 'you', m.user_id = v_me,
        'name', coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), case when m.user_id = v_me then 'You' else 'Team member' end),
        'callbacks', jsonb_build_object(
          'assigned', (select count(*) from public.callbacks c where c.business_id = p_business_id and c.assigned_to = m.user_id and c.created_at >= v_from and c.created_at < v_to),
          'completed', (select count(*) from public.callbacks c where c.business_id = p_business_id and c.assigned_to = m.user_id and c.status = 'completed' and c.completed_at >= v_from and c.completed_at < v_to),
          'median_minutes_to_first_call', (select round((percentile_cont(0.5) within group (order by extract(epoch from (fa.first_at - c.created_at)) / 60))::numeric)
                     from public.callbacks c
                     cross join lateral (select min(a.attempted_at) as first_at from public.callback_attempts a where a.callback_id = c.id) fa
                    where c.business_id = p_business_id and c.assigned_to = m.user_id and c.created_at >= v_from and c.created_at < v_to and fa.first_at is not null),
          'overdue_now', (select count(*) from public.callbacks c where c.business_id = p_business_id and c.assigned_to = m.user_id
                            and c.status not in ('completed', 'cancelled', 'needs_review') and c.due_at < now())),
        'leads', jsonb_build_object(
          'assigned', (select count(*) from public.customers c where c.business_id = p_business_id and c.assigned_to = m.user_id and c.lead_stage is not null and c.created_at >= v_from and c.created_at < v_to),
          'won', (select count(*) from public.customers c where c.business_id = p_business_id and c.assigned_to = m.user_id and c.lead_stage = 'won' and c.converted_at >= v_from and c.converted_at < v_to),
          'lost', (select count(*) from public.customers c where c.business_id = p_business_id and c.assigned_to = m.user_id and c.lead_stage = 'lost' and c.lost_at >= v_from and c.lost_at < v_to),
          'median_hours_to_contact', (select round((percentile_cont(0.5) within group (order by extract(epoch from (c.last_contacted_at - c.created_at)) / 3600))::numeric, 1)
                     from public.customers c where c.business_id = p_business_id and c.assigned_to = m.user_id and c.lead_stage is not null
                      and c.created_at >= v_from and c.created_at < v_to and c.last_contacted_at >= c.created_at)),
        'tasks', jsonb_build_object(
          'completed', (select count(*) from public.crm_tasks t where t.business_id = p_business_id and t.assigned_to = m.user_id and t.status = 'done' and t.completed_at >= v_from and t.completed_at < v_to),
          'overdue_now', (select count(*) from public.crm_tasks t where t.business_id = p_business_id and t.assigned_to = m.user_id and t.status = 'open' and t.due_at < now()))
      ) as person
        from public.business_members m left join public.profiles p on p.id = m.user_id
       where m.business_id = p_business_id and m.status = 'active' and (v_all or m.user_id = v_me)) x), '[]'::jsonb),
    'bookable', case when v_all then coalesce((select jsonb_agg(jsonb_build_object('staff_id', g.id, 'name', g.name, 'active', g.is_active,
        'booked', g.booked, 'completed', g.completed, 'no_shows', g.no_shows, 'cancelled', g.cancelled) order by g.sort_order, g.name)
      from (select s.id, s.name, s.is_active, s.sort_order, count(a.id) as booked,
                   count(a.id) filter (where a.status = 'completed') as completed,
                   count(a.id) filter (where a.status = 'no_show') as no_shows,
                   count(a.id) filter (where a.status = 'cancelled') as cancelled
              from public.staff_members s
              left join public.appointments a on a.staff_id = s.id and a.business_id = p_business_id and a.start_time >= v_from and a.start_time < v_to
             where s.business_id = p_business_id
             group by s.id, s.name, s.is_active, s.sort_order
            having s.is_active or count(a.id) > 0) g), '[]'::jsonb) else '[]'::jsonb end);
end $$;
revoke all on function public.zella_staff_scorecards(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.zella_staff_scorecards(uuid, timestamptz, timestamptz) to authenticated;
