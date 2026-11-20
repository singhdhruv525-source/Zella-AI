-- Zella Voice: each scheduled job's intended state, recorded next to its real state (docs/ADMIN_AUDIT_2026-11-16.md
-- PLT-07). zella_admin_scheduler_health listed every zella% cron job as on or off, but nothing said whether a job was
-- off on purpose, and nothing said what a job drives, so a bare "Off" read the same as a fault.
--   1. A server only table, scheduled_job_intents: one row per job with the intended state (on or off), the reason,
--      who recorded it and when. Row security on, no policies, no grants to signed in people.
--   2. The jobs the owner decides on before go live (zella_dispatch, the every 5, every 15, hourly, daily and weekly
--      jobs, zella_cron_cleanup, zella_platform_emails, zella_spam_hourly) are recorded as "deliberately off until go
--      live" (the recommended answer in plan.owner_decisions PLT-07). Existing rows are never overwritten.
--   3. zella_admin_job_intent_save(job, intended, reason): platform.configure, a reason of 3 characters or more,
--      audited (scheduled_job.intent_recorded). Saving an intent is a record, not a switch: it never runs
--      cron.alter_job and never changes cron.job. Switching a job on or off stays the owner's live switch.
--   4. zella_admin_scheduler_health keeps every key it returned and adds, per job: intended, intent_reason, intent_at,
--      intent_by (the admin's email, null when this file recorded it), intent_matches and drives (what the job runs,
--      in plain words); and at the top level intent_mismatches and intent_only (intents for jobs that don't exist).
--      Archived first; it must match production's version exactly (16 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_job_intent_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_admin_scheduler_health()'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_admin_require(text)') is null or to_regprocedure('public.zella_admin_audit(text,text,uuid,uuid,jsonb,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regclass('public.scheduled_job_intents') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'scheduled_job_intents' and column_name = 'intended') then
    raise exception 'VERSION_MISMATCH: a different scheduled_job_intents table already exists';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'b8391d24bcdae1a24a42189233432c16' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_job_intent', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> '494ea08eb56a1e8283a828c8e0a01926' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
end $$;

create table if not exists public.scheduled_job_intents (
  job_name text primary key check (job_name ~ '^zella[a-z0-9_]{0,60}$'),
  intended text not null check (intended in ('on', 'off')),
  reason text not null check (length(btrim(reason)) between 3 and 300),
  decided_by uuid,
  decided_at timestamptz not null default now()
);
alter table public.scheduled_job_intents enable row level security;
revoke all on table public.scheduled_job_intents from public, anon, authenticated;
grant all on table public.scheduled_job_intents to service_role;

insert into public.scheduled_job_intents (job_name, intended, reason)
select j, 'off', 'Deliberately off until go live'
  from unnest(array['zella_dispatch', 'zella_jobs_every5', 'zella_jobs_every15', 'zella_jobs_hourly', 'zella_jobs_daily', 'zella_jobs_weekly',
                    'zella_cron_cleanup', 'zella_platform_emails', 'zella_spam_hourly']) j
on conflict (job_name) do nothing;

create or replace function public.zella_admin_job_intent_save(p_job text, p_intended text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); v_old public.scheduled_job_intents; v_new public.scheduled_job_intents;
begin
  perform public.zella_admin_require('platform.configure');
  if p_job is null or p_job !~ '^zella[a-z0-9_]{0,60}$' then raise exception 'INVALID_JOB'; end if;
  if p_intended is null or p_intended not in ('on', 'off') then raise exception 'INVALID_INTENT'; end if;
  -- one save per job at a time (also for a job with no row yet), so the audit's old value is the one this save replaced
  perform pg_advisory_xact_lock(hashtextextended('zella_job_intent:' || p_job, 0));
  select * into v_old from public.scheduled_job_intents where job_name = p_job;
  -- a record only: cron.job is never read for writing here, and nothing is switched on or off
  insert into public.scheduled_job_intents (job_name, intended, reason, decided_by, decided_at)
  values (p_job, p_intended, v_reason, auth.uid(), now())
  on conflict (job_name) do update set intended = excluded.intended, reason = excluded.reason, decided_by = excluded.decided_by, decided_at = excluded.decided_at
  returning * into v_new;
  perform public.zella_admin_audit('scheduled_job.intent_recorded', 'scheduled_job', null, null,
    case when v_old.job_name is null then null else jsonb_build_object('job', v_old.job_name, 'intended', v_old.intended, 'reason', v_old.reason) end,
    jsonb_build_object('job', v_new.job_name, 'intended', v_new.intended, 'reason', v_new.reason));
  return jsonb_build_object('job', v_new.job_name, 'intended', v_new.intended, 'reason', v_new.reason, 'at', v_new.decided_at);
end $$;
revoke all on function public.zella_admin_job_intent_save(text, text, text) from public, anon;
grant execute on function public.zella_admin_job_intent_save(text, text, text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.zella_admin_scheduler_health()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_jobs jsonb := '[]'::jsonb; v_secret boolean := false; v_intents jsonb;
  -- what each job runs, in plain words (sql/zella_dispatcher.sql zella_run_schedule_group and the files that create the jobs)
  drives constant jsonb := '{
    "zella_dispatch": "Hands due work to n8n: reminders, follow ups, texts, emails, calendar sync, provider checks and admin alert emails",
    "zella_jobs_every5": "Stuck and open call sweeps, overdue callbacks and leads, transfer failure checks, engine health and offers",
    "zella_jobs_every15": "Call usage reconcile, uptime checks, response times, quote follow ups and recovery of orphaned work",
    "zella_jobs_hourly": "Daily summaries, calendar pulls, call verification, failed text recovery and scheduled cancellations",
    "zella_jobs_daily": "Trials, renewals, payment policy, connection checks, retention scan, tenant check and scheduled cancellations",
    "zella_jobs_weekly": "Weekly reviews, integration reminders and knowledge gap reports",
    "zella_cron_cleanup": "Deletes scheduled job run history older than 3 days",
    "zella_platform_emails": "Safety net for emails from Zella Voice to businesses (new emails also wake the sender at once)",
    "zella_spam_hourly": "Spam protection checks every hour",
    "zella_usage_thresholds": "Plan usage alerts at each threshold",
    "zella_billing_reconcile": "Billing event reconcile with the payment provider"
  }'::jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  if to_regclass('cron.job') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('name', j.jobname, 'schedule', j.schedule, 'active', j.active,
                   'last_run', (select jsonb_build_object('status', d.status, 'at', d.end_time, 'message', left(d.return_message, 160))
                                  from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1),
                   'last_success', (select max(d.end_time) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'succeeded'),
                   'failures_24h', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' and d.start_time > now() - interval '24 hours'))
                   order by j.jobname), '[]'::jsonb) from cron.job j where j.jobname like 'zella%'$q$ into v_jobs;
  end if;
  if to_regclass('vault.secrets') is not null then
    execute $q$select exists (select 1 from vault.secrets where name = 'zella_n8n_secret')$q$ into v_secret;
  end if;
  select coalesce(jsonb_object_agg(i.job_name, jsonb_build_object('intended', i.intended, 'reason', i.reason, 'at', i.decided_at,
                    'by', (select u.email from auth.users u where u.id = i.decided_by))), '{}'::jsonb)
    into v_intents from public.scheduled_job_intents i;
  -- each job with its intended state beside the real one; intent_matches is null when nothing is recorded
  select coalesce(jsonb_agg(j || jsonb_build_object('intended', v_intents -> (j ->> 'name') ->> 'intended',
            'intent_reason', v_intents -> (j ->> 'name') ->> 'reason', 'intent_at', v_intents -> (j ->> 'name') -> 'at',
            'intent_by', v_intents -> (j ->> 'name') -> 'by', 'drives', drives ->> (j ->> 'name'),
            'intent_matches', case when v_intents ? (j ->> 'name')
                                   then ((v_intents -> (j ->> 'name') ->> 'intended') = 'on') = coalesce((j ->> 'active')::boolean, false) end)
            order by j ->> 'name'), '[]'::jsonb)
    into v_jobs from jsonb_array_elements(v_jobs) j;
  return jsonb_build_object('jobs', v_jobs, 'n8n_secret_stored', v_secret,
    'n8n_address_set', coalesce(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}', '') <> '',
    'dispatch_switch', coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true),
    'dispatch', coalesce((select jsonb_agg(jsonb_build_object('workflow', workflow, 'last_triggered_at', last_triggered_at, 'waiting', last_count,
                                                              'stuck', consecutive_same >= 12, 'total', triggers_total) order by workflow)
                            from public.n8n_dispatch_state where workflow <> '_kick'), '[]'::jsonb),
    'overdue', jsonb_build_object('reminders', (select count(*) from public.appointment_reminders where status = 'pending' and due_at < now() - interval '15 minutes'),
                                  'followups', (select count(*) from public.followup_tasks where status = 'pending' and due_at < now() - interval '15 minutes'),
                                  'events', (select count(*) from public.automation_events where status = 'received' and coalesce(next_attempt_at, received_at) < now() - interval '15 minutes')),
    'failed_24h', jsonb_build_object('workflows', (select count(*) from public.workflow_executions where status = 'failed' and started_at > now() - interval '24 hours'),
                                     'events', (select count(*) from public.automation_events where status = 'failed' and received_at > now() - interval '24 hours')),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('severity', a.severity, 'kind', a.kind, 'title', a.title, 'detail', left(a.detail, 300), 'at', a.last_seen_at, 'business_id', a.business_id))
                          from public.platform_alerts a where a.status <> 'resolved'
                           and a.kind in ('scheduler_failed', 'automation_heartbeat', 'automation_stalled', 'queue_backlog', 'integration_disconnected', 'workflow_failed', 'dead_letter')), '[]'::jsonb),
    'intent_mismatches', (select count(*) from jsonb_array_elements(v_jobs) j where (j ->> 'intent_matches')::boolean is false),
    'intent_only', coalesce((select jsonb_agg(jsonb_build_object('name', k, 'intended', v ->> 'intended', 'intent_reason', v ->> 'reason',
                                                                'intent_at', v -> 'at', 'intent_by', v -> 'by', 'drives', drives ->> k) order by k)
                               from jsonb_each(v_intents) e(k, v)
                              where not exists (select 1 from jsonb_array_elements(v_jobs) j where j ->> 'name' = k)), '[]'::jsonb));
end $function$;

commit;
