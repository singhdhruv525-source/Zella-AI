-- K3: receptionist settings reach calls with no one editing Vapi (tests/assistant/run.sh). The owner edits through the
-- CRM's own path (draft, check, publish); what a call gets is what voice-rules returns to Vapi's assistant-request
-- (zella_assistant_for_call). The provider is not called: this proves what Zella answers, not what Vapi does with it.
-- Test data and test platform settings only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
-- platform settings a ready assistant needs (test values)
insert into platform_settings (key, value) values ('vapi_server_url', '"https://example.test/functions/v1/voice-rules"'), ('vapi_credential_id', '"cred-test"'),
  ('voice_llm_provider', '"anthropic"'), ('voice_llm_model', '"claude-sonnet-5"'), ('voice_tts_provider', '"11labs"'), ('voice_tts_voice_id', '"testvoice01"')
on conflict (key) do update set value = excluded.value;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.name, i.id, 'UTC', true, 'active' from (values ('5b000000-0000-0000-0000-00000000000a', 'Delivery Salon', 'beauty-salon'), ('5b000000-0000-0000-0000-00000000000b', 'Delivery Plumbing', 'plumbing')) v(id, name, slug)
  join industries i on i.slug = v.slug;
insert into business_hours (business_id, weekday, opens, closes) select b, d, '09:00', '17:00' from generate_series(0, 6) d, (values ('5b000000-0000-0000-0000-00000000000a'::uuid), ('5b000000-0000-0000-0000-00000000000b'::uuid)) x(b);
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values
  ('5b100000-0000-0000-0000-00000000000a', '5b000000-0000-0000-0000-00000000000a', 'Ava', 'receptionist', 'active', true),
  ('5b100000-0000-0000-0000-00000000000b', '5b000000-0000-0000-0000-00000000000b', 'Max', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules) values
  ('5b100000-0000-0000-0000-00000000000a', 'You are the receptionist of Delivery Salon. Help callers book and take messages.', '{"transfer_enabled": false}', '{}', '{}'),
  ('5b100000-0000-0000-0000-00000000000b', 'You are the receptionist of Delivery Plumbing. Take job details and messages.', '{"transfer_enabled": false}', '{}', '{}');
insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values
  ('5b000000-0000-0000-0000-00000000000a', '+15125557001', 'vpn-salon'), ('5b000000-0000-0000-0000-00000000000b', '+15125557002', 'vpn-plumb');
insert into auth.users (id, email, email_confirmed_at) values ('5b300000-0000-0000-0000-000000000001', 'owner@delivery.test', now()), ('5b300000-0000-0000-0000-000000000002', 'staff@delivery.test', now());
insert into business_members (business_id, user_id, role, status) values
  ('5b000000-0000-0000-0000-00000000000a', '5b300000-0000-0000-0000-000000000001', 'owner', 'active'), ('5b000000-0000-0000-0000-00000000000a', '5b300000-0000-0000-0000-000000000002', 'staff', 'active');

