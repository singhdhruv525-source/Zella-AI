-- Zella - messaging status (2026-10-26). Safe to re-run. Adds two read-only functions: one for business members,
-- one for platform admins (zella_automation_readiness, at the end).
--
-- The calendar's booking panel shows each booking's reminders and follow-ups. So it can say honestly whether they
-- really go out, it needs to know, without seeing any key, number or secret:
--   texts / emails / calls  the platform switch is on AND a sender is set (sms_live + sms_from_number,
--                           email_live + email_from_address, calls_live)
--   scheduler               the database job that hands due work to n8n is switched on and its secret is stored
--   automations             this business's own appointment automations and whether each is active
-- Only members of the business may ask. Returns on/off flags only.
-- Rollback: drop function public.zella_messaging_status(uuid);

create or replace function public.zella_messaging_status(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
end $$;

revoke all on function public.zella_messaging_status(uuid) from public, anon;
grant execute on function public.zella_messaging_status(uuid) to authenticated;

-- Platform admins: is the automation engine really connected end to end? Admin Settings > Integrations > n8n shows
-- this as a go-live checklist. On/off facts and timestamps only; no secret, key, number or address is returned.
-- Rollback: drop function public.zella_automation_readiness();
create or replace function public.zella_automation_readiness()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_setting jsonb; v_jobs jsonb := '[]'::jsonb; v_secret boolean := false; v_dispatch jsonb := '[]'::jsonb;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_setting from public.platform_settings
   where key in ('sms_live', 'sms_from_number', 'email_live', 'email_from_address', 'calls_live', 'n8n_dispatch_enabled', 'n8n_base_url', 'app_base_url', 'calendar_sync_live');
  if to_regclass('cron.job') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('name', jobname, 'schedule', schedule, 'active', active) order by jobname), '[]'::jsonb)
                 from cron.job where jobname like 'zella%'$q$ into v_jobs;
  end if;
  if to_regclass('vault.secrets') is not null then
    execute $q$select exists (select 1 from vault.secrets where name = 'zella_n8n_secret')$q$ into v_secret;
  end if;
  if to_regclass('public.n8n_dispatch_state') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('workflow', workflow, 'last_triggered_at', last_triggered_at, 'triggers_total', triggers_total) order by workflow), '[]'::jsonb)
                 from public.n8n_dispatch_state$q$ into v_dispatch;
  end if;
  return jsonb_build_object(
    'dispatch_switch', coalesce((v_setting ->> 'n8n_dispatch_enabled')::boolean, true),
    'dispatch_job', exists (select 1 from jsonb_array_elements(v_jobs) j where j ->> 'name' = 'zella_dispatch' and (j ->> 'active')::boolean),
    'secret_stored', v_secret,
    'n8n_address_set', coalesce(v_setting ->> 'n8n_base_url', '') <> '',
    'app_address_set', coalesce(v_setting ->> 'app_base_url', '') ~ '^https://',
    'texts_live', coalesce((v_setting ->> 'sms_live')::boolean, false), 'text_sender_set', coalesce(v_setting ->> 'sms_from_number', '') <> '',
    'emails_live', coalesce((v_setting ->> 'email_live')::boolean, false), 'email_sender_set', coalesce(v_setting ->> 'email_from_address', '') <> '',
    'calls_live', coalesce((v_setting ->> 'calls_live')::boolean, false),
    'calendar_sync_live', coalesce((v_setting ->> 'calendar_sync_live')::boolean, false),
    'jobs', v_jobs, 'dispatch', v_dispatch);
end $$;
revoke all on function public.zella_automation_readiness() from public, anon;
grant execute on function public.zella_automation_readiness() to authenticated;
