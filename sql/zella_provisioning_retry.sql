-- Zella Voice: failed internal setup steps can be retried, by a person or on a timer (SET-ONB-RETRY part 2).
-- owner-provision-business now records every setup step in provisioning_steps (part 1). Default for which steps may be
-- retried (owner can change): only internal database steps are retried without a person; the owner invitation email
-- and anything that reaches a provider (assistant delivery, phone numbers) get a manual Retry only, in the admin.
-- Now:
--   * zella_retry_provisioning(p_business, p_step, p_actor) repairs one internal step, only adding what is missing
--     (never changing what an admin chose):
--       modules       every active module of the business's industry gets a row (on, as a new draft has it);
--       receptionist  the business gets its receptionist (disabled, as a new draft has it) and its settings row;
--       automations   nothing is invented: done when the business has automations, otherwise it stays failed with a
--                     note to save the Automations step again (Continue setup);
--     It records the outcome through zella_track_provisioning (which raises or resolves the provisioning alert) and
--     audits the attempt (provisioning.step_retried, the actor, or the timer when there is none). Server only.
--   * zella_retry_provisioning_due() retries failed internal steps last changed more than an hour ago, at most 3 timed
--     attempts per step; its timed job zella_provisioning_retry is created switched OFF: turning it on is the owner's
--     switch.
-- Nothing existing is replaced. Each new function must be absent or exactly this file's version, otherwise
-- VERSION_MISMATCH. Rollback: sql/rollback/zella_provisioning_retry_rollback.sql
begin;

do $$
declare f record;
begin
  if to_regprocedure('public.zella_track_provisioning(uuid,text,text,text)') is null or to_regclass('public.provisioning_steps') is null
     or to_regclass('public.business_modules') is null or to_regclass('public.ai_agent_configs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_retry_provisioning(uuid,text,uuid)', 'b5b05c27d48b7c001a8f6b453c484b78'),
      ('public.zella_retry_provisioning_due()', 'f608e26c9df1d31cccd43c638fa8d26b')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

CREATE OR REPLACE FUNCTION public.zella_retry_provisioning(p_business uuid, p_step text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b businesses; v_agent uuid; v_added integer := 0; v_status text := 'done'; v_note text;
begin
  if p_step not in ('modules', 'receptionist', 'automations') then raise exception 'NOT_INTERNAL: %', p_step; end if;
  select * into b from businesses where id = p_business for update;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  if b.cancelled_at is not null then raise exception 'CANCELLED'; end if;
  if p_step = 'modules' then
    insert into business_modules (business_id, module_id, enabled)
    select b.id, m.id, true from industry_modules m
     where m.industry_id = b.industry_id and m.is_active
       and not exists (select 1 from business_modules x where x.business_id = b.id and x.module_id = m.id);
    get diagnostics v_added = row_count;
  elsif p_step = 'receptionist' then
    select id into v_agent from ai_agents where business_id = b.id and agent_type = 'receptionist' order by is_default desc, created_at limit 1;
    if v_agent is null then
      insert into ai_agents (business_id, name, agent_type, status, channels, is_default)
      values (b.id, 'AI Receptionist', 'receptionist', 'disabled', '{}', true) returning id into v_agent;
      v_added := 1;
    end if;
    if not exists (select 1 from ai_agent_configs where agent_id = v_agent) then
      insert into ai_agent_configs (agent_id, business_context)
      values (v_agent, jsonb_build_object('business_name', b.name, 'industry_id', b.industry_id, 'timezone', b.timezone));
      v_added := v_added + 1;
    end if;
  else
    if not exists (select 1 from automations where business_id = b.id) then
      v_status := 'failed'; v_note := 'No automations saved yet: open Continue setup and save the Automations step again';
    end if;
  end if;
  perform zella_track_provisioning(b.id, p_step, v_status, v_note);
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (b.id, p_actor, 'provisioning.step_retried', 'provisioning_step', b.id,
          jsonb_build_object('step', p_step, 'status', v_status, 'added', v_added, 'by', case when p_actor is null then 'timer' else 'admin' end));
  return jsonb_build_object('business_id', b.id, 'step', p_step, 'status', v_status, 'added', v_added, 'note', v_note);
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_retry_provisioning_due()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; n integer := 0;
begin
  for s in select p.business_id, p.step from provisioning_steps p join businesses b on b.id = p.business_id
            where p.status = 'failed' and p.step in ('modules', 'receptionist', 'automations') and p.updated_at < now() - interval '1 hour'
              and b.cancelled_at is null
              and (select count(*) from audit_logs a where a.business_id = p.business_id and a.action = 'provisioning.step_retried'
                     and a.user_id is null and a.new_data ->> 'step' = p.step) < 3
            for update of p skip locked loop
    perform zella_retry_provisioning(s.business_id, s.step, null);
    n := n + 1;
  end loop;
  return n;
end
$function$;

revoke all on function public.zella_retry_provisioning(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.zella_retry_provisioning_due() from public, anon, authenticated;
grant execute on function public.zella_retry_provisioning(uuid, text, uuid) to service_role;
grant execute on function public.zella_retry_provisioning_due() to service_role;

-- the timed job, created switched OFF (the owner's switch); Supabase edits jobs with cron.alter_job
do $$ declare v_id bigint; begin
  if to_regnamespace('cron') is not null and not exists (select 1 from cron.job where jobname = 'zella_provisioning_retry') then
    v_id := cron.schedule('zella_provisioning_retry', '17 * * * *', 'select public.zella_retry_provisioning_due()');
    if to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null then
      perform cron.alter_job(job_id := v_id, active := false);
    else
      update cron.job set active = false where jobid = v_id;
    end if;
  end if;
end $$;

commit;
