CREATE OR REPLACE FUNCTION public.zella_check_invitations()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare i record; v_hours jsonb := public.zella_setting('invitation_reminder_hours', '[24, 72]'); v_due jsonb := '[]'::jsonb; v_next numeric; v_expired integer := 0;
begin
  for i in select * from public.business_invitations where status in ('pending', 'sent', 'failed') for update skip locked loop
    if i.expires_at is not null and i.expires_at < now() then
      update public.business_invitations set status = 'expired', updated_at = now() where id = i.id; v_expired := v_expired + 1;
      perform public.zella_platform_alert('invitation_expired', 'Owner invitation expired', i.email, 'warning', i.business_id, i.id::text);
      continue;
    end if;
    if i.reminder_count < jsonb_array_length(v_hours) then
      v_next := (v_hours ->> i.reminder_count)::numeric;
      if coalesce(i.last_reminded_at, i.invited_at, i.created_at) <= now() - make_interval(secs => v_next * 3600)
         and coalesce(i.invited_at, i.created_at) <= now() - make_interval(secs => v_next * 3600) then
        v_due := v_due || jsonb_build_array(jsonb_build_object('invitation_id', i.id, 'business_id', i.business_id, 'email', i.email, 'owner_name', i.owner_name, 'reminder_no', i.reminder_count + 1));
      end if;
    end if;
  end loop;
  return jsonb_build_object('reminders_due', v_due, 'expired', v_expired);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_kpis()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; y numeric; w numeric; n integer := 0; v_fail numeric; v_sent numeric;
begin
  for b in select id, name from businesses where suspended_at is null and cancelled_at is null loop
    select count(*) filter (where created_at >= date_trunc('day', now()) - interval '1 day'),
           count(*) filter (where created_at < date_trunc('day', now()) - interval '1 day') / 7.0
      into y, w from calls
     where business_id = b.id and direction = 'inbound' and answered_at is null and not coalesce(ai_handled, false)
       and created_at >= date_trunc('day', now()) - interval '8 days' and created_at < date_trunc('day', now());
    if y >= 5 and y >= 2 * greatest(w, 1) then
      perform public.zella_notify(b.id, 'kpi_missed_calls', 'Missed calls are up', 'Yesterday had ' || y || ' missed calls, against about ' || round(w, 1) || ' a day last week.', 'warning', 'calls');
      n := n + 1;
    end if;
    select count(*) filter (where status in ('failed','undelivered','bounced')), count(*) into v_fail, v_sent
      from (select status from sms_messages where business_id = b.id and direction = 'outbound' and created_at >= now() - interval '1 day'
            union all select status from email_messages where business_id = b.id and direction = 'outbound' and created_at >= now() - interval '1 day') m;
    if v_sent >= 5 and v_fail / v_sent >= 0.2 then
      perform public.zella_notify(b.id, 'kpi_message_failures', 'Many messages failed to send', v_fail || ' of ' || v_sent || ' messages in the last day did not go through.', 'warning', 'inbox');
      n := n + 1;
    end if;
    select count(*) filter (where status in ('no_show','cancelled') and start_time >= date_trunc('day', now()) - interval '1 day'),
           count(*) filter (where status in ('no_show','cancelled') and start_time < date_trunc('day', now()) - interval '1 day') / 7.0
      into y, w from appointments
     where business_id = b.id and start_time >= date_trunc('day', now()) - interval '8 days' and start_time < date_trunc('day', now());
    if y >= 5 and y >= 2 * greatest(w, 1) then
      perform public.zella_notify(b.id, 'kpi_no_shows', 'No-shows and cancellations are up', 'Yesterday had ' || y || ', against about ' || round(w, 1) || ' a day last week.', 'warning', 'calendar');
      n := n + 1;
    end if;
  end loop;
  select count(*) filter (where status in ('failed','error')), count(*) into v_fail, v_sent from automation_runs where created_at >= now() - interval '1 day';
  if v_sent >= 10 and v_fail / v_sent >= 0.25 then
    perform public.zella_platform_alert('kpi_workflow_failures', 'Many automation runs failed', v_fail || ' of ' || v_sent || ' runs failed in the last day.', 'warning', null, 'kpi_workflow_failures');
    n := n + 1;
  end if;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_milestones()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; v_calls integer; v_books integer; m integer; n integer := 0; v_tz text; v_week_start date; v_last integer; v_best integer;
