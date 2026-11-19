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
--   * zella_provisioning_begin(p_business, p_step) and zella_provisioning_end(p_business, p_step, p_attempt, p_outcome,
--     ...): one setup save's attempt. Begin marks the step pending with a new attempt id (provisioning_steps.attempt_id)
--     and returns it with the status it had; end writes done, failed, or the earlier status back (a refusal), only
--     while the step is still that attempt's pending mark, under the business and step locks (the retries' order). An
--     older attempt that ends late never overwrites what a newer attempt, a retry or the timer recorded. Server only.
-- Nothing existing is replaced; provisioning_steps gains one column (attempt_id, empty until a save begins). Each new
-- function must be absent or exactly this file's version, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_provisioning_retry_rollback.sql
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
      ('public.zella_retry_provisioning_due()', '1504ba6ce453432daccbe72f67f59000'),
      ('public.zella_provisioning_begin(uuid,text)', 'ea7cafd97b8324ddcc36a1d6fa174c42'),
      ('public.zella_provisioning_end(uuid,text,uuid,text,text,text,text)', '29d2bd7fd0e7e11fd3c7254b20ed42b7')) as t(sig, want) loop
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
  -- The same lock order as a retry by hand (zella_retry_provisioning): the business row first, then its step row, each
  -- skipped if someone else holds it, so the timer and a person retrying at once never deadlock.
  for s in select p.business_id, p.step from provisioning_steps p join businesses b on b.id = p.business_id
            where p.status = 'failed' and p.step in ('modules', 'receptionist', 'automations') and p.updated_at < now() - interval '1 hour'
              and b.cancelled_at is null
              and (select count(*) from audit_logs a where a.business_id = p.business_id and a.action = 'provisioning.step_retried'
                     and a.user_id is null and a.new_data ->> 'step' = p.step) < 3 loop
    continue when not exists (select 1 from (select 1 from businesses where id = s.business_id and cancelled_at is null for update skip locked) x);
    continue when not exists (select 1 from (select 1 from provisioning_steps where business_id = s.business_id and step = s.step and status = 'failed'
                                              for update skip locked) y);
    -- the timer's 3 tries, counted again under the locks (an overlapping run may have retried it meanwhile)
    continue when (select count(*) from audit_logs a where a.business_id = s.business_id and a.action = 'provisioning.step_retried'
                    and a.user_id is null and a.new_data ->> 'step' = s.step) >= 3;
    perform zella_retry_provisioning(s.business_id, s.step, null);
    n := n + 1;
  end loop;
  return n;
end
$function$;

alter table public.provisioning_steps add column if not exists attempt_id uuid;

CREATE OR REPLACE FUNCTION public.zella_provisioning_begin(p_business_id uuid, p_step text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r provisioning_steps; v uuid := gen_random_uuid();
begin
  if p_business_id is null or p_step is null or length(p_step) not between 1 and 40 then raise exception 'INVALID_INPUT'; end if;
  perform 1 from businesses where id = p_business_id for update;   -- the business first, then its step (as the retries)
  select * into r from provisioning_steps where business_id = p_business_id and step = p_step for update;
  perform zella_track_provisioning(p_business_id, p_step, 'pending', null);
  update provisioning_steps set attempt_id = v where business_id = p_business_id and step = p_step;
  return jsonb_build_object('attempt', v, 'before_status', r.status, 'before_error', r.error);
end
$function$;

-- p_outcome: done or failed (recorded through zella_track_provisioning, which raises or resolves the alert), or restore
-- (a refusal: the step goes back to p_before_status and p_before_error, or away when it had none). True when written.
CREATE OR REPLACE FUNCTION public.zella_provisioning_end(p_business_id uuid, p_step text, p_attempt uuid, p_outcome text, p_error text,
  p_before_status text, p_before_error text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r provisioning_steps;
begin
  if p_outcome is null or p_outcome not in ('done', 'failed', 'restore') or p_attempt is null then raise exception 'INVALID_INPUT'; end if;
  perform 1 from businesses where id = p_business_id for update;
  select * into r from provisioning_steps where business_id = p_business_id and step = p_step for update;
  if r.business_id is null or r.status <> 'pending' or r.attempt_id is distinct from p_attempt then return false; end if;
  if p_outcome = 'restore' and p_before_status = 'pending' then
    -- this attempt began over another one still pending, whose end is now ignored: put back nothing that no attempt
    -- owns; it reads failed, so it can be retried and shows that the earlier save didn't finish
    perform zella_track_provisioning(p_business_id, p_step, 'failed', 'An earlier save of this step didn''t finish. Save it again.');
    update provisioning_steps set attempt_id = null where business_id = p_business_id and step = p_step;
  elsif p_outcome = 'restore' then
    if p_before_status is null then delete from provisioning_steps where business_id = p_business_id and step = p_step;
    else update provisioning_steps set status = p_before_status, error = p_before_error, attempt_id = null, updated_at = now()
          where business_id = p_business_id and step = p_step;
    end if;
  else
    perform zella_track_provisioning(p_business_id, p_step, p_outcome, p_error);
    update provisioning_steps set attempt_id = null where business_id = p_business_id and step = p_step;
  end if;
  return true;
end
$function$;

revoke all on function public.zella_provisioning_begin(uuid, text) from public, anon, authenticated;
revoke all on function public.zella_provisioning_end(uuid, text, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_provisioning_begin(uuid, text) to service_role;
grant execute on function public.zella_provisioning_end(uuid, text, uuid, text, text, text, text) to service_role;

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
