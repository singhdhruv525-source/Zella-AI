-- Zella Voice: one weekly platform summary for Zella Voice admins (docs/ADMIN_AUDIT_2026-11-16.md ACC-25, build checklist
-- "Scheduled reports and report permissions"). The owner's decision, 16 Nov 2026:
--   * one report, weekly, for the whole platform (not per business; business daily reports are zella_report_schedules.sql);
--   * delivered as an in app admin notification now, and in the admin email digest only once email is live;
--   * readable with a new permission, reports.view, which zella_owner and super_admin have by default (zella_admin_can
--     already gives them every permission but admins.manage and roles.manage); a restricted role gets it only when the
--     owner ticks it in Settings, Platform roles (the edge function's permission catalog lists it).
--
-- What it does
--   * platform_report_runs: one row per report and week (unique on kind and week start), so a second run, a retry or two
--     overlapping runs in the same week make one report, never two. Server only (row security on, no policies, no grants
--     to signed in users); admins read it through zella_admin_weekly_reports.
--   * zella_platform_weekly_summary(from, to): the figures for one week. Counts only, no names, numbers or messages:
--     new businesses, live businesses, calls, missed calls, texts sent and received, open platform alerts, support tickets
--     (opened that week and still open) and failed automation runs. Each definition is in the function below and is
--     shown under its figure in Settings.
--   * zella_post_weekly_platform_report(now): the job. It reports the last complete week, Monday 00:00 to Monday 00:00
--     UTC, once. It does not catch up older weeks: a week the job missed (for example while the weekly job is off) has
--     no report. After saving the report it raises one platform alert (kind weekly_report, severity info) that says the
--     report is ready and where to read it, without any figure, because every platform admin sees the alerts bell and the
--     email digest while only reports.view may read the figures. Earlier weeks' report alerts are resolved, so the
--     bell and the digest carry only the latest one. The digest (zella_admin_alerts.sql) sends open alerts only while
--     email_live is on and a sender is set, so the report reaches email only once email is live; nothing changes there.
--   * zella_admin_weekly_reports(limit): the latest reports for Settings, Reporting configuration, with the schedule's
--     state (whether the weekly job is switched on, when it runs next, whether email is live). Needs reports.view.
--   * Adds itself to zella_run_scheduled_job's allowed list and to zella_run_schedule_group('weekly') with
--     zella_patch_function. Both functions are archived first and must be a version this file was written for (md5),
--     otherwise VERSION_MISMATCH and nothing changes.
--
-- It runs only once the weekly job zella_jobs_weekly (Mondays 08:00 UTC) is switched on, which is the owner's switch; it
-- is off in production. Nothing here sends a message by itself.
-- Production md5s: computed on the isolated copy (zprod3 + zella_writing_cleanup.sql + the merged, unapplied migrations
-- in docs/SCHEMA_STATUS.md); production md5s to be confirmed by the supervisor before applying.
-- Rollback: sql/rollback/zella_weekly_platform_report_rollback.sql
begin;

do $$
declare job constant text := 'public.zella_run_scheduled_job(text)'; grp constant text := 'public.zella_run_schedule_group(text)'; d text;
begin
  if to_regprocedure(job) is null or to_regprocedure(grp) is null
     or to_regclass('public.zella_function_archive') is null or to_regprocedure('public.zella_patch_function(text,text,text,text)') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null
     or to_regprocedure('public.zella_admin_require(text)') is null or to_regprocedure('public.zella_setting(text,jsonb)') is null
     or to_regclass('public.platform_alerts') is null or to_regclass('public.support_tickets') is null or to_regclass('public.automation_runs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(job::regprocedure);
  if md5(d) = '671ec3ca5b53cc2d660f054b837d67d1' then                      -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_weekly_platform_report', job, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> '36a6c80d11d36e6d2f0c7a0f90af716b' then                                       -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', job;
  end if;
  d := pg_get_functiondef(grp::regprocedure);
  if md5(d) in ('78b7fdfea58e49d1dfb594e7acc9b808',                          -- production's version
                '5a9bc8c34841edd1ad3d66ff4156a006') then                     -- the same with zella_cancellations_scheduled.sql
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_weekly_platform_report', grp, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) not in ('7a0efdaefe88a79b7ebb828a573d7120', '7e119dba5056dde8ffa8247419743808') then                                 -- nor this file's version over one of them
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', grp;
  end if;
end $$;

-- 1. One row per report and week ----------------------------------------------------------------------------------------
create table if not exists public.platform_report_runs (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'weekly_platform_summary' check (kind in ('weekly_platform_summary')),
  period_start date not null,                     -- the Monday the week starts (UTC)
  period_end date not null,                       -- the Sunday it ends (UTC)
  summary jsonb not null,
  alert_id uuid,                                  -- the platform alert that told admins it is ready
  created_at timestamptz not null default now(),
  unique (kind, period_start),
  check (period_end = period_start + 6)
);
alter table public.platform_report_runs enable row level security;
revoke all on public.platform_report_runs from public, anon, authenticated;
grant select, insert, update, delete on public.platform_report_runs to service_role;

-- 2. The figures for one week (counts only) ------------------------------------------------------------------------------
create or replace function public.zella_platform_weekly_summary(p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    -- businesses created in the week, whatever their setup stage
    'new_businesses', (select count(*) from businesses where created_at >= p_from and created_at < p_to),
    -- live when the report ran: setup finished (active), switched on, not suspended, not cancelled
    'live_businesses', (select count(*) from businesses where onboarding_status = 'active' and coalesce(is_active, false)
                          and suspended_at is null and cancelled_at is null),
    -- every call, both directions; missed is the call's own status
    'calls', (select count(*) from calls where created_at >= p_from and created_at < p_to),
    'missed_calls', (select count(*) from calls where created_at >= p_from and created_at < p_to and status = 'missed'),
    -- texts that reached the provider (sent or delivered), and texts received; test mode and blocked texts are not counted
    'texts_sent', (select count(*) from sms_messages where created_at >= p_from and created_at < p_to and direction = 'outbound' and status in ('sent', 'delivered')),
    'texts_received', (select count(*) from sms_messages where created_at >= p_from and created_at < p_to and direction = 'inbound'),
    -- platform alerts open when the report ran (the weekly report's own alert is not counted)
    'open_alerts', (select count(*) from platform_alerts where status = 'open' and kind <> 'weekly_report'),
    'urgent_alerts', (select count(*) from platform_alerts where status = 'open' and kind <> 'weekly_report' and severity = 'urgent'),
    -- support tickets opened in the week, and all tickets still open or in progress when the report ran
    'tickets_opened', (select count(*) from support_tickets where created_at >= p_from and created_at < p_to),
    'tickets_open', (select count(*) from support_tickets where status in ('open', 'in_progress')),
    -- automation runs that failed, started in the week
    'failed_automations', (select count(*) from automation_runs where created_at >= p_from and created_at < p_to and status = 'failed'));
$$;

-- 3. The job: the last complete week, once --------------------------------------------------------------------------------
create or replace function public.zella_post_weekly_platform_report(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_start date := (date_trunc('week', p_now at time zone 'UTC'))::date - 7;   -- the Monday of the last complete week
  v_from timestamptz := v_start::timestamp at time zone 'UTC';
  v_id uuid; v_alert uuid;
begin
  insert into platform_report_runs (kind, period_start, period_end, summary)
  values ('weekly_platform_summary', v_start, v_start + 6, public.zella_platform_weekly_summary(v_from, v_from + interval '7 days'))
  on conflict (kind, period_start) do nothing
  returning id into v_id;
  if v_id is null then return 0; end if;          -- this week's report already exists (a second run, or one running now)
  v_alert := public.zella_platform_alert('weekly_report', 'The weekly platform report is ready',
    format('Week of %s to %s. Read it in Settings, Analytics and reporting, Reporting configuration.',
           to_char(v_start, 'FMMonth FMDD'), to_char(v_start + 6, 'FMMonth FMDD, YYYY')),
    'info', null, v_start::text, jsonb_build_object('report_id', v_id, 'period_start', v_start));
  update platform_report_runs set alert_id = v_alert where id = v_id;
  -- earlier weeks' report alerts are resolved, so the bell and the email digest carry only the latest one
  update platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Replaced by the next weekly report.'
   where kind = 'weekly_report' and status <> 'resolved' and business_id is null and dedupe_key < v_start::text;
  return 1;
end $$;

-- 4. Settings, Reporting configuration (reports.view) ---------------------------------------------------------------------
create or replace function public.zella_admin_weekly_reports(p_limit integer default 12) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_job boolean; v_found boolean := false; v_next timestamptz;
begin
  perform public.zella_admin_require('reports.view');
  begin
    execute $q$select bool_or(active), count(*) > 0 from cron.job where jobname = 'zella_jobs_weekly'$q$ into v_job, v_found;
  exception when others then v_job := null; v_found := false;      -- no scheduler here: say so rather than guess
  end;
  if coalesce(v_job, false) then                                   -- Mondays 08:00 UTC (zella_dispatcher.sql)
    v_next := (date_trunc('week', now() at time zone 'UTC') + interval '8 hours') at time zone 'UTC';
    if v_next <= now() then v_next := v_next + interval '7 days'; end if;
  end if;
  return jsonb_build_object(
    'reports', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'period_start', r.period_start, 'period_end', r.period_end,
                          'summary', r.summary, 'created_at', r.created_at, 'notified', r.alert_id is not null) order by r.period_start desc)
                         from (select * from platform_report_runs where kind = 'weekly_platform_summary'
                               order by period_start desc limit greatest(1, least(coalesce(p_limit, 12), 52))) r), '[]'::jsonb),
    'schedule', jsonb_build_object('job', 'zella_jobs_weekly', 'job_found', v_found, 'job_on', coalesce(v_job, false), 'next_run_at', v_next,
                  'email_live', coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false)
                                and nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '') is not null));
