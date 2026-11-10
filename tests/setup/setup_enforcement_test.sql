-- Regression tests for sql/zella_setup_enforcement.sql on an isolated copy (tests/setup/run.sh). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;

-- a salon (takes bookings), open every day 08:00-20:00, with its receptionist
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'e1000000-0000-0000-0000-000000000001', 'Setup Salon', i.id, 'UTC', true, 'active' from industries i where i.slug = 'beauty-salon';
insert into business_hours (business_id, weekday, opens, closes) select 'e1000000-0000-0000-0000-000000000001', d, '08:00', '20:00' from generate_series(0, 6) d;
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('e2000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Ava', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, knowledge_base, appointment_rules) values ('e2000000-0000-0000-0000-000000000001', '{}', '{}');

-- D1: booking abilities switched off in setup
do $$ declare t jsonb; r jsonb; begin
  t := public.zella_brain_context('e1000000-0000-0000-0000-000000000001') -> 'tools';
  assert t ? 'book_appointment' and t ? 'check_availability', 'tools before: ' || t;
  update ai_agent_configs set appointment_rules = '{"can_book": false, "can_reschedule": true, "can_cancel": false}' where agent_id = 'e2000000-0000-0000-0000-000000000001';
  t := public.zella_brain_context('e1000000-0000-0000-0000-000000000001') -> 'tools';
  assert not (t ? 'book_appointment') and not (t ? 'check_availability') and not (t ? 'cancel_appointment'), 'switched-off tools still offered: ' || t;
  assert t ? 'reschedule_appointment' and t ? 'search_knowledge' and t ? 'take_message', 'other tools must stay: ' || t;
  r := public.zella_ai_tool(null, 'e1000000-0000-0000-0000-000000000001', 'book_appointment', '{"start":"2030-01-01T10:00:00Z"}');
  assert r ->> 'status' = 'not_available', 'book_appointment not refused: ' || r;
  r := public.zella_ai_tool(null, 'e1000000-0000-0000-0000-000000000001', 'cancel_appointment', '{}');
  assert r ->> 'status' = 'not_available', 'cancel not refused: ' || r;
  update ai_agent_configs set appointment_rules = '{}' where agent_id = 'e2000000-0000-0000-0000-000000000001';
  t := public.zella_brain_context('e1000000-0000-0000-0000-000000000001') -> 'tools';
  assert t ? 'book_appointment', 'missing flags must keep booking on (older setups)';
  raise notice 'PASS D1 booking abilities switched off in setup: left out of the tool list and refused if called; others untouched';
end $$;

-- D2: setup answers become searchable knowledge; owner items untouched
do $$ declare s jsonb; n int; own uuid; begin
  insert into knowledge_items (business_id, kind, title, answer, status) values ('e1000000-0000-0000-0000-000000000001', 'faq', 'Parking', 'Free parking behind the shop.', 'ready') returning id into own;
  assert (public.zella_brain_search('e1000000-0000-0000-0000-000000000001', 'do you do gift vouchers', 3) ->> 'confidence') = 'none', 'fixture';
  update ai_agent_configs set knowledge_base = '{"faqs":[{"question":"Do you sell gift vouchers?","answer":"Yes, in any amount at the front desk."}],
     "policies":{"cancellation":"Please give 24 hours notice to cancel."}, "about":"Family salon since 1998.", "service_area":"",
     "business_details":[{"label":"Wheelchair access","value":"Step-free entrance"}], "services":[{"name":"Cut"}]}'
   where agent_id = 'e2000000-0000-0000-0000-000000000001';
  s := public.zella_brain_search('e1000000-0000-0000-0000-000000000001', 'gift vouchers', 3);
  assert s ->> 'confidence' <> 'none' and (s -> 'results' -> 0 ->> 'answer') like '%front desk%', 'setup FAQ not searchable: ' || s;
  s := public.zella_brain_search('e1000000-0000-0000-0000-000000000001', 'cancellation notice', 3);
  assert (s -> 'results' -> 0 ->> 'answer') like '%24 hours%', 'policy not searchable: ' || s;
  select count(*) into n from knowledge_items where business_id = 'e1000000-0000-0000-0000-000000000001' and source_key like 'setup:%' and status = 'ready';
  assert n = 4, 'expected faq, policy, about, detail; got ' || n;   -- the empty service area is skipped
  -- changed answer follows; removed FAQ is archived; the owner's own item is untouched
  update ai_agent_configs set knowledge_base = jsonb_set(knowledge_base, '{faqs}', '[]') || '{"policies":{"cancellation":"48 hours notice please."}}' where agent_id = 'e2000000-0000-0000-0000-000000000001';
  assert (select answer from knowledge_items where source_key = 'setup:policy:cancellation') = '48 hours notice please.', 'policy change not followed';
  assert (select status from knowledge_items where source_key like 'setup:faq:%') = 'archived', 'removed FAQ not archived';
  assert (select status from knowledge_items where id = own) = 'ready' and (select source_key from knowledge_items where id = own) is null, 'owner item changed';
  assert (public.zella_brain_search('e1000000-0000-0000-0000-000000000001', 'gift vouchers', 3) ->> 'confidence') = 'none', 'archived FAQ still answered';
  raise notice 'PASS D2 setup FAQs, policies, about and details are searchable; changes follow, removals archive, owner items untouched';
