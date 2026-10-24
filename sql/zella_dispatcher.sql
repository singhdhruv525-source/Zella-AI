-- Zella - the dispatcher. Safe to run more than once.
-- Needs zella_message_types.sql, zella_staff_sms.sql, zella_ops_automation.sql, zella_retention.sql (team summary, spot checks, reconcile), zella_website_crawler.sql (website lane) and zella_meta.sql (meta lanes) run first.
-- WHY: n8n Cloud's Starter plan allows 2,500 workflow runs a month, and a workflow that wakes up every
-- minute uses ~43,000. So the timer now lives in Supabase (free), and n8n is only called when there is
-- something waiting. Two parts:
--   1. Timed database jobs (overdue leads, daily summary, weekly review ...) run inside Supabase with pg_cron.
--      They no longer need n8n at all.
--   2. Every minute a cheap check asks "is any reminder, follow-up, email or event due?". Only if yes, it
--      calls the matching n8n workflow, which then does the sending exactly as before.
-- Run this AFTER the other Zella SQL files (including zella_callback_alerts.sql). Then do the one-time secret step at the bottom.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- 1. Settings and a little bookkeeping so a stuck item can never make n8n run every minute forever.
insert into public.platform_settings (key, value) values ('n8n_base_url', '"https://dhruvsingh.app.n8n.cloud"'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('n8n_dispatch_enabled', 'true'::jsonb) on conflict (key) do nothing;

create table if not exists public.n8n_dispatch_state (
  workflow text primary key,
  last_triggered_at timestamptz,
  last_count integer not null default 0,
  consecutive_same integer not null default 0,
  triggers_total bigint not null default 0
);
alter table public.n8n_dispatch_state enable row level security;
revoke all on public.n8n_dispatch_state from anon, authenticated;

-- 2. Timed database jobs, run inside Supabase. A job that fails raises one grouped platform alert.
create or replace function public.zella_run_scheduled_job(p_job text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_job not in ('zella_flag_overdue_leads', 'zella_expire_holds', 'zella_expire_waitlist_offers', 'zella_detect_transfer_failures',
                   'zella_queue_quote_followups', 'zella_post_daily_summaries', 'zella_queue_lead_reactivation',
                   'zella_check_setup_incomplete', 'zella_check_trials', 'zella_apply_payment_policy', 'zella_post_weekly_reviews',
                   'zella_flag_overdue_callbacks', 'zella_sweep_stuck_calls', 'zella_check_engine_health', 'zella_schedule_calendar_pulls',
                   'zella_rebalance_assignments', 'zella_check_unassigned_work', 'zella_check_customer_requests', 'zella_queue_customer_touches', 'zella_check_kpis', 'zella_check_escalation_acks', 'zella_recover_orphaned_work', 'zella_check_renewals', 'zella_post_callback_digests', 'zella_check_connections', 'zella_post_team_summaries', 'zella_sample_ai_responses', 'zella_reconcile', 'zella_retention_scan', 'zella_recover_failed_texts') then
    return 'not_allowed';
  end if;
  begin
    execute format('select public.%I(%s)', p_job, case when p_job = 'zella_queue_lead_reactivation' then '200' else '' end);
    return 'ok';
  exception when others then
    perform public.zella_platform_alert('scheduler_failed', 'Scheduled job failed: ' || p_job, 'The database job ' || p_job || ' failed.', 'warning', null, p_job,
                                        jsonb_build_object('job', p_job, 'sqlstate', sqlstate));
    return 'failed';
  end;
end $$;

create or replace function public.zella_run_schedule_group(p_group text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j text; r jsonb := '{}'::jsonb;
begin
  for j in select unnest(case p_group
      when 'every5'  then array['zella_flag_overdue_leads', 'zella_expire_holds', 'zella_expire_waitlist_offers', 'zella_detect_transfer_failures', 'zella_flag_overdue_callbacks', 'zella_sweep_stuck_calls', 'zella_check_engine_health', 'zella_rebalance_assignments', 'zella_check_unassigned_work', 'zella_check_escalation_acks']
      when 'every15' then array['zella_queue_quote_followups', 'zella_recover_orphaned_work']
      when 'hourly'  then array['zella_post_daily_summaries', 'zella_schedule_calendar_pulls', 'zella_check_customer_requests', 'zella_post_callback_digests', 'zella_post_team_summaries', 'zella_recover_failed_texts']
      when 'daily'   then array['zella_queue_lead_reactivation', 'zella_check_setup_incomplete', 'zella_check_trials', 'zella_apply_payment_policy', 'zella_queue_customer_touches', 'zella_check_kpis', 'zella_check_renewals', 'zella_check_connections', 'zella_sample_ai_responses', 'zella_reconcile', 'zella_retention_scan']
      when 'weekly'  then array['zella_post_weekly_reviews']
      else array[]::text[] end) loop
    r := r || jsonb_build_object(j, public.zella_run_scheduled_job(j));
  end loop;
  return r;
end $$;

-- 3. The dispatcher. Counts what is due for each n8n workflow and calls it only when something is waiting.
--    The kind lists below must match the lists in n8n/src/build.mjs (a test checks this).
create or replace function public.zella_dispatch_n8n()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_base text := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '');
  v_on boolean := coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
  v_secret text; w record; n integer; st public.n8n_dispatch_state; v_same integer; v_res jsonb := '{}'::jsonb;
  v_text_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'reply_confirmed', 'reply_reschedule', 'reply_help', 'waitlist_offer'];
  v_email_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up'];
begin
  if not v_on then return jsonb_build_object('skipped', 'switched_off'); end if;
  if v_base is null then return jsonb_build_object('skipped', 'no_base_url'); end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_n8n_secret' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('skipped', 'no_secret'); end if;

  for w in select * from (values ('event-router'), ('sms-sender'), ('email-sender'), ('followup-texts'), ('followup-emails'), ('owner-emails'), ('outbound-calls'), ('knowledge-sync'), ('calendar-sync'), ('connection-tests'), ('meta-leads'), ('meta-sender'), ('meta-health'), ('website-crawl'), ('staff-sms')) as t(name) loop
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
    -- n8n was only just called: give it a few seconds to pick the work up before calling again.
    if st.last_triggered_at > now() - interval '8 seconds' then continue; end if;
    -- Same amount waiting after many calls in a row (about two minutes) means n8n is not clearing it: slow down to once per 15 minutes.
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
end $$;

-- 4. Only the service role (and the scheduler, which runs as the database owner) may call these.
do $$
declare f text;
begin
  foreach f in array array['zella_run_scheduled_job(text)', 'zella_run_schedule_group(text)', 'zella_dispatch_n8n()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- 5. The timers (UTC). Re-running this file replaces them, it does not duplicate them.
-- Event-driven first: saving anything urgent calls the dispatcher at once (section 5). This once-a-minute run is only a
-- safety net for work that becomes due later (a reminder at 3 pm) and for retries.
select cron.schedule('zella_dispatch',        '* * * * *',    $$select public.zella_dispatch_n8n()$$);
select cron.schedule('zella_jobs_every5',     '*/5 * * * *',  $$select public.zella_run_schedule_group('every5')$$);
select cron.schedule('zella_jobs_every15',    '*/15 * * * *', $$select public.zella_run_schedule_group('every15')$$);
select cron.schedule('zella_jobs_hourly',     '0 * * * *',    $$select public.zella_run_schedule_group('hourly')$$);
select cron.schedule('zella_jobs_daily',      '0 4 * * *',    $$select public.zella_run_schedule_group('daily')$$);
select cron.schedule('zella_jobs_weekly',     '0 8 * * 1',    $$select public.zella_run_schedule_group('weekly')$$);
select cron.schedule('zella_cron_cleanup',    '30 3 * * *',   $$delete from cron.job_run_details where end_time < now() - interval '3 days'$$);

-- ONE-TIME STEP (do this yourself, never paste the secret into chat):
-- Store the same secret you gave the n8n credential "Zella gateway secret". Replace PASTE_YOUR_SECRET, run it once:
--   select vault.create_secret('PASTE_YOUR_SECRET', 'zella_n8n_secret');
-- To change it later:
--   select vault.update_secret((select id from vault.secrets where name = 'zella_n8n_secret'), 'NEW_SECRET');


-- 5. Act at once: when something urgent is saved, call the dispatcher right away instead of waiting for the next
--    10-second tick. At most one kick every 2 seconds.
create or replace function public.zella_kick_dispatch()
returns trigger language plpgsql security definer set search_path = public as $$
declare st public.n8n_dispatch_state;
begin
  if tg_table_name = 'followup_tasks' and new.due_at > now() + interval '5 seconds' then return new; end if;
  insert into public.n8n_dispatch_state (workflow) values ('_kick') on conflict do nothing;
  update public.n8n_dispatch_state set last_triggered_at = now()
   where workflow = '_kick' and (last_triggered_at is null or last_triggered_at < now() - interval '2 seconds');
  if found then perform public.zella_dispatch_n8n(); end if;
  return new;
exception when others then
  return new;   -- a dispatch problem must never block saving the row
end $$;
do $$
declare t text;
begin
  foreach t in array array['automation_events', 'followup_tasks', 'staff_notifications', 'appointment_reminders', 'meta_events', 'meta_outbox', 'website_pages', 'website_sources'] loop
    execute format('drop trigger if exists zella_kick_dispatch on public.%I', t);
    execute format('create trigger zella_kick_dispatch after insert on public.%I for each row execute function public.zella_kick_dispatch()', t);
  end loop;
end $$;
