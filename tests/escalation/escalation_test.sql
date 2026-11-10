-- Regression tests for sql/zella_escalation_rules.sql (tests/escalation/run.sh). Test data only.
-- Edits go through the CRM's own path (save a draft, check it, publish it, as the signed-in owner); behaviour is read
-- through the functions the call handler (voice-rules) uses: zella_ai_tool for tool calls, zella_transfer_destination
-- for the phone system's transfer request, zella_brain_prompt for the instructions.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'ee000000-0000-0000-0000-000000000001', 'Escalation Salon', i.id, 'UTC', true, 'active' from industries i where i.slug = 'beauty-salon';
insert into business_hours (business_id, weekday, opens, closes) select 'ee000000-0000-0000-0000-000000000001', d, '00:00', '23:59' from generate_series(0, 6) d;
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('ee100000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000001', 'Ava', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules)
values ('ee100000-0000-0000-0000-000000000001', 'You are the friendly receptionist of Escalation Salon. Help callers book, answer questions from the knowledge, and take messages.',
        '{"transfer_enabled": true, "transfer_number": "+15125550199"}', '{}', '{}');
insert into calls (business_id, direction, status, from_number, external_call_id, ai_handled)
select 'ee000000-0000-0000-0000-000000000001', 'inbound', 'answered', '+1512555020' || g, 'esc-call-' || g, true from generate_series(1, 9) g;
insert into auth.users (id, email, email_confirmed_at) values ('ee300000-0000-0000-0000-000000000001', 'owner@esc.test', now());
insert into business_members (business_id, user_id, role, status) values ('ee000000-0000-0000-0000-000000000001', 'ee300000-0000-0000-0000-000000000001', 'owner', 'active');