end $$;

revoke all on function public.zella_platform_weekly_summary(timestamptz, timestamptz), public.zella_post_weekly_platform_report(timestamptz)
  from public, anon, authenticated;
grant execute on function public.zella_platform_weekly_summary(timestamptz, timestamptz), public.zella_post_weekly_platform_report(timestamptz) to service_role;
revoke all on function public.zella_admin_weekly_reports(integer) from public, anon;
grant execute on function public.zella_admin_weekly_reports(integer) to authenticated, service_role;

-- 5. The weekly job list (Mondays 08:00 UTC, zella_jobs_weekly) -----------------------------------------------------------
do $$ declare r text; begin
  r := public.zella_patch_function('public.zella_run_scheduled_job(text)', $t$'zella_post_weekly_platform_report'$t$,
         $t$'zella_team_scorecard_nudge') then$t$, $t$'zella_team_scorecard_nudge', 'zella_post_weekly_platform_report') then$t$);
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_run_scheduled_job (%)', r; end if;
  r := public.zella_patch_function('public.zella_run_schedule_group(text)', $t$'zella_post_weekly_platform_report'$t$,
         $t$'zella_send_gap_reports']$t$, $t$'zella_send_gap_reports', 'zella_post_weekly_platform_report']$t$);
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_run_schedule_group (%)', r; end if;
end $$;

commit;
