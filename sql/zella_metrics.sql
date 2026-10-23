-- Zella - reports, metrics and KPI alerts. Safe to run more than once. Read-only except for notifications.
-- zella_business_metrics: one report for a business over any dates (and optionally one team member).
-- zella_platform_metrics: platform-wide health and usage (service role only).
-- zella_check_kpis: daily, warns the business when yesterday looks far worse than its usual week.

create or replace function public.zella_business_metrics(
  p_business_id uuid, p_from timestamptz default now() - interval '30 days', p_to timestamptz default now(), p_assigned_to uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_to - p_from > interval '400 days' then p_from := p_to - interval '400 days'; end if;
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'assigned_to', p_assigned_to),
    'calls', (select jsonb_build_object(
        'total', count(*), 'inbound', count(*) filter (where direction = 'inbound'), 'outbound', count(*) filter (where direction = 'outbound'),
        'missed', count(*) filter (where direction = 'inbound' and answered_at is null and not coalesce(ai_handled, false)),
        'handled_by_ai', count(*) filter (where ai_handled), 'needed_a_person', count(*) filter (where needs_human or escalated_at is not null),
        'failed_transfers', count(*) filter (where transfer_status = 'failed'),
        'avg_seconds', round(coalesce(avg(duration_seconds) filter (where duration_seconds > 0), 0)))
        from calls c where c.business_id = p_business_id and c.created_at >= p_from and c.created_at < p_to
         and (p_assigned_to is null or c.assigned_to = p_assigned_to)),
    'callbacks', (select jsonb_build_object(
        'created', count(*), 'completed', count(*) filter (where status in ('completed','done','reached')),
        'open', count(*) filter (where status not in ('completed','done','reached','cancelled','failed')),
        'overdue', count(*) filter (where status not in ('completed','done','reached','cancelled','failed') and due_at < now()),
        'avg_attempts', round(coalesce(avg(attempts), 0), 1))
        from callbacks k where k.business_id = p_business_id and k.created_at >= p_from and k.created_at < p_to
         and (p_assigned_to is null or k.assigned_to = p_assigned_to)),
    'appointments', (select jsonb_build_object(
        'total', count(*), 'completed', count(*) filter (where status = 'completed'), 'cancelled', count(*) filter (where status = 'cancelled'),
        'no_show', count(*) filter (where status = 'no_show'), 'rescheduled', count(*) filter (where coalesce(reschedule_count, 0) > 0),
        'booked_by_ai', count(*) filter (where coalesce(metadata ->> 'source', '') in ('ai', 'phone', 'ai_call')))
        from appointments a where a.business_id = p_business_id and a.start_time >= p_from and a.start_time < p_to
         and (p_assigned_to is null or a.assigned_to = p_assigned_to)),
    'leads', (select jsonb_build_object(
        'new', count(*), 'won', count(*) filter (where lead_stage = 'won'), 'lost', count(*) filter (where lead_stage = 'lost'),
        'still_open', count(*) filter (where lead_stage in ('new','contacted','qualified','quote_sent')),
        'unassigned', count(*) filter (where assigned_to is null and lead_stage in ('new','contacted','qualified','quote_sent')),
        'conversion_percent', round(100.0 * count(*) filter (where lead_stage = 'won') / nullif(count(*), 0), 1),
        'avg_hours_to_first_contact', round(coalesce(avg(extract(epoch from (last_contacted_at - created_at)) / 3600) filter (where last_contacted_at > created_at), 0)::numeric, 1))
        from customers x where x.business_id = p_business_id and x.created_at >= p_from and x.created_at < p_to
         and x.lead_stage is not null and (p_assigned_to is null or x.assigned_to = p_assigned_to)),
    'messages', jsonb_build_object(
      'texts_sent', (select count(*) from sms_messages m where m.business_id = p_business_id and m.direction = 'outbound' and m.created_at >= p_from and m.created_at < p_to),
      'texts_delivered', (select count(*) from sms_messages m where m.business_id = p_business_id and m.direction = 'outbound' and m.delivered_at is not null and m.created_at >= p_from and m.created_at < p_to),
      'texts_failed', (select count(*) from sms_messages m where m.business_id = p_business_id and m.direction = 'outbound' and m.status in ('failed','undelivered') and m.created_at >= p_from and m.created_at < p_to),
      'texts_received', (select count(*) from sms_messages m where m.business_id = p_business_id and m.direction = 'inbound' and m.created_at >= p_from and m.created_at < p_to),
      'emails_sent', (select count(*) from email_messages m where m.business_id = p_business_id and m.direction = 'outbound' and m.created_at >= p_from and m.created_at < p_to),
      'emails_delivered', (select count(*) from email_messages m where m.business_id = p_business_id and m.direction = 'outbound' and m.delivered_at is not null and m.created_at >= p_from and m.created_at < p_to),
      'emails_failed', (select count(*) from email_messages m where m.business_id = p_business_id and m.direction = 'outbound' and m.status in ('failed','bounced','complained') and m.created_at >= p_from and m.created_at < p_to)),
    'follow_ups', (select jsonb_build_object(
        'done', count(*) filter (where status = 'done'), 'failed', count(*) filter (where status = 'failed'),
        'skipped', count(*) filter (where status = 'skipped'), 'waiting', count(*) filter (where status in ('pending','in_progress')),
        'completion_percent', round(100.0 * count(*) filter (where status = 'done') / nullif(count(*) filter (where status in ('done','failed','skipped')), 0), 1))
        from followup_tasks f where f.business_id = p_business_id and f.created_at >= p_from and f.created_at < p_to),
    'knowledge', jsonb_build_object(
      'open_gaps', (select count(*) from knowledge_gaps g where g.business_id = p_business_id and g.status in ('open','new','suggested')),
      'questions_asked', (select coalesce(sum(times_asked), 0) from knowledge_gaps g where g.business_id = p_business_id and g.last_asked_at >= p_from and g.last_asked_at < p_to),
      'top_unanswered', (select coalesce(jsonb_agg(jsonb_build_object('question', q.question, 'times_asked', q.times_asked)), '[]'::jsonb)
                           from (select question, times_asked from knowledge_gaps g where g.business_id = p_business_id and g.status in ('open','new','suggested') order by times_asked desc limit 5) q)),
    'requests', (select jsonb_build_object('open', count(*) filter (where status not in ('resolved','closed','cancelled')),
        'overdue', count(*) filter (where status not in ('resolved','closed','cancelled') and due_at < now()))
        from customer_requests q where q.business_id = p_business_id and (p_assigned_to is null or q.assigned_to = p_assigned_to)),
    'integrations', (select coalesce(jsonb_agg(jsonb_build_object('provider', provider, 'status', status, 'errors', coalesce(error_count, 0), 'last_checked', last_checked_at)), '[]'::jsonb)
        from integrations i where i.business_id = p_business_id)
  ) into r;
  return r;