create function pg_temp.publish(p_patch jsonb) returns uuid language plpgsql as $$
declare v uuid; errs jsonb; base jsonb;
begin
  perform set_config('request.jwt.claims', '{"sub":"5b300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
  set local role authenticated;
  select jsonb_build_object('system_prompt', c.system_prompt, 'escalation_rules', c.escalation_rules, 'knowledge_base', c.knowledge_base, 'appointment_rules', c.appointment_rules) into base
    from ai_agent_configs c where c.agent_id = '5b100000-0000-0000-0000-00000000000a';
  v := public.zella_save_agent_config_draft('5b100000-0000-0000-0000-00000000000a', base || p_patch);
  errs := public.zella_validate_agent_config(v);
  if jsonb_array_length(coalesce(errs, '[]')) > 0 then raise exception 'not valid: %', errs; end if;
  perform public.zella_publish_agent_config(v);
  reset role;
  return v;
end $$;
create function pg_temp.prompt(r jsonb) returns text language sql as $$ select r #>> '{assistant,model,messages,0,content}' $$;
create temp table t_v (k text primary key, id uuid);

-- 1. a published change is used by the very next call, and the version is shown as live
insert into t_v select 'v1', pg_temp.publish('{"knowledge_base": {"restrictions": ["Never quote prices for colour treatments"]}}');
do $$ declare r jsonb; begin
  assert (select sync_status from agent_config_versions where id = (select id from t_v where k = 'v1')) = 'pending', 'publish did not mark it pending';
  r := public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-1');
  assert r ->> 'outcome' = 'served', 'not served: ' || r::text;
  assert pg_temp.prompt(r) like '%Never quote prices for colour treatments%', 'the published rule is not in the call''s instructions';
  assert (select sync_status from agent_config_versions where id = (select id from t_v where k = 'v1')) = 'live', 'version not marked live';
  assert r #>> '{assistant,metadata,business_id}' = '5b000000-0000-0000-0000-00000000000a', 'wrong business';
  raise notice 'PASS a rule published in the CRM is in the very next call''s instructions; the version shows as live (was: pending forever, never delivered)';
end $$;

-- 2. editing again: the next call gets the new rule and not the old one; removing it removes it
insert into t_v select 'v2', pg_temp.publish('{"knowledge_base": {"restrictions": ["Always offer the earliest opening first"]}}');
do $$ declare r jsonb; begin
  r := public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-2');
  assert pg_temp.prompt(r) like '%Always offer the earliest opening first%' and pg_temp.prompt(r) not like '%colour treatments%', 'edit not reflected: ' || left(pg_temp.prompt(r), 200);
  assert (select status from agent_config_versions where id = (select id from t_v where k = 'v1')) = 'superseded', 'old version still published';
end $$;
insert into t_v select 'v3', pg_temp.publish('{"knowledge_base": {"restrictions": []}}');
do $$ declare r jsonb; begin
  r := public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-3');
  assert pg_temp.prompt(r) not like '%earliest opening first%', 'a removed rule is still sent';
  raise notice 'PASS edits replace the rule from the next call, a removed rule is no longer sent, and older versions are superseded';
end $$;

-- 3. each number gets only its own business; an unknown or suspended number gets nothing
do $$ declare r jsonb; begin
  r := public.zella_assistant_for_call('+15125557002', 'vpn-plumb', 'dl-call-4');
  assert pg_temp.prompt(r) like '%Delivery Plumbing%' and pg_temp.prompt(r) not like '%Delivery Salon%', 'cross-business: ' || left(pg_temp.prompt(r), 120);
  r := public.zella_assistant_for_call('+15125550000', 'vpn-unknown', 'dl-call-5');
  assert r ->> 'outcome' = 'unknown_number' and not r ? 'assistant', 'unknown number got an assistant: ' || r::text;
  update businesses set suspended_at = now() where id = '5b000000-0000-0000-0000-00000000000b';
  r := public.zella_assistant_for_call('+15125557002', 'vpn-plumb', 'dl-call-6');
  assert r ->> 'outcome' = 'unknown_number', 'suspended business still served: ' || r::text;
  update businesses set suspended_at = null where id = '5b000000-0000-0000-0000-00000000000b';
  raise notice 'PASS each number gets only its own business''s assistant; an unknown or suspended number gets none';
end $$;

-- 4. settings that can't be sent: the version shows failed with the reason, owners are told once, standby used if set
delete from platform_settings where key = 'voice_tts_voice_id';
do $$ declare r jsonb; begin
  r := public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-7');
  assert r ->> 'outcome' = 'not_ready' and not r ? 'assistant' and r ->> 'fallback_assistant_id' is null, 'not refused: ' || r::text;
  assert (select sync_status from agent_config_versions where id = (select id from t_v where k = 'v3')) = 'failed', 'not marked failed';
  assert (select sync_error from agent_config_versions where id = (select id from t_v where k = 'v3')) like '%voice_tts_voice_id%', 'reason not shown';
  perform public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-8');
  assert (select count(*) from staff_notifications where business_id = '5b000000-0000-0000-0000-00000000000a' and kind = 'assistant_not_ready') between 1 and 2, 'owners not told, or told every call';
  insert into platform_settings (key, value) values ('assistant_fallback_id', '"0a1b2c3d-0000-4000-8000-000000000001"');
  r := public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-9');
  assert r ->> 'fallback_assistant_id' = '0a1b2c3d-0000-4000-8000-000000000001', 'standby not offered';
  insert into platform_settings (key, value) values ('voice_tts_voice_id', '"testvoice01"');
  r := public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'dl-call-10');
  assert r ->> 'outcome' = 'served' and (select sync_status from agent_config_versions where id = (select id from t_v where k = 'v3')) = 'live', 'did not recover';
  raise notice 'PASS settings that can''t be sent: failed with the reason, owners told (not per call), standby assistant used if set; fixed settings go live on the next call';
end $$;

-- 5. the CRM status, for managers and up; never callable by the CRM's own sign-in for a call
select set_config('request.jwt.claims', '{"sub":"5b300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare s jsonb; begin
  s := public.zella_assistant_delivery_status('5b000000-0000-0000-0000-00000000000a');
  assert s #>> '{version,sync_status}' = 'live' and s ->> 'last_served_at' is not null and s #>> '{last_problem,problems}' like '%voice_tts_voice_id%', 'status: ' || s::text;
  begin perform public.zella_assistant_for_call('+15125557001', 'vpn-salon', 'x'); raise exception 'the CRM sign-in could fetch an assistant';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"5b300000-0000-0000-0000-000000000002","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ begin
  perform public.zella_assistant_delivery_status('5b000000-0000-0000-0000-00000000000a'); raise exception 'staff saw the status';
exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end $$;
reset role;
do $$ begin raise notice 'PASS the CRM shows the live version, last call served and last problem to managers and up; staff can''t; only the server can fetch an assistant'; end $$;
-- the test platform settings go (production has none of these keys; other suites share this database)
delete from platform_settings where key in ('vapi_server_url', 'vapi_credential_id', 'voice_llm_provider', 'voice_llm_model', 'voice_tts_provider', 'voice_tts_voice_id', 'assistant_fallback_id');
