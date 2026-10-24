-- Zella - retention workflows (checklist 112). Safe to run more than once.
-- Finds regular customers who have gone quiet and gives the team a task to reach out personally.
-- A "regular" has at least 3 completed visits. Their usual gap is the average time between visits;
-- they are "at risk" once they are overdue by half again that gap (and at least 30 days since the last visit).
-- It only creates staff tasks. It never messages a customer by itself.

create or replace function public.zella_retention_scan(p_limit integer default 50)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0; v_name text;
begin
  for r in
    select c.business_id, c.id as customer_id, c.assigned_to, c.first_name, c.last_name,
           count(*) as visits, max(a.start_time) as last_visit, min(a.start_time) as first_visit
      from public.customers c
      join public.appointments a on a.customer_id = c.id and a.business_id = c.business_id and a.status = 'completed'
      join public.businesses b on b.id = c.business_id and b.suspended_at is null and b.cancelled_at is null
     where coalesce(c.status, 'active') = 'active' and not coalesce(c.do_not_contact, false)
     group by c.business_id, c.id, c.assigned_to, c.first_name, c.last_name
    having count(*) >= 3
       and max(a.start_time) < now() - greatest(interval '30 days', 1.5 * ((max(a.start_time) - min(a.start_time)) / (count(*) - 1)))
       and max(a.start_time) > now() - interval '2 years'
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  loop
    continue when exists (select 1 from public.crm_tasks t where t.customer_id = r.customer_id and t.kind = 'retention_check'
                            and (t.status = 'open' or t.created_at > now() - interval '90 days'));
    v_name := trim(coalesce(r.first_name, '') || ' ' || coalesce(r.last_name, ''));
    insert into public.crm_tasks (business_id, customer_id, kind, title, body, priority, due_at, assigned_to, source)
    values (r.business_id, r.customer_id, 'retention_check', 'Regular customer is overdue: ' || coalesce(nullif(v_name, ''), 'a customer'),
            r.visits || ' visits, usually about every ' || round(extract(epoch from (r.last_visit - r.first_visit)) / 86400 / (r.visits - 1))::int
              || ' days. Last visit ' || to_char(r.last_visit, 'Mon FMDD, YYYY') || '. A personal call or message usually works best.',
            'normal', now() + interval '3 days', r.assigned_to, 'automation');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_retention_scan(integer) from public, anon, authenticated;
grant execute on function public.zella_retention_scan(integer) to service_role;

-- A summary for the dashboard: how many regulars, how many are drifting, and how many came back.
create or replace function public.zella_retention_summary(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select jsonb_build_object(
    'regulars', count(*) filter (where visits >= 3),
    'at_risk', count(*) filter (where visits >= 3 and last_visit < now() - greatest(interval '30 days', 1.5 * gap) and last_visit > now() - interval '2 years'),
    'returning_customers', count(*) filter (where visits >= 2),
    'customers_with_visits', count(*),
    'open_retention_tasks', (select count(*) from public.crm_tasks t where t.business_id = p_business_id and t.kind = 'retention_check' and t.status = 'open'))
  into v
  from (select a.customer_id, count(*) visits, max(a.start_time) last_visit,
               case when count(*) > 1 then (max(a.start_time) - min(a.start_time)) / (count(*) - 1) else interval '0' end gap
          from public.appointments a where a.business_id = p_business_id and a.status = 'completed' and a.customer_id is not null group by a.customer_id) x;
  return v;
end $$;
revoke execute on function public.zella_retention_summary(uuid) from public, anon;
grant execute on function public.zella_retention_summary(uuid) to authenticated, service_role;
