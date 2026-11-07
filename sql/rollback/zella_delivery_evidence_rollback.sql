-- Rollback for sql/zella_delivery_evidence.sql (hand-written): both functions as in production on 6 Nov 2026 (after #10).
-- The config_hash column is kept (it is only evidence).
begin;
CREATE OR REPLACE FUNCTION public.zella_assistant_for_call(p_called_number text, p_vapi_phone_number_id text, p_provider_call_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_biz uuid := public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null);   -- no fallback: the number decides
  v_cfg jsonb; v_version uuid;
  v_fallback text := nullif(public.zella_setting('assistant_fallback_id', 'null'::jsonb) #>> '{}', '');
begin
  if v_fallback is not null and v_fallback !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_fallback := null; end if;
  if v_biz is null then
    insert into assistant_deliveries (business_id, provider_call_id, outcome) values (null, left(p_provider_call_id, 120), 'unknown_number');
    return jsonb_build_object('ok', false, 'outcome', 'unknown_number', 'fallback_assistant_id', v_fallback);
  end if;
  v_cfg := public.zella_assistant_config(v_biz);
  select v.id into v_version from agent_config_versions v where v.business_id = v_biz and v.status = 'published' order by v.published_at desc nulls last limit 1;
  if coalesce((v_cfg ->> 'ready_to_send')::boolean, false) then
    update agent_config_versions set sync_status = 'live', sync_error = null where id = v_version and (sync_status <> 'live' or sync_error is not null);
    insert into assistant_deliveries (business_id, version_id, provider_call_id, outcome) values (v_biz, v_version, left(p_provider_call_id, 120), 'served');
    return jsonb_build_object('ok', true, 'outcome', 'served', 'version_id', v_version, 'assistant', v_cfg -> 'assistant');
  end if;
  update agent_config_versions set sync_status = 'failed', sync_error = left(array_to_string(array(select jsonb_array_elements_text(v_cfg -> 'problems')), '; '), 500)
   where id = v_version and sync_status <> 'failed';
  insert into assistant_deliveries (business_id, version_id, provider_call_id, outcome, problems)
  values (v_biz, v_version, left(p_provider_call_id, 120), 'not_ready', coalesce(v_cfg -> 'problems', '[]'));
  -- the owners hear about it once a day at most; the problems are platform settings the Zella team fixes
  if not exists (select 1 from staff_notifications n where n.business_id = v_biz and n.kind = 'assistant_not_ready' and n.created_at > now() - interval '24 hours') then
    begin
      perform public.zella_notify_owners(v_biz, 'assistant_not_ready', 'A call could not use your receptionist settings',
        'The Zella team has been told what to fix. Calls are ' || case when v_fallback is null then 'not being answered by the AI receptionist' else 'using the standby receptionist' end || ' until then.', 'warning', 'receptionist');
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', false, 'outcome', 'not_ready', 'problems', coalesce(v_cfg -> 'problems', '[]'), 'fallback_assistant_id', v_fallback);
end $function$

;
CREATE OR REPLACE FUNCTION public.zella_assistant_delivery_status(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'version', (select jsonb_build_object('id', v.id, 'version', v.version, 'published_at', v.published_at, 'sync_status', v.sync_status, 'sync_error', v.sync_error)
                  from agent_config_versions v where v.business_id = p_business_id and v.status = 'published' order by v.published_at desc nulls last limit 1),
    'last_served_at', (select max(created_at) from assistant_deliveries where business_id = p_business_id and outcome = 'served'),
    'last_problem', (select jsonb_build_object('at', d.created_at, 'problems', d.problems) from assistant_deliveries d
                      where d.business_id = p_business_id and d.outcome = 'not_ready' order by d.created_at desc limit 1));
end $function$

;
commit;