end $$;

-- Platform-wide numbers for the operator: workflow results, integrations and usage.
create or replace function public.zella_platform_metrics(p_from timestamptz default now() - interval '7 days', p_to timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'automation_runs', (select jsonb_build_object('total', count(*), 'succeeded', count(*) filter (where status in ('completed','success')),
        'failed', count(*) filter (where status in ('failed','error')), 'waiting', count(*) filter (where status in ('running','pending','waiting')))
        from automation_runs where created_at >= p_from and created_at < p_to),
    'integrations', (select jsonb_build_object('total', count(*), 'with_errors', count(*) filter (where coalesce(error_count, 0) > 0 or status in ('error','failed','expired'))) from integrations),
    'usage', (select coalesce(jsonb_object_agg(usage_type, total), '{}'::jsonb)
        from (select usage_type, sum(quantity) total from usage_records where created_at >= p_from and created_at < p_to group by 1) u),
    'knowledge_sync', (select jsonb_build_object('items', count(*), 'updated_in_period', count(*) filter (where updated_at >= p_from and updated_at < p_to)) from knowledge_items),
    'businesses', (select jsonb_build_object('active', count(*) filter (where suspended_at is null and cancelled_at is null), 'suspended', count(*) filter (where suspended_at is not null)) from businesses)
  );
