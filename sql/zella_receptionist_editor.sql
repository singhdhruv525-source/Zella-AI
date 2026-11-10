-- Zella - read the receptionist's live settings for the editor in the business app (2026-10-26). Safe to re-run.
--
-- Purpose
--   The AI Receptionist page can now edit the receptionist through the existing versioned flow in
--   zella_workflows.sql: zella_save_agent_config_draft -> zella_validate_agent_config -> zella_publish_agent_config,
--   with zella_rollback_agent_config to bring back an earlier version. A draft has to carry the full settings (the
--   validator needs escalation_rules), so the editor starts from what is live. ai_agent_configs comes from the base
--   schema and its row security is not in this repo, so this function reads it for managers instead of the browser.
--
-- Needs: zella_workflows.sql (agent_config_versions, zella_can_manage). Base tables ai_agents and ai_agent_configs.
--   Columns read are the ones zella_publish_agent_config writes.
--
-- Authorization: owner, admin or manager of the agent's business (zella_can_manage). Read only.
--
-- Rollback: drop function public.zella_agent_config_current(uuid);
--
-- Validation (rolled back), as a manager: select public.zella_agent_config_current('<agent id>');  -> settings object
--   as a member of another business -> NOT_ALLOWED

create or replace function public.zella_agent_config_current(p_agent_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_b uuid; c record;
begin
  select business_id into v_b from public.ai_agents where id = p_agent_id;
  if v_b is null or not public.zella_can_manage(v_b) then raise exception 'NOT_ALLOWED'; end if;
  select * into c from public.ai_agent_configs where agent_id = p_agent_id;
  if not found then return '{}'::jsonb; end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'system_prompt', c.system_prompt, 'personality', c.personality, 'tone', c.tone, 'goals', c.goals,
    'capabilities', c.capabilities, 'knowledge_base', c.knowledge_base, 'escalation_rules', c.escalation_rules,
    'appointment_rules', c.appointment_rules, 'voice_config', c.voice_config, 'business_context', c.business_context));
end $$;
revoke all on function public.zella_agent_config_current(uuid) from public, anon;
grant execute on function public.zella_agent_config_current(uuid) to authenticated, service_role;
