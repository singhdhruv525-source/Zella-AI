-- Zella - messaging status for the business app (2026-10-26). Safe to re-run. Adds one read-only function.
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