begin
  for b in select id, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    select count(*) into v_calls from public.calls where business_id = b.id and ai_handled;
    foreach m in array array[1, 100, 500, 1000, 5000] loop
      if v_calls >= m and public.zella_milestone_once(b.id, 'calls_' || m) then
        perform public.zella_notify(b.id, 'milestone',
          case when m = 1 then 'Your AI receptionist answered its first call' else 'Your AI receptionist has answered ' || to_char(m, 'FM9,999') || ' calls' end,
          case when m = 1 then 'Zella is on the line for you. Have a look at how it went in Calls.' else 'That''s ' || to_char(m, 'FM9,999') || ' callers who got an answer straight away.' end,
          'info', 'calls');
        n := n + 1;
      end if;
    end loop;
    select count(*) into v_books from public.ai_tool_calls where business_id = b.id and tool = 'book_appointment' and status = 'done' and verified is true;
    foreach m in array array[1, 50, 250] loop
      if v_books >= m and public.zella_milestone_once(b.id, 'ai_bookings_' || m) then
        perform public.zella_notify(b.id, 'milestone',
          case when m = 1 then 'Your AI receptionist booked its first appointment' else 'Your AI receptionist has booked ' || m || ' appointments' end,
          'Booked straight into your calendar while you got on with your day.', 'info', 'calendar');
        n := n + 1;
      end if;
    end loop;
    v_week_start := date_trunc('week', (now() at time zone b.tz))::date;
    if extract(isodow from (now() at time zone b.tz)) = 1 then
      select count(*) into v_last from public.appointments a where a.business_id = b.id and a.status = 'completed'
         and (a.start_time at time zone b.tz)::date >= v_week_start - 7 and (a.start_time at time zone b.tz)::date < v_week_start;
      select coalesce(max(c), 0) into v_best from (
        select count(*) c from public.appointments a where a.business_id = b.id and a.status = 'completed'
           and (a.start_time at time zone b.tz)::date >= v_week_start - 7 * 13 and (a.start_time at time zone b.tz)::date < v_week_start - 7
         group by date_trunc('week', a.start_time at time zone b.tz)) w;
      if v_last >= 5 and v_last > v_best and public.zella_milestone_once(b.id, 'best_week_' || (v_week_start - 7)::text) then
        perform public.zella_notify(b.id, 'best_week', 'Your best week in three months',
          v_last || ' completed appointments last week, more than any week since ' || to_char(v_week_start - 7 * 13, 'FMMonth FMDD') || '.', 'info', 'reports');
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_overdue_tasks(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; n integer := 0;
  v_grace integer := greatest(5, coalesce((public.zella_setting('task_overdue_grace_minutes', '60'::jsonb) #>> '{}')::integer, 60));
  v_esc integer := greatest(1, coalesce((public.zella_setting('task_escalate_hours', '24'::jsonb) #>> '{}')::integer, 24));
begin
  for t in select k.* from public.crm_tasks k join public.businesses b on b.id = k.business_id and b.suspended_at is null and b.cancelled_at is null
            where k.status = 'open' and k.due_at is not null and k.due_at < now() - make_interval(mins => v_grace) and k.kind <> 'overdue_contact'
              and (k.overdue_notified_at is null or (k.escalated_at is null and k.due_at < now() - make_interval(hours => v_esc)))
            order by k.due_at limit greatest(1, least(coalesce(p_limit, 100), 500)) loop
    if t.overdue_notified_at is null then
      if t.assigned_to is not null then
        perform public.zella_notify(t.business_id, 'task_overdue', 'A task is overdue', left(t.title, 150), 'warning', 'tasks', t.id, t.assigned_to);
      else
        perform public.zella_notify_owners(t.business_id, 'task_overdue', 'An unassigned task is overdue', left(t.title, 150), 'warning', 'tasks');
      end if;
      update public.crm_tasks set overdue_notified_at = now() where id = t.id;
      n := n + 1;
    end if;
    if t.escalated_at is null and t.due_at < now() - make_interval(hours => v_esc) then
      update public.crm_tasks set escalated_at = now(), priority = 'urgent' where id = t.id and escalated_at is null;
      perform public.zella_notify_owners(t.business_id, 'task_escalated', 'Escalated: a task is a day late', left(t.title, 150), 'urgent', 'tasks');
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_renewals()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; n integer := 0;
begin
  for s in select * from public.subscriptions where status = 'active' and current_period_end is not null
            and current_period_end < now() + interval '3 days' and current_period_end > now() for update skip locked loop
    update public.subscriptions set status = 'renewal_due' where id = s.id;
    perform public.zella_notify_owners(s.business_id, 'renewal_upcoming', 'Your plan renews soon', 'Your plan renews in the next few days. Make sure your billing details are up to date.', 'info', 'settings');
    n := n + 1;
  end loop;
  for s in select * from public.subscriptions where status in ('active', 'renewal_due') and current_period_end is not null
            and current_period_end < now() - interval '2 days' and provider is not null for update skip locked loop
    perform public.zella_record_payment_result(s.business_id, false, null, 'No payment received for the new period');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_response_times()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0; v_min integer := greatest(10, coalesce((public.zella_setting('response_time_minutes', '60'::jsonb) #>> '{}')::int, 60));
begin
  for r in
    select business_id, count(*) as waiting, array_agg(id) as ids from public.sms_messages m
     where m.direction = 'inbound' and m.status = 'received' and m.created_at between now() - interval '24 hours' and now() - make_interval(mins => v_min)
       and coalesce(m.metadata ->> 'slow_notified', '') = ''
       and upper(regexp_replace(coalesce(m.message_body, ''), '[^A-Za-z]', '', 'g')) not in ('STOP','STOPALL','UNSUBSCRIBE','CANCEL','END','QUIT','START','UNSTOP','HELP','YES','Y','OK','OKAY','CONFIRM','CONFIRMED','HERE','ARRIVED','THANKS','THANKYOU','')
       and (public.zella_business_open(m.business_id) ->> 'open')::boolean
       and not exists (select 1 from public.sms_messages o where o.business_id = m.business_id and o.direction = 'outbound' and o.created_at > m.created_at
                         and (o.customer_id = m.customer_id and m.customer_id is not null or o.to_number = m.from_number))
     group by business_id loop
    perform public.zella_notify_owners(r.business_id, 'slow_reply', r.waiting || (case when r.waiting = 1 then ' text is' else ' texts are' end) || ' waiting for a reply',
      'Customers have been waiting more than ' || v_min || ' minutes. Open the inbox to reply.', 'warning', 'inbox');
    update public.sms_messages set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('slow_notified', now()) where id = any (r.ids);
    n := n + 1;
  end loop;
  for r in
    select business_id, count(*) as waiting, array_agg(id) as ids from public.email_messages m
     where m.direction = 'inbound' and m.created_at between now() - interval '24 hours' and now() - make_interval(mins => v_min * 4)
       and coalesce(m.metadata ->> 'slow_notified', '') = ''
       and (public.zella_business_open(m.business_id) ->> 'open')::boolean
       and not exists (select 1 from public.email_messages o where o.business_id = m.business_id and o.direction = 'outbound' and o.created_at > m.created_at
                         and (o.customer_id = m.customer_id and m.customer_id is not null))
     group by business_id loop
    perform public.zella_notify_owners(r.business_id, 'slow_reply', r.waiting || (case when r.waiting = 1 then ' email is' else ' emails are' end) || ' waiting for a reply',
      'Open the inbox to reply.', 'warning', 'inbox');
    update public.email_messages set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('slow_notified', now()) where id = any (r.ids);
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_setup_incomplete()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; v_days integer := (public.zella_setting('setup_incomplete_after_days', '3'))::text::integer; v_rep jsonb; v_missing text; n integer := 0;
begin
  for b in select * from public.businesses where onboarding_status not in ('active', 'paused', 'failed') and suspended_at is null and cancelled_at is null and created_at < now() - make_interval(days => v_days) loop
    v_rep := public.zella_activation_report(b.id);
    select string_agg(c ->> 'label', ', ') into v_missing from jsonb_array_elements(v_rep -> 'checks') c where not (c ->> 'ok')::boolean;
    if v_missing is not null then
      perform public.zella_platform_alert('setup_incomplete', b.name || ' has not finished setup', 'Still missing: ' || v_missing, 'warning', b.id, to_char(now(), 'IYYY-IW'));
      -- the business owner is told too, once a week
      if not exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'setup_incomplete' and created_at > now() - interval '7 days') then
        perform public.zella_notify_owners(b.id, 'setup_incomplete', 'Finish setting up Zella', 'Still to do: ' || v_missing, 'info', 'receptionist');
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_trials()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; v_days jsonb := public.zella_setting('trial_notice_days', '[7, 3, 1]'); d integer; v_left numeric; n integer := 0;
begin
  for s in select * from public.subscriptions where status = 'trial' and trial_end_at is not null for update skip locked loop
    v_left := extract(epoch from (s.trial_end_at - now())) / 86400.0;
    if v_left <= 0 then
      perform public.zella_platform_alert('trial_ended', 'A trial has ended', null, 'warning', s.business_id, to_char(s.trial_end_at, 'YYYY-MM-DD'));
      perform public.zella_notify_owners(s.business_id, 'trial_ended', 'Your trial has ended', 'Choose a plan to keep using Zella.', 'urgent', 'settings');
      n := n + 1; continue;
    end if;
    select min(x::integer) into d from jsonb_array_elements_text(v_days) x where v_left <= x::integer;
    if d is not null and not (d = any (s.trial_notice_days)) then
      -- remember every threshold already passed so only one notice goes out
      update public.subscriptions set trial_notice_days = array(select distinct unnest(trial_notice_days || array(select x::integer from jsonb_array_elements_text(v_days) x where x::integer >= d))) where id = s.id;
      perform public.zella_notify_owners(s.business_id, 'trial_ending', 'Your trial ends in ' || ceil(v_left)::int || ' day(s)', 'Choose a plan to keep your AI receptionist running.', 'warning', 'settings');
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_unassigned_work()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_alerts integer := 0; u record;
begin
  for r in
    select b.id business_id, coalesce(a.unassigned_alert_minutes, 10) mins,
           (select count(*) from public.customers c where c.business_id = b.id and c.assigned_to is null and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent') and c.created_at < now() - make_interval(mins => coalesce(a.unassigned_alert_minutes, 10))) leads,
           (select count(*) from public.callbacks k where k.business_id = b.id and k.assigned_to is null and k.status not in ('completed', 'cancelled') and k.created_at < now() - make_interval(mins => coalesce(a.unassigned_alert_minutes, 10))) callbacks
      from public.businesses b left join public.assignment_rules a on a.business_id = b.id
     where b.suspended_at is null and b.cancelled_at is null
  loop
    if r.leads + r.callbacks = 0 then continue; end if;
    if exists (select 1 from public.staff_notifications n where n.business_id = r.business_id and n.kind = 'unassigned_work' and n.created_at > now() - interval '6 hours') then continue; end if;
    for u in select user_id from public.business_members where business_id = r.business_id and status = 'active' and role in ('owner', 'admin') loop
      perform public.zella_notify(r.business_id, 'unassigned_work', 'Work with no owner',
        r.leads || ' lead(s) and ' || r.callbacks || ' callback(s) have been waiting with nobody assigned. Check who is available.', 'warning', 'customers', null, u.user_id);
    end loop;
    v_alerts := v_alerts + 1;
  end loop;
  return v_alerts;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_uptime()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_last timestamptz; v_stuck text[]; v_since timestamptz;
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
begin
  select max(checked_at) into v_last from public.provider_health;
  select min(updated_at) into v_since from public.platform_settings where key = 'provider_checks_live';
  if public.zella_provider_checks_live() and coalesce(v_last, v_since, now()) < now() - interval '6 hours' then
    perform public.zella_platform_alert('automation_heartbeat', 'The automation engine looks down',
      'No connection check has come back for 6 hours (last: ' || coalesce(to_char(v_last at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never')
      || '). n8n may be down or the Connection Tests workflow switched off.', 'urgent', null, 'heartbeat');
  else
    perform public.zella_resolve_platform_alerts('automation_heartbeat', null, 'heartbeat', 'Connection checks are coming back again');
  end if;
  select coalesce(array_agg(workflow order by workflow), '{}') into v_stuck from public.n8n_dispatch_state
   where workflow <> '_kick' and consecutive_same >= 12 and last_count > 0 and last_triggered_at > now() - interval '30 minutes';
  if v_n8n and cardinality(v_stuck) > 0 then
    perform public.zella_platform_alert('automation_stalled', 'Automations are not being worked',
      'n8n keeps being called but these queues are not going down: ' || array_to_string(v_stuck, ', ') || '. Check the workflows are published and their credentials work.',
      'urgent', null, 'stalled', jsonb_build_object('workflows', to_jsonb(v_stuck)));
  else
    perform public.zella_resolve_platform_alerts('automation_stalled', null, 'stalled', 'Queues are moving again');
  end if;
  return jsonb_build_object('heartbeat_last', v_last, 'stalled', to_jsonb(v_stuck));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_check_usage_thresholds()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0;
begin
  for r in select b.id from public.businesses b where b.suspended_at is null and b.cancelled_at is null loop
    begin n := n + public.zella_evaluate_call_usage_thresholds(r.id); exception when others then null; end;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_admin_alert_email(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_to jsonb; v_alerts jsonb;
begin
  select coalesce(jsonb_agg(distinct lower(trim(u.email))), '[]'::jsonb) into v_to
  from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null and not exists (select 1 from public.admin_alert_prefs ap where ap.user_id = p.user_id and not ap.email_enabled);
  if not v_live or v_from is null or jsonb_array_length(v_to) = 0 then
    return jsonb_build_object('alerts', '[]'::jsonb, 'to', v_to, 'live', v_live, 'from', v_from,
                              'why', case when not v_live then 'email_off' when v_from is null then 'no_sender' else 'no_admins' end);
  end if;
  with c as (
    update public.platform_alerts a set notified_at = now()
    where a.id in (select s.id from public.platform_alerts s
                   where s.notified_at is null and s.status = 'open'
                   order by case s.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, s.first_seen_at
                   limit greatest(1, least(coalesce(p_limit, 25), 50)) for update skip locked)
    returning a.id, a.kind, a.severity, a.title, a.detail, a.occurrences, a.first_seen_at, a.last_seen_at, a.business_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'severity', c.severity, 'title', c.title, 'detail', c.detail,
           'occurrences', c.occurrences, 'first_seen_at', c.first_seen_at, 'last_seen_at', c.last_seen_at, 'business', b.name)
           order by case c.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, c.first_seen_at), '[]'::jsonb)
    into v_alerts from c left join public.businesses b on b.id = c.business_id;
  return jsonb_build_object('alerts', v_alerts, 'to', v_to, 'live', true, 'from', v_from, 'from_name', 'Zella');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_agent_syncs(p_limit integer DEFAULT 10)
 RETURNS SETOF agent_config_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query select v.* from public.agent_config_versions v where v.status = 'published' and v.sync_status = 'pending' order by v.published_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_calendar_pulls(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare v_res jsonb := '[]'::jsonb; c record; v_token text;
begin
  if not public.zella_calendar_live() then return v_res; end if;
  for c in select * from public.calendar_connections where status = 'active' and busy_refresh_due_at <= now()
            order by busy_refresh_due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked loop
    select decrypted_secret into v_token from vault.decrypted_secrets where name = c.vault_secret_name limit 1;
    if v_token is null then
      update public.calendar_connections set status = 'error', last_error = 'The calendar needs to be connected again.', busy_refresh_due_at = null where id = c.id; continue;
    end if;
    update public.calendar_connections set busy_refresh_due_at = now() + interval '15 minutes' where id = c.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('connection_id', c.id, 'business_id', c.business_id, 'calendar_id', c.calendar_id,
      'refresh_token', v_token, 'from', now() - interval '1 day', 'to', now() + interval '60 days'));
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_calendar_sync(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare v_res jsonb := '[]'::jsonb; q record; a record; c record; b record; cu record; v_token text;
begin
  if not public.zella_calendar_live() then return v_res; end if;
  for q in select * from public.calendar_sync_queue where status = 'pending' and due_at <= now()
            order by due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked loop
    select * into c from public.calendar_connections where business_id = q.business_id and status = 'active';
    select * into a from public.appointments where id = q.appointment_id;
    if c.id is null or a.id is null then
      update public.calendar_sync_queue set status = 'skipped', error = 'no_active_connection_or_appointment', completed_at = now() where id = q.id; continue;
    end if;
    select decrypted_secret into v_token from vault.decrypted_secrets where name = c.vault_secret_name limit 1;
    if v_token is null then
      update public.calendar_sync_queue set status = 'failed', error = 'no_token', completed_at = now() where id = q.id;
      update public.calendar_connections set status = 'error', last_error = 'The calendar needs to be connected again.' where id = c.id;
      continue;
    end if;
    select coalesce(timezone, 'America/New_York') as tz, name into b from public.businesses where id = q.business_id;
    select nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '') as nm, phone into cu from public.customers where id = a.customer_id;
    update public.calendar_sync_queue set status = 'in_progress', attempts = attempts + 1, claimed_at = now() where id = q.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'queue_id', q.id, 'action', q.action, 'appointment_id', a.id, 'event_id', a.external_event_id, 'attempt', q.attempts + 1,
      'calendar_id', c.calendar_id, 'refresh_token', v_token,
      'event', jsonb_build_object(
        'summary', left(coalesce(nullif(trim(a.title), ''), 'Appointment') || coalesce(' - ' || cu.nm, ''), 200),
        'description', left('Booked with Zella.' || coalesce(E'\nCustomer: ' || cu.nm, '') || coalesce(E'\nPhone: ' || cu.phone, '') || coalesce(E'\nNotes: ' || a.description, ''), 1000),
        'start', a.start_time, 'end', a.end_time, 'timezone', b.tz)));
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_call_insights(p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('call_intel_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_model text := coalesce(nullif(trim(public.zella_setting('call_intel_model', '"claude-haiku-5-5"'::jsonb) #>> '{}'), ''), 'claude-haiku-5-5');
  v_limit integer := coalesce((public.zella_setting('call_intel_monthly_limit', '300'::jsonb) #>> '{}')::integer, 300);
  v_res jsonb := '[]'::jsonb; r record; v_used integer; v_ind text;
begin
  if not v_live then return v_res; end if;
  update public.call_insights set status = 'pending' where status = 'processing' and claimed_at < now() - interval '15 minutes';
  update public.call_insights set status = 'failed', error = 'Gave up after 3 tries.' where status = 'pending' and attempts >= 3;
  for r in select i.id, i.call_id, i.business_id from public.call_insights i
            where i.status = 'pending' and i.attempts < 3 order by i.created_at limit greatest(1, least(coalesce(p_limit, 5), 20)) for update skip locked loop
    select count(*) into v_used from public.call_insights x where x.business_id = r.business_id and x.status in ('processing', 'done') and x.claimed_at >= date_trunc('month', now());
    if v_used >= v_limit then
      update public.call_insights set status = 'skipped', error = 'Monthly limit reached.' where id = r.id;
      continue;
    end if;
    if not exists (select 1 from public.businesses b where b.id = r.business_id and b.suspended_at is null and b.cancelled_at is null) then
      update public.call_insights set status = 'skipped', error = 'Business not active.' where id = r.id;
      continue;
    end if;
    update public.call_insights set status = 'processing', claimed_at = now(), attempts = attempts + 1, model = v_model where id = r.id;
    select ind.name into v_ind from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = r.business_id;
    v_res := v_res || jsonb_build_array((
      select jsonb_build_object('call_id', c.id, 'model', v_model, 'business', jsonb_build_object('id', b.id, 'name', b.name, 'industry', v_ind),
               'transcript', left(c.transcript, 12000), 'summary', left(coalesce(c.summary, ''), 600), 'direction', c.direction, 'caller_known', c.customer_id is not null)
        from public.calls c join public.businesses b on b.id = c.business_id where c.id = r.call_id));
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_callback_calls(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(x || jsonb_build_object('source', 'callback', 'id', x ->> 'callback_id') || public.zella_call_config()), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_callbacks(p_limit)) x;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_callbacks(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res jsonb := '[]'::jsonb; v_cb record; v_biz record; v_cust record; v_next timestamptz;
begin
  for v_cb in
    select c.* from public.callbacks c
     where c.status in ('scheduled', 'retry_scheduled', 'due') and c.due_at <= now() and c.auto_call
       and (c.locked_at is null or c.locked_at < now() - interval '15 minutes')
     order by case c.priority when 'urgent' then 0 when 'high' then 1 else 2 end, c.due_at
     limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as tz, b.suspended_at, b.cancelled_at, coalesce(b.is_active, true) as is_active
      into v_biz from public.businesses b where b.id = v_cb.business_id;
    select c.first_name, c.last_name, (coalesce(c.do_not_contact, false) or not public.zella_can_contact(v_cb.business_id, c.id, 'call', 'transactional')) as dnc
      into v_cust from public.customers c where c.id = v_cb.customer_id; -- zella_callback_consent
    if v_cb.customer_id is null then   -- a caller not in the CRM: their latest call consent for this number
      v_cust.dnc := coalesce((select k.status = 'opted_out' from public.contact_consents k where k.business_id = v_cb.business_id and k.channel = 'call'
                                and k.phone_digits = public.zella_digits(v_cb.contact_number) order by k.recorded_at desc limit 1), false);
    end if;
    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not v_biz.is_active then
      update public.callbacks set status = 'needs_review', outcome = 'business_inactive', updated_at = now() where id = v_cb.id; continue;
    end if;
    if coalesce(v_cust.dnc, false) then
      update public.callbacks set status = 'cancelled', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_cb.id; continue;
    end if;
    v_next := public.zella_next_call_time(now(), v_biz.tz);
    if v_next > now() + interval '1 minute' then
      update public.callbacks set due_at = v_next, updated_at = now() where id = v_cb.id; continue;
    end if;
    update public.callbacks set status = 'in_progress', attempts = attempts + 1, locked_at = now(), updated_at = now() where id = v_cb.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'callback_id', v_cb.id, 'attempt', v_cb.attempts + 1, 'max_attempts', v_cb.max_attempts, 'reason', v_cb.reason,
      'contact_number', v_cb.contact_number, 'summary', v_cb.summary,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.tz),
      'customer', jsonb_build_object('id', v_cb.customer_id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name)));
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_events(p_limit integer DEFAULT 20)
 RETURNS SETOF automation_events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query
  with picked as (
    select id from public.automation_events
     where (status = 'received' and coalesce(next_attempt_at, now()) <= now())
        or (status = 'processing' and claimed_at < now() - interval '10 minutes')
     order by received_at
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 20), 100))
  )
  update public.automation_events e
     set status = 'processing', attempts = e.attempts + 1, claimed_at = now()
    from picked where e.id = picked.id
  returning e.*;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_followup_calls(p_limit integer DEFAULT 10, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_res jsonb := '[]'::jsonb; v_cfg jsonb := public.zella_call_config();
  v_task record; v_biz record; v_cust record; v_appt record; v_next timestamptz; v_purpose text;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'call' and t.due_at <= now() and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email into v_cust from public.customers c where c.id = v_task.customer_id;
    v_purpose := case when v_task.kind = 'lead_reactivation' then 'marketing' else 'transactional' end;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or not public.zella_can_contact(v_task.business_id, v_task.customer_id, 'call', v_purpose) or nullif(trim(coalesce(v_cust.phone, '')), '') is null then
      if v_cust.id is not null and nullif(trim(coalesce(v_cust.phone, '')), '') is not null and public.zella_can_contact(v_task.business_id, v_task.customer_id, 'sms', v_purpose) then
        update public.followup_tasks set channel = 'sms', updated_at = now() where id = v_task.id;
      elsif v_cust.id is not null and public.zella_valid_email(v_cust.email) and public.zella_can_contact(v_task.business_id, v_task.customer_id, 'email', v_purpose) then
        update public.followup_tasks set channel = 'email', updated_at = now() where id = v_task.id;
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;
    v_next := public.zella_next_call_time(now(), v_biz.timezone);
    if v_next > now() + interval '1 minute' then
      update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
      continue;
    end if;

    select a.id, a.title, a.start_time into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'source', 'task', 'id', v_task.id, 'task_id', v_task.id, 'kind', v_task.kind, 'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone),
      'appointment', case when v_appt.id is null then null else jsonb_build_object('id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time) end) || v_cfg);
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_followup_emails(p_limit integer DEFAULT 10, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(e || jsonb_build_object('vars',
           coalesce((select f.vars from public.followup_tasks f where f.id = (e ->> 'task_id')::uuid), '{}'::jsonb)
           -- rebook: no-show follow-ups carry the link to pick a new time
           || case when e ->> 'kind' = 'no_show_follow_up' and e #>> '{appointment,id}' is not null
                   then jsonb_build_object('reschedule_line', public.zella_rebook_line((e #>> '{appointment,id}')::uuid)) else '{}'::jsonb end)), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_followup_emails_base(p_limit, p_kinds)) e;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_followup_emails_base(p_limit integer DEFAULT 10, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result jsonb := '[]'::jsonb; v_task record; v_biz record; v_cust record; v_appt record;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'email' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email, coalesce(c.do_not_contact, false) as do_not_contact,
           coalesce(c.do_not_email, false) as do_not_email, coalesce(c.do_not_sms, false) as do_not_sms
      into v_cust from public.customers c where c.id = v_task.customer_id;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or v_cust.do_not_contact then
      update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.do_not_email or not public.zella_valid_email(v_cust.email) then
      if public.zella_digits(v_cust.phone) is not null and not v_cust.do_not_sms then
        update public.followup_tasks set channel = 'sms', updated_at = now() where id = v_task.id;   -- the text claim takes it from here
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id, 'kind', v_task.kind, 'channel', v_task.channel, 'entity_ref', v_task.entity_ref,
      'callback_reason', (select cb.reason from public.callbacks cb where cb.id = v_task.entity_ref and cb.business_id = v_task.business_id),
      'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time, 'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end));
  end loop;
  return v_result;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_followup_tasks(p_limit integer DEFAULT 10, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result jsonb := '[]'::jsonb;
  v_task record;
  v_biz record;
  v_cust record;
  v_appt record;
  v_next timestamptz;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at
     limit greatest(1, least(coalesce(p_limit, 10), 50))
     for update skip locked
  loop
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone,
           b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email, coalesce(c.do_not_contact, false) as do_not_contact
      into v_cust from public.customers c where c.id = v_task.customer_id;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or v_cust.do_not_contact or nullif(trim(coalesce(v_cust.phone, '')), '') is null then
      update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;

    -- Outside the calling window: try again when it opens.
    v_next := public.zella_next_call_time(now(), v_biz.timezone);
    if v_next > now() + interval '1 minute' then
      update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
      continue;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt
      from public.appointments a where a.id = v_task.appointment_id;

    update public.followup_tasks
       set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now()
     where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id,
      'kind', v_task.kind,
      'channel', v_task.channel,
      'attempt', v_task.attempts + 1,
      'max_attempts', v_task.max_attempts,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object(
        'id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name,
        'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time,
        'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end
    ));
  end loop;
  return v_result;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_followup_texts(p_limit integer DEFAULT 10, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(e || jsonb_build_object('vars',
           coalesce((select f.vars from public.followup_tasks f where f.id = (e ->> 'task_id')::uuid), '{}'::jsonb)
           -- rebook: no-show follow-ups carry the link to pick a new time
           || case when e ->> 'kind' = 'no_show_follow_up' and e #>> '{appointment,id}' is not null
                   then jsonb_build_object('reschedule_line', public.zella_rebook_line((e #>> '{appointment,id}')::uuid)) else '{}'::jsonb end)), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_followup_texts_base(p_limit, p_kinds)) e;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_followup_texts_base(p_limit integer DEFAULT 10, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result jsonb := '[]'::jsonb;
  v_task record; v_biz record; v_cust record; v_appt record; v_next timestamptz; v_reply boolean; v_offer record;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'sms' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    select e.id, e.title, e.status, e.offered_start, e.offered_end, e.offer_expires_at into v_offer from public.waitlist_entries e where false;
    v_reply := v_task.kind like 'reply\_%' or v_task.kind = 'waitlist_offer';
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email, coalesce(c.do_not_contact, false) as do_not_contact,
           coalesce(c.do_not_email, false) as do_not_email, coalesce(c.do_not_sms, false) as do_not_sms
      into v_cust from public.customers c where c.id = v_task.customer_id;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or v_cust.do_not_contact then
      update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if nullif(trim(coalesce(v_cust.phone, '')), '') is null or v_cust.do_not_sms then
      if not v_reply and public.zella_valid_email(v_cust.email) and not v_cust.do_not_email then
        update public.followup_tasks set channel = 'email', updated_at = now() where id = v_task.id;
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;
    if not v_reply then
      v_next := public.zella_next_call_time(now(), v_biz.timezone);
      if v_next > now() + interval '1 minute' then
        update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
        continue;
      end if;
    end if;

    if v_task.kind = 'waitlist_offer' then
      select e.id, e.title, e.status, e.offered_start, e.offered_end, e.offer_expires_at into v_offer from public.waitlist_entries e where e.id = v_task.entity_ref;
      if v_offer.id is null or v_offer.status <> 'offered' or v_offer.offer_expires_at < now() then
        update public.followup_tasks set status = 'skipped', outcome = 'offer_no_longer_open', completed_at = now(), updated_at = now() where id = v_task.id;
        continue;
      end if;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id, 'kind', v_task.kind, 'channel', v_task.channel, 'entity_ref', v_task.entity_ref,
      'callback_reason', (select cb.reason from public.callbacks cb where cb.id = v_task.entity_ref and cb.business_id = v_task.business_id),
      'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'offer', case when v_task.kind = 'waitlist_offer' then jsonb_build_object('title', v_offer.title, 'start', v_offer.offered_start, 'end', v_offer.offered_end,
                      'expires_at', v_offer.offer_expires_at, 'line', public.zella_waitlist_offer_line(v_task.entity_ref)) end,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time, 'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end));
  end loop;
  return v_result;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_gap_drafts(p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('knowledge_ai_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_model text := coalesce(nullif(trim(public.zella_setting('knowledge_ai_model', '"claude-haiku-5-5"'::jsonb) #>> '{}'), ''), 'claude-haiku-5-5');
  v_res jsonb := '[]'::jsonb; g record; v_biz record;
begin
  if not v_live then return v_res; end if;
  for g in select * from public.zella_claim_gaps_for_suggestion(greatest(1, least(coalesce(p_limit, 5), 20))) loop
    select b.id, b.name, b.suspended_at, b.cancelled_at into v_biz from public.businesses b where b.id = g.business_id;
    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null then
      update public.knowledge_gaps set suggested_at = now(), suggestion_confidence = 'none' where id = g.id;
      continue;
    end if;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'gap_id', g.id, 'question', g.question, 'times_asked', g.times_asked, 'model', v_model,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name),
      'knowledge', coalesce((select jsonb_agg(jsonb_build_object('kind', k.kind, 'title', k.title, 'answer', left(k.answer, 800)))
                               from (select * from public.knowledge_items where business_id = g.business_id and status = 'ready' order by updated_at desc limit 40) k), '[]'::jsonb)));
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_gaps_for_suggestion(p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, business_id uuid, question text, times_asked integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query
  with picked as (
    select g.id from public.knowledge_gaps g
     where g.status = 'open' and g.suggested_at is null and g.suggestion_attempts < 3
     order by g.times_asked desc, g.first_asked_at
     limit greatest(1, least(coalesce(p_limit, 10), 50))
     for update skip locked
  )
  update public.knowledge_gaps g set suggestion_attempts = g.suggestion_attempts + 1
    from picked where g.id = picked.id
  returning g.id, g.business_id, g.question, g.times_asked;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_knowledge_updates(p_limit integer DEFAULT 20)
 RETURNS SETOF knowledge_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query
  select k.* from public.knowledge_items k
   where k.status = 'processing'
   order by k.updated_at limit greatest(1, least(coalesce(p_limit, 20), 100))
   for update skip locked;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_notifications(p_limit integer DEFAULT 50)
 RETURNS SETOF staff_notifications
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query
  update public.staff_notifications n set delivery_status = 'sent', delivered_at = now()
   where n.id in (select s.id from public.staff_notifications s where s.delivery_status = 'pending' order by s.created_at
                   limit greatest(1, least(coalesce(p_limit, 50), 200)) for update skip locked)
  returning n.*;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_owner_emails(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n record; m record; v_res jsonb := '[]'::jsonb; v_pref boolean; v_default boolean; v_found int; v_html text; v_text text;
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
begin
  for n in select s.*, b.name as business_name from public.staff_notifications s join public.businesses b on b.id = s.business_id
            where (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes'))
              and b.suspended_at is null and b.cancelled_at is null
            order by s.created_at limit greatest(1, least(coalesce(p_limit, 20), 50)) for update of s skip locked loop
    v_default := n.kind in ('daily_summary', 'weekly_review', 'business_welcome') or n.severity in ('warning', 'urgent');
    v_found := 0;
    v_text := n.title || E'\n\n' || coalesce(n.body, '') || E'\n\nOpen Zella to see the details.';
    v_html := replace(replace(replace(replace(replace(v_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
    v_html := '<p>' || replace(replace(v_html, E'\n\n', '</p><p>'), E'\n', '<br>') || '</p>';
    for m in select bm.user_id, lower(trim(u.email)) as email from public.business_members bm join auth.users u on u.id = bm.user_id
              where bm.business_id = n.business_id and bm.status = 'active'
                and ((n.user_id is not null and bm.user_id = n.user_id) or (n.user_id is null and bm.role in ('owner', 'admin')))
                and coalesce(u.email, '') ~ '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' loop
      select np.email_enabled into v_pref from public.notification_preferences np
       where np.user_id = m.user_id and np.business_id = n.business_id and np.notification_type = n.kind limit 1;
      if coalesce(v_pref, v_default) then
        v_found := v_found + 1;
        v_res := v_res || jsonb_build_array(jsonb_build_object(
          'notification_id', n.id, 'business_id', n.business_id, 'to', m.email,
          'subject', left(regexp_replace(n.title, '[\r\n]+', ' ', 'g'), 200), 'body_text', v_text, 'body_html', v_html,
          'live', v_live, 'from', v_from, 'from_name', 'Zella', 'kind', n.kind));
      end if;
    end loop;
    if v_found = 0 then
      update public.staff_notifications set delivery_status = 'skipped', delivery_error = 'not_emailed', claimed_at = now() where id = n.id;
    else
      update public.staff_notifications set delivery_status = 'sending', claimed_at = now() where id = n.id;
    end if;
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_platform_alerts(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_alerts jsonb; v_emails jsonb := '[]'::jsonb;
begin
  with c as (
    update public.platform_alerts a set notified_at = now()
     where a.id in (select s.id from public.platform_alerts s where s.notified_at is null and s.status = 'open' order by s.first_seen_at limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked)
    returning a.*)
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into v_alerts from c;
  if to_regclass('auth.users') is not null and to_regclass('public.platform_admins') is not null then
    execute 'select coalesce(jsonb_agg(u.email), ''[]''::jsonb) from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null' into v_emails;
  end if;
  return jsonb_build_object('alerts', v_alerts, 'admin_emails', v_emails);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_provider_checks(p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p text; v_out jsonb := '[]'::jsonb; n integer := 0;
begin
  if not public.zella_provider_checks_live() then return v_out; end if;
  foreach p in array array['telnyx', 'vapi', 'resend'] loop
    exit when n >= greatest(1, least(coalesce(p_limit, 5), 10));
    if exists (select 1 from public.provider_health h where h.provider = p
                and (coalesce(h.checked_at, 'epoch') > now() - interval '3 hours' or coalesce(h.claimed_at, 'epoch') > now() - interval '10 minutes')) then continue; end if;
    insert into public.provider_health (provider, claimed_at) values (p, now()) on conflict (provider) do update set claimed_at = now();
    v_out := v_out || jsonb_build_array(jsonb_build_object('provider', p));
    n := n + 1;
  end loop;
  return v_out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_reminders(p_limit integer DEFAULT 25, p_channel text DEFAULT 'sms'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res jsonb := '[]'::jsonb; r record; a record; c record; b record; v_staff text;
        v_channel text := case when p_channel = 'email' then 'email' else 'sms' end;
        v_phone_ok boolean; v_email_ok boolean;
begin
  for r in select * from public.appointment_reminders where status = 'pending' and due_at <= now() and channel = v_channel order by due_at
           limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked loop
    select * into a from public.appointments where id = r.appointment_id;
    select * into c from public.customers where id = r.customer_id;
    select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = r.business_id;
    if a.id is null or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or (r.kind in ('reminder', 'confirmation_request') and a.start_time <= now()) then
      update public.appointment_reminders set status = 'skipped', error = 'appointment_no_longer_active' where id = r.id; continue;
    end if;
    if b.suspended_at is not null or b.cancelled_at is not null or c.id is null or coalesce(c.do_not_contact, false) or (public.zella_digits(c.phone) is null and nullif(trim(coalesce(c.email, '')), '') is null) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    v_phone_ok := public.zella_digits(c.phone) is not null and not coalesce(c.do_not_sms, false);
    v_email_ok := public.zella_valid_email(c.email) and not coalesce(c.do_not_email, false);
    if v_channel = 'sms' and not v_phone_ok and v_email_ok then
      update public.appointment_reminders set channel = 'email' where id = r.id; continue;
    elsif v_channel = 'email' and not v_email_ok and v_phone_ok then
      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;
    end if;
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'reschedule_line', public.zella_reschedule_line(a.id),
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_claim_staff_sms(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(public.zella_setting('sms_from_number', '""'::jsonb) #>> '{}', '');
  n record; m record; v_out jsonb := '[]'::jsonb; v_to text; v_digits text; v_text text; v_msg uuid; v_sent integer; v_bn text;
begin
  if not v_live or v_from is null then return v_out; end if;
  for n in select sn.* from public.staff_notifications sn
            where (sn.sms_status = 'pending' or (sn.sms_status = 'sending' and sn.sms_claimed_at < now() - interval '15 minutes'))
              and sn.created_at > now() - interval '6 hours'
            order by sn.created_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked loop
    update public.staff_notifications set sms_status = 'sending', sms_claimed_at = now() where id = n.id;
    select b.name into v_bn from public.businesses b where b.id = n.business_id and b.suspended_at is null and b.cancelled_at is null;
    if v_bn is null then update public.staff_notifications set sms_status = 'skipped' where id = n.id; continue; end if;
    select count(*) into v_sent from public.sms_messages where business_id = n.business_id and metadata ->> 'staff_alert' = 'true' and created_at > now() - interval '1 hour';
    if v_sent >= 5 then update public.staff_notifications set sms_status = 'skipped' where id = n.id; continue; end if;
    v_text := left(regexp_replace('Zella: ' || n.title || coalesce('. ' || n.body, ''), '\s+', ' ', 'g'), 300);
    for m in select bm.user_id, p.phone from public.business_members bm join public.profiles p on p.id = bm.user_id
              where bm.business_id = n.business_id and bm.status = 'active' and bm.sms_alerts
                and ((n.user_id is null and bm.role in ('owner', 'admin')) or bm.user_id = n.user_id) loop
      v_digits := regexp_replace(coalesce(m.phone, ''), '\D', '', 'g');
      v_to := case when coalesce(m.phone, '') like '+%' and length(v_digits) between 8 and 15 then '+' || v_digits
                   when length(v_digits) = 10 then '+1' || v_digits
                   when length(v_digits) = 11 and left(v_digits, 1) = '1' then '+' || v_digits end;
      continue when v_to is null;
      insert into public.sms_messages (business_id, direction, status, from_number, to_number, message_body, metadata)
      values (n.business_id, 'outbound', 'queued', v_from, v_to, v_text, jsonb_build_object('dedupe_key', 'staffsms:' || n.id || ':' || m.user_id, 'staff_alert', 'true'))
      on conflict (business_id, (metadata ->> 'dedupe_key')) where metadata ->> 'dedupe_key' is not null do nothing
      returning id into v_msg;
      continue when v_msg is null;
      v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_msg, 'from', v_from, 'to', v_to, 'text', v_text));
    end loop;
    update public.staff_notifications set sms_status = 'done' where id = n.id;
  end loop;
  return v_out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_classify_email(p_subject text, p_body text, p_auto boolean DEFAULT false)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when p_auto or coalesce(p_subject, '') ~* '^\s*(automatic reply|auto[- ]?reply|auto:|out of office|undeliverable|delivery status notification|mail delivery)' then 'auto_reply'
    when coalesce(p_body, '') ~* '\m(unsubscribe|remove me|stop (emailing|sending)|take me off|opt[- ]?out)\M' then 'unsubscribe'
    when coalesce(p_subject, '') || ' ' || coalesce(p_body, '') ~* '\m(complain|complaint|unhappy|disappointed|terrible|refund|chargeback|lawyer|legal action|sue)\M' then 'complaint'
    when coalesce(p_subject, '') || ' ' || coalesce(p_body, '') ~* '\m(cancel|cancellation|cancelled)\M' then 'cancel'
    when coalesce(p_subject, '') || ' ' || coalesce(p_body, '') ~* '\m(reschedule|different time|another time|move (my|the) appointment|change (my|the) (appointment|time))\M' then 'reschedule'
    when left(trim(coalesce(p_body, '')), 120) ~* '^(yes|confirmed?|confirm|ok(ay)?|sounds good|see you)\M' then 'confirm'
    when coalesce(p_body, '') like '%?%' then 'question'
    else 'other' end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_clean_automation_config(p_type text, p_cfg jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare
  v_out jsonb := '{}'::jsonb;
  k text; v jsonb;
  v_nums text[]; v_text text[];
begin
  if p_cfg is null or jsonb_typeof(p_cfg) <> 'object' then return '{}'::jsonb; end if;
  for k, v in select * from jsonb_each(p_cfg) loop
    v_nums := null; v_text := null;
    case
      when k = 'hours_before' and p_type = 'appointment_reminder' then
        if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then raise exception 'BAD_FIELD:hours_before'; end if;
        if exists (select 1 from jsonb_array_elements_text(v) e where e not in ('0.25','0.5','1','2','4','24','48')) then raise exception 'BAD_FIELD:hours_before'; end if;
        v_out := v_out || jsonb_build_object(k, (select jsonb_agg(distinct e::numeric order by e::numeric) from jsonb_array_elements_text(v) e));
        continue;
      when k = 'hours_before' and p_type = 'appointment_confirmation' then v_nums := array['24','48','72'];
      when k = 'minutes_after' and p_type = 'no_show_follow_up' then v_nums := array['10','15','30','60'];
      when k = 'minutes_after' and p_type = 'missed_call_follow_up' then v_nums := array['0','5','15','30'];
      when k = 'minutes_after' and p_type = 'new_lead_callback' then v_nums := array['0','5','15','60'];
      when k = 'max_attempts' and p_type in ('missed_call_follow_up','new_lead_callback') then v_nums := array['1','2','3'];
      when k = 'max_attempts' and p_type = 'quote_follow_up' then v_nums := array['1','2','3'];
      when k = 'contact_within_minutes' and p_type = 'new_lead_callback' then v_nums := array['5','15','30','60'];
      when k = 'escalate_after_minutes' and p_type = 'new_lead_callback' then v_nums := array['30','60','120','240'];
      when k = 'retry_after_hours' and p_type = 'new_lead_callback' then v_nums := array['1','4','24'];
      when k = 'hours_after' and p_type = 'post_appointment_follow_up' then v_nums := array['2','24','72'];
      when k = 'hours_after' and p_type = 'quote_follow_up' then v_nums := array['24','48','72'];
      when k = 'days_inactive' and p_type = 'lead_reactivation' then v_nums := array['14','30','60','90'];
      when k = 'offers' and p_type = 'waitlist_offer' then v_nums := array['1','2','3','5'];
      when k = 'offer_minutes' and p_type = 'waitlist_offer' then v_nums := array['15','30','60'];
      when k = 'fallback_sms' and p_type in ('missed_call_follow_up','new_lead_callback') then
        if jsonb_typeof(v) <> 'boolean' then raise exception 'BAD_FIELD:fallback_sms'; end if;
        v_out := v_out || jsonb_build_object(k, v);
        continue;
      when k = 'notify_via' then v_text := array['sms','email','both'];
      when k = 'channel' and p_type in ('appointment_reminder') then v_text := array['sms','call','sms_and_call'];
      when k = 'channel' and p_type in ('appointment_confirmation','no_show_follow_up','waitlist_offer','staff_unavailable') then v_text := array['sms','call'];
      when k = 'channel' and p_type in ('post_appointment_follow_up','quote_follow_up','lead_reactivation') then v_text := array['sms','email'];
      else raise exception 'BAD_FIELD:%', k;
    end case;
    if v_nums is not null then
      if jsonb_typeof(v) <> 'number' or not ((v #>> '{}') = any (v_nums)) then raise exception 'BAD_FIELD:%', k; end if;
      v_out := v_out || jsonb_build_object(k, (v #>> '{}')::int);
    else
      if jsonb_typeof(v) <> 'string' or not ((v #>> '{}') = any (v_text)) then raise exception 'BAD_FIELD:%', k; end if;
      v_out := v_out || jsonb_build_object(k, v);
    end if;
  end loop;
  return v_out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_clean_origins(p_origins text[])
 RETURNS text[]
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare o text; v_out text[] := '{}';
begin
  foreach o in array coalesce(p_origins, '{}') loop
    o := lower(regexp_replace(trim(o), '/+$', ''));
    if o = '' then continue; end if;
    if o !~ '^https?://(localhost|[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+)(:[0-9]{2,5})?$' then raise exception 'BAD_ORIGIN'; end if;
    if not (o = any (v_out)) then v_out := v_out || o; end if;
  end loop;
  if cardinality(v_out) > 10 then raise exception 'TOO_MANY_ORIGINS'; end if;
  return v_out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_clear_live_notice(p_business_id uuid, p_notice_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.live_notices set cleared_at = now() where id = p_notice_id and business_id = p_business_id and cleared_at is null;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'live_notice_cleared', 'live_notice', p_notice_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_complete_agent_sync(p_version_id uuid, p_ok boolean, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v record;
begin
  select * into v from public.agent_config_versions where id = p_version_id for update;
  if not found or v.status <> 'published' then return; end if;
  update public.agent_config_versions set sync_status = case when p_ok then 'live' else 'failed' end, sync_error = case when p_ok then null else left(p_error, 300) end where id = p_version_id;
  if not p_ok then
    perform public.zella_platform_alert('agent_sync_failed', 'An AI receptionist update did not go live', p_error, 'warning', v.business_id, p_version_id::text);
    perform public.zella_notify_owners(v.business_id, 'agent_sync_failed', 'Your latest AI changes are not live yet', 'We could not apply version ' || v.version || '. The previous version is still answering calls.', 'warning', 'receptionist');
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_complete_event(p_event_id uuid, p_ok boolean, p_error_category text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.automation_events; v_temp boolean;
begin
  select * into e from public.automation_events where id = p_event_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_ok then
    update public.automation_events set status = 'processed', processed_at = now(), error_category = null, error_message = null where id = e.id;
    return 'processed';
  end if;
  v_temp := coalesce(p_error_category, 'unknown_error') in ('rate_limited','temporary_network','provider_timeout','unknown_error');
  if v_temp and e.attempts < 5 then
    update public.automation_events
       set status = 'received', next_attempt_at = now() + make_interval(secs => least(3600, 30 * power(2, e.attempts)::int)),
           error_category = coalesce(p_error_category, 'unknown_error'), error_message = public.zella_redact(p_error)
     where id = e.id;
    return 'retry';
  end if;
  update public.automation_events
     set status = 'failed', processed_at = now(), error_category = coalesce(p_error_category, 'unknown_error'), error_message = public.zella_redact(p_error)
   where id = e.id;
  insert into public.automation_dead_letters (business_id, source_table, source_id, event_id, reason, error_category)
  values (e.business_id, 'automation_events', e.id, e.id, coalesce(public.zella_redact(p_error), 'Failed'), coalesce(p_error_category, 'unknown_error'))
  on conflict do nothing;
  return 'dead_letter';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_complete_followup_task(p_task_id uuid, p_outcome text, p_notes text DEFAULT NULL::text, p_provider_call_id text DEFAULT NULL::text, p_call_id uuid DEFAULT NULL::uuid, p_retry_in_minutes integer DEFAULT 120)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task record; v_tz text; v_status text;
begin
  select * into v_task from public.followup_tasks where id = p_task_id for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if p_outcome not in ('rescheduled', 'wants_callback', 'declined', 'no_answer', 'voicemail', 'sms_sent', 'email_sent', 'failed') then
    raise exception 'BAD_OUTCOME';
  end if;

  if p_outcome in ('no_answer', 'voicemail', 'failed') and v_task.attempts < v_task.max_attempts then
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = v_task.business_id;
    update public.followup_tasks
       set status = 'pending', outcome = p_outcome, outcome_notes = p_notes,
           provider_call_id = coalesce(p_provider_call_id, provider_call_id),
           call_id = coalesce(p_call_id, call_id),
           due_at = public.zella_next_call_time(now() + make_interval(mins => greatest(5, coalesce(p_retry_in_minutes, 120))), v_tz),
           updated_at = now()
     where id = p_task_id;
    return 'retry_scheduled';
  end if;

  v_status := case when p_outcome = 'failed' then 'failed' else 'done' end;
  update public.followup_tasks
     set status = v_status, outcome = p_outcome, outcome_notes = p_notes,
         provider_call_id = coalesce(p_provider_call_id, provider_call_id),
         call_id = coalesce(p_call_id, call_id),
         completed_at = now(), updated_at = now()
   where id = p_task_id;

  if p_outcome = 'wants_callback' and coalesce(p_call_id, v_task.call_id) is not null then
    update public.calls
       set needs_human = true,
           escalation_reason = coalesce(nullif(p_notes, ''), 'Asked for a call back after a missed appointment'),
           escalated_at = now(), escalation_resolved_at = null, updated_at = now()
     where id = coalesce(p_call_id, v_task.call_id);
  end if;
  return v_status;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_complete_knowledge_update(p_item_id uuid, p_version integer, p_ok boolean, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_item record;
begin
  select * into v_item from public.knowledge_items where id = p_item_id for update;
  if not found then raise exception 'ITEM_NOT_FOUND'; end if;
  if v_item.version <> p_version or v_item.status <> 'processing' then return 'stale'; end if;
  if p_ok then
    update public.knowledge_items set status = 'ready', ready_at = now(), error = null where id = p_item_id;
    return 'ready';
  end if;
  update public.knowledge_items set status = 'failed', error = left(coalesce(p_error, 'Could not be processed'), 500) where id = p_item_id;
  return 'failed';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_complete_reminder(p_reminder_id uuid, p_ok boolean, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record;
begin
  select * into r from public.appointment_reminders where id = p_reminder_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'sending' then return r.status; end if;
  if p_ok then update public.appointment_reminders set status = 'sent', sent_at = now(), error = null where id = p_reminder_id; return 'sent'; end if;
  if r.attempts < 2 then
    update public.appointment_reminders set status = 'pending', due_at = now() + interval '10 minutes', error = left(p_error, 300) where id = p_reminder_id; return 'retry';
  end if;
  update public.appointment_reminders set status = 'failed', error = left(p_error, 300) where id = p_reminder_id;
  perform public.zella_notify(r.business_id, 'reminder_failed', 'A customer message was not delivered', 'A ' || r.kind || ' could not be sent. Contact them another way.', 'warning', 'calendar', r.appointment_id);
  return 'failed';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_complete_task(p_task_id uuid, p_cancel boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_b uuid;
begin
  select business_id into v_b from public.crm_tasks where id = p_task_id;
  if v_b is null or not public.zella_is_member(v_b) then raise exception 'NOT_ALLOWED'; end if;
  update public.crm_tasks set status = case when p_cancel then 'cancelled' else 'done' end, completed_at = now() where id = p_task_id and status = 'open';
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_confirm_hold(p_appointment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is not null and not public.zella_is_member(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.booking_state <> 'tentative' or a.status <> 'scheduled' or a.hold_expires_at < now() then raise exception 'HOLD_EXPIRED'; end if;
  update public.appointments set booking_state = 'confirmed', hold_expires_at = null, updated_at = now() where id = p_appointment_id;
  return p_appointment_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_confirm_requested_appointment(p_appointment_id uuid, p_start timestamp with time zone, p_duration_minutes integer DEFAULT 30, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v_slot record;
begin
  perform public.zella_booking_lock((select x.business_id from public.appointments x where x.id = p_appointment_id)); -- zella_booking_lock
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found or not public.zella_is_member(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.booking_state = 'confirmed' then raise exception 'ALREADY_CONFIRMED'; end if;
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  select * into v_slot from public.zella_available_slots(a.business_id, p_start, p_start, p_duration_minutes, p_staff_id, 5, 1, p_appointment_id) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  update public.appointments set start_time = v_slot.slot_start, end_time = v_slot.slot_end, staff_id = v_slot.staff_id, booking_state = 'confirmed', hold_expires_at = null, updated_at = now() where id = p_appointment_id;
  update public.callbacks set status = 'completed', outcome = 'booked', completed_at = now(), auto_call = false, updated_at = now()
   where appointment_id = p_appointment_id and reason = 'appointment_request' and status not in ('completed', 'cancelled');
  return p_appointment_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_connections_to_reconnect(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'label') from (
      select jsonb_build_object('kind', 'calendar', 'label', 'Calendar', 'reason', coalesce(left(last_error, 120), 'Needs to be connected again')) x
        from public.calendar_connections where business_id = p_business_id and status = 'error'
      union all
      select jsonb_build_object('kind', 'meta', 'label', coalesce(page_name, 'Facebook/Instagram'), 'reason', coalesce(left(last_error, 120), 'Needs to be connected again'))
        from public.meta_connections where business_id = p_business_id and status in ('needs_reconnect', 'error')) y), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_conversation_touch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.conversations
     set last_message_at = greatest(coalesce(last_message_at, new.created_at), new.created_at),
         last_inbound_at = case when new.sender_type = 'customer' then greatest(coalesce(last_inbound_at, new.created_at), new.created_at) else last_inbound_at end,
         updated_at = now()
   where id = new.conversation_id;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_create_business_draft(p_fields jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_industry    uuid := (p_fields->>'industry_id')::uuid;
  v_business_id uuid;
  v_agent_id    uuid;
  v_modules     integer;
  v_timezone    text := coalesce(nullif(p_fields->>'timezone', ''), 'America/New_York');
begin
  if not exists (select 1 from industries where id = v_industry and is_active) then
    raise exception 'INDUSTRY_NOT_FOUND';
  end if;

  insert into businesses (
    name, legal_name, industry_id, email, phone, website,
    address_line_1, address_line_2, city, state, postal_code, country,
    timezone, onboarding_status, is_active
  )
  values (
    p_fields->>'name',
    nullif(p_fields->>'legal_name', ''),
    v_industry,
    nullif(p_fields->>'email', ''),
    nullif(p_fields->>'phone', ''),
    nullif(p_fields->>'website', ''),
    nullif(p_fields->>'address_line_1', ''),
    nullif(p_fields->>'address_line_2', ''),
    nullif(p_fields->>'city', ''),
    nullif(p_fields->>'state', ''),
    nullif(p_fields->>'postal_code', ''),
    coalesce(nullif(p_fields->>'country', ''), 'US'),
    v_timezone,
    'business_info',
    false            -- workspace stays inactive until setup is finished
  )
  returning id into v_business_id;

  -- All of the industry's active modules start enabled; step 4 adjusts them.
  insert into business_modules (business_id, module_id, enabled)
  select v_business_id, m.id, true
  from industry_modules m
  where m.industry_id = v_industry and m.is_active;
  get diagnostics v_modules = row_count;

  -- AI receptionist is created disabled; it goes live only after setup and phone connection.
  insert into ai_agents (business_id, name, agent_type, status, channels, is_default)
  values (v_business_id, 'AI Receptionist', 'receptionist', 'disabled', '{}', true)
  returning id into v_agent_id;

  insert into ai_agent_configs (agent_id, business_context)
  values (
    v_agent_id,
    jsonb_build_object(
      'business_name', p_fields->>'name',
      'industry_id',   v_industry,
      'timezone',      v_timezone
    )
  );

  return jsonb_build_object(
    'business_id',     v_business_id,
    'agent_id',        v_agent_id,
    'modules_enabled', v_modules
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_create_callback(p_business_id uuid, p_contact_number text, p_reason text DEFAULT 'other'::text, p_priority text DEFAULT 'normal'::text, p_summary text DEFAULT NULL::text, p_preferred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_customer_id uuid DEFAULT NULL::uuid, p_call_id uuid DEFAULT NULL::uuid, p_appointment_id uuid DEFAULT NULL::uuid, p_created_by text DEFAULT 'ai'::text, p_automation text DEFAULT 'missed_call_follow_up'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text; v_auto record; v_due timestamptz; v_cust uuid := p_customer_id; v_id uuid; v_note text;
  v_reason text := case when p_reason in ('missed_call','new_lead','requested','needs_human','transfer_failed','appointment_request','booking_failed','after_hours') then p_reason else 'other' end;
  v_priority text := case when p_priority in ('high','urgent') then p_priority else 'normal' end;
  v_max integer; v_delay integer; v_first integer;
begin
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  if v_tz is null then raise exception 'BUSINESS_NOT_FOUND'; end if;
  if nullif(trim(coalesce(p_contact_number, '')), '') is null and v_cust is null then raise exception 'NO_CONTACT'; end if;
  if v_cust is null then select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_contact_number, null) m where m.certainty = 'exact'; end if;
  if nullif(trim(coalesce(p_contact_number, '')), '') is null then select c.phone into p_contact_number from public.customers c where c.id = v_cust; end if;

  -- Zella calls back by itself only when the business switched that on.
  select a.* into v_auto from public.automations a
   where a.business_id = p_business_id and a.trigger_type = case when p_automation = 'new_lead_callback' then 'new_lead_callback' else 'missed_call_follow_up' end and a.status = 'active' limit 1;
  v_max := coalesce((v_auto.trigger_config ->> 'max_attempts')::integer, 3);
  -- missed-call: retry after retry_delay_minutes (default 2h); new lead: retry_after_hours (default 24h)
  v_delay := coalesce((v_auto.trigger_config ->> 'retry_delay_minutes')::integer, (v_auto.trigger_config ->> 'retry_after_hours')::integer * 60, 120);
  v_first := coalesce((v_auto.trigger_config ->> 'minutes_after')::integer, 5);

  -- Never silently book an inappropriate time: move it into the calling window.
  v_due := public.zella_next_call_time(coalesce(p_preferred_at, now() + make_interval(mins => v_first)), v_tz);
  if p_preferred_at is not null and v_due <> p_preferred_at then
    v_note := 'The requested time was outside calling hours, so it was moved to the next available time.';
  end if;

  insert into public.callbacks (business_id, customer_id, call_id, appointment_id, reason, priority, status, contact_number, summary,
      preferred_at, due_at, auto_call, max_attempts, retry_delay_minutes, note, created_by)
  values (p_business_id, v_cust, p_call_id, p_appointment_id, v_reason, v_priority, 'scheduled', p_contact_number, left(p_summary, 1000),
      p_preferred_at, v_due, (v_auto.id is not null and coalesce(v_auto.trigger_config ->> 'channel', 'call') = 'call' and v_reason not in ('needs_human', 'transfer_failed')),
      v_max, v_delay, v_note, case when p_created_by in ('ai','system','staff') then p_created_by else 'ai' end)
  on conflict (business_id, (public.zella_digits(contact_number)), reason) where contact_number is not null and status not in ('completed','cancelled','needs_review')
  do update set summary = coalesce(excluded.summary, callbacks.summary), priority = case when excluded.priority = 'urgent' or callbacks.priority = 'urgent' then 'urgent' when excluded.priority = 'high' or callbacks.priority = 'high' then 'high' else 'normal' end,
                call_id = coalesce(excluded.call_id, callbacks.call_id), updated_at = now()
  returning id into v_id;

  perform public.zella_notify(p_business_id, 'callback', 'Callback needed',
    coalesce(p_summary, 'A caller needs a call back.'), case when v_priority = 'normal' then 'info' else 'urgent' end, 'callbacks', v_id);
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_create_handover(p_business_id uuid, p_to_user uuid, p_note text DEFAULT NULL::text, p_from_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_from uuid := coalesce(p_from_user, auth.uid()); v_moved jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_from is not null and v_from <> coalesce(auth.uid(), v_from)
     and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin','manager')) then
    raise exception 'NOT_ALLOWED';
  end if;
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;
  v_moved := public.zella_move_open_work(p_business_id, v_from, p_to_user);
  insert into public.staff_handovers (business_id, from_user, to_user, note, moved, created_by) values (p_business_id, v_from, p_to_user, left(p_note, 1000), v_moved, auth.uid());
  perform public.zella_notify(p_business_id, 'shift_handover', 'Work handed over to you',
    coalesce(left(p_note, 300), 'Open leads, callbacks and requests were moved to you.'), 'info', 'inbox', null, p_to_user);
  return v_moved;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_create_task(p_business_id uuid, p_customer_id uuid, p_kind text, p_title text, p_body text DEFAULT NULL::text, p_priority text DEFAULT 'normal'::text, p_due_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_assigned_to uuid DEFAULT NULL::uuid, p_source text DEFAULT 'automation'::text, p_entity_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  insert into public.crm_tasks (business_id, customer_id, kind, title, body, priority, due_at, assigned_to, source, entity_id)
  values (p_business_id, p_customer_id, coalesce(p_kind, 'follow_up'), p_title, p_body, case when p_priority in ('high','urgent') then p_priority else 'normal' end,
          p_due_at, p_assigned_to, case when p_source in ('automation','ai','staff') then p_source else 'automation' end, p_entity_id)
  on conflict (business_id, customer_id, kind) where status = 'open' and customer_id is not null and kind in ('overdue_contact','duplicate_review','onboarding','quote_review')
  do nothing returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_create_website_form(p_business_id uuid, p_name text DEFAULT 'Website'::text, p_allowed_origins text[] DEFAULT '{}'::text[])
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  if auth.uid() is not null and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin','manager')) then
    raise exception 'NOT_ALLOWED';
  end if;
  insert into public.website_forms (business_id, name, allowed_origins) values (p_business_id, left(coalesce(nullif(trim(p_name), ''), 'Website'), 80), coalesce(p_allowed_origins, '{}'))
  returning public_key into v_key;
  return v_key;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_crm_clean_data(p_fields jsonb, p_data jsonb, OUT cleaned jsonb, OUT unique_key text)
 RETURNS record
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare f jsonb; k text; v text; lbl text; ty text; out_obj jsonb := '{}'::jsonb;
begin
  for f in select * from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) loop
    k := f ->> 'key'; lbl := f ->> 'label'; ty := f ->> 'type';
    v := nullif(trim(coalesce(p_data ->> k, '')), '');
    if v is null then
      if coalesce((f ->> 'required')::boolean, false) and ty <> 'bool' then raise exception 'FIELD_REQUIRED:%', lbl; end if;
      continue;
    end if;
    if ty = 'number' then
      begin perform v::numeric; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v::numeric);
    elsif ty = 'bool' then
      out_obj := out_obj || jsonb_build_object(k, v in ('true', 't', '1', 'yes'));
    elsif ty = 'date' then
      begin perform v::date; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v::date::text);
    elsif ty = 'datetime' then
      begin perform v::timestamptz; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v);
    elsif ty = 'select' then
      if not (f -> 'options') ? v then raise exception 'BAD_FIELD:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, v);
    elsif ty = 'email' then
      if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_FIELD:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, lower(v));
    else
      out_obj := out_obj || jsonb_build_object(k, left(v, 4000));
    end if;
    if coalesce((f ->> 'unique')::boolean, false) then unique_key := lower(regexp_replace(v, '[^[:alnum:]]', '', 'g')); end if;
  end loop;
  cleaned := out_obj;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_crm_on_industry()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.industry_id is not null and new.onboarding_status in ('testing', 'ready', 'active', 'paused')
     and (tg_op = 'INSERT' or new.industry_id is distinct from old.industry_id or new.onboarding_status is distinct from old.onboarding_status) then
    begin
      perform public.zella_apply_crm_preset(new.id);
    exception when others then
      raise warning 'zella_crm_on_industry: %', sqlerrm;
    end;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_crm_write_record(p_actor uuid, p_source text, p_business_id uuid, p_type_key text, p_id uuid, p_title text, p_status text, p_customer_id uuid, p_assigned_to uuid, p_due_at timestamp with time zone, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ty record; v_status text; v_clean jsonb; v_ukey text; v_dup uuid; v_id uuid; v_old_status text;
begin
  select * into ty from public.crm_record_types where business_id = p_business_id and key = p_type_key and enabled;
  if not found then raise exception 'NOT_VALID'; end if;
  if nullif(trim(coalesce(p_title, '')), '') is null then raise exception 'EMPTY_TITLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if ty.link_person = false then p_customer_id := null; end if;
  select c.cleaned, c.unique_key into v_clean, v_ukey from public.zella_crm_clean_data(ty.fields, p_data) c;
  if p_id is not null then
    select status into v_old_status from public.crm_records
      where id = p_id and business_id = p_business_id and type_key = p_type_key and archived_at is null for update;
    if not found then raise exception 'NOT_ALLOWED'; end if;
  end if;
  v_status := coalesce(nullif(p_status, ''), v_old_status, ty.statuses -> 0 ->> 'key');
  if not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = v_status) then raise exception 'NOT_VALID'; end if;
  if v_ukey is not null then
    select id into v_dup from public.crm_records
      where business_id = p_business_id and type_key = p_type_key and unique_key = v_ukey and archived_at is null and id is distinct from p_id limit 1;
    if v_dup is not null then raise exception 'DUPLICATE:%', v_dup; end if;
  end if;
  if p_id is null then
    insert into public.crm_records (business_id, type_key, title, status, customer_id, assigned_to, due_at, data, unique_key, source, created_by, closed_at)
    values (p_business_id, p_type_key, trim(p_title), v_status, p_customer_id, p_assigned_to, p_due_at, v_clean, v_ukey, p_source, p_actor,
            case when v_status = any (ty.closed_statuses) then now() end)
    returning id into v_id;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'created', null, p_actor);
  else
    update public.crm_records set title = trim(p_title), status = v_status, customer_id = p_customer_id, assigned_to = p_assigned_to, due_at = p_due_at,
      data = v_clean, unique_key = v_ukey, updated_at = now(),
      closed_at = case when v_status = any (ty.closed_statuses) then coalesce(closed_at, now()) else null end
      where id = p_id;
    v_id := p_id;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'edited', null, p_actor);
    if v_old_status <> v_status then
      insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'status', v_old_status || ' → ' || v_status, p_actor);
    end if;
  end if;
  return jsonb_build_object('id', v_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_booked()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.customer_id is null then return new; end if;
  update public.followup_tasks f set status = 'cancelled', outcome = 'already_booked', completed_at = now(), updated_at = now()
   where f.customer_id = new.customer_id and f.business_id = new.business_id and f.kind = 'cross_sell' and f.status = 'pending'
     and position(lower(f.vars ->> 'suggestion') in lower(coalesce(new.title, '') || ' ' || coalesce(new.appointment_type, ''))) > 0;
  return new;
exception when others then
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.cross_sell_rules; c record; v_channel text; v_text text;
begin
  if new.status <> 'completed' or old.status is not distinct from new.status or new.customer_id is null then return new; end if;
  if coalesce(public.zella_setting('customer_touches', '{}'::jsonb) -> 'cross_sell', 'true'::jsonb) = 'false'::jsonb then return new; end if;
  v_text := lower(coalesce(new.title, '') || ' ' || coalesce(new.appointment_type, ''));
  select x.id, x.phone, x.email, coalesce(x.do_not_contact, false) dnc, coalesce(x.do_not_sms, false) dns, coalesce(x.do_not_email, false) dne, x.preferred_channel pref
    into c from public.customers x where x.id = new.customer_id and x.business_id = new.business_id;
  if c.id is null or c.dnc then return new; end if;
  if exists (select 1 from public.followup_tasks f where f.customer_id = c.id and f.kind = 'cross_sell' and f.created_at > now() - interval '14 days') then return new; end if;
  for r in select * from public.cross_sell_rules where business_id = new.business_id and active order by created_at loop
    continue when position(lower(r.after_service) in v_text) = 0;
    continue when exists (select 1 from public.followup_tasks f where f.customer_id = c.id and f.kind = 'cross_sell'
                            and f.vars ->> 'rule_id' = r.id::text and f.created_at > now() - interval '90 days');
    continue when exists (select 1 from public.appointments a where a.customer_id = c.id and a.business_id = new.business_id
                            and a.start_time > now() and a.status in ('scheduled', 'confirmed') and position(lower(r.suggestion) in lower(coalesce(a.title, ''))) > 0);
    if c.pref = 'email' and public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
    elsif public.zella_digits(c.phone) is not null and not c.dns then v_channel := 'sms';
    elsif public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
    else return new; end if;
    insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)
    values (new.business_id, c.id, new.id, 'cross_sell', v_channel, now() + make_interval(days => r.delay_days), 2,
            jsonb_build_object('service', left(coalesce(nullif(trim(new.title), ''), r.after_service), 80), 'suggestion', r.suggestion, 'rule_id', r.id))
    on conflict do nothing;
    exit;
  end loop;
  return new;
exception when others then
  return new;   -- a suggestion must never block completing an appointment
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_delete(p_business_id uuid, p_rule_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  update public.followup_tasks set status = 'cancelled', outcome = 'rule_removed', completed_at = now(), updated_at = now()
   where business_id = p_business_id and kind = 'cross_sell' and status = 'pending' and vars ->> 'rule_id' = p_rule_id::text;
  delete from public.cross_sell_rules where id = p_rule_id and business_id = p_business_id;
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_ideas(p_industry_slug text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(ideas.v -> p_industry_slug, '[]'::jsonb) from (select '{
    "dental": [{"after_service": "cleaning", "suggestion": "teeth whitening", "delay_days": 14}],
    "beauty-salon": [{"after_service": "colour", "suggestion": "deep conditioning treatment", "delay_days": 21},
                     {"after_service": "cut", "suggestion": "blow-dry", "delay_days": 28}],
    "spa-wellness": [{"after_service": "massage", "suggestion": "facial", "delay_days": 21}],
    "hvac": [{"after_service": "install", "suggestion": "annual maintenance plan", "delay_days": 30},
             {"after_service": "repair", "suggestion": "annual maintenance plan", "delay_days": 14}],
    "plumbing": [{"after_service": "repair", "suggestion": "water heater check", "delay_days": 30}],
    "electrical": [{"after_service": "install", "suggestion": "electrical safety inspection", "delay_days": 30}],
    "automotive": [{"after_service": "oil change", "suggestion": "tire rotation", "delay_days": 30}],
    "cleaning-services": [{"after_service": "clean", "suggestion": "deep clean", "delay_days": 30}],
    "landscaping-lawn-care": [{"after_service": "mow", "suggestion": "seasonal clean-up", "delay_days": 30}],
    "pest-control": [{"after_service": "treatment", "suggestion": "quarterly prevention plan", "delay_days": 30}],
    "fitness": [{"after_service": "trial", "suggestion": "personal training session", "delay_days": 3}],
    "pet-care-veterinary": [{"after_service": "grooming", "suggestion": "nail trim", "delay_days": 28}],
    "photography-events": [{"after_service": "session", "suggestion": "printed photos", "delay_days": 7}]
  }'::jsonb as v) ideas;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_list(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_slug text;
begin
  if auth.uid() is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select i.slug into v_slug from public.businesses b left join public.industries i on i.id = b.industry_id where b.id = p_business_id;
  return jsonb_build_object(
    'can_edit', public.zella_can_manage(p_business_id),
    'marketing_texts_allowed', coalesce(public.zella_setting('sms_marketing_allowed', 'false'::jsonb) = 'true'::jsonb, false),
    'rules', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'after_service', r.after_service, 'suggestion', r.suggestion, 'delay_days', r.delay_days,
                 'active', r.active,
                 'queued', (select count(*) from public.followup_tasks f where f.business_id = p_business_id and f.kind = 'cross_sell' and f.vars ->> 'rule_id' = r.id::text and f.status in ('pending', 'in_progress')),
                 'sent', (select count(*) from public.followup_tasks f where f.business_id = p_business_id and f.kind = 'cross_sell' and f.vars ->> 'rule_id' = r.id::text and f.status = 'done' and f.created_at > now() - interval '90 days'),
                 'not_sent', (select count(*) from public.followup_tasks f where f.business_id = p_business_id and f.kind = 'cross_sell' and f.vars ->> 'rule_id' = r.id::text and f.status in ('skipped', 'cancelled', 'failed') and f.created_at > now() - interval '90 days'))
               order by r.created_at) from public.cross_sell_rules r where r.business_id = p_business_id), '[]'::jsonb),
    'ideas', (select coalesce(jsonb_agg(i), '[]'::jsonb) from jsonb_array_elements(public.zella_cross_sell_ideas(v_slug)) i
               where not exists (select 1 from public.cross_sell_rules r where r.business_id = p_business_id
                                   and lower(r.after_service) = lower(i ->> 'after_service') and lower(r.suggestion) = lower(i ->> 'suggestion'))));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_save(p_business_id uuid, p_rule jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_after text; v_sugg text; v_days integer; v_active boolean;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_rule) <> 'object' then raise exception 'INVALID_RULE'; end if;
  v_after := trim(regexp_replace(coalesce(p_rule ->> 'after_service', ''), '\s+', ' ', 'g'));
  v_sugg := trim(regexp_replace(coalesce(p_rule ->> 'suggestion', ''), '\s+', ' ', 'g'));
  if length(v_after) not between 2 and 80 or length(v_sugg) not between 2 and 80 then raise exception 'INVALID_RULE'; end if;
  if (v_after || ' ' || v_sugg) ~ '(https?://|www\.|[{}<>])' then raise exception 'RULE_TEXT'; end if;
  if lower(v_after) = lower(v_sugg) then raise exception 'SAME_SERVICE'; end if;
  begin v_days := coalesce((p_rule ->> 'delay_days')::integer, 14); exception when others then raise exception 'INVALID_DELAY'; end;
  if v_days not between 1 and 365 then raise exception 'INVALID_DELAY'; end if;
  v_active := coalesce((p_rule ->> 'active')::boolean, true);
  if nullif(p_rule ->> 'id', '') is not null then
    begin v_id := (p_rule ->> 'id')::uuid; exception when others then raise exception 'NOT_FOUND'; end;
    update public.cross_sell_rules set after_service = v_after, suggestion = v_sugg, delay_days = v_days, active = v_active, updated_at = now()
     where id = v_id and business_id = p_business_id;
    if not found then raise exception 'NOT_FOUND'; end if;
  else
    if (select count(*) from public.cross_sell_rules where business_id = p_business_id) >= 30 then raise exception 'TOO_MANY_RULES'; end if;
    insert into public.cross_sell_rules (business_id, after_service, suggestion, delay_days, active, created_by)
    values (p_business_id, v_after, v_sugg, v_days, v_active, auth.uid()) returning id into v_id;
  end if;
  return v_id;
exception when unique_violation then raise exception 'DUPLICATE_RULE';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_cross_sell_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('table', to_regclass('public.cross_sell_rules') is not null,
    'templates', (select count(*) = 2 from public.message_templates where business_id is null and key = 'cross_sell' and status = 'active' and purpose = 'marketing'),
    'dispatcher_kind', coalesce(pg_get_functiondef(to_regprocedure('public.zella_dispatch_n8n()')) like '%''cross_sell''%', false));
$function$
;
CREATE OR REPLACE FUNCTION public.zella_current_subscription(p_business_id uuid)
 RETURNS subscriptions
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select s.* from public.subscriptions s
   where s.business_id = p_business_id and s.status in ('trial', 'active', 'renewal_due', 'past_due', 'grace_period')
   order by s.created_at desc limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_customer_change_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f text[] := '{}'; dup uuid;
begin
  if new.first_name is distinct from old.first_name then f := array_append(f, 'first_name'::text); end if;
  if new.last_name is distinct from old.last_name then f := array_append(f, 'last_name'::text); end if;
  if new.phone is distinct from old.phone then f := array_append(f, 'phone'::text); end if;
  if new.email is distinct from old.email then f := array_append(f, 'email'::text); end if;
  if new.do_not_contact is distinct from old.do_not_contact then f := array_append(f, 'do_not_contact'::text); end if;
  if new.do_not_sms is distinct from old.do_not_sms then f := array_append(f, 'do_not_sms'::text); end if;
  if new.do_not_email is distinct from old.do_not_email then f := array_append(f, 'do_not_email'::text); end if;
  if new.do_not_call is distinct from old.do_not_call then f := array_append(f, 'do_not_call'::text); end if;
  if new.preferred_channel is distinct from old.preferred_channel then f := array_append(f, 'preferred_channel'::text); end if;
  if new.status is distinct from old.status then f := array_append(f, 'status'::text); end if;
  if cardinality(f) = 0 then return new; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (new.business_id, auth.uid(), 'customer.updated', 'customer', new.id, jsonb_build_object('fields', to_jsonb(f)));
  if (f && array['phone', 'email']) and new.status = 'active' then
    select c.id into dup from public.customers c
     where c.business_id = new.business_id and c.id <> new.id and c.status = 'active'
       and ((public.zella_digits(new.phone) is not null and public.zella_digits(c.phone) = public.zella_digits(new.phone)) or (nullif(new.email, '') is not null and lower(c.email) = lower(new.email)))
     limit 1;
    if dup is not null and not exists (select 1 from public.duplicate_reviews r where r.business_id = new.business_id and r.status = 'open'
                                         and ((r.customer_id = dup and r.incoming ->> 'duplicate_customer_id' = new.id::text) or (r.customer_id = new.id and r.incoming ->> 'duplicate_customer_id' = dup::text))) then
      insert into public.duplicate_reviews (business_id, customer_id, incoming)
      values (new.business_id, dup, jsonb_build_object('duplicate_customer_id', new.id, 'first_name', new.first_name, 'last_name', new.last_name, 'phone', new.phone, 'email', new.email, 'source', 'edit'));
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_customer_timeline(p_business_id uuid, p_customer_id uuid, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_limit integer := greatest(1, least(coalesce(p_limit, 100), 300));
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  return coalesce((select jsonb_agg(e order by (e ->> 'at') desc) from (select e from (
    (select jsonb_build_object('type', 'call', 'at', coalesce(started_at, created_at), 'id', id, 'title', case direction when 'inbound' then 'Call from customer' else 'Call to customer' end,
            'detail', left(coalesce(summary, outcome_note, ''), 300), 'status', coalesce(outcome, status)) e
       from public.calls where business_id = p_business_id and customer_id = p_customer_id order by coalesce(started_at, created_at) desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'text', 'at', created_at, 'id', id, 'title', case direction when 'inbound' then 'Text from customer' else 'Text to customer' end, 'detail', left(coalesce(message_body, ''), 200), 'status', status)
       from public.sms_messages where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'email', 'at', created_at, 'id', id, 'title', case direction when 'inbound' then 'Email from customer' else 'Email to customer' end, 'detail', left(coalesce(subject, ''), 200), 'status', status)
       from public.email_messages where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'appointment', 'at', start_time, 'id', id, 'title', coalesce(title, 'Appointment'), 'detail', '', 'status', status)
       from public.appointments where business_id = p_business_id and customer_id = p_customer_id order by start_time desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'callback', 'at', created_at, 'id', id, 'title', 'Callback (' || reason || ')', 'detail', left(coalesce(summary, ''), 200), 'status', status)
       from public.callbacks where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'task', 'at', created_at, 'id', id, 'title', coalesce(title, kind), 'detail', '', 'status', status)
       from public.crm_tasks where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'change', 'at', created_at, 'id', id, 'title', 'Record ' || replace(action, 'customer.', ''), 'detail', coalesce(new_data ->> 'fields', ''), 'status', '')
       from public.audit_logs where business_id = p_business_id and entity_type = 'customer' and entity_id = p_customer_id order by created_at desc limit v_limit)
    ) x order by (e ->> 'at') desc limit v_limit) y), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_decide_approval(p_approval_id uuid, p_approve boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record;
begin
  select * into a from public.sensitive_approvals where id = p_approval_id for update;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(a.business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if auth.uid() is not null and a.requested_by = auth.uid() then raise exception 'CANNOT_APPROVE_OWN_REQUEST'; end if;
  if a.status <> 'pending' then return a.status; end if;
  if a.expires_at < now() then update public.sensitive_approvals set status = 'expired' where id = a.id; return 'expired'; end if;
  update public.sensitive_approvals set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now() where id = a.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (a.business_id, auth.uid(), 'approval_' || case when p_approve then 'approved' else 'rejected' end, 'approval', a.id, jsonb_build_object('action', a.action));
  return case when p_approve then 'approved' else 'rejected' end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_decide_draft(p_draft_id uuid, p_send boolean, p_body text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.message_drafts; v_body text; v_id uuid;
begin
  select * into d from public.message_drafts where id = p_draft_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(d.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if p_send then
    v_body := left(coalesce(nullif(trim(p_body), ''), d.body), 300);
    if v_body ~ '[$€£]' or v_body ~* '\m(sale|discount|% off|offer ends|promo)\M' then raise exception 'NO_MARKETING_OR_PRICES'; end if;
    v_id := public.zella_queue_customer_message(d.business_id, d.customer_id, 'record_status_update',
              jsonb_build_object('status_line', v_body, 'status', 'draft', 'record_title', ''), interval '0', null, interval '0');
    if v_id is null then raise exception 'CANNOT_REACH'; end if;
    update public.message_drafts set status = 'sent', decided_by = auth.uid(), decided_at = now() where id = d.id;
  else
    update public.message_drafts set status = 'dismissed', decided_by = auth.uid(), decided_at = now() where id = d.id;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (d.business_id, auth.uid(), case when p_send then 'draft_sent' else 'draft_dismissed' end, 'message_draft', d.id, jsonb_build_object('customer_id', d.customer_id));
  return case when p_send then 'queued' else 'dismissed' end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_decide_time_off(p_request_id uuid, p_approve boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.time_off_requests%rowtype; v_name text; v_block uuid;
begin
  select * into r from public.time_off_requests where id = p_request_id;
  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  select name into v_name from public.staff_members where id = r.staff_id;
  if p_approve then
    insert into public.blocked_times (business_id, title, reason, start_time, end_time, staff_id, created_by, source)
    values (r.business_id, 'Time off: ' || coalesce(v_name, 'staff'), coalesce(r.reason, 'Time off'), r.from_at, r.to_at, r.staff_id, auth.uid(), 'time_off')
    returning id into v_block;
  end if;
  update public.time_off_requests set status = case when p_approve then 'approved' else 'declined' end, decided_by = auth.uid(), decided_at = now(), blocked_time_id = v_block where id = r.id;
  if r.requested_by is not null then
    perform public.zella_notify(r.business_id, 'time_off_decision', case when p_approve then 'Time off approved' else 'Time off declined' end,
      coalesce(v_name, 'Staff') || ': ' || to_char(r.from_at, 'Mon FMDD') || ' to ' || to_char(r.to_at, 'Mon FMDD'), 'info', 'calendar', r.id, r.requested_by);
  end if;
  return case when p_approve then 'approved' else 'declined' end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_decline_waitlist_offer(p_entry_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e record;
begin
  select * into e from public.waitlist_entries where id = p_entry_id for update;
  if not found or e.status <> 'offered' then return; end if;
  update public.waitlist_entries set status = 'waiting', offered_start = null, offered_end = null, offer_expires_at = null where id = p_entry_id;
  perform public.zella_offer_slot(e.business_id, e.offered_start, e.offered_end, e.offered_staff_id, e.customer_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_delete_business_closure(p_closure_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.business_closures;
begin
  select * into c from public.business_closures where id = p_closure_id for update;
  if not found then return false; end if;
  if not public.zella_has_role(c.business_id, array['owner', 'admin', 'manager']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  delete from public.business_closures where id = p_closure_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data)
  values (c.business_id, auth.uid(), 'business.closure_removed', 'business_closure', p_closure_id,
          jsonb_build_object('starts_on', c.starts_on, 'ends_on', c.ends_on, 'label', c.label));
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_detect_knowledge_conflicts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0; b record; v_biz uuid[] := '{}';
begin
  for r in
    select a.id as older, c.id as newer, a.business_id, a.title
      from public.knowledge_items a
      join public.knowledge_items c on c.business_id = a.business_id and c.kind = a.kind and (c.created_at, c.id) > (a.created_at, a.id)
     where a.status = 'ready' and c.status = 'ready' and c.conflicts_with is null and a.conflicts_with is distinct from c.id
       and (lower(regexp_replace(a.title, '[^a-zA-Z0-9]+', ' ', 'g')) = lower(regexp_replace(c.title, '[^a-zA-Z0-9]+', ' ', 'g')) or a.kind = 'hours')
       and lower(regexp_replace(a.answer, '\s+', ' ', 'g')) <> lower(regexp_replace(c.answer, '\s+', ' ', 'g'))
     limit 100
  loop
    update public.knowledge_items set conflicts_with = r.older where id = r.newer and conflicts_with is null;
    n := n + 1; v_biz := v_biz || r.business_id;
  end loop;
  for b in select business_id, count(*) as k from public.knowledge_items where conflicts_with is not null and status = 'ready' and business_id = any (v_biz) group by business_id loop
    perform public.zella_platform_alert('knowledge_conflict', 'Two answers disagree', b.k || ' of your answers disagree with another. Choose which one is right.', 'info', b.business_id, 'knowledge_conflict:' || b.business_id, '{}'::jsonb);
    perform public.zella_notify_owners(b.business_id, 'knowledge_conflict', 'Two of your answers disagree', 'Open the knowledge page and choose which answer is right. The assistant may give mixed answers until you do.', 'warning', 'knowledge');
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_detect_repeated_questions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g record; n integer := 0; v_min integer := greatest(2, coalesce((public.zella_setting('knowledge_repeat_threshold', '3'::jsonb) #>> '{}')::int, 3));
begin
  for g in select id, business_id, question, times_asked from public.knowledge_gaps
            where status = 'open' and times_asked >= v_min and repeat_notified_at is null for update skip locked loop
    perform public.zella_notify_owners(g.business_id, 'knowledge_repeat', 'Customers keep asking the same thing',
      '"' || left(g.question, 140) || '" was asked ' || g.times_asked || ' times. Add an answer so the assistant can reply.', 'warning', 'knowledge');
    update public.knowledge_gaps set repeat_notified_at = now() where id = g.id;
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_detect_transfer_failures()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; v_n integer; v_thr integer := (public.zella_setting('transfer_failure_threshold', '3'))::text::integer; v_found integer := 0; v_cfg record; v_auto boolean;
begin
  for b in
    select c.business_id, count(*) as n from public.calls c
     where c.transfer_status in ('failed', 'no_one_available') and c.created_at > now() - interval '24 hours'
     group by c.business_id having count(*) >= v_thr
  loop
    v_found := v_found + 1;
    perform public.zella_platform_alert('repeated_transfer_failures', 'Transfers keep failing', b.n || ' transfers failed in 24 hours.', 'warning', b.business_id, to_char(now(), 'YYYY-MM-DD'), jsonb_build_object('failures', b.n));
    -- an authorised fallback route is applied automatically; otherwise it is only recommended
    select cfg.* into v_cfg from public.ai_agent_configs cfg join public.ai_agents ag on ag.id = cfg.agent_id where ag.business_id = b.business_id and ag.is_default limit 1;
    v_auto := coalesce((v_cfg.escalation_rules ->> 'auto_fallback')::boolean, false) and nullif(v_cfg.escalation_rules ->> 'fallback_number', '') is not null;
    if exists (select 1 from public.staff_notifications where business_id = b.business_id and kind in ('transfer_fallback_applied', 'transfer_failures') and created_at > now() - interval '24 hours') then
      continue;   -- the owner was already told today
    end if;
    if v_auto and coalesce(v_cfg.escalation_rules ->> 'transfer_route', '') <> 'fallback' then
      update public.ai_agent_configs set escalation_rules = coalesce(escalation_rules, '{}'::jsonb) || '{"transfer_route":"fallback"}'::jsonb, updated_at = now() where id = v_cfg.id;
      perform public.zella_notify_owners(b.business_id, 'transfer_fallback_applied', 'Switched to your backup number', 'Transfers kept failing, so Zella is now sending callers to your backup route.', 'urgent', 'receptionist');
    else
      perform public.zella_notify_owners(b.business_id, 'transfer_failures', 'Transfers keep failing', 'Callers asking for a person are not getting through. Check your transfer number or add a backup.', 'urgent', 'receptionist');
    end if;
  end loop;
  return v_found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_digits(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '');
$function$
;
CREATE OR REPLACE FUNCTION public.zella_dismiss_dead_letter(p_id uuid, p_note text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.automation_dead_letters;
begin
  select * into d from public.automation_dead_letters where id = p_id for update;
  if not found or d.business_id is null or not public.zella_can_manage(d.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  update public.automation_dead_letters set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = d.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (d.business_id, auth.uid(), 'automation.dead_letter_dismissed', 'automation_event', d.source_id, jsonb_build_object('reason', d.reason), jsonb_build_object('note', left(p_note, 300)));
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_dismiss_knowledge_gap(p_gap_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_business uuid;
begin
  select business_id into v_business from public.knowledge_gaps where id = p_gap_id;
  if v_business is null or not exists (select 1 from public.business_members m where m.business_id = v_business and m.user_id = auth.uid() and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  update public.knowledge_gaps set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id and status = 'open';
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_dispatch_n8n()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_base text := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '');
  v_on boolean := coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
  v_secret text; w record; n integer; st public.n8n_dispatch_state; v_same integer; v_res jsonb := '{}'::jsonb; v_spam integer := 0; v_reconcile integer := 0; v_reviews integer := 0;
  v_text_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'reply_confirmed', 'reply_reschedule', 'reply_help', 'waitlist_offer', 'cross_sell'];
  v_email_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'cross_sell'];
begin
  if not v_on then return jsonb_build_object('skipped', 'switched_off'); end if;
  if v_base is null then return jsonb_build_object('skipped', 'no_base_url'); end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_n8n_secret' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('skipped', 'no_secret'); end if;
  if to_regprocedure('public.zella_spam_work_waiting()') is not null then
    begin execute 'select public.zella_spam_work_waiting()' into v_spam; exception when others then v_spam := 0; end;
  end if;
  if to_regprocedure('public.zella_call_reconcile_waiting()') is not null then
    begin execute 'select public.zella_call_reconcile_waiting()' into v_reconcile; exception when others then v_reconcile := 0; end;
  end if;

  if to_regprocedure('public.zella_review_work_waiting()') is not null then
    begin execute 'select public.zella_review_work_waiting()' into v_reviews; exception when others then v_reviews := 0; end;
  end if;

  for w in select * from (values ('event-router'), ('sms-sender'), ('email-sender'), ('followup-texts'), ('followup-emails'), ('owner-emails'), ('outbound-calls'), ('knowledge-sync'), ('calendar-sync'), ('connection-tests'), ('meta-leads'), ('meta-sender'), ('meta-health'), ('website-crawl'), ('staff-sms'), ('call-intel'), ('admin-alerts'), ('spam-response'), ('call-reconcile'), ('review-replies')) as t(name) loop
    n := case w.name
      when 'event-router' then (select count(*) from public.automation_events
         where (status = 'received' and coalesce(next_attempt_at, now()) <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes'))
      when 'sms-sender' then (select count(*) from public.appointment_reminders where status = 'pending' and channel = 'sms' and due_at <= now())
      when 'email-sender' then (select count(*) from public.appointment_reminders where status = 'pending' and channel = 'email' and due_at <= now())
      when 'followup-texts' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'sms' and due_at <= now() and kind = any (v_text_kinds))
      when 'followup-emails' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'email' and due_at <= now() and kind = any (v_email_kinds))
      when 'outbound-calls' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'call' and due_at <= now())
         + (select count(*) from public.callbacks where status in ('scheduled', 'retry_scheduled', 'due') and due_at <= now() and auto_call
              and (locked_at is null or locked_at < now() - interval '15 minutes'))
      when 'knowledge-sync' then (select count(*) from public.knowledge_items where status = 'processing')
         + case when coalesce(public.zella_setting('knowledge_ai_live', 'false'::jsonb) = 'true'::jsonb, false)
                then (select count(*) from public.knowledge_gaps where status = 'open' and suggested_at is null and suggestion_attempts < 3) else 0 end
      when 'call-intel' then case when coalesce(public.zella_setting('call_intel_live', 'false'::jsonb) = 'true'::jsonb, false)
         then (select count(*) from public.call_insights where (status = 'pending' and attempts < 3) or (status = 'processing' and claimed_at < now() - interval '15 minutes')) else 0 end
      when 'calendar-sync' then case when public.zella_calendar_live()
         then (select count(*) from public.calendar_sync_queue where status = 'pending' and due_at <= now())
            + (select count(*) from public.calendar_connections where status = 'active' and busy_refresh_due_at <= now()) else 0 end
      when 'connection-tests' then case when public.zella_provider_checks_live()
         then (select count(*) from unnest(array['telnyx', 'vapi', 'resend']) p where not exists (select 1 from public.provider_health h where h.provider = p
                 and (coalesce(h.checked_at, 'epoch') > now() - interval '3 hours' or coalesce(h.claimed_at, 'epoch') > now() - interval '10 minutes'))) else 0 end
      when 'meta-leads' then (select count(*) from public.meta_events where kind = 'lead'
         and ((status = 'pending' and next_try_at <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes')))
      when 'meta-sender' then (select count(*) from public.meta_outbox where (status = 'queued' and next_try_at <= now()) or (status = 'sending' and claimed_at < now() - interval '10 minutes'))
      when 'meta-health' then (select count(*) from public.meta_connections where status in ('connected', 'error') and next_check_at <= now())
      when 'website-crawl' then case when public.zella_website_crawl_live()
         then (select count(*) from public.website_pages wp join public.website_sources ws on ws.id = wp.source_id and ws.status = 'active'
                where wp.status in ('approved', 'broken', 'missing') and wp.next_fetch_at <= now() and (wp.claimed_at is null or wp.claimed_at < now() - interval '10 minutes'))
            + (select count(*) from public.website_sources where status = 'active' and next_discovery_at <= now()) else 0 end
      when 'staff-sms' then case when coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false)
         then (select count(*) from public.staff_notifications where created_at > now() - interval '6 hours'
                 and (sms_status = 'pending' or (sms_status = 'sending' and sms_claimed_at < now() - interval '15 minutes'))) else 0 end
      when 'admin-alerts' then case when coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false)
                                     and nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '') is not null
         then (select count(*) from public.platform_alerts where notified_at is null and status = 'open') else 0 end
      when 'spam-response' then coalesce(v_spam, 0)
      when 'call-reconcile' then coalesce(v_reconcile, 0)
      when 'review-replies' then coalesce(v_reviews, 0)
      when 'owner-emails' then (select count(*) from public.staff_notifications s join public.businesses b on b.id = s.business_id
         where b.suspended_at is null and b.cancelled_at is null
           and (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes')))
      else 0 end;
    if n = 0 then
      update public.n8n_dispatch_state set last_count = 0, consecutive_same = 0 where workflow = w.name;
      continue;
    end if;

    insert into public.n8n_dispatch_state (workflow) values (w.name) on conflict do nothing;
    select * into st from public.n8n_dispatch_state where workflow = w.name;
    if st.last_triggered_at > now() - interval '8 seconds' then continue; end if;
    v_same := case when n >= st.last_count and st.last_triggered_at > now() - interval '10 minutes' then st.consecutive_same + 1 else 0 end;
    if v_same >= 12 and st.last_triggered_at > now() - interval '15 minutes' then
      update public.n8n_dispatch_state set last_count = n, consecutive_same = v_same where workflow = w.name;
      v_res := v_res || jsonb_build_object(w.name, 'backed_off');
      continue;
    end if;

    perform net.http_post(url := v_base || '/webhook/zella/run/' || w.name,
                          headers := jsonb_build_object('Content-Type', 'application/json', 'X-Zella-Secret', v_secret),
                          body := '{}'::jsonb, timeout_milliseconds := 5000);
    update public.n8n_dispatch_state set last_triggered_at = now(), last_count = n, consecutive_same = v_same, triggers_total = triggers_total + 1 where workflow = w.name;
    v_res := v_res || jsonb_build_object(w.name, n);
  end loop;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_dnc_stops_callbacks()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(new.do_not_contact, false) and not coalesce(old.do_not_contact, false) then
    update public.callbacks set status = 'cancelled', outcome = 'do_not_contact', auto_call = false, completed_at = now(), updated_at = now()
     where customer_id = new.id and status not in ('completed', 'cancelled');
    update public.followup_tasks set status = 'cancelled', outcome = 'do_not_contact', completed_at = now(), updated_at = now()
     where customer_id = new.id and status = 'pending';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_ensure_crm_types(p_business_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_status text;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select onboarding_status into v_status from public.businesses where id = p_business_id;
  if v_status is null or v_status not in ('testing', 'ready', 'active', 'paused') then return 0; end if;
  return public.zella_apply_crm_preset(p_business_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_entitlement_allows(p_business_id uuid, p_key text, p_add numeric DEFAULT 1)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.subscriptions; v_limit numeric; v_used numeric;
begin
  s := public.zella_current_subscription(p_business_id);
  if s.id is null then return true; end if;
  select nullif(p.limits ->> p_key, '')::numeric into v_limit from public.plans p where p.id = s.plan_id;
  if v_limit is null then return true; end if;
  v_used := coalesce((public.zella_usage_counts(p_business_id, coalesce(s.current_period_start, date_trunc('month', now())),
                       coalesce(s.current_period_end, date_trunc('month', now()) + interval '1 month')) ->> p_key)::numeric, 0);
  return v_used + coalesce(p_add, 0) <= v_limit;
exception when invalid_text_representation then return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_entitlements(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select jsonb_build_object('plan', p.slug, 'status', s.status, 'features', coalesce(p.features, '{}'::jsonb), 'limits', coalesce(p.limits, '{}'::jsonb),
                            'active', s.status in ('trial','active','renewal_due','past_due','grace_period'))
    into r from public.subscriptions s join public.plans p on p.id = s.plan_id
   where s.business_id = p_business_id order by s.created_at desc limit 1;
  return coalesce(r, jsonb_build_object('plan', null, 'status', 'none', 'features', '{}'::jsonb, 'limits', '{}'::jsonb, 'active', false));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_erase_customer(p_business_id uuid, p_customer_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  if not public.zella_approval_ok(p_business_id, 'erase_customer', p_customer_id) then raise exception 'APPROVAL_REQUIRED'; end if;
  update public.sms_messages set message_body = '[removed]' where customer_id = p_customer_id and business_id = p_business_id;
  update public.email_messages set subject = '[removed]', body_text = '[removed]', body_html = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.callbacks set contact_number = null, summary = null, note = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.followup_tasks set status = 'cancelled', updated_at = now() where customer_id = p_customer_id and business_id = p_business_id and status in ('pending','in_progress');
  update public.customers set first_name = 'Deleted', last_name = null, phone = null, email = null, address = null, notes = null, date_of_birth = null, company_name = null,
         tags = '{}', metadata = '{}'::jsonb, qualification = null, do_not_contact = true, status = 'archived', updated_at = now()
   where id = p_customer_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'customer_erased', 'customer', p_customer_id);
  return 'erased';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_evaluate_call_usage_thresholds(p_business_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a jsonb; v_used numeric; v_limit numeric; v_period text; t record; n integer := 0; v_key text; v_hit boolean; v_ev uuid; v_note uuid;
        v_legacy integer[];
begin
  a := public.zella_call_allowance(p_business_id);
  if not (a ->> 'configured')::boolean then return 0; end if;     -- nothing to measure against: no events, no notices
  v_used := (a ->> 'consumed_minutes')::numeric; v_limit := (a ->> 'included_minutes')::numeric;
  v_period := a ->> 'period_from';
  select coalesce(u.notify_thresholds, '{70,90,100}') into v_legacy from public.business_usage_preferences u where u.business_id = p_business_id;
  v_legacy := coalesce(v_legacy, '{70,90,100}');
  for t in
    select 'pct:' || x::text as key, 'percent_of_allowance' as measure, x::numeric as value,
           case when x >= 100 then 'allowance_limit' when x >= 90 then 'reached' else 'approaching' end as event_type
      from unnest(v_legacy) x
    union all
    select 'th:' || h.id::text, h.measure, h.value, h.event_type from public.usage_thresholds h
     where h.enabled and (h.business_id is null or h.business_id = p_business_id)
    order by 3 desc
  loop
    v_hit := case t.measure when 'percent_of_allowance' then v_limit > 0 and v_used * 100 / v_limit >= t.value else v_used >= t.value end;
    continue when not v_hit;
    v_key := v_period || ':' || t.key;
    -- a threshold already notified under the old key (business_usage_preferences.notified) is not notified again
    continue when t.key like 'pct:%' and exists (select 1 from public.business_usage_preferences u where u.business_id = p_business_id and u.notified ? (v_period || ':' || t.value::int));
    insert into public.usage_threshold_events (business_id, threshold_key, period_key, event_type, usage_minutes, limit_minutes)
    values (p_business_id, t.key, v_period, t.event_type, v_used, v_limit) on conflict do nothing returning id into v_ev;
    continue when v_ev is null;
    perform public.zella_notify_owners(p_business_id, 'usage_threshold',
      case when t.event_type = 'allowance_limit' then 'Your included AI minutes are used up'
           when t.measure = 'percent_of_allowance' then 'You have used ' || t.value::int || '% of your AI minutes'
           else 'AI calling has reached ' || t.value || ' minutes this period' end,
      round(v_used) || ' of ' || round(v_limit) || ' minutes this period. Open Settings > Billing > Calling usage.',
      case when t.event_type = 'allowance_limit' then 'urgent' else 'warning' end, 'settings');
    select id into v_note from public.staff_notifications where business_id = p_business_id and kind = 'usage_threshold' order by created_at desc limit 1;
    update public.usage_threshold_events set notification_id = v_note where id = v_ev;
    if t.key like 'pct:%' then
      insert into public.business_usage_preferences (business_id, notified) values (p_business_id, jsonb_build_object(v_period || ':' || t.value::int, now()))
      on conflict (business_id) do update set notified = public.business_usage_preferences.notified || jsonb_build_object(v_period || ':' || t.value::int, now());
    end if;
    n := n + 1;
    exit when t.measure = 'percent_of_allowance';   -- the highest percentage reached is enough; lower ones are implied
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_expire_holds()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  update public.appointments set status = 'cancelled', cancel_reason = 'Hold expired', updated_at = now()
   where booking_state = 'tentative' and hold_expires_at < now() and status in ('scheduled', 'confirmed');
  get diagnostics n = row_count; return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_expire_waitlist_offers()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e record; n integer := 0;
begin
  for e in select * from public.waitlist_entries where status = 'offered' and offer_expires_at < now() for update skip locked loop
    update public.waitlist_entries set status = 'waiting', offered_start = null, offered_end = null, offer_expires_at = null where id = e.id;
    perform public.zella_offer_slot(e.business_id, e.offered_start, e.offered_end, e.offered_staff_id, e.customer_id);
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_export_customer_data(p_business_id uuid, p_customer_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  select jsonb_build_object(
    'customer', (select to_jsonb(c) - 'business_id' from public.customers c where c.id = p_customer_id),
    'appointments', coalesce((select jsonb_agg(to_jsonb(a) - 'business_id') from public.appointments a where a.customer_id = p_customer_id and a.business_id = p_business_id), '[]'),
    'texts', coalesce((select jsonb_agg(jsonb_build_object('direction', m.direction, 'body', m.message_body, 'at', m.created_at)) from public.sms_messages m where m.customer_id = p_customer_id and m.business_id = p_business_id), '[]'),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('direction', m.direction, 'subject', m.subject, 'body', m.body_text, 'at', m.created_at)) from public.email_messages m where m.customer_id = p_customer_id and m.business_id = p_business_id), '[]'),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('direction', k.direction, 'at', k.started_at, 'summary', k.summary, 'transcript', k.transcript)) from public.calls k where k.customer_id = p_customer_id and k.business_id = p_business_id), '[]'),
    'callbacks', coalesce((select jsonb_agg(to_jsonb(k) - 'business_id') from public.callbacks k where k.customer_id = p_customer_id and k.business_id = p_business_id), '[]'),
    'consents', coalesce((select jsonb_agg(jsonb_build_object('channel', x.channel, 'purpose', x.purpose, 'status', x.status, 'source', x.source, 'at', x.recorded_at)) from public.contact_consents x where x.customer_id = p_customer_id and x.business_id = p_business_id), '[]'),
    'requests', coalesce((select jsonb_agg(to_jsonb(q) - 'business_id') from public.customer_requests q where q.customer_id = p_customer_id and q.business_id = p_business_id), '[]'))
  into r;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'customer_data_exported', 'customer', p_customer_id);
  return r;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_fail_call_insight(p_call_id uuid, p_error text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update public.call_insights set status = case when attempts >= 3 then 'failed' else 'pending' end, error = left(coalesce(p_error, 'AI error'), 300)
   where call_id = p_call_id and status = 'processing';
$function$
;
CREATE OR REPLACE FUNCTION public.zella_fail_notification(p_id uuid, p_error text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update public.staff_notifications set delivery_status = 'failed', delivery_error = left(p_error, 300) where id = p_id;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_failed_work(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'channel', channel, 'outcome', outcome, 'at', updated_at) order by updated_at desc)
                         from (select * from public.followup_tasks where business_id = p_business_id and status = 'failed' and updated_at > now() - interval '7 days' limit 50) t), '[]'::jsonb),
    'reminders', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'channel', channel, 'error', error, 'due_at', due_at) order by due_at desc)
                         from (select * from public.appointment_reminders where business_id = p_business_id and status = 'failed' and due_at > now() - interval '7 days' limit 50) t), '[]'::jsonb),
    'social', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'channel', channel, 'error', last_error, 'at', created_at) order by created_at desc)
                         from (select * from public.meta_outbox where business_id = p_business_id and status = 'failed' and created_at > now() - interval '7 days' limit 50) t), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_finish_admin_alert_email(p_ids uuid[], p_ok boolean, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_released integer := 0; v_dropped integer := 0;
begin
  if p_ok then
    update public.platform_alerts set meta = meta || jsonb_build_object('emailed_at', now()) where id = any (coalesce(p_ids, array[]::uuid[]));
    return jsonb_build_object('ok', true);
  end if;
  with u as (
    update public.platform_alerts
       set meta = meta || jsonb_build_object('email_attempts', coalesce((meta ->> 'email_attempts')::int, 0) + 1, 'email_error', left(p_error, 200)),
           notified_at = case when coalesce((meta ->> 'email_attempts')::int, 0) + 1 < 3 then null else notified_at end
     where id = any (coalesce(p_ids, array[]::uuid[]))
    returning notified_at)
  select count(*) filter (where notified_at is null), count(*) filter (where notified_at is not null) into v_released, v_dropped from u;
  return jsonb_build_object('ok', false, 'retry', v_released, 'gave_up', v_dropped);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_finish_calendar_sync(p_queue_id uuid, p_ok boolean, p_event_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q record;
begin
  select * into q from public.calendar_sync_queue where id = p_queue_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if q.status <> 'in_progress' then return 'ignored'; end if;
  if p_ok then
    update public.calendar_sync_queue set status = 'done', event_id = left(p_event_id, 200), error = null, completed_at = now() where id = q.id;
    update public.appointments set external_event_id = case when q.action = 'delete' then null else coalesce(left(p_event_id, 200), external_event_id) end where id = q.appointment_id;
    update public.calendar_connections set last_pushed_at = now(), last_error = null where business_id = q.business_id and provider = 'google';
    return 'done';
  end if;
  if q.attempts < 5 then
    update public.calendar_sync_queue set status = 'pending', due_at = now() + make_interval(mins => 5 * q.attempts), error = left(p_error, 300) where id = q.id;
    return 'retry';
  end if;
  update public.calendar_sync_queue set status = 'failed', error = left(p_error, 300), completed_at = now() where id = q.id;
  update public.calendar_connections set last_error = left(p_error, 300) where business_id = q.business_id and provider = 'google';
  if not exists (select 1 from public.staff_notifications where business_id = q.business_id and kind = 'calendar_sync_owner' and created_at > now() - interval '12 hours') then perform public.zella_notify_owners(q.business_id, 'calendar_sync_owner', 'A booking is not on your calendar', 'Zella could not copy a booking to Google Calendar. The booking itself is saved. Check the calendar connection in Settings.', 'warning', 'settings'); end if;
  perform public.zella_platform_alert('calendar_sync_failed', 'A booking could not be copied to Google Calendar', left(p_error, 300), 'warning', q.business_id, q.appointment_id::text);
  return 'failed';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_finish_execution(p_execution_id uuid, p_ok boolean, p_step text DEFAULT NULL::text, p_steps jsonb DEFAULT NULL::jsonb, p_provider_refs jsonb DEFAULT NULL::jsonb, p_error_category text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_needs_manual boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.workflow_executions
     set status = case when p_ok then 'succeeded' else 'failed' end,
         current_step = coalesce(p_step, current_step),
         steps = coalesce(p_steps, steps),
         provider_refs = coalesce(p_provider_refs, provider_refs),
         error_category = case when p_ok then null else coalesce(p_error_category, 'unknown_error') end,
         error_message = case when p_ok then null else public.zella_redact(p_error) end,
         needs_manual = case when p_ok then false else coalesce(p_needs_manual, false) end,
         finished_at = now()
   where id = p_execution_id and status = 'running';
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_finish_owner_email(p_id uuid, p_result text, p_note text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_result not in ('sent', 'skipped', 'failed') then raise exception 'INVALID_RESULT'; end if;
  if p_result = 'sent' then
    update public.staff_notifications set delivery_status = 'sent', delivered_at = now(), delivery_error = null where id = p_id and delivery_status in ('sending', 'failed', 'skipped');
  else
    update public.staff_notifications set delivery_status = p_result, delivery_error = left(coalesce(p_note, p_result), 300) where id = p_id and delivery_status = 'sending';
  end if;
  return p_result;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_flag_overdue_callbacks()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

    if c.overdue_notified_at is null or c.overdue_notified_at < c.due_at then
      perform public.zella_notify(c.business_id, 'callback_overdue', 'Callback overdue',
        v_who || ' is waiting for a call back (' || v_late || ' late).' || coalesce(' ' || left(c.summary, 200), ''), 'warning', 'callbacks', c.id, c.assigned_to);
      update public.callbacks set overdue_notified_at = now() where id = c.id;
      n := n + 1;
    end if;
    if c.due_at < now() - interval '3 hours' and (c.overdue_escalated_at is null or c.overdue_escalated_at < c.due_at) then
      perform public.zella_notify(c.business_id, 'callback_escalated', 'Callback still not made',
        v_who || ' has waited ' || v_late || ' for a call back.', 'urgent', 'callbacks', c.id, null);
      update public.callbacks set overdue_escalated_at = now() where id = c.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_flag_overdue_leads()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; n integer := 0; v_esc integer; v_auto record;
begin
  for c in select * from public.customers x
            where x.lead_stage = 'new' and x.contact_deadline_at is not null and x.contact_deadline_at < now() and x.last_contacted_at is null loop
    select a.* into v_auto from public.automations a where a.business_id = c.business_id and a.trigger_type = 'new_lead_callback' and a.status = 'active' limit 1;
    v_esc := nullif(v_auto.trigger_config ->> 'escalate_after_minutes', '')::integer;
    if public.zella_create_task(c.business_id, c.id, 'overdue_contact', 'Overdue: contact ' || coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'this lead'),
         'This lead was not contacted in time.', 'high', now(), c.assigned_to, 'automation') is not null then
      perform public.zella_notify(c.business_id, 'lead_overdue', 'Lead not contacted in time', coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'A lead') || ' is waiting.', 'warning', 'tasks', c.id, c.assigned_to);
      n := n + 1;
    end if;
    if v_esc is not null and c.contact_deadline_at < now() - make_interval(mins => v_esc) then
      update public.crm_tasks set escalated_at = now(), priority = 'urgent'
       where customer_id = c.id and kind = 'overdue_contact' and status = 'open' and escalated_at is null;
      if found then
        perform public.zella_notify(c.business_id, 'lead_escalated', 'Escalated: lead still not contacted', coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), 'A lead') || ' has waited too long.', 'urgent', 'tasks', c.id);
      end if;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_flag_unrecorded_appointments()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; n integer := 0; v_who text;
begin
  for a in select ap.id, ap.business_id, ap.customer_id, ap.assigned_to, ap.title, ap.end_time from public.appointments ap
            where ap.status in ('scheduled', 'confirmed') and ap.end_time < now() - interval '2 hours' and ap.end_time > now() - interval '7 days'
              and ap.arrived_at is null and ap.checked_in_at is null and ap.in_service_at is null
              and not exists (select 1 from public.crm_tasks t where t.kind = 'record_attendance' and t.entity_id = ap.id)
            order by ap.end_time limit 100 loop
    select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), a.title, 'a customer') into v_who from public.customers c where c.id = a.customer_id;
    v_who := coalesce(v_who, a.title, 'a customer');
    perform public.zella_create_task(a.business_id, a.customer_id, 'record_attendance', 'Did ' || v_who || ' come in? Mark completed or no-show', 'The appointment ended and nothing was recorded.', 'normal', now() + interval '1 day', a.assigned_to, 'automation', a.id);
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_fulfil_data_rights_request(p_request_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.data_rights_requests; v_out jsonb := '{}'::jsonb;
begin
  select * into r from public.data_rights_requests where id = p_request_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(r.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'open' then raise exception 'ALREADY_HANDLED'; end if;
  if r.kind = 'export' then
    if r.customer_id is null then raise exception 'NO_CUSTOMER'; end if;
    v_out := public.zella_export_customer_data(r.business_id, r.customer_id);
  elsif r.kind = 'erase' then
    if r.customer_id is null then raise exception 'NO_CUSTOMER'; end if;
    perform public.zella_erase_customer(r.business_id, r.customer_id);
  end if;
  update public.data_rights_requests set status = 'done', handled_by = auth.uid(), handled_at = now(), note = coalesce(left(p_note, 1000), note) where id = r.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (r.business_id, auth.uid(), 'data_rights_done', 'data_rights_request', r.id, jsonb_build_object('kind', r.kind));
  return v_out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_get_call_recording(p_call_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k record;
begin
  select id, business_id, recording_url, transcript into k from public.calls where id = p_call_id;
  if k.id is null then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(k.business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (k.business_id, auth.uid(), 'call_recording_viewed', 'call', k.id);
  return jsonb_build_object('recording_url', k.recording_url, 'transcript', k.transcript);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_get_review_link(p_business_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return (select setup_data ->> 'review_link' from public.businesses where id = p_business_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_handle_inbound_sms_keyword(p_business_id uuid, p_from text, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  k text := upper(regexp_replace(trim(coalesce(p_body, '')), '[^A-Za-z]', '', 'g'));
  v_text text := lower(coalesce(p_body, ''));
  v_cust uuid; v_name text; v_appt record; v_action text;
begin
  select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_from, null) m where m.certainty = 'exact' limit 1;
  select coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), p_from) into v_name from public.customers c where c.id = v_cust;
  v_name := coalesce(v_name, p_from);

  if not exists (select 1 from public.sms_messages where business_id = p_business_id and direction = 'inbound' and from_number = p_from
                   and message_body = left(p_body, 1600) and created_at > now() - interval '2 minutes') then
    insert into public.sms_messages (business_id, customer_id, direction, status, from_number, message_body, metadata)
    values (p_business_id, v_cust, 'inbound', 'received', p_from, left(p_body, 1600), jsonb_build_object('keyword', nullif(k, ''), 'source', 'router'));
  end if;

  if k in ('STOP','STOPALL','UNSUBSCRIBE','CANCEL','END','QUIT') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'marketing', k);
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_out', 'keyword', k);
  elsif k in ('START','UNSTOP','YES') and exists (
      select 1 from public.contact_consents where business_id = p_business_id and phone_digits = public.zella_digits(p_from) and channel = 'sms' and status = 'opted_out') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_in', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_in', 'keyword', k);
  elsif k = 'HELP' then
    if v_cust is not null then
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts) values (p_business_id, v_cust, 'reply_help', 'sms', now(), 2);
    end if;
    return jsonb_build_object('action', 'help', 'reply_queued', v_cust is not null);
  end if;

  if v_cust is not null and k in ('HERE','ARRIVED','IMHERE','CHECKIN','CHECKEDIN') then
    select a.id into v_appt from public.appointments a
     where a.business_id = p_business_id and a.customer_id = v_cust and a.status in ('scheduled', 'confirmed')
       and a.start_time between now() - interval '30 minutes' and now() + interval '60 minutes' order by a.start_time limit 1;
    if v_appt.id is not null then
      perform public.zella_set_attendance(v_appt.id, 'arrived');
      return jsonb_build_object('action', 'arrived', 'appointment_id', v_appt.id);
    end if;
  end if;

  if v_cust is not null then
    select a.id, a.start_time, a.status into v_appt from public.appointments a
     where a.business_id = p_business_id and a.customer_id = v_cust and a.start_time > now() and a.start_time < now() + interval '7 days' and a.status in ('scheduled', 'confirmed')
     order by a.start_time limit 1;
    if k in ('CONFIRM','CONFIRMED','YES','Y','YEP','YEAH','OK','OKAY','SURE') and v_appt.id is not null then
      update public.appointments set status = 'confirmed', updated_at = now() where id = v_appt.id and status = 'scheduled';
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      select p_business_id, v_cust, v_appt.id, 'reply_confirmed', 'sms', now(), 2
       where not exists (select 1 from public.followup_tasks where appointment_id = v_appt.id and kind = 'reply_confirmed' and created_at > now() - interval '1 day');
      return jsonb_build_object('action', 'confirmed', 'appointment_id', v_appt.id);
    end if;
    if (k in ('RESCHEDULE','CHANGE','MOVE') or v_text ~ '(need|want|have) to (reschedule|change|move)|new time|different time|can.t make it|cannot make it') and v_appt.id is not null then
      perform public.zella_create_callback(p_business_id, p_from, 'appointment_request', 'high', left('Customer replied to ask for a new time: ' || p_body, 400), null, v_cust, null, v_appt.id, 'customer_reply', null);
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      select p_business_id, v_cust, v_appt.id, 'reply_reschedule', 'sms', now(), 2
       where not exists (select 1 from public.followup_tasks where appointment_id = v_appt.id and kind = 'reply_reschedule' and created_at > now() - interval '1 day');
      perform public.zella_notify_owners(p_business_id, 'customer_reply', v_name || ' needs a new time', left(coalesce(p_body, ''), 300), 'warning', 'inbox');
      return jsonb_build_object('action', 'reschedule_requested', 'appointment_id', v_appt.id);
    end if;
  end if;

  v_action := case when v_text ~ 'urgent|emergency|asap|right away|immediately' then 'warning' else 'info' end;
  perform public.zella_notify_owners(p_business_id, 'customer_reply', 'New text from ' || v_name, left(coalesce(p_body, ''), 300), v_action, 'inbox');
  if v_cust is not null
     and coalesce((public.zella_business_open(p_business_id, now()) ->> 'open')::boolean, true) = false
     and not exists (select 1 from public.followup_tasks f where f.customer_id = v_cust and f.kind = 'reply_after_hours' and f.created_at > now() - interval '12 hours') then
    insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts) values (p_business_id, v_cust, 'reply_after_hours', 'sms', now(), 2);
    return jsonb_build_object('action', 'reply_received', 'known_customer', true, 'urgent', v_action = 'warning', 'after_hours_reply_queued', true);
  end if;
  return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null, 'urgent', v_action = 'warning');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_handle_staff_unavailable(p_business_id uuid, p_staff_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v_alt text; v_n integer := 0; v_auto record; v_tz text; v_who text; v_staff_name text;
begin
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  select name into v_staff_name from public.staff_members where id = p_staff_id;
  select x.* into v_auto from public.automations x where x.business_id = p_business_id and x.trigger_type = 'staff_unavailable' and x.status = 'active' limit 1;
  for a in select * from public.appointments ap
            where ap.business_id = p_business_id and ap.status in ('scheduled', 'confirmed') and coalesce(ap.booking_state, 'confirmed') = 'confirmed'
              and ap.start_time > now() and ap.start_time < p_to and ap.end_time > p_from
              and (p_staff_id is null or ap.staff_id = p_staff_id) and ap.conflict_note is null loop
    select string_agg(to_char(s.slot_start at time zone v_tz, 'Dy Mon DD HH12:MI AM') || coalesce(' with ' || s.staff_name, ''), '; ' order by s.slot_start) into v_alt
      from public.zella_available_slots(p_business_id, greatest(now(), p_from), greatest(now(), p_from) + interval '7 days',
             greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int), null, 30, 3, a.id) s
     where s.slot_start >= p_to or s.slot_start + (a.end_time - a.start_time) <= p_from;
    select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), a.title) into v_who from public.customers c where c.id = a.customer_id;
    v_who := coalesce(v_who, a.title);
    update public.appointments set conflict_note = left(coalesce(v_staff_name, 'The team') || ' is unavailable' || coalesce(' (' || p_reason || ')', '') || '.', 200) where id = a.id;
    perform public.zella_create_task(p_business_id, a.customer_id, 'staff_unavailable', 'Reschedule ' || v_who || ': ' || coalesce(v_staff_name, 'staff') || ' is unavailable',
      'Appointment ' || to_char(a.start_time at time zone v_tz, 'Dy Mon DD HH12:MI AM') || '. ' || case when v_alt is null then 'No alternative found yet.' else 'Possible times: ' || v_alt || '.' end,
      'high', a.start_time - interval '1 day', null, 'automation', a.id);
    -- ask the customer only when the business enabled it; never move them without their confirmation
    if v_auto.id is not null and a.customer_id is not null and exists (select 1 from public.customers c where c.id = a.customer_id and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null) then
      insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
      values (p_business_id, a.customer_id, a.id, 'reschedule_offer', case when v_auto.trigger_config ->> 'channel' = 'sms' then 'sms' else 'call' end, public.zella_next_call_time(now(), v_tz), 2) on conflict do nothing;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    perform public.zella_notify(p_business_id, 'staff_unavailable', v_n || (case when v_n = 1 then ' appointment is' else ' appointments are' end) || ' affected',
      coalesce(v_staff_name, 'Someone') || ' is unavailable. Review the tasks to rebook them.', 'warning', 'tasks', null);
  end if;
  return v_n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_has_role(p_business_id uuid, p_roles text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when auth.uid() is null then coalesce(auth.jwt() ->> 'role', '') not in ('anon', 'authenticated')
    else exists (select 1 from public.business_members m
                  where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role = any (p_roles))
  end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_hold_slot(p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamp with time zone, p_duration_minutes integer DEFAULT 30, p_staff_id uuid DEFAULT NULL::uuid, p_hold_minutes integer DEFAULT 15)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_slot record; v_tz text; v_id uuid;
begin
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  perform public.zella_booking_lock(p_business_id); -- zella_booking_lock
  select * into v_slot from public.zella_available_slots(p_business_id, p_start, p_start, p_duration_minutes, p_staff_id, 5, 1, null) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, staff_id, booking_state, hold_expires_at)
  values (p_business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Appointment'), v_slot.slot_start, v_slot.slot_end, v_tz, 'scheduled', v_slot.staff_id, 'tentative', now() + make_interval(mins => greatest(5, p_hold_minutes)))
  returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_inbound_email_address(p_business_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when d.dom ~ '^[a-z0-9.-]+\.[a-z]{2,}$' then b.inbound_email_token || '@' || d.dom end
    from public.businesses b,
         lateral (select lower(trim(both '"' from coalesce(public.zella_setting('inbound_email_domain', 'null'::jsonb)::text, ''))) as dom) d
   where b.id = p_business_id and b.inbound_email_token is not null;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_inbox_add_note(p_conversation_id uuid, p_body text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.conversations; v_name text;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  select coalesce(nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Team member') into v_name from public.profiles where id = auth.uid();
  insert into public.conversation_notes (business_id, conversation_id, author_id, author_name, body)
  values (c.business_id, p_conversation_id, auth.uid(), coalesce(v_name, 'Team member'), trim(p_body));
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_inbox_conv(p_id uuid)
 RETURNS conversations
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.conversations;
begin
  select * into c from public.conversations where id = p_id;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  return c;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_inbox_handover(p_conversation_id uuid, p_to_ai boolean DEFAULT false, p_assign_to uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.conversations;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if p_assign_to is not null and not exists (select 1 from public.business_members where business_id = c.business_id and user_id = p_assign_to and status = 'active') then
    raise exception 'NOT_A_MEMBER';
  end if;
  if p_to_ai then
    update public.conversations set ai_handled = true, handover_at = null, updated_at = now() where id = p_conversation_id;
  else
    update public.conversations set ai_handled = false, handover_at = now(), status = 'open',
           assigned_to = coalesce(p_assign_to, assigned_to, auth.uid()), updated_at = now() where id = p_conversation_id;
  end if;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content)
  values (p_conversation_id, 'system', 'text', case when p_to_ai then 'Handed back to the AI receptionist.' else 'A team member took over from the AI receptionist.' end);
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (c.business_id, auth.uid(), case when p_to_ai then 'inbox.returned_to_ai' else 'inbox.handover' end, 'conversation', p_conversation_id, jsonb_build_object('assigned_to', p_assign_to));
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_inbox_mark_read(p_conversation_id uuid, p_read boolean DEFAULT true)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.conversations;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  update public.conversations
     set last_read_at = case when p_read then now() else null end
   where id = p_conversation_id;
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_inbox_reply(p_conversation_id uuid, p_body text, p_subject text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.conversations; p public.customers; v_biz public.businesses; v_msg uuid;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'MESSAGE_REQUIRED'; end if;
  if c.channel not in ('sms', 'email') then raise exception 'CHANNEL_NOT_SUPPORTED'; end if;
  if c.customer_id is null then raise exception 'NO_RECIPIENT'; end if;
  select * into p from public.customers where id = c.customer_id;
  if coalesce(p.do_not_contact, false) or (c.channel = 'sms' and coalesce(p.do_not_sms, false)) or (c.channel = 'email' and coalesce(p.do_not_email, false)) then
    raise exception 'OPTED_OUT';
  end if;
  if c.channel = 'sms' then
    if nullif(trim(coalesce(p.phone, '')), '') is null then raise exception 'NO_RECIPIENT'; end if;
    select * into v_biz from public.businesses where id = c.business_id;
    insert into public.sms_messages (business_id, customer_id, conversation_id, direction, status, from_number, to_number, message_body)
    values (c.business_id, p.id, c.id, 'outbound', 'queued', coalesce(v_biz.phone, ''), p.phone, trim(p_body));
  else
    if nullif(trim(coalesce(p.email, '')), '') is null then raise exception 'NO_RECIPIENT'; end if;
    insert into public.email_messages (business_id, customer_id, conversation_id, direction, status, from_email, to_email, subject, body_text)
    values (c.business_id, p.id, c.id, 'outbound', 'queued', '', p.email, coalesce(nullif(trim(p_subject), ''), c.subject, 'Re: your message'), trim(p_body));
  end if;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, metadata)
  values (c.id, 'agent', 'text', trim(p_body), jsonb_build_object('sent_by', auth.uid(), 'delivery', 'queued'))
  returning id into v_msg;
  update public.conversations set ai_handled = false, handover_at = coalesce(handover_at, now()), last_read_at = now(),
         assigned_to = coalesce(assigned_to, auth.uid()), status = 'open', updated_at = now() where id = c.id;
  return 'queued';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_inbox_update(p_conversation_id uuid, p_assign_to uuid DEFAULT NULL::uuid, p_priority text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_unassign boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.conversations;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if p_priority is not null and p_priority not in ('normal', 'high', 'urgent') then raise exception 'BAD_PRIORITY'; end if;
  if p_status is not null and p_status not in ('open', 'pending', 'closed') then raise exception 'BAD_STATUS'; end if;
  if p_assign_to is not null and not exists (select 1 from public.business_members where business_id = c.business_id and user_id = p_assign_to and status = 'active') then
    raise exception 'NOT_A_MEMBER';
  end if;
  update public.conversations
     set assigned_to = case when p_unassign then null else coalesce(p_assign_to, assigned_to) end,
         priority = coalesce(p_priority, priority),
         status = coalesce(p_status, status),
         updated_at = now()
   where id = p_conversation_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (c.business_id, auth.uid(), 'inbox.updated', 'conversation', p_conversation_id,
          jsonb_build_object('assigned_to', c.assigned_to, 'priority', c.priority, 'status', c.status),
          jsonb_build_object('assigned_to', case when p_unassign then null else coalesce(p_assign_to, c.assigned_to) end, 'priority', coalesce(p_priority, c.priority), 'status', coalesce(p_status, c.status)));
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_industry_act(p_biz uuid, p_rule jsonb, p_cust uuid, p_entity uuid, p_title text, p_status text, p_assigned uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_line text; v_raw text; v_link text; t jsonb; nt jsonb;
begin
  if p_rule ? 'message' and p_cust is not null then
    v_raw := p_rule ->> 'message';
    v_link := null;
    if v_raw like '%{review_link}%' then
      select nullif(b.setup_data ->> 'review_link', '') into v_link from public.businesses b where b.id = p_biz;
      if v_link is null then v_raw := null; end if;
    end if;
    if v_raw is not null then
      v_line := left(replace(replace(replace(v_raw, '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), '{review_link}', coalesce(v_link, '')), 300);
      if coalesce(p_rule ->> 'mode', '') = 'draft' then
        if not exists (select 1 from public.message_drafts where business_id = p_biz and customer_id = p_cust and status = 'pending' and entity_id is not distinct from p_entity and body = v_line) then
          insert into public.message_drafts (business_id, customer_id, body, reason, entity_id)
          values (p_biz, p_cust, v_line, left(coalesce(nullif(p_title, ''), 'Follow-up'), 120), p_entity);
          perform public.zella_notify_owners(p_biz, 'draft_ready', 'A message is ready to review', 'Check it and send it, or dismiss it.', 'info', 'drafts');
        end if;
      else
        perform public.zella_queue_customer_message(p_biz, p_cust, 'record_status_update',
          jsonb_build_object('status_line', v_line, 'status', p_status, 'record_title', p_title),
          make_interval(mins => greatest(1, coalesce((p_rule ->> 'delay_minutes')::int, 1))), null, interval '0');
      end if;
    end if;
  end if;
  if p_rule ? 'task' then
    t := p_rule -> 'task';
    perform public.zella_create_task(p_biz, p_cust, 'industry', left(replace(replace(t ->> 'title', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 200),
      left(replace(replace(t ->> 'body', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 500),
      coalesce(nullif(t ->> 'priority', ''), 'normal'), now() + make_interval(hours => greatest(0, coalesce((t ->> 'due_hours')::int, 24))), p_assigned, 'automation', p_entity);
  end if;
  if p_rule ? 'notify' then
    nt := p_rule -> 'notify';
    perform public.zella_notify_owners(p_biz, 'industry_alert', left(replace(replace(nt ->> 'title', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 150),
      left(replace(replace(nt ->> 'body', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 300), coalesce(nullif(nt ->> 'severity', ''), 'warning'), 'records');
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_industry_apply_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.zella_apply_industry_automations(new.id);
  return new;
exception when others then
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_industry_key_for(p_business_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text; v_key text;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  return coalesce(v_key, 'other');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_industry_rule_list(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  if not (public.is_platform_admin() or public.zella_is_member(p_business_id)) then raise exception 'NOT_ALLOWED'; end if;
  v_key := public.zella_industry_key_for(p_business_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'name', p.name, 'description', p.description, 'checklist_no', p.checklist_no, 'trigger_type', p.trigger_type,
             'preferred', v_key <> 'other' and p.industry_key <> 'general', 'status', a.status, 'notify_via', coalesce(a.trigger_config ->> 'notify_via', 'both'),
             'enabled', coalesce(a.status = 'active', false))
           order by (p.industry_key = 'general'), p.checklist_no nulls last, p.name)
      from (select distinct on (name) * from public.industry_automation_presets
             where industry_key in (v_key, 'general') or v_key = 'other' order by name, (industry_key = 'general')) p
      left join public.automations a on a.business_id = p_business_id and a.name = p.name
     ), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_industry_rules_for(p_industry_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text; v_key text;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select regexp_replace(lower(coalesce(name, '')), '[^a-z]', '', 'g') into v_name from public.industries where id = p_industry_id;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  v_key := coalesce(v_key, 'other');
  return coalesce((select jsonb_agg(jsonb_build_object('name', p.name, 'description', p.description, 'checklist_no', p.checklist_no,
           'trigger_type', p.trigger_type, 'preferred', v_key <> 'other' and p.industry_key <> 'general', 'enabled', v_key <> 'other' and p.industry_key <> 'general', 'notify_via', 'both')
           order by (p.industry_key = 'general'), p.checklist_no nulls last, p.name)
      from (select distinct on (name) * from public.industry_automation_presets
             where industry_key in (v_key, 'general') or v_key = 'other' order by name, (industry_key = 'general')) p), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_industry_status_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; r jsonb;
begin
  if TG_OP = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  if exists (select 1 from public.businesses b where b.id = new.business_id and (b.suspended_at is not null or b.cancelled_at is not null)) then return new; end if;
  for a in select * from public.automations x where x.business_id = new.business_id and x.trigger_type = 'record_status_action' and x.status = 'active'
              and x.trigger_config ->> 'type_key' = new.type_key loop
    perform set_config('zella.notify_via', coalesce(nullif(a.trigger_config ->> 'notify_via', ''), 'both'), true);
    for r in select * from jsonb_array_elements(coalesce(a.trigger_config -> 'rules', '[]'::jsonb)) loop
      if r ->> 'status' = new.status
         and (not (r ? 'when_data') or lower(new.data ->> (r -> 'when_data' ->> 'key')) = lower(r -> 'when_data' ->> 'value')) then
        perform public.zella_industry_act(new.business_id, r, new.customer_id, new.id, new.title, new.status, new.assigned_to);
      end if;
    end loop;
  end loop;
  perform set_config('zella.notify_via', '', true);
  return new;
exception when others then
  perform set_config('zella.notify_via', '', true);
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_ingest_event(p_business_id uuid, p_event_type text, p_source text, p_idempotency_key text, p_payload jsonb DEFAULT '{}'::jsonb, p_provider_event_id text DEFAULT NULL::text, p_correlation_id uuid DEFAULT NULL::uuid, p_causation_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; b public.businesses;
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then raise exception 'INVALID_BUSINESS'; end if;
  if b.cancelled_at is not null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  insert into public.automation_events (business_id, event_type, source, idempotency_key, payload, provider_event_id, correlation_id, causation_id)
  values (p_business_id, p_event_type, p_source, p_idempotency_key, coalesce(p_payload, '{}'::jsonb), p_provider_event_id, coalesce(p_correlation_id, gen_random_uuid()), p_causation_id)
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.automation_events where business_id = p_business_id and idempotency_key = p_idempotency_key;
    return jsonb_build_object('id', v_id, 'duplicate', true);
  end if;
  return jsonb_build_object('id', v_id, 'duplicate', false);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_integration_summary(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_items jsonb := '[]'::jsonb; v_n integer; v_bad integer := 0; v_status text; v_err text;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select count(*) into v_n from public.business_phone_numbers where business_id = p_business_id and status = 'active';
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'phone', 'label', 'Phone number', 'ok', v_n > 0, 'detail', case when v_n > 0 then v_n || ' active' else 'No phone number connected' end));
  select status, last_error into v_status, v_err from public.calendar_connections where business_id = p_business_id order by connected_at desc nulls last limit 1;
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'calendar', 'label', 'Calendar', 'ok', coalesce(v_status = 'active', false), 'detail', case when v_status is null then 'Not connected' when v_status = 'active' then 'Connected' else 'Needs attention: ' || coalesce(left(v_err, 100), v_status) end));
  select count(*), count(*) filter (where status <> 'connected') into v_n, v_bad from public.meta_connections where business_id = p_business_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'social', 'label', 'Facebook, Instagram, WhatsApp', 'ok', v_n > 0 and v_bad = 0, 'detail', case when v_n = 0 then 'Not connected' when v_bad = 0 then 'Connected' else v_bad || ' need to be reconnected' end));
  select count(*) into v_n from public.sms_messages where business_id = p_business_id and direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours';
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'texts', 'label', 'Texts sent in the last day', 'ok', v_n = 0, 'detail', case when v_n = 0 then 'No failures' else v_n || ' failed' end));
  select count(*) into v_n from public.email_messages where business_id = p_business_id and direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours';
  v_items := v_items || jsonb_build_array(jsonb_build_object('key', 'emails', 'label', 'Emails sent in the last day', 'ok', v_n = 0, 'detail', case when v_n = 0 then 'No failures' else v_n || ' failed' end));
  return jsonb_build_object('items', v_items, 'all_ok', not exists (select 1 from jsonb_array_elements(v_items) i where (i ->> 'ok')::boolean = false));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_invite_staff(p_business_id uuid, p_email text, p_name text, p_role text DEFAULT 'staff'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_role not in ('admin', 'manager', 'staff', 'viewer') then raise exception 'BAD_ROLE'; end if;
  if p_role = 'admin' and not public.zella_has_role(p_business_id, array['owner']) then raise exception 'ONLY_OWNER_CAN_INVITE_ADMIN'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  if exists (select 1 from public.business_members m join auth.users u on u.id = m.user_id where m.business_id = p_business_id and lower(u.email) = v_email and m.status = 'active') then raise exception 'ALREADY_A_MEMBER'; end if;
  if exists (select 1 from public.business_invitations where business_id = p_business_id and lower(email) = v_email and status in ('pending', 'sent')) then raise exception 'ALREADY_INVITED'; end if;
  insert into public.business_invitations (business_id, email, owner_name, invited_by, status, role, invited_at, expires_at)
  values (p_business_id, v_email, left(coalesce(nullif(trim(p_name), ''), v_email), 100), auth.uid(), 'pending', p_role, now(), now() + interval '14 days') returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'staff_invited', 'business_invitation', v_id, jsonb_build_object('email', v_email, 'role', p_role));
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_is_member(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.business_members m
                  where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active');
$function$
;
CREATE OR REPLACE FUNCTION public.zella_is_zella_owner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.platform_admins where user_id = auth.uid() and is_active and role = 'zella_owner');
$function$
;
CREATE OR REPLACE FUNCTION public.zella_issue_quote(p_customer_id uuid, p_title text, p_expires_in_days integer DEFAULT 30)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; v_id uuid; v_auto record;
begin
  select * into c from public.customers where id = p_customer_id;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  select a.* into v_auto from public.automations a where a.business_id = c.business_id and a.trigger_type = 'quote_follow_up' and a.status = 'active' limit 1;
  insert into public.quotes (business_id, customer_id, title, expires_at, max_follow_ups, follow_up_every_days, next_follow_up_at, created_by)
  values (c.business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Quote'), now() + make_interval(days => greatest(1, coalesce(p_expires_in_days, 30))),
          coalesce((v_auto.trigger_config ->> 'max_follow_ups')::integer, 3), coalesce((v_auto.trigger_config ->> 'every_days')::integer, 3),
          case when v_auto.id is not null then now() + make_interval(days => coalesce((v_auto.trigger_config ->> 'every_days')::integer, 3)) end, auth.uid())
  returning id into v_id;
  update public.customers set lead_stage = 'quote_sent', contact_deadline_at = null, updated_at = now() where id = p_customer_id and coalesce(lead_stage, 'new') not in ('won', 'lost');
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_join_waitlist(p_business_id uuid, p_customer_id uuid, p_title text DEFAULT NULL::text, p_duration_minutes integer DEFAULT 30, p_earliest timestamp with time zone DEFAULT NULL::timestamp with time zone, p_latest timestamp with time zone DEFAULT NULL::timestamp with time zone, p_staff_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.waitlist_entries (business_id, customer_id, title, duration_minutes, earliest_at, latest_at, staff_id, notes)
  values (p_business_id, p_customer_id, nullif(trim(p_title), ''), greatest(5, coalesce(p_duration_minutes, 30)), p_earliest, p_latest, p_staff_id, left(p_notes, 500))
  on conflict (business_id, customer_id, coalesce(title, '')) where status in ('waiting', 'offered') do update set earliest_at = excluded.earliest_at, latest_at = excluded.latest_at, notes = excluded.notes
  returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_knowledge_gap_report(p_business_id uuid, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'open_questions', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'question', question, 'times_asked', times_asked, 'last_asked_at', last_asked_at) order by times_asked desc, last_asked_at desc)
                                  from (select * from public.knowledge_gaps where business_id = p_business_id and status = 'open' order by times_asked desc, last_asked_at desc limit 10) t), '[]'::jsonb),
    'open_count', (select count(*) from public.knowledge_gaps where business_id = p_business_id and status = 'open'),
    'answered_count', (select count(*) from public.knowledge_gaps where business_id = p_business_id and status = 'answered' and resolved_at > now() - d),
    'dismissed_count', (select count(*) from public.knowledge_gaps where business_id = p_business_id and status = 'dismissed' and resolved_at > now() - d),
    'times_asked_total', coalesce((select sum(times_asked) from public.knowledge_gaps where business_id = p_business_id and last_asked_at > now() - d), 0));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_knowledge_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_service boolean := coalesce(auth.role(), 'service_role') = 'service_role' and auth.uid() is null;
begin
  if tg_op = 'INSERT' then
    if not v_service then
      new.status := case when new.status = 'draft' then 'draft' else 'processing' end;
      new.version := 1; new.error := null; new.ready_at := null;
      new.created_by := auth.uid();
      if new.status = 'processing' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    end if;
    return new;
  end if;

  if not v_service then
    -- members may change content, archive, or send a draft for processing; nothing else
    if new.status not in ('draft', 'processing', 'archived') then
      new.status := old.status;
    end if;
    if new.status = 'ready' or (old.status = 'ready' and new.status = 'ready') then new.status := old.status; end if;
    new.ready_at := old.ready_at; new.error := old.error; new.version := old.version;
    new.business_id := old.business_id; new.created_by := old.created_by; new.gap_id := old.gap_id;
    if (new.title, new.question, new.answer, new.kind) is distinct from (old.title, old.question, old.answer, old.kind)
       and new.status <> 'archived' then
      -- changed content is never live until it has been processed again
      new.status := case when old.status = 'draft' and new.status = 'draft' then 'draft' else 'processing' end;
      new.version := old.version + 1; new.error := null; new.ready_at := null;
      if new.status = 'processing' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    elsif old.status = 'draft' and new.status = 'processing' then
      new.approved_by := auth.uid(); new.approved_at := now(); new.version := old.version + 1;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_knowledge_rollback(p_item_id uuid, p_version integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k public.knowledge_items%rowtype; v public.knowledge_versions%rowtype;
begin
  select * into k from public.knowledge_items where id = p_item_id;
  if not found or not public.zella_has_role(k.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  select * into v from public.knowledge_versions where item_id = k.id and version = p_version order by created_at desc limit 1;
  if not found then raise exception 'NO_SUCH_VERSION'; end if;
  update public.knowledge_items set title = v.title, question = v.question, answer = v.answer where id = k.id;
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_knowledge_source_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_service boolean := coalesce(auth.role(), 'service_role') = 'service_role' and auth.uid() is null;
begin
  if v_service then return new; end if;
  if tg_op = 'INSERT' then
    new.source_page_id := null; new.source_url := null; new.source_key := null; new.conflicts_with := null; new.source_stale := false;
  else
    new.source_page_id := old.source_page_id; new.source_url := old.source_url; new.source_key := old.source_key; new.conflicts_with := old.conflicts_with;
    if (new.title, new.answer, new.status) is distinct from (old.title, old.answer, old.status) then new.source_stale := false; else new.source_stale := old.source_stale; end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_knowledge_version_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'INSERT' or (new.title, new.question, new.answer, new.status, new.version) is distinct from (old.title, old.question, old.answer, old.status, old.version) then
    insert into public.knowledge_versions (item_id, business_id, version, title, question, answer, status, changed_by)
    values (new.id, new.business_id, new.version, new.title, new.question, new.answer, new.status, auth.uid());
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_language_catalog()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_array(
    jsonb_build_object('code', 'en-US', 'label', 'English (US)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-GB', 'label', 'English (UK)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-AU', 'label', 'English (Australia)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-IN', 'label', 'English (India)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-NZ', 'label', 'English (New Zealand)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'es', 'label', 'Spanish', 'english', false, 'greeting', 'Gracias por llamar a {name}. ¿En qué puedo ayudarle?'),
    jsonb_build_object('code', 'es-419', 'label', 'Spanish (Latin America)', 'english', false, 'greeting', 'Gracias por llamar a {name}. ¿En qué le puedo ayudar?'),
    jsonb_build_object('code', 'hi', 'label', 'Hindi', 'english', false, 'greeting', '{name} में कॉल करने के लिए धन्यवाद। बताइए, मैं आपकी कैसे मदद करूँ?'),
    jsonb_build_object('code', 'fr', 'label', 'French', 'english', false, 'greeting', 'Merci d''avoir appelé {name}. Comment puis-je vous aider ?'),
    jsonb_build_object('code', 'fr-CA', 'label', 'French (Canada)', 'english', false, 'greeting', 'Merci d''avoir appelé {name}. Comment puis-je vous aider?'),
    jsonb_build_object('code', 'de', 'label', 'German', 'english', false, 'greeting', 'Vielen Dank für Ihren Anruf bei {name}. Wie kann ich Ihnen helfen?'),
    jsonb_build_object('code', 'pt-BR', 'label', 'Portuguese (Brazil)', 'english', false, 'greeting', 'Obrigado por ligar para {name}. Como posso ajudar?'),
    jsonb_build_object('code', 'it', 'label', 'Italian', 'english', false, 'greeting', 'Grazie per aver chiamato {name}. Come posso aiutarla?'),
    jsonb_build_object('code', 'nl', 'label', 'Dutch', 'english', false, 'greeting', 'Bedankt voor het bellen naar {name}. Waarmee kan ik u helpen?'),
    jsonb_build_object('code', 'pl', 'label', 'Polish', 'english', false, 'greeting', 'Dzień dobry, tu {name}. W czym mogę pomóc?'),
    jsonb_build_object('code', 'ru', 'label', 'Russian', 'english', false, 'greeting', 'Здравствуйте, это {name}. Чем могу помочь?'),
    jsonb_build_object('code', 'tr', 'label', 'Turkish', 'english', false, 'greeting', 'Merhaba, {name}. Size nasıl yardımcı olabilirim?'),
    jsonb_build_object('code', 'ta', 'label', 'Tamil', 'english', false, 'greeting', 'வணக்கம், {name}. நான் உங்களுக்கு எப்படி உதவலாம்?'),
    jsonb_build_object('code', 'vi', 'label', 'Vietnamese', 'english', false, 'greeting', 'Xin chào, đây là {name}. Tôi có thể giúp gì cho quý khách?'),
    jsonb_build_object('code', 'id', 'label', 'Indonesian', 'english', false, 'greeting', 'Terima kasih telah menghubungi {name}. Ada yang bisa saya bantu?'),
    jsonb_build_object('code', 'ja', 'label', 'Japanese', 'english', false, 'greeting', '{name}にお電話いただきありがとうございます。ご用件をお伺いします。'),
    jsonb_build_object('code', 'ko', 'label', 'Korean', 'english', false, 'greeting', '{name}에 전화해 주셔서 감사합니다. 무엇을 도와드릴까요?'),
    jsonb_build_object('code', 'zh-CN', 'label', 'Chinese (Mandarin, Simplified)', 'english', false, 'greeting', '感谢您致电{name}。请问有什么可以帮您？'));
$function$
;
CREATE OR REPLACE FUNCTION public.zella_languages_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'table', to_regclass('public.business_languages') is not null,
    'assistant_config', pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) like '%zella_languages%'
                        and pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) like '%v_lang ->> ''prompt''%'
                        and pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) like '%v_lang ->> ''greeting''%');
$function$
;
CREATE OR REPLACE FUNCTION public.zella_lead_rule_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_match jsonb := '{}'::jsonb;
begin
  new.name := left(coalesce(nullif(trim(new.name), ''), 'Rule'), 80);
  if new.assign_to is not null and not exists (select 1 from public.business_members m where m.business_id = new.business_id and m.user_id = new.assign_to and m.status = 'active') then
    raise exception 'TARGET_NOT_ACTIVE';
  end if;
  if jsonb_typeof(coalesce(new.match, '{}'::jsonb)) <> 'object' then raise exception 'BAD_INPUT'; end if;
  if nullif(trim(new.match ->> 'source'), '') is not null then v_match := v_match || jsonb_build_object('source', left(lower(trim(new.match ->> 'source')), 40)); end if;
  if nullif(trim(new.match ->> 'keyword'), '') is not null then v_match := v_match || jsonb_build_object('keyword', left(trim(new.match ->> 'keyword'), 80)); end if;
  if jsonb_typeof(new.match -> 'answer_equals') = 'object' and new.match -> 'answer_equals' <> '{}'::jsonb then v_match := v_match || jsonb_build_object('answer_equals', new.match -> 'answer_equals'); end if;
  new.match := v_match;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_lead_source_report(p_business_id uuid, p_from timestamp with time zone DEFAULT (now() - '30 days'::interval), p_to timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(r order by r.leads desc) from (
    select coalesce(s.source ->> 'utm_source', s.channel) as source, coalesce(s.source ->> 'utm_campaign', '(none)') as campaign,
           count(distinct s.customer_id) as leads, count(*) as submissions,
           count(distinct s.customer_id) filter (where c.lead_stage = 'won') as won
      from public.lead_submissions s left join public.customers c on c.id = s.customer_id
     where s.business_id = p_business_id and s.status = 'accepted' and s.created_at >= p_from and s.created_at < p_to
     group by 1, 2) r), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_list_drafts(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'body', d.body, 'reason', d.reason, 'customer_id', d.customer_id,
            'customer', nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), 'created_at', d.created_at) order by d.created_at)
          from public.message_drafts d join public.customers c on c.id = d.customer_id
         where d.business_id = p_business_id and d.status = 'pending'), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_list_invitations(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'email', email, 'name', owner_name, 'role', role, 'status', status,
      'invited_at', invited_at, 'expires_at', expires_at, 'last_error', last_error) order by invited_at desc)
    from public.business_invitations
    where business_id = p_business_id and status in ('pending','sent','failed','expired')), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_lock_call_columns()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
   where table_schema = 'public' and table_name = 'calls' and column_name not in ('recording_url', 'transcript');
  execute 'revoke select on public.calls from authenticated';
  execute 'grant select (' || cols || ') on public.calls to authenticated';
  return 'locked';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_log_customer_request(p_business_id uuid, p_customer_id uuid, p_kind text, p_summary text, p_source text DEFAULT 'staff'::text, p_call_id uuid DEFAULT NULL::uuid, p_priority text DEFAULT 'normal'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_summary text := left(regexp_replace(trim(coalesce(p_summary, '')), '\s+', ' ', 'g'), 1000); v_id uuid; v_user uuid; v_due timestamptz; v_status text; u record;
begin
  if p_kind not in ('complaint', 'correction', 'data_access', 'data_deletion') then raise exception 'INVALID_KIND'; end if;
  if length(v_summary) < 3 then raise exception 'EMPTY_SUMMARY'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then p_customer_id := null; end if;
  select id into v_id from public.customer_requests
   where business_id = p_business_id and kind = p_kind and status in ('open', 'in_progress', 'waiting_verification')
     and customer_id is not distinct from p_customer_id and created_at > now() - interval '24 hours' limit 1;
  if v_id is not null then return v_id; end if;

  v_due := now() + case p_kind when 'complaint' then case when p_priority = 'urgent' then interval '4 hours' else interval '24 hours' end
                                when 'correction' then interval '3 days' else interval '30 days' end;
  v_status := case when p_kind in ('data_access', 'data_deletion') then 'waiting_verification' else 'open' end;
  if p_kind in ('data_access', 'data_deletion') then
    select user_id into v_user from public.business_members where business_id = p_business_id and status = 'active' and role in ('owner', 'admin') order by created_at limit 1;
  else
    v_user := public.zella_pick_assignee(p_business_id);
    if v_user is not null then perform public.zella_mark_assigned(p_business_id, v_user); end if;
  end if;
  insert into public.customer_requests (business_id, customer_id, call_id, kind, summary, source, status, priority, assigned_to, due_at)
  values (p_business_id, p_customer_id, p_call_id, p_kind, v_summary, case when p_source in ('phone', 'web', 'email', 'sms', 'staff') then p_source else 'staff' end,
          v_status, case when p_priority in ('normal', 'high', 'urgent') then p_priority else 'normal' end, v_user, v_due) returning id into v_id;

  if p_kind in ('data_access', 'data_deletion') or v_user is null then
    for u in select user_id from public.business_members where business_id = p_business_id and status = 'active' and role in ('owner', 'admin') loop
      perform public.zella_notify(p_business_id, 'customer_request', case p_kind when 'complaint' then 'New complaint' when 'correction' then 'Data correction request' when 'data_access' then 'Privacy request: access to data' else 'Privacy request: deletion' end,
        left(v_summary, 200), case when p_kind = 'complaint' then 'warning' else 'info' end, 'customers', v_id, u.user_id);
    end loop;
  else
    perform public.zella_notify(p_business_id, 'customer_request', case p_kind when 'complaint' then 'New complaint for you' else 'Data correction request for you' end,
      left(v_summary, 200), case when p_kind = 'complaint' then 'warning' else 'info' end, 'customers', v_id, v_user);
  end if;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_log_data_rights_request(p_business_id uuid, p_kind text, p_customer_id uuid DEFAULT NULL::uuid, p_name text DEFAULT NULL::text, p_contact text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.data_rights_requests (business_id, customer_id, kind, requester_name, requester_contact, note, created_by)
  values (p_business_id, p_customer_id, p_kind, left(p_name, 200), left(p_contact, 200), left(p_note, 1000), auth.uid()) returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'data_rights_logged', 'data_rights_request', v_id, jsonb_build_object('kind', p_kind));
  perform public.zella_notify_owners(p_business_id, 'data_rights_request', 'A customer asked about their information', 'Reply within 30 days. Open the request to export or erase their details.', 'warning', 'customers');
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_log_knowledge_gap(p_business_id uuid, p_question text, p_call_id uuid DEFAULT NULL::uuid, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text := trim(lower(regexp_replace(coalesce(p_question, ''), '[^a-zA-Z0-9]+', ' ', 'g'))); v_id uuid;
begin
  if v_key = '' then raise exception 'EMPTY_QUESTION'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'BUSINESS_NOT_FOUND'; end if;
  insert into public.knowledge_gaps (business_id, call_id, customer_id, question, question_key)
  values (p_business_id, p_call_id, p_customer_id, left(trim(p_question), 500), left(v_key, 300))
  on conflict (business_id, question_key) where status = 'open'
  do update set times_asked = knowledge_gaps.times_asked + case when excluded.call_id is not null and excluded.call_id = knowledge_gaps.call_id then 0 else 1 end /* zella_gap_once_per_call */, last_asked_at = now(),
                call_id = coalesce(excluded.call_id, knowledge_gaps.call_id)
  returning id into v_id;
  -- zella_gap_notice: a question asked for the first time tells the owners (at most one notice an hour per business)
  if (select g.times_asked = 1 and g.notified_at is null and g.first_asked_at > now() - interval '1 minute' from public.knowledge_gaps g where g.id = v_id)
     and not exists (select 1 from public.staff_notifications n where n.business_id = p_business_id and n.kind = 'knowledge_gap' and n.created_at > now() - interval '1 hour') then
    begin
      perform public.zella_notify_owners(p_business_id, 'knowledge_gap', 'A caller asked something the assistant could not answer',
        '"' || left(regexp_replace(trim(p_question), '\s+', ' ', 'g'), 160) || '" Open Knowledge > Questions to review to add an answer.', 'info', 'knowledge');
      update public.knowledge_gaps set notified_at = now() where id = v_id;
    exception when others then null;   -- a notice problem never loses the question
    end;
  end if;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_log_outbound_email(p_business_id uuid, p_customer_id uuid, p_to text, p_from text, p_subject text, p_body_text text, p_body_html text, p_dedupe_key text, p_status text DEFAULT 'queued'::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.email_messages;
begin
  if p_dedupe_key is null or length(p_dedupe_key) < 8 then raise exception 'INVALID_DEDUPE_KEY'; end if;
  if p_status not in ('queued', 'dry_run', 'blocked') then raise exception 'INVALID_STATUS'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then
    raise exception 'TENANT_MISMATCH';
  end if;
  insert into public.email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, body_text, body_html, metadata)
  values (p_business_id, p_customer_id, 'outbound', p_status, nullif(p_from, ''), p_to, left(p_subject, 300), left(p_body_text, 20000), left(p_body_html, 40000),
          coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('dedupe_key', p_dedupe_key))
  on conflict (business_id, (metadata ->> 'dedupe_key')) where metadata ->> 'dedupe_key' is not null do nothing
  returning * into r;
  if r.id is not null then return jsonb_build_object('id', r.id, 'duplicate', false, 'status', r.status); end if;

  select * into r from public.email_messages where business_id = p_business_id and metadata ->> 'dedupe_key' = p_dedupe_key;
  if r.status = 'failed' and p_status = 'queued' then
    update public.email_messages set status = 'queued', updated_at = now() where id = r.id;
    return jsonb_build_object('id', r.id, 'duplicate', false, 'status', 'queued');
  end if;
  return jsonb_build_object('id', r.id, 'duplicate', true, 'status', r.status);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_log_outbound_sms(p_business_id uuid, p_customer_id uuid, p_to text, p_from text, p_body text, p_dedupe_key text, p_status text DEFAULT 'queued'::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.sms_messages;
begin
  if p_dedupe_key is null or length(p_dedupe_key) < 8 then raise exception 'INVALID_DEDUPE_KEY'; end if;
  if p_status not in ('queued', 'dry_run', 'blocked') then raise exception 'INVALID_STATUS'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then
    raise exception 'TENANT_MISMATCH';
  end if;
  insert into public.sms_messages (business_id, customer_id, direction, status, from_number, to_number, message_body, metadata)
  values (p_business_id, p_customer_id, 'outbound', p_status, nullif(p_from, ''), p_to, left(p_body, 1600),
          coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('dedupe_key', p_dedupe_key))
  on conflict (business_id, (metadata ->> 'dedupe_key')) where metadata ->> 'dedupe_key' is not null do nothing
  returning * into r;
  if r.id is not null then return jsonb_build_object('id', r.id, 'duplicate', false, 'status', r.status); end if;

  select * into r from public.sms_messages where business_id = p_business_id and metadata ->> 'dedupe_key' = p_dedupe_key;
  if r.status = 'failed' and p_status = 'queued' then
    update public.sms_messages set status = 'queued', updated_at = now() where id = r.id;
    return jsonb_build_object('id', r.id, 'duplicate', false, 'status', 'queued');
  end if;
  return jsonb_build_object('id', r.id, 'duplicate', true, 'status', r.status);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_mark_assigned(p_business_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update public.business_members set last_assigned_at = now() where business_id = p_business_id and user_id = p_user_id;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_mark_call_placed(p_source text, p_id uuid, p_provider_call_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_source = 'task' then
    update public.followup_tasks set provider_call_id = left(p_provider_call_id, 200), updated_at = now() where id = p_id and status = 'in_progress';
  elsif p_source <> 'callback' then
    raise exception 'BAD_SOURCE';
  end if;
  return 'placed';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_mark_invitation_reminded(p_invitation_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update public.business_invitations set reminder_count = reminder_count + 1, last_reminded_at = now(), updated_at = now() where id = p_invitation_id;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_mark_notifications_read(p_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  update public.staff_notifications set read_at = now()
   where id = any (p_ids) and read_at is null and public.zella_is_member(business_id) and (user_id is null or user_id = auth.uid());
  get diagnostics n = row_count; return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_mark_staff_sms()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_via text := coalesce(nullif(current_setting('zella.notify_via', true), ''), 'both'); v_ok boolean;
begin
  select exists (select 1 from public.business_members m where m.business_id = new.business_id and m.status = 'active' and m.sms_alerts
                  and (new.user_id is null and m.role in ('owner', 'admin') or m.user_id = new.user_id)) into v_ok;
  if v_via = 'sms' then
    if v_ok then new.sms_status := 'pending'; new.delivery_status := 'skipped'; end if;
  elsif v_via = 'email' then
    new.sms_status := null;
  elsif (new.severity = 'urgent' or (new.kind = 'on_call_starting' and new.user_id is not null)) and v_ok then -- zella_on_call_text
    new.sms_status := 'pending';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_match_customer(p_business_id uuid, p_phone text, p_email text)
 RETURNS TABLE(customer_id uuid, certainty text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_phone text := public.zella_digits(p_phone); v_email text := lower(nullif(trim(coalesce(p_email, '')), ''));
        v_by_phone uuid[]; v_by_email uuid[];
begin
  select coalesce(array_agg(c.id), '{}') into v_by_phone from public.customers c
   where c.business_id = p_business_id and v_phone is not null and public.zella_digits(c.phone) = v_phone;
  select coalesce(array_agg(c.id), '{}') into v_by_email from public.customers c
   where c.business_id = p_business_id and v_email is not null and lower(c.email) = v_email;
  if cardinality(v_by_phone) = 0 and cardinality(v_by_email) = 0 then
    return query select null::uuid, 'none'::text; return;
  end if;
  if cardinality(v_by_phone) = 1 and cardinality(v_by_email) = 0 then return query select v_by_phone[1], 'exact'; return; end if;
  if cardinality(v_by_email) = 1 and cardinality(v_by_phone) = 0 then return query select v_by_email[1], 'exact'; return; end if;
  if cardinality(v_by_phone) = 1 and cardinality(v_by_email) = 1 and v_by_phone[1] = v_by_email[1] then
    return query select v_by_phone[1], 'exact'; return;
  end if;
  return query select coalesce(v_by_phone[1], v_by_email[1]), 'uncertain';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_merge_customers(p_business_id uuid, p_keep uuid, p_drop uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k public.customers; d public.customers; t record; v_moved integer := 0; v_skipped text[] := '{}'; v_n integer;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_keep = p_drop then raise exception 'SAME_CUSTOMER'; end if;
  select * into k from public.customers where id = p_keep and business_id = p_business_id for update;
  select * into d from public.customers where id = p_drop and business_id = p_business_id for update;
  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;
  for t in select distinct c1.table_name from information_schema.columns c1 join information_schema.columns c2 on c2.table_schema = 'public' and c2.table_name = c1.table_name and c2.column_name = 'business_id'
            join information_schema.tables tb on tb.table_schema = 'public' and tb.table_name = c1.table_name and tb.table_type = 'BASE TABLE'
            where c1.table_schema = 'public' and c1.column_name = 'customer_id' and c1.table_name not in ('duplicate_reviews', 'email_unsubscribe_tokens', 'contact_consents', 'data_rights_requests') loop
    begin
      execute format('update public.%I set customer_id = $1 where customer_id = $2 and business_id = $3', t.table_name) using p_keep, p_drop, p_business_id;
      get diagnostics v_n = row_count; v_moved := v_moved + v_n;
    exception when others then v_skipped := v_skipped || t.table_name;
    end;
  end loop;
  update public.customers set
      first_name = coalesce(first_name, d.first_name), last_name = coalesce(last_name, d.last_name), phone = coalesce(phone, d.phone), email = coalesce(email, d.email),
      company_name = coalesce(company_name, d.company_name), date_of_birth = coalesce(date_of_birth, d.date_of_birth), address = coalesce(address, d.address),
      do_not_contact = coalesce(do_not_contact, false) or coalesce(d.do_not_contact, false), do_not_sms = coalesce(do_not_sms, false) or coalesce(d.do_not_sms, false),
      do_not_email = coalesce(do_not_email, false) or coalesce(d.do_not_email, false), do_not_call = coalesce(do_not_call, false) or coalesce(d.do_not_call, false),
      notes = case when nullif(d.notes, '') is null then notes else coalesce(notes || E'\n', '') || d.notes end,
      last_contacted_at = greatest(last_contacted_at, d.last_contacted_at), updated_at = now()
   where id = p_keep;
  update public.customers set status = 'archived', phone = null, email = null, notes = null, metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('merged_into', p_keep, 'merged_at', now()), updated_at = now() where id = p_drop;
  update public.duplicate_reviews set status = 'merged', resolved_by = auth.uid(), resolved_at = now()
   where business_id = p_business_id and status = 'open' and (customer_id in (p_keep, p_drop) and (incoming ->> 'duplicate_customer_id') in (p_keep::text, p_drop::text));
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'customer.merged', 'customer', p_keep, jsonb_build_object('merged_from', p_drop, 'rows_moved', v_moved, 'tables_skipped', to_jsonb(v_skipped)));
  return jsonb_build_object('kept', p_keep, 'archived', p_drop, 'rows_moved', v_moved, 'tables_skipped', to_jsonb(v_skipped));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_message_summary(p_business_id uuid, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'texts', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.sms_messages where business_id = p_business_id and direction = 'outbound' and created_at > now() - d group by status) x), '{}'::jsonb),
    'emails', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.email_messages where business_id = p_business_id and direction = 'outbound' and created_at > now() - d group by status) x), '{}'::jsonb),
    'replies', (select count(*) from public.sms_messages where business_id = p_business_id and direction = 'inbound' and created_at > now() - d),
    'unsubscribed', (select count(*) from public.contact_consents where business_id = p_business_id and status = 'opted_out' and recorded_at > now() - d));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_messaging_status(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_setting jsonb;
  v_sms boolean; v_email boolean; v_calls boolean; v_sched boolean := false;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_setting
    from public.platform_settings
   where key in ('sms_live', 'sms_from_number', 'email_live', 'email_from_address', 'calls_live', 'n8n_dispatch_enabled');

  v_sms := coalesce((v_setting ->> 'sms_live')::boolean, false) and coalesce(v_setting ->> 'sms_from_number', '') <> '';
  v_email := coalesce((v_setting ->> 'email_live')::boolean, false) and coalesce(v_setting ->> 'email_from_address', '') <> '';
  v_calls := coalesce((v_setting ->> 'calls_live')::boolean, false);

  if to_regclass('cron.job') is not null and to_regclass('vault.secrets') is not null then
    execute $q$select exists (select 1 from cron.job where jobname = 'zella_dispatch' and active)
                  and exists (select 1 from vault.secrets where name = 'zella_n8n_secret')$q$ into v_sched;
  end if;
  v_sched := v_sched and coalesce((v_setting ->> 'n8n_dispatch_enabled')::boolean, true);

  return jsonb_build_object(
    'texts', v_sms, 'emails', v_email, 'calls', v_calls, 'scheduler', v_sched,
    'automations', coalesce((
      select jsonb_object_agg(trigger_type, status)
        from (select distinct on (trigger_type) trigger_type, status
                from public.automations
               where business_id = p_business_id
                 and trigger_type in ('appointment_confirmation', 'appointment_reminder', 'no_show_follow_up', 'post_appointment_follow_up')
               order by trigger_type, (status = 'active') desc, updated_at desc nulls last) x), '{}'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_capture_lead(p_event_id uuid, p_fields jsonb, p_campaign text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e public.meta_events%rowtype; c public.meta_connections%rowtype; f jsonb; k text; v text;
  v_name text; v_first text; v_last text; v_phone text; v_email text; v_consent boolean := false; v_notes text := '';
  v_digits text; v_cust uuid; v_cb uuid; v_platform text; v_src jsonb; v_ok boolean; v_summary text; v_label text; v_camp text;
begin
  select * into e from public.meta_events where id = p_event_id and kind = 'lead';
  if not found then return jsonb_build_object('result', 'missing'); end if;
  select * into c from public.meta_connections where page_id = e.page_id and business_id = e.business_id and status <> 'disconnected' limit 1;
  if c.id is null or not exists (select 1 from public.businesses b where b.id = e.business_id and b.suspended_at is null and b.cancelled_at is null) then
    update public.meta_events set status = 'ignored', last_error = 'no_connection' where id = p_event_id; return jsonb_build_object('result', 'ignored');
  end if;
  if jsonb_typeof(p_fields) <> 'array' then raise exception 'BAD_FIELDS'; end if;
  v_platform := coalesce(e.payload ->> 'platform', 'facebook'); v_label := initcap(v_platform);

  for f in select * from jsonb_array_elements(p_fields) loop
    k := lower(coalesce(f ->> 'name', '')); v := nullif(trim(coalesce(f -> 'values' ->> 0, '')), '');
    continue when v is null;
    if k ~ 'email' then v_email := lower(left(v, 254));
    elsif k ~ 'phone' then v_phone := left(v, 40);
    elsif k = 'full_name' then v_name := left(v, 120);
    elsif k = 'first_name' then v_first := left(v, 60);
    elsif k = 'last_name' then v_last := left(v, 60);
    elsif k ~ '(consent|agree|permission|contact_me|opt_in)' then v_consent := v_consent or lower(v) ~ '^(yes|true|agree|i agree|1|ok|sure)';
    elsif length(v_notes) < 400 then v_notes := v_notes || case when v_notes = '' then '' else '; ' end || left(replace(k, '_', ' '), 40) || ': ' || left(v, 100);
    end if;
  end loop;
  if v_first is null then v_first := nullif(split_part(coalesce(v_name, ''), ' ', 1), ''); end if;
  if v_last is null and v_name is not null then v_last := nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''); end if;
  v_digits := public.zella_digits(v_phone);
  if v_digits is not null and (length(v_digits) < 7 or length(v_digits) > 15) then v_phone := null; v_digits := null; end if;
  if v_email is not null and not public.zella_valid_email(v_email) then v_email := null; end if;
  if v_digits is null and v_email is null then
    update public.meta_events set status = 'done', last_error = 'no_contact_details' where id = p_event_id;
    perform public.zella_notify_owners(e.business_id, 'meta_lead_incomplete', 'A ' || v_label || ' lead had no phone or email', 'Check the lead in Facebook Leads Center.', 'info', 'customers');
    return jsonb_build_object('result', 'no_contact');
  end if;

  v_camp := coalesce(nullif(left(p_campaign, 120), ''), 'form ' || coalesce(e.payload ->> 'form_id', '?'));
  v_src := jsonb_build_object('utm_source', v_platform, 'utm_medium', 'paid_social', 'utm_campaign', v_camp, 'meta_form_id', e.payload ->> 'form_id', 'meta_ad_id', e.payload ->> 'ad_id');
  select m.customer_id into v_cust from public.zella_match_customer(e.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
  if v_cust is null then
    insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification, metadata)
    values (e.business_id, coalesce(v_first, v_label || ' lead'), v_last, v_phone, v_email, 'active', v_platform, 'new', 'normal',
            jsonb_build_object('kind', 'social_lead', 'has_phone', v_digits is not null, 'has_email', v_email is not null, 'form_answers', nullif(v_notes, '')),
            jsonb_build_object('attribution', jsonb_build_object('first_touch', v_src || jsonb_build_object('channel', v_platform, 'at', now()))))
    returning id into v_cust;
  else
    update public.customers set metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), '{attribution,last_touch}', v_src || jsonb_build_object('channel', v_platform, 'at', now()), true), updated_at = now() where id = v_cust;
  end if;

  v_ok := v_consent or c.call_consent_confirmed;
  if v_ok then
    if v_digits is not null then
      perform public.zella_record_consent(e.business_id, 'call', 'opted_in', 'web_form', v_cust, v_phone, null, 'transactional', null, jsonb_build_object('meta_lead', e.payload ->> 'leadgen_id'));
      perform public.zella_record_consent(e.business_id, 'sms', 'opted_in', 'web_form', v_cust, v_phone, null, 'transactional', null, jsonb_build_object('meta_lead', e.payload ->> 'leadgen_id'));
    end if;
    if v_email is not null then
      perform public.zella_record_consent(e.business_id, 'email', 'opted_in', 'web_form', v_cust, null, v_email, 'transactional', null, jsonb_build_object('meta_lead', e.payload ->> 'leadgen_id'));
    end if;
  end if;

  v_summary := left(v_label || ' lead (' || v_camp || ')' || case when v_notes <> '' then ': ' || v_notes else '' end, 600);
  if v_digits is not null and v_ok then
    v_cb := public.zella_create_callback(e.business_id, v_phone, 'new_lead', 'normal', v_summary, null, v_cust, null, null, 'system', 'new_lead_callback');
  else
    perform public.zella_notify(e.business_id, 'social_lead', 'New ' || v_label || ' lead',
      v_summary || case when v_digits is not null and not v_ok then ' (not called: the form has no consent to be contacted)' when v_digits is null then ' (email only: ' || v_email || ')' else '' end,
      'info', 'customers', v_cust);
  end if;
  insert into public.lead_submissions (business_id, kind, channel, status, customer_id, callback_id, source, summary)
  values (e.business_id, 'social_lead', v_platform, 'accepted', v_cust, v_cb, v_src, v_summary);
  update public.meta_events set status = 'done', last_error = null where id = p_event_id;
  return jsonb_build_object('result', 'captured', 'customer_id', v_cust, 'called', v_cb is not null);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_claim_checks(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  with c as (select id from public.meta_connections where status in ('connected', 'error') and next_check_at <= now() order by next_check_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked),
  u as (update public.meta_connections m set next_check_at = now() + interval '6 hours', last_checked_at = now() from c where m.id = c.id returning m.page_id, m.waba_id, m.whatsapp_phone_id)
  select coalesce(jsonb_agg(jsonb_build_object('page_id', page_id, 'waba_id', waba_id, 'whatsapp_phone_id', whatsapp_phone_id)), '[]'::jsonb) into v from u;
  return v;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_claim_leads(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  update public.meta_events set status = 'failed', last_error = 'stuck' where kind = 'lead' and status = 'processing' and claimed_at < now() - interval '10 minutes' and attempts >= 5;
  with c as (
    select id from public.meta_events
     where kind = 'lead' and ((status = 'pending' and next_try_at <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes'))
     order by created_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked),
  u as (update public.meta_events e set status = 'processing', attempts = e.attempts + 1, claimed_at = now() from c where e.id = c.id
        returning e.id, e.page_id, e.payload)
  select coalesce(jsonb_agg(jsonb_build_object('event_id', id, 'page_id', page_id, 'leadgen_id', payload ->> 'leadgen_id', 'form_id', payload ->> 'form_id', 'ad_id', payload ->> 'ad_id')), '[]'::jsonb) into v from u;
  return v;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_claim_outbox(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o record; v_out jsonb := '[]'::jsonb; v_last timestamptz; c public.meta_connections%rowtype;
begin
  for o in select * from public.meta_outbox
            where (status = 'queued' and next_try_at <= now()) or (status = 'sending' and claimed_at < now() - interval '10 minutes')
            order by created_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked loop
    select * into c from public.meta_connections where page_id = o.page_id and business_id = o.business_id;
    if c.id is null or c.status = 'disconnected' then
      update public.meta_outbox set status = 'cancelled', last_error = 'no_connection' where id = o.id; continue;
    end if;
    -- a free-form message is only allowed within 24 hours of the customer's last message
    if o.kind = 'message' and o.conversation_id is not null then
      select last_inbound_at into v_last from public.conversations where id = o.conversation_id;
      if v_last is null or v_last < now() - interval '24 hours' then
        update public.meta_outbox set status = 'cancelled', last_error = case when o.channel = 'whatsapp' then 'template_required' else 'window_closed' end where id = o.id;
        perform public.zella_notify_owners(o.business_id, 'social_window_closed', 'A reply could not be sent',
          case when o.channel = 'whatsapp' then 'The 24-hour WhatsApp window has closed. Send an approved template, or call the customer.' else 'The 24-hour reply window has closed. Contact the customer another way.' end, 'info', 'inbox'); -- window_closed_notice
        continue;
      end if;
    end if;
    update public.meta_outbox set status = 'sending', attempts = attempts + 1, claimed_at = now() where id = o.id;
    v_out := v_out || jsonb_build_array(jsonb_build_object('id', o.id, 'page_id', o.page_id, 'channel', o.channel, 'kind', o.kind, 'recipient', o.recipient,
      'text', o.text_body, 'instagram_id', c.instagram_id, 'whatsapp_phone_id', c.whatsapp_phone_id, 'template_name', o.template_name, 'template_language', o.template_language));
  end loop;
  return v_out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_fail_event(p_event_id uuid, p_error text, p_permanent boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.meta_events%rowtype;
begin
  select * into e from public.meta_events where id = p_event_id;
  if not found then return; end if;
  if p_permanent or e.attempts >= 5 then
    update public.meta_events set status = 'failed', last_error = left(coalesce(p_error, 'unknown'), 200) where id = p_event_id;
    perform public.zella_platform_alert('meta_lead_failed', 'A Facebook or Instagram lead could not be fetched', left(coalesce(p_error, 'unknown'), 200), 'warning', e.business_id, 'meta_lead_failed:' || e.business_id::text);
    perform public.zella_notify_owners(e.business_id, 'meta_lead_failed', 'A social lead could not be fetched', 'Open your Meta leads page in Facebook to see it, and check the Meta connection in Zella.', 'warning', 'integrations');
  else
    update public.meta_events set status = 'pending', last_error = left(coalesce(p_error, 'unknown'), 200), next_try_at = now() + (power(2, e.attempts) || ' minutes')::interval where id = p_event_id;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_process_event(p_event_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e public.meta_events%rowtype; c public.meta_connections%rowtype; p jsonb; v_biz text;
  v_ch text; v_sender text; v_name text; v_text text; v_phone text; v_contact public.meta_contacts%rowtype;
  v_cust uuid; v_conv uuid; v_assignee uuid; v_intent text; v_label text; v_email text; v_digits text; v_first text; v_flow text;
begin
  select * into e from public.meta_events where id = p_event_id;
  if not found then return 'missing'; end if;
  select * into c from public.meta_connections where page_id = e.page_id and business_id = e.business_id and status <> 'disconnected' limit 1;
  if c.id is null then
    update public.meta_events set status = 'ignored', last_error = 'no_connection' where id = p_event_id; return 'no_connection';
  end if;
  p := e.payload;
  select name into v_biz from public.businesses where id = e.business_id and suspended_at is null and cancelled_at is null;
  if v_biz is null then
    update public.meta_events set status = 'ignored', last_error = 'business_inactive' where id = p_event_id; return 'business_inactive';
  end if;

  if e.kind = 'comment' then
    v_text := lower(coalesce(p ->> 'text', ''));
    if coalesce((p ->> 'from_page')::boolean, false) or cardinality(c.comment_keywords) = 0
       or not exists (select 1 from unnest(c.comment_keywords) k where position(k in v_text) > 0) then
      update public.meta_events set status = 'ignored' where id = p_event_id; return 'ignored';
    end if;
    insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body)
    values (e.business_id, e.page_id, case when p ->> 'platform' = 'instagram' then 'instagram' else 'messenger' end, 'private_reply', p ->> 'comment_id',
            'Hi! Thanks for your comment. This is ' || v_biz || '. How can we help? Reply here and our team will get back to you.');
    perform public.zella_notify_owners(e.business_id, 'social_comment', 'A comment got a private reply', left(coalesce(p ->> 'text', ''), 200), 'info', 'inbox');
    update public.meta_events set status = 'done' where id = p_event_id;
    return 'private_reply_queued';
  end if;

  v_ch := p ->> 'channel'; v_sender := left(p ->> 'sender_id', 100); v_name := nullif(left(coalesce(p ->> 'sender_name', ''), 120), '');
  v_text := coalesce(nullif(left(trim(coalesce(p ->> 'text', '')), 2000), ''), '(attachment)'); v_phone := nullif(left(coalesce(p ->> 'phone', ''), 30), '');
  if v_ch not in ('messenger', 'instagram', 'whatsapp') or v_sender is null then
    update public.meta_events set status = 'ignored', last_error = 'bad_message' where id = p_event_id; return 'bad_message';
  end if;
  v_label := case v_ch when 'whatsapp' then 'WhatsApp' when 'instagram' then 'Instagram' else 'Messenger' end;

  insert into public.meta_contacts (business_id, channel, external_id, display_name) values (e.business_id, v_ch, v_sender, v_name)
  on conflict (business_id, channel, external_id) do update set display_name = coalesce(excluded.display_name, public.meta_contacts.display_name)
  returning * into v_contact;

  v_cust := v_contact.customer_id;
  if v_cust is null and v_phone is not null then
    select m.customer_id into v_cust from public.zella_match_customer(e.business_id, v_phone, null) m where m.certainty = 'exact' limit 1;
  end if;

  v_intent := case
    when v_text ~* '\m(human|real person|agent|speak to (someone|a person)|talk to (someone|a person)|call me)\M' then 'human'
    when v_text ~* '\m(complain|complaint|unhappy|terrible|refund|disappointed)\M' then 'complaint'
    when v_text ~* '\m(book|booking|appointment|available|availability|schedule|reserve)\M' then 'booking'
    when v_text ~* '\m(price|prices|cost|quote|how much|estimate)\M' then 'price'
    else 'message' end;

  if v_cust is null and v_intent in ('booking', 'price', 'human') then
    v_email := lower(substring(v_text from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
    v_digits := substring(v_text from '(\+?[0-9][0-9 ().-]{7,18}[0-9])');
    v_phone := coalesce(v_phone, v_digits);
    if public.zella_digits(v_phone) is not null or v_email is not null then
      select m.customer_id into v_cust from public.zella_match_customer(e.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
      if v_cust is null then
        v_first := coalesce(split_part(v_name, ' ', 1), v_label || ' contact');
        insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification, metadata)
        values (e.business_id, coalesce(nullif(v_first, ''), v_label || ' contact'), nullif(trim(substr(coalesce(v_name, ''), length(split_part(coalesce(v_name, ''), ' ', 1)) + 1)), ''),
                case when public.zella_digits(v_phone) is not null then v_phone end, v_email, 'active', lower(v_label), 'new', case when v_intent = 'human' then 'high' else 'normal' end,
                jsonb_build_object('intent', v_intent, 'has_phone', public.zella_digits(v_phone) is not null, 'has_email', v_email is not null),
                jsonb_build_object('attribution', jsonb_build_object('first_touch', jsonb_build_object('utm_source', lower(v_label), 'channel', lower(v_label), 'at', now()))))
        returning id into v_cust;
      end if;
    end if;
  end if;

  v_conv := v_contact.conversation_id;
  if v_conv is not null and not exists (select 1 from public.conversations where id = v_conv and status <> 'closed') then v_conv := null; end if;
  if v_conv is null then
    insert into public.conversations (business_id, customer_id, channel, status, subject, ai_handled)
    values (e.business_id, v_cust, v_ch, 'open', v_label || ' conversation' || coalesce(' with ' || v_name, ''), false) returning id into v_conv;
  elsif v_cust is not null then
    update public.conversations set customer_id = coalesce(customer_id, v_cust) where id = v_conv;
  end if;
  update public.meta_contacts set conversation_id = v_conv, customer_id = coalesce(customer_id, v_cust) where id = v_contact.id;
  update public.conversations set status = 'open', priority = case when v_intent in ('human', 'complaint') then 'high' else priority end where id = v_conv;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, external_message_id, metadata)
  values (v_conv, 'customer', 'text', v_text, left(p ->> 'message_id', 200), jsonb_build_object('channel', v_ch, 'intent', v_intent));

  if (select assigned_to from public.conversations where id = v_conv) is null then
    v_assignee := public.zella_pick_assignee(e.business_id);
    if v_assignee is not null then
      update public.conversations set assigned_to = v_assignee where id = v_conv;
      perform public.zella_mark_assigned(e.business_id, v_assignee);
    end if;
  end if;

  perform public.zella_notify_owners(e.business_id, 'social_message',
    case v_intent when 'human' then v_label || ': ' || coalesce(v_name, 'someone') || ' wants a person' when 'complaint' then v_label || ' complaint from ' || coalesce(v_name, 'a customer')
      else 'New ' || v_label || ' message' || coalesce(' from ' || v_name, '') end,
    left(v_text, 300), case when v_intent in ('human', 'complaint') then 'urgent' else 'info' end, 'inbox');

  if c.qualify_flow then
    begin
      v_flow := public.zella_social_flow(v_conv, v_text, v_intent);
    exception when others then v_flow := null; end;
    if v_flow is not null then
      insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, conversation_id)
      values (e.business_id, e.page_id, v_ch, 'message', v_sender, v_flow, v_conv);
      update public.meta_contacts set last_ack_at = now() where id = v_contact.id;
    end if;
  end if;
  if v_flow is null and c.auto_acknowledge and (v_contact.last_ack_at is null or v_contact.last_ack_at < now() - interval '24 hours')
     and not exists (select 1 from public.conversation_messages m where m.conversation_id = v_conv and m.sender_type = 'agent') then
    insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, conversation_id)
    values (e.business_id, e.page_id, v_ch, 'message', v_sender, 'Thanks for messaging ' || v_biz || '! We have your message and the team will reply soon.', v_conv);
    update public.meta_contacts set last_ack_at = now() where id = v_contact.id;
  end if;

  update public.meta_events set status = 'done' where id = p_event_id;
  return 'processed:' || v_intent;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_receive(p_raw text, p_signature text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_secret text; j jsonb; en jsonb; ch jsonb; msg jsonb; v_obj text; v_id uuid; v_conn public.meta_connections%rowtype; v_val jsonb;
  n_leads integer := 0; n_msgs integer := 0; v_key text; v_from text; v_name text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_meta_app_secret' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('result', 'not_configured'); end if;
  if p_signature is null or p_raw is null or
     encode(sha256(convert_to(p_signature, 'utf8')), 'hex') <> encode(sha256(convert_to('sha256=' || encode(hmac(convert_to(p_raw, 'utf8'), convert_to(v_secret, 'utf8'), 'sha256'), 'hex'), 'utf8')), 'hex') then
    return jsonb_build_object('result', 'unauthorized');
  end if;
  begin j := p_raw::jsonb; exception when others then return jsonb_build_object('result', 'ignored'); end;
  v_obj := j ->> 'object';
  if v_obj not in ('page', 'instagram', 'whatsapp_business_account') or jsonb_typeof(j -> 'entry') <> 'array' then return jsonb_build_object('result', 'ignored'); end if;

  for en in select * from jsonb_array_elements(j -> 'entry') loop
    v_conn := null;
    if v_obj = 'whatsapp_business_account' then
      select * into v_conn from public.meta_connections where status <> 'disconnected' and (waba_id = en ->> 'id'
         or whatsapp_phone_id in (select x #>> '{value,metadata,phone_number_id}' from jsonb_array_elements(coalesce(en -> 'changes', '[]'::jsonb)) x)) limit 1;
    else
      select * into v_conn from public.meta_connections where status <> 'disconnected' and (page_id = en ->> 'id' or instagram_id = en ->> 'id') limit 1;
    end if;
    if v_conn.id is null then continue; end if;

    for msg in select * from jsonb_array_elements(case when jsonb_typeof(en -> 'messaging') = 'array' then en -> 'messaging' else '[]'::jsonb end) loop
      if msg #>> '{message,mid}' is null or coalesce((msg #>> '{message,is_echo}')::boolean, false) then continue; end if;
      v_from := msg #>> '{sender,id}';
      if v_from is null or v_from in (v_conn.page_id, coalesce(v_conn.instagram_id, '-')) then continue; end if;
      v_key := 'msg:' || (msg #>> '{message,mid}');
      v_id := null;
      insert into public.meta_events (event_key, kind, page_id, business_id, payload)
      values (v_key, 'message', v_conn.page_id, v_conn.business_id, jsonb_build_object('channel', case when v_obj = 'instagram' then 'instagram' else 'messenger' end,
              'sender_id', v_from, 'text', left(coalesce(msg #>> '{message,text}', ''), 2000), 'message_id', msg #>> '{message,mid}'))
      on conflict (event_key) do nothing returning id into v_id;
      if v_id is not null then
        begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
        exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
      end if;
    end loop;

    for ch in select * from jsonb_array_elements(case when jsonb_typeof(en -> 'changes') = 'array' then en -> 'changes' else '[]'::jsonb end) loop
      v_val := case when jsonb_typeof(ch -> 'value') = 'object' then ch -> 'value' else '{}'::jsonb end;
      v_id := null;
      if ch ->> 'field' = 'leadgen' and v_val ->> 'leadgen_id' ~ '^[0-9]{5,30}$' then
        insert into public.meta_events (event_key, kind, page_id, business_id, payload)
        values ('lead:' || (v_val ->> 'leadgen_id'), 'lead', v_conn.page_id, v_conn.business_id,
                jsonb_build_object('leadgen_id', v_val ->> 'leadgen_id', 'form_id', v_val ->> 'form_id', 'ad_id', v_val ->> 'ad_id', 'adgroup_id', v_val ->> 'adgroup_id',
                                   'platform', case when v_obj = 'instagram' then 'instagram' else 'facebook' end))
        on conflict (event_key) do nothing returning id into v_id;
        if v_id is not null then n_leads := n_leads + 1; end if;
      elsif ch ->> 'field' = 'feed' and v_val ->> 'item' = 'comment' and v_val ->> 'verb' = 'add' and v_val ->> 'comment_id' is not null then
        insert into public.meta_events (event_key, kind, page_id, business_id, payload)
        values ('comment:' || (v_val ->> 'comment_id'), 'comment', v_conn.page_id, v_conn.business_id,
                jsonb_build_object('comment_id', v_val ->> 'comment_id', 'text', left(coalesce(v_val ->> 'message', ''), 1000), 'from_id', v_val #>> '{from,id}',
                                   'from_page', (v_val #>> '{from,id}') = v_conn.page_id, 'platform', 'facebook'))
        on conflict (event_key) do nothing returning id into v_id;
        if v_id is not null then
          begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
          exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
        end if;
      elsif ch ->> 'field' = 'comments' and v_val ->> 'id' is not null then
        insert into public.meta_events (event_key, kind, page_id, business_id, payload)
        values ('comment:' || (v_val ->> 'id'), 'comment', v_conn.page_id, v_conn.business_id,
                jsonb_build_object('comment_id', v_val ->> 'id', 'text', left(coalesce(v_val ->> 'text', ''), 1000), 'from_id', v_val #>> '{from,id}',
                                   'from_page', (v_val #>> '{from,id}') = coalesce(v_conn.instagram_id, '-'), 'platform', 'instagram'))
        on conflict (event_key) do nothing returning id into v_id;
        if v_id is not null then
          begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
          exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
        end if;
      elsif ch ->> 'field' = 'messages' and jsonb_typeof(v_val -> 'messages') = 'array' then
        for msg in select * from jsonb_array_elements(v_val -> 'messages') loop
          if msg ->> 'id' is null or msg ->> 'from' is null then continue; end if;
          v_name := null; v_id := null;
          select c2 #>> '{profile,name}' into v_name from jsonb_array_elements(coalesce(v_val -> 'contacts', '[]'::jsonb)) c2 where c2 ->> 'wa_id' = msg ->> 'from' limit 1;
          insert into public.meta_events (event_key, kind, page_id, business_id, payload)
          values ('msg:' || (msg ->> 'id'), 'message', v_conn.page_id, v_conn.business_id,
                  jsonb_build_object('channel', 'whatsapp', 'sender_id', msg ->> 'from', 'sender_name', v_name, 'phone', '+' || regexp_replace(msg ->> 'from', '[^0-9]', '', 'g'),
                                     'text', case when msg ->> 'type' = 'text' then left(coalesce(msg #>> '{text,body}', ''), 2000) else '' end, 'message_id', msg ->> 'id'))
          on conflict (event_key) do nothing returning id into v_id;
          if v_id is not null then
            begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
            exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
          end if;
        end loop;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('result', 'ok', 'leads', n_leads, 'messages', n_msgs);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_record_check(p_page_id text, p_ok boolean, p_permissions text[] DEFAULT NULL::text[], p_auth_failed boolean DEFAULT false, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.meta_connections%rowtype; v_missing text[]; v_need text[] := array['pages_messaging','pages_show_list','leads_retrieval','pages_manage_metadata','pages_read_engagement'];
begin
  select * into c from public.meta_connections where page_id = p_page_id;
  if not found then return; end if;
  if p_ok then
    update public.meta_connections set status = 'connected', last_error = null, last_checked_at = now(), granted_permissions = coalesce(p_permissions, granted_permissions) where id = c.id;
    perform public.zella_resolve_platform_alerts('meta_disconnected', c.business_id, p_page_id, 'Connection works again');
    if p_permissions is not null then
      select array_agg(x) into v_missing from unnest(v_need) x where not (x = any (p_permissions));
      if v_missing is not null then
        perform public.zella_platform_alert('meta_permissions_missing', 'Facebook/Instagram access is missing permissions', 'Missing: ' || array_to_string(v_missing, ', '), 'warning', c.business_id, p_page_id);
        perform public.zella_notify_owners(c.business_id, 'meta_permissions_missing', 'Facebook/Instagram needs more access', 'Reconnect your page and approve all the requested permissions so leads and messages keep working.', 'warning', 'integrations');
      else
        perform public.zella_resolve_platform_alerts('meta_permissions_missing', c.business_id, p_page_id, 'All permissions granted');
      end if;
    end if;
  elsif p_auth_failed then
    update public.meta_connections set status = 'needs_reconnect', last_error = left(coalesce(p_error, 'access token rejected'), 200), last_checked_at = now() where id = c.id;
    if c.status <> 'needs_reconnect' then
      perform public.zella_platform_alert('meta_disconnected', 'Facebook/Instagram needs to be reconnected', left(coalesce(p_error, 'access token rejected'), 200), 'urgent', c.business_id, p_page_id);
      perform public.zella_notify_owners(c.business_id, 'meta_disconnected', 'Reconnect Facebook/Instagram', 'Zella lost access to your page, so new leads and messages are not coming in. Reconnect it in Settings > Integrations.', 'urgent', 'integrations');
    end if;
  else
    update public.meta_connections set status = 'error', last_error = left(coalesce(p_error, 'unknown'), 200), last_checked_at = now(), next_check_at = now() + interval '30 minutes' where id = c.id;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_record_send(p_id uuid, p_ok boolean, p_external_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_auth_failed boolean DEFAULT false, p_retry boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.meta_outbox%rowtype;
begin
  select * into o from public.meta_outbox where id = p_id;
  if not found then return; end if;
  if p_ok then
    update public.meta_outbox set status = 'sent', external_id = left(p_external_id, 200), last_error = null where id = p_id;
  elsif p_retry and o.attempts < 4 then
    update public.meta_outbox set status = 'queued', last_error = left(coalesce(p_error, 'error'), 200), next_try_at = now() + (power(2, o.attempts) * 2 || ' minutes')::interval where id = p_id;
  else
    update public.meta_outbox set status = 'failed', last_error = left(coalesce(p_error, 'error'), 200) where id = p_id;
    if p_auth_failed then
      perform public.zella_meta_record_check(o.page_id, false, null, true, left(p_error, 200));
    else
      perform public.zella_platform_alert('meta_send_failed', 'A Facebook, Instagram or WhatsApp reply could not be sent', left(coalesce(p_error, 'error'), 200), 'warning', o.business_id, 'meta_send_failed:' || o.business_id::text);
    end if;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_record_templates(p_page_id text, p_templates jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.meta_connections%rowtype; t jsonb; n integer := 0;
begin
  select * into c from public.meta_connections where page_id = p_page_id;
  if not found or jsonb_typeof(p_templates) <> 'array' then return 0; end if;
  for t in select * from jsonb_array_elements(p_templates) loop
    continue when nullif(t ->> 'name', '') is null;
    insert into public.meta_templates (business_id, name, language, category, body, status, synced_at)
    values (c.business_id, left(t ->> 'name', 100), coalesce(nullif(t ->> 'language', ''), 'en_US'), left(t ->> 'category', 40), left(t ->> 'body', 1024), lower(coalesce(t ->> 'status', 'unknown')), now())
    on conflict (business_id, name, language) do update set category = excluded.category, body = excluded.body, status = excluded.status, synced_at = now();
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_set_flow(p_business_id uuid, p_page_id text, p_enabled boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.meta_connections set qualify_flow = coalesce(p_enabled, false) where business_id = p_business_id and page_id = p_page_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_settings(p_business_id uuid, p_page_id text, p_call_consent boolean DEFAULT NULL::boolean, p_auto_ack boolean DEFAULT NULL::boolean, p_keywords text[] DEFAULT NULL::text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.meta_connections set
      call_consent_confirmed = coalesce(p_call_consent, call_consent_confirmed),
      auto_acknowledge = coalesce(p_auto_ack, auto_acknowledge),
      comment_keywords = coalesce((select array_agg(lower(trim(k))) filter (where length(trim(k)) between 2 and 40) from unnest(p_keywords) k), comment_keywords)
   where business_id = p_business_id and page_id = p_page_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_staff_reply(p_conversation_id uuid, p_text text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cv public.conversations%rowtype; ct public.meta_contacts%rowtype; c public.meta_connections%rowtype; v_id uuid; v_txt text := left(trim(coalesce(p_text, '')), 1000);
begin
  select * into cv from public.conversations where id = p_conversation_id;
  if not found or not public.zella_has_role(cv.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if cv.channel not in ('messenger','instagram','whatsapp') then raise exception 'NOT_A_SOCIAL_CONVERSATION'; end if;
  if length(v_txt) < 1 then raise exception 'EMPTY'; end if;
  select * into ct from public.meta_contacts where conversation_id = cv.id limit 1;
  select * into c from public.meta_connections where business_id = cv.business_id and status = 'connected' order by created_at limit 1;
  if ct.id is null or c.id is null then raise exception 'NOT_CONNECTED'; end if;
  if cv.last_inbound_at is null or cv.last_inbound_at < now() - interval '24 hours' then
    raise exception '%', case when cv.channel = 'whatsapp' then 'TEMPLATE_REQUIRED' else 'WINDOW_CLOSED' end;
  end if;
  insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, conversation_id)
  values (cv.business_id, c.page_id, cv.channel, 'message', ct.external_id, v_txt, cv.id) returning id into v_id;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, metadata)
  values (cv.id, 'agent', 'text', v_txt, jsonb_build_object('channel', cv.channel, 'user_id', auth.uid()));
  update public.conversations set assigned_to = coalesce(assigned_to, auth.uid()), ai_handled = false, handover_at = coalesce(handover_at, now()), updated_at = now() where id = cv.id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_staff_template(p_conversation_id uuid, p_template_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cv public.conversations%rowtype; ct public.meta_contacts%rowtype; c public.meta_connections%rowtype; t public.meta_templates%rowtype; v_id uuid;
begin
  select * into cv from public.conversations where id = p_conversation_id;
  if not found or not public.zella_has_role(cv.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if cv.channel <> 'whatsapp' then raise exception 'NOT_A_WHATSAPP_CONVERSATION'; end if;
  select * into t from public.meta_templates where business_id = cv.business_id and name = p_template_name and upper(status) = 'APPROVED' order by synced_at desc limit 1;
  if t.id is null then raise exception 'TEMPLATE_NOT_APPROVED'; end if;
  if t.body is null or t.body ~ '\{\{' or t.name !~ '^[a-z0-9_]{1,200}$' or t.language !~ '^[a-z]{2}(_[A-Z]{2})?$' then raise exception 'TEMPLATE_HAS_VALUES'; end if;
  select * into ct from public.meta_contacts where conversation_id = cv.id limit 1;
  select * into c from public.meta_connections where business_id = cv.business_id and status = 'connected' order by created_at limit 1;
  if ct.id is null or c.id is null then raise exception 'NOT_CONNECTED'; end if;
  insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, template_name, template_language, conversation_id)
  values (cv.business_id, c.page_id, 'whatsapp', 'template', ct.external_id, left(t.body, 1000), t.name, t.language, cv.id) returning id into v_id;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, metadata)
  values (cv.id, 'agent', 'text', left(t.body, 1000), jsonb_build_object('channel', 'whatsapp', 'template', t.name, 'user_id', auth.uid()));
  update public.conversations set assigned_to = coalesce(assigned_to, auth.uid()), ai_handled = false, handover_at = coalesce(handover_at, now()), updated_at = now() where id = cv.id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_status(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('page_id', page_id, 'page_name', page_name, 'instagram', instagram_id is not null, 'whatsapp', whatsapp_phone_id is not null,
    'status', status, 'permissions', granted_permissions, 'call_consent_confirmed', call_consent_confirmed, 'auto_acknowledge', auto_acknowledge,
    'comment_keywords', comment_keywords, 'last_checked_at', last_checked_at, 'last_error', last_error) order by created_at) from public.meta_connections where business_id = p_business_id), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_store_connection(p_business_id uuid, p_page_id text, p_page_name text, p_token text, p_instagram_id text DEFAULT NULL::text, p_whatsapp_phone_id text DEFAULT NULL::text, p_waba_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text := 'meta_token_' || p_page_id; v_id uuid; v_exist uuid;
begin
  if p_page_id !~ '^[0-9]{5,30}$' or coalesce(length(p_token), 0) < 20 then raise exception 'BAD_INPUT'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and cancelled_at is null) then raise exception 'UNKNOWN_BUSINESS'; end if;
  if exists (select 1 from public.meta_connections where page_id = p_page_id and business_id <> p_business_id and status <> 'disconnected') then raise exception 'PAGE_IN_USE'; end if;
  select id into v_exist from vault.secrets where name = v_name;
  if v_exist is null then perform vault.create_secret(p_token, v_name); else perform vault.update_secret(v_exist, p_token, v_name); end if;
  insert into public.meta_connections (business_id, page_id, page_name, instagram_id, whatsapp_phone_id, waba_id, token_secret, status, last_error, next_check_at)
  values (p_business_id, p_page_id, left(p_page_name, 200), nullif(p_instagram_id, ''), nullif(p_whatsapp_phone_id, ''), nullif(p_waba_id, ''), v_name, 'connected', null, now())
  on conflict (page_id) do update set business_id = excluded.business_id, page_name = excluded.page_name, instagram_id = excluded.instagram_id,
     whatsapp_phone_id = excluded.whatsapp_phone_id, waba_id = excluded.waba_id, token_secret = excluded.token_secret, status = 'connected', last_error = null, next_check_at = now()
  returning id into v_id;
  perform public.zella_resolve_platform_alerts('meta_disconnected', p_business_id, p_page_id, 'Reconnected');
  return v_id;
end $function$
;
