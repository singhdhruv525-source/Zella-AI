-- Zella - alerts for callbacks that are overdue. Safe to run more than once.
-- Needs zella_run_all.sql (callbacks) and zella_owner_emails.sql (warnings and urgent alerts are emailed).
-- A callback that is due but nobody has dealt with raises ONE warning after a short wait, and ONE urgent alert
-- later if it is still open. Nothing is sent from here: the alerts appear in the app and the Owner Emails workflow
-- emails them (warning and urgent alerts are emailed). It runs every 5 minutes inside Supabase (zella_dispatcher.sql).
--   waiting time before the warning: 10 min for urgent callbacks, 30 min for others, 60 min when Zella is
--   meant to place the call itself (it gets time to try first). Urgent alert: after 3 hours.

alter table public.callbacks add column if not exists overdue_notified_at timestamptz;
alter table public.callbacks add column if not exists overdue_escalated_at timestamptz;

create or replace function public.zella_flag_overdue_callbacks()
returns integer language plpgsql security definer set search_path = public as $$
declare
  c record; v_who text; v_wait integer; n integer := 0; v_late text;
begin
  for c in
    select cb.*, cu.first_name, cu.last_name
      from public.callbacks cb
      left join public.customers cu on cu.id = cb.customer_id
      join public.businesses b on b.id = cb.business_id and b.suspended_at is null and b.cancelled_at is null
     where cb.status in ('new', 'scheduled', 'due', 'retry_scheduled', 'reschedule_requested', 'needs_review', 'escalated')
       and cb.due_at is not null and cb.due_at < now()
  loop
    v_wait := case when c.priority = 'urgent' then 10 when c.auto_call and c.status not in ('needs_review', 'escalated') then 60 else 30 end;
    if c.due_at > now() - make_interval(mins => v_wait) then continue; end if;
    v_who := coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), nullif(c.contact_number, ''), 'A caller');
    v_late := case when now() - c.due_at >= interval '2 hours' then (extract(epoch from (now() - c.due_at)) / 3600)::int || ' hours'
                   else (extract(epoch from (now() - c.due_at)) / 60)::int || ' minutes' end;

    -- one warning per due time (a callback moved to a later time can warn again)
    if c.overdue_notified_at is null or c.overdue_notified_at < c.due_at then
      perform public.zella_notify(c.business_id, 'callback_overdue', 'Callback overdue',
        v_who || ' is waiting for a call back (' || v_late || ' late).' || coalesce(' ' || left(c.summary, 200), ''), 'warning', 'callbacks', c.id, c.assigned_to);
      update public.callbacks set overdue_notified_at = now() where id = c.id;
      n := n + 1;
    end if;
    -- one urgent alert to the owners if it is still open after 3 hours
    if c.due_at < now() - interval '3 hours' and (c.overdue_escalated_at is null or c.overdue_escalated_at < c.due_at) then
      perform public.zella_notify(c.business_id, 'callback_escalated', 'Callback still not made',
        v_who || ' has waited ' || v_late || ' for a call back.', 'urgent', 'callbacks', c.id, null);
      update public.callbacks set overdue_escalated_at = now() where id = c.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke execute on function public.zella_flag_overdue_callbacks() from public, anon, authenticated;
grant execute on function public.zella_flag_overdue_callbacks() to service_role;
