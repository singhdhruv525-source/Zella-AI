-- Zella - engine health watch. Safe to run more than once.
-- Needs zella_run_all.sql (platform alerts) and zella_dispatcher.sql (it runs every 5 minutes there).
-- Two jobs, both inside Supabase (no n8n runs):
--   1. Stuck work is freed. A follow-up text or email, a reminder or a notification that was picked up but never
--      finished (n8n crashed or timed out) goes back to the queue. Sending is safe to repeat: every message has a
--      duplicate guard, so a customer is never sent the same message twice.
--   2. A pile-up raises ONE alert per queue (and clears itself when the queue is empty again): reminders, follow-ups,
--      events and owner notifications that have waited too long mean the engine is not running or a provider is down.
-- Calls are handled by the stuck-call sweep in zella_outbound_calls.sql.

create or replace function public.zella_check_engine_health()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_freed integer := 0; n integer; q record; v_backlog jsonb := '{}'::jsonb;
begin
  -- 1. free stuck work
  update public.followup_tasks set status = 'pending', due_at = now(), updated_at = now()
   where status = 'in_progress' and channel in ('sms', 'email') and claimed_at < now() - interval '30 minutes';
  get diagnostics n = row_count; v_freed := v_freed + n;
  update public.appointment_reminders set status = 'pending'
   where status = 'sending' and due_at < now() - interval '60 minutes';
  get diagnostics n = row_count; v_freed := v_freed + n;
  update public.staff_notifications set delivery_status = 'pending'
   where delivery_status = 'sending' and claimed_at < now() - interval '30 minutes';
  get diagnostics n = row_count; v_freed := v_freed + n;
  if v_freed > 0 then
    perform public.zella_platform_alert('engine_stuck_work', 'Stuck work was put back in the queue',
      v_freed || ' item(s) were picked up but never finished, so they were put back to be tried again.', 'info', null, 'stuck', jsonb_build_object('freed', v_freed));
  end if;

  -- 2. backlog: how many items have waited too long, per queue
  for q in
    select * from (values
      ('reminders', 'Appointment reminders are waiting', (select count(*) from public.appointment_reminders where status = 'pending' and due_at < now() - interval '30 minutes')),
      ('followups', 'Follow-ups are waiting', (select count(*) from public.followup_tasks where status = 'pending' and channel in ('sms', 'email') and due_at < now() - interval '60 minutes')),
      ('events', 'Events are waiting to be processed', (select count(*) from public.automation_events where status = 'received' and received_at < now() - interval '15 minutes')),
      ('notifications', 'Owner notifications are waiting', (select count(*) from public.staff_notifications where delivery_status = 'pending' and created_at < now() - interval '60 minutes'))
    ) as t(queue, title, waiting)
  loop
    v_backlog := v_backlog || jsonb_build_object(q.queue, q.waiting);
    if q.waiting > 0 then
      perform public.zella_platform_alert('queue_backlog', q.title,
        q.waiting || ' item(s) have waited too long. The automation engine may be switched off, or a provider may be down.', 'warning', null, q.queue,
        jsonb_build_object('waiting', q.waiting));
    else
      perform public.zella_resolve_platform_alerts('queue_backlog', null, q.queue, 'Queue is empty again');
    end if;
  end loop;

  return jsonb_build_object('freed', v_freed, 'waiting', v_backlog);
end $$;
revoke execute on function public.zella_check_engine_health() from public, anon, authenticated;
grant execute on function public.zella_check_engine_health() to service_role;
