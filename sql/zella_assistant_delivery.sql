-- Receptionist settings reach calls without anyone editing Vapi (K3). Safe to run twice.
-- Rollback: sql/rollback/zella_assistant_delivery_rollback.sql.
--
-- K3  Publishing a receptionist version set sync_status = 'pending', but nothing delivered the assistant to Vapi
--     (zella_claim_agent_syncs has no consumer), so wording, greeting, languages and tool changes never reached the
--     phone line by themselves.
--     Now Vapi asks for the assistant at the start of every inbound call (assistant-request, sent to voice-rules), and
--     the answer is built from the business's current published settings (zella_assistant_config). Nothing is cached
--     at the provider, so there is nothing to keep in sync. Each answer is recorded:
--       served          the current settings were used for this call; the published version becomes 'live'
--       not_ready       the settings can't be sent (problems listed); the version is 'failed' with the reason, the
--                       caller hears that the call can't be taken (or goes to the fallback assistant, if one is set)
--       unknown_number  the number belongs to no active business; nothing about any business is returned
--     Prerequisite (provider, needs approval): each Vapi phone number has no assistant and its server URL is
--     voice-rules. Until then calls keep using whatever assistant is set on the number.

create table if not exists public.assistant_deliveries (
  id bigint generated always as identity primary key,
  business_id uuid references public.businesses(id) on delete cascade,
  version_id uuid references public.agent_config_versions(id) on delete set null,
  provider_call_id text,
  outcome text not null check (outcome in ('served', 'not_ready', 'unknown_number')),
  problems jsonb not null default '[]',
  created_at timestamptz not null default now()
);
create index if not exists assistant_deliveries_business_idx on public.assistant_deliveries (business_id, created_at desc);
alter table public.assistant_deliveries enable row level security;
revoke all on public.assistant_deliveries from anon, authenticated;
grant select, insert, delete on public.assistant_deliveries to service_role;

-- Server only (voice-rules, after the request's signature check).
create or replace function public.zella_assistant_for_call(p_called_number text, p_vapi_phone_number_id text, p_provider_call_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- What the CRM shows: the published version, whether calls are using it, and the last problem.
create or replace function public.zella_assistant_delivery_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'version', (select jsonb_build_object('id', v.id, 'version', v.version, 'published_at', v.published_at, 'sync_status', v.sync_status, 'sync_error', v.sync_error)
                  from agent_config_versions v where v.business_id = p_business_id and v.status = 'published' order by v.published_at desc nulls last limit 1),
    'last_served_at', (select max(created_at) from assistant_deliveries where business_id = p_business_id and outcome = 'served'),
    'last_problem', (select jsonb_build_object('at', d.created_at, 'problems', d.problems) from assistant_deliveries d
                      where d.business_id = p_business_id and d.outcome = 'not_ready' order by d.created_at desc limit 1));
end $$;

revoke execute on function public.zella_assistant_for_call(text, text, text) from public, anon, authenticated;
grant execute on function public.zella_assistant_for_call(text, text, text) to service_role;
revoke execute on function public.zella_assistant_delivery_status(uuid) from public, anon;
grant execute on function public.zella_assistant_delivery_status(uuid) to authenticated, service_role;