end $$;

-- D3: default length, minimum notice, how far ahead
do $$ declare r jsonb; v_first timestamptz; v_last timestamptz; begin
  update ai_agent_configs set appointment_rules = '{"default_minutes": 60, "min_notice_hours": 24, "max_days_ahead": 3}' where agent_id = 'e2000000-0000-0000-0000-000000000001';
  r := public.zella_ai_booking(null, 'e1000000-0000-0000-0000-000000000001', 'availability', jsonb_build_object('date', current_date::text, 'days', 7));
  select min((x ->> 'start')::timestamptz), max((x ->> 'start')::timestamptz) into v_first, v_last from jsonb_array_elements(r -> 'slots') x;
  assert v_first is not null and v_first >= now() + interval '24 hours', 'slot inside the notice: ' || coalesce(v_first::text, 'none') || ' ' || r;
  assert v_last <= now() + interval '3 days', 'slot beyond the horizon: ' || v_last;
  r := public.zella_ai_booking(null, 'e1000000-0000-0000-0000-000000000001', 'book', jsonb_build_object('start', (date_trunc('hour', now()) + interval '3 hours')::text, 'first_name', 'Ana', 'phone', '+15550001111', 'confirmed', true));
  assert r ->> 'status' = 'unavailable', 'booking inside the notice accepted: ' || r;
  r := public.zella_ai_booking(null, 'e1000000-0000-0000-0000-000000000001', 'book', jsonb_build_object('start', (date_trunc('hour', now()) + interval '10 days')::text, 'first_name', 'Ana', 'phone', '+15550001111', 'confirmed', true));
  assert r ->> 'status' = 'unavailable', 'booking beyond the horizon accepted: ' || r;
  r := public.zella_ai_booking(null, 'e1000000-0000-0000-0000-000000000001', 'book', jsonb_build_object('start', v_first::text, 'first_name', 'Ana', 'phone', '+15550001111', 'confirmed', true));
  assert r ->> 'status' in ('booked', 'requested'), 'an offered slot was refused: ' || r;
  assert (select extract(epoch from end_time - start_time) / 60 from appointments where business_id = 'e1000000-0000-0000-0000-000000000001' order by created_at desc limit 1) = 60,
    'default length not used';
  r := public.zella_ai_manage_booking(null, 'e1000000-0000-0000-0000-000000000001', 'reschedule',
    jsonb_build_object('appointment_id', (select id from appointments where business_id = 'e1000000-0000-0000-0000-000000000001' limit 1), 'start', (now() + interval '2 hours')::text, 'caller_number', '+15550001111', 'confirmed', true));
  assert r ->> 'status' in ('unavailable', 'need_info', 'not_found') and r ->> 'status' <> 'rescheduled', 'reschedule inside the notice accepted: ' || r;
  raise notice 'PASS D3 booking keeps to the setup default length, minimum notice and horizon (offer, book, reschedule)';
end $$;

-- D6: language and greeting into the live settings
do $$ declare r jsonb; l record; begin
  r := public.zella_setup_language_apply('e1000000-0000-0000-0000-000000000001', 'en-US+es-US', 'Thanks for calling {name}!');
  select * into l from business_languages where business_id = 'e1000000-0000-0000-0000-000000000001';
  assert r ->> 'ok' = 'true' and l.primary_language = 'en-US' and l.extra_languages = '{es}' and l.greeting = 'Thanks for calling {name}!', 'language not applied: ' || r;
  assert (public.zella_business_language_plan('e1000000-0000-0000-0000-000000000001') ->> 'greeting') like 'Thanks for calling Setup Salon%', 'live plan does not use it';
  assert (public.zella_setup_language_apply('e1000000-0000-0000-0000-000000000001', 'xx', null) ->> 'ok') = 'false', 'unknown language accepted';
  assert (public.zella_setup_language_apply('e1000000-0000-0000-0000-000000000001', 'en-US', 'visit https://evil.example') ->> 'ok') = 'false', 'link in greeting accepted';
  raise notice 'PASS D6 setup language and greeting reach the live language settings, with the same checks';
end $$;

-- grants
do $$ declare f text; bad text := ''; begin
  foreach f in array array['zella_setup_knowledge_sync(uuid)', 'zella_setup_language_apply(uuid,text,text)', 'zella_setup_disabled_tools(uuid)', 'zella_booking_rules(uuid)'] loop
    if has_function_privilege('authenticated', 'public.' || f, 'execute') or has_function_privilege('anon', 'public.' || f, 'execute') then bad := bad || f || ' '; end if;
  end loop;
  assert bad = '', 'callable by users: ' || bad;
  raise notice 'PASS new functions are server-only';
end $$;