-- the CRM's publish path, as the owner
create or replace function pg_temp.publish(p_patch jsonb) returns void language plpgsql as $$
declare v uuid; errs jsonb; base jsonb;
begin
  perform set_config('request.jwt.claims', '{"sub":"ee300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
  set local role authenticated;
  select jsonb_build_object('system_prompt', c.system_prompt, 'escalation_rules', c.escalation_rules, 'knowledge_base', c.knowledge_base, 'appointment_rules', c.appointment_rules) into base
    from ai_agent_configs c where c.agent_id = 'ee100000-0000-0000-0000-000000000001';
  v := public.zella_save_agent_config_draft('ee100000-0000-0000-0000-000000000001', base || p_patch);
  errs := public.zella_validate_agent_config(v);
  if jsonb_array_length(coalesce(errs, '[]')) > 0 then raise exception 'not valid: %', errs; end if;
  perform public.zella_publish_agent_config(v);
  reset role;
end $$;

do $$ declare r jsonb; d jsonb; begin
  -- before: no triggers saved, today's behaviour (upset caller is transferred)
  r := public.zella_ai_tool('esc-call-1', 'ee000000-0000-0000-0000-000000000001', 'transfer_to_human', '{"reason":"upset_customer"}');
  assert r ->> 'status' = 'transfer', 'before: ' || r::text;
  d := public.zella_transfer_destination('esc-call-9', null, null, '+15125550209');   -- no approval needed before triggers are saved
  assert d ->> 'ok' = 'true', 'older setups lost transfers: ' || d::text;
  raise notice 'PASS businesses that never saved triggers keep today''s transfers';
end $$;

-- the owner ticks only "asks for a person" and publishes
select pg_temp.publish('{"escalation_rules": {"transfer_enabled": true, "transfer_number": "+15125550199", "triggers": ["customer_requests_human"]}}');
do $$ declare r jsonb; d jsonb; p text; begin
  r := public.zella_ai_tool('esc-call-2', 'ee000000-0000-0000-0000-000000000001', 'transfer_to_human', '{"reason":"upset_customer"}');
  assert r ->> 'status' = 'not_for_this' and r::text not like '%5550199%', 'upset caller still transferred after the owner unticked it: ' || r::text;
  d := public.zella_transfer_destination('esc-call-2', null, null, '+15125550202');
  assert d ->> 'ok' = 'false' and d ->> 'reason' = 'not_approved' and d::text not like '%5550199%', 'phone system got the number anyway: ' || d::text;
  r := public.zella_ai_tool('esc-call-3', 'ee000000-0000-0000-0000-000000000001', 'transfer_to_human', '{"reason":"customer_requests_human"}');
  assert r ->> 'status' = 'transfer', 'asked-for-person refused: ' || r::text;
  d := public.zella_transfer_destination('esc-call-3', null, null, '+15125550203');
  assert d ->> 'ok' = 'true' and d ->> 'number' = '+15125550199', 'approved transfer not connected: ' || d::text;
  -- a reason the assistant made up counts as "asks for a person"
  r := public.zella_ai_tool('esc-call-4', 'ee000000-0000-0000-0000-000000000001', 'transfer_to_human', '{"reason":"wants the manager"}');
  assert r ->> 'status' = 'transfer', 'free-text reason: ' || r::text;
  p := public.zella_brain_prompt('ee000000-0000-0000-0000-000000000001');
  assert p like '%only when: the caller asks for a person%' and p not like '%is upset, or you cannot help, use transfer_to_human%', 'instructions not updated';
  raise notice 'PASS D5 after the owner publishes "only when asked": an upset caller is not transferred and the phone system gets no number; asking for a person still connects; the instructions say so';
end $$;

-- nothing ticked: no transfers by the receptionist; emergencies are not governed by the triggers
select pg_temp.publish('{"escalation_rules": {"transfer_enabled": true, "transfer_number": "+15125550199", "emergency_enabled": true, "emergency_keywords": ["flood"], "triggers": []}}');
do $$ declare r jsonb; d jsonb; begin
  r := public.zella_ai_tool('esc-call-5', 'ee000000-0000-0000-0000-000000000001', 'transfer_to_human', '{"reason":"customer_requests_human"}');
  assert r ->> 'status' = 'not_for_this', 'transfer with nothing ticked: ' || r::text;
  r := public.zella_ai_tool('esc-call-6', 'ee000000-0000-0000-0000-000000000001', 'report_emergency', '{"summary":"Flood in the salon","phone":"+15125550206"}');
  d := public.zella_transfer_destination('esc-call-6', null, null, '+15125550206');
  assert d ->> 'ok' = 'true', 'emergency blocked by the triggers: ' || r::text || ' / ' || d::text;
  assert public.zella_brain_prompt('ee000000-0000-0000-0000-000000000001') like '%does not take calls passed to a person by you%', 'instructions';
  raise notice 'PASS D5 with nothing ticked no call is passed to a person, but an emergency still is (it follows the emergency setting)';
end $$;

-- ticking "upset" again brings it back (the edit works both ways)
select pg_temp.publish('{"escalation_rules": {"transfer_enabled": true, "transfer_number": "+15125550199", "triggers": ["upset_customer", "billing_question"]}}');
do $$ declare r jsonb; begin
  r := public.zella_ai_tool('esc-call-7', 'ee000000-0000-0000-0000-000000000001', 'transfer_to_human', '{"reason":"upset_customer"}');
  assert r ->> 'status' = 'transfer', 're-ticked reason refused: ' || r::text;
  raise notice 'PASS D5 ticking a reason again restores it at once (no sync needed: the server reads the published settings on each call)';
end $$;

-- D7: restrictions and booking notes
select pg_temp.publish('{"knowledge_base": {"restrictions": ["Never give medical advice", "Never promise a same-day appointment"]},
  "appointment_rules": {"notes": "New clients need a 60-minute first visit.", "default_minutes": 30}}');
do $$ declare p text; r jsonb; begin
  p := public.zella_brain_prompt('ee000000-0000-0000-0000-000000000001');
  assert p like E'%THE OWNER''S RULES%- Never give medical advice%- Never promise a same-day appointment%', 'restrictions not in the instructions';
  assert p like '%BOOKING NOTES FROM THE BUSINESS%checked by the booking tools, never by these notes%New clients need a 60-minute first visit.%', 'notes not in the instructions';
  -- the note is information: the booking rule that is enforced is default_minutes
  r := public.zella_ai_booking(null, 'ee000000-0000-0000-0000-000000000001', 'book', jsonb_build_object('start', (date_trunc('hour', now()) + interval '2 days 3 hours')::text, 'first_name', 'Nia', 'phone', '+15125550301', 'confirmed', true));
  assert (select extract(epoch from end_time - start_time) / 60 from appointments where business_id = 'ee000000-0000-0000-0000-000000000001' order by created_at desc limit 1) = 30,
    'a note changed the booked length (only the booking rules may)';
  raise notice 'PASS D7 restrictions and booking notes reach the instructions, labelled; a note never changes what is booked (the enforced default length does)';
end $$;
select pg_temp.publish('{"knowledge_base": {"restrictions": []}, "appointment_rules": {"notes": ""}}');
do $$ declare p text; begin
  p := public.zella_brain_prompt('ee000000-0000-0000-0000-000000000001');
  assert p not like '%Never give medical advice%' and p not like '%BOOKING NOTES FROM THE BUSINESS%', 'removed rules still in the instructions';
  raise notice 'PASS D7 removing them in the CRM removes them from the instructions';
end $$;