$$;

-- Daily KPI check: compares yesterday with the average of the 7 days before it. Needs a clear change to alert.
create or replace function public.zella_check_kpis()
returns integer language plpgsql security definer set search_path = public as $$
declare b record; y numeric; w numeric; n integer := 0; v_fail numeric; v_sent numeric;
begin
  for b in select id, name from businesses where suspended_at is null and cancelled_at is null loop
    -- missed calls
    select count(*) filter (where created_at >= date_trunc('day', now()) - interval '1 day'),
           count(*) filter (where created_at < date_trunc('day', now()) - interval '1 day') / 7.0
      into y, w from calls
     where business_id = b.id and direction = 'inbound' and answered_at is null and not coalesce(ai_handled, false)
       and created_at >= date_trunc('day', now()) - interval '8 days' and created_at < date_trunc('day', now());
    if y >= 5 and y >= 2 * greatest(w, 1) then
      perform public.zella_notify(b.id, 'kpi_missed_calls', 'Missed calls are up', 'Yesterday had ' || y || ' missed calls, against about ' || round(w, 1) || ' a day last week.', 'warning', 'calls');
      n := n + 1;
    end if;
    -- failed messages
    select count(*) filter (where status in ('failed','undelivered','bounced')), count(*) into v_fail, v_sent
      from (select status from sms_messages where business_id = b.id and direction = 'outbound' and created_at >= now() - interval '1 day'
            union all select status from email_messages where business_id = b.id and direction = 'outbound' and created_at >= now() - interval '1 day') m;
    if v_sent >= 5 and v_fail / v_sent >= 0.2 then
      perform public.zella_notify(b.id, 'kpi_message_failures', 'Many messages failed to send', v_fail || ' of ' || v_sent || ' messages in the last day did not go through.', 'warning', 'inbox');
      n := n + 1;
    end if;
    -- cancellations / no-shows
    select count(*) filter (where status in ('no_show','cancelled') and start_time >= date_trunc('day', now()) - interval '1 day'),
           count(*) filter (where status in ('no_show','cancelled') and start_time < date_trunc('day', now()) - interval '1 day') / 7.0
      into y, w from appointments
     where business_id = b.id and start_time >= date_trunc('day', now()) - interval '8 days' and start_time < date_trunc('day', now());
    if y >= 5 and y >= 2 * greatest(w, 1) then
      perform public.zella_notify(b.id, 'kpi_no_shows', 'No-shows and cancellations are up', 'Yesterday had ' || y || ', against about ' || round(w, 1) || ' a day last week.', 'warning', 'calendar');
      n := n + 1;
    end if;
  end loop;
  -- platform: automation failures
  select count(*) filter (where status in ('failed','error')), count(*) into v_fail, v_sent from automation_runs where created_at >= now() - interval '1 day';
  if v_sent >= 10 and v_fail / v_sent >= 0.25 then
    perform public.zella_platform_alert('kpi_workflow_failures', 'Many automation runs failed', v_fail || ' of ' || v_sent || ' runs failed in the last day.', 'warning', null, 'kpi_workflow_failures');
    n := n + 1;
  end if;
  return n;
end $$;

revoke execute on function public.zella_business_metrics(uuid, timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.zella_business_metrics(uuid, timestamptz, timestamptz, uuid) to authenticated, service_role;
revoke execute on function public.zella_platform_metrics(timestamptz, timestamptz), public.zella_check_kpis() from public, anon, authenticated;
grant execute on function public.zella_platform_metrics(timestamptz, timestamptz), public.zella_check_kpis() to service_role;
