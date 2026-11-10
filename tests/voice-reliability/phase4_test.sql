-- Phase 4 on the staging copy (live functions + production's call triggers + all migrations). Assertions; PASS notices.
delete from business_phone_numbers; delete from callbacks; delete from callback_attempts; delete from knowledge_gaps; delete from knowledge_items;
delete from staff_notifications; delete from contact_consents; delete from business_members; delete from platform_settings where key in ('vapi_server_url', 'vapi_credential_id', 'voice_llm_model', 'voice_llm_provider', 'voice_tts_provider', 'voice_tts_voice_id', 'voice_stt_provider', 'voice_stt_model', 'voice_stt_language', 'voice_max_call_seconds');
insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'pn-A'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'pn-B');
insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'Ava', 'receptionist', true), ('b0000000-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-000000000002', 'Bo', 'receptionist', true);
insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "+15550101111", "transfer_open_hours_only": false}'), ('b0000000-0000-4000-8000-00000000000b', '{"transfer_enabled": false}');

do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; B uuid := 'bbbbbbbb-0000-4000-8000-000000000002';
        t0 timestamptz := now() - interval '10 minutes'; c record; r jsonb; n int; v text; g uuid; item uuid; u uuid := 'eeeeeeee-0000-4000-8000-00000000000e';
begin
  -- ---- 1. a real conversation is never turned into a missed call while its report is on the way
  perform zella_record_call_status('p4-1', 'ringing', '+15550001000', 'pn-A', '+15551230001', 'inbound', t0, null);
  perform zella_record_call_status('p4-1', 'in-progress', '+15550001000', 'pn-A', '+15551230001', 'inbound', t0 + interval '2 seconds', null);
  perform zella_record_call_status('p4-1', 'ended', '+15550001000', 'pn-A', '+15551230001', 'inbound', t0 + interval '95 seconds', 'customer-ended-call');
  select * into c from calls where external_call_id = 'p4-1';
  assert c.status <> 'missed' and not exists (select 1 from callbacks where call_id = c.id), 'ended before report: ' || c.status;
  perform zella_record_inbound_call('p4-1', '+15550001000', 'pn-A', '+15551230001', t0, t0 + interval '95 seconds', 95, 'customer-ended-call', 'Asked about hours.', null, 'AI: Hello.', false);
  select * into c from calls where external_call_id = 'p4-1';
  assert c.status = 'completed' and not exists (select 1 from callbacks where call_id = c.id) and c.outcome = 'resolved', 'after report: ' || c.status || ' ' || coalesce(c.outcome, '');
  raise notice 'PASS a 95-second call: not marked missed while the report is on the way, no callback, outcome resolved';
  -- a genuinely missed call (hung up within seconds, nothing said) still gets one callback, and a second one is merged
  perform zella_record_call_status('p4-2', 'ringing', '+15550001000', 'pn-A', '+15551230077', 'inbound', t0, null);
  perform zella_record_inbound_call('p4-2', '+15550001000', 'pn-A', '+15551230077', t0, t0 + interval '3 seconds', 3, 'customer-ended-call', null, null, null, false);
  perform zella_record_call_status('p4-3', 'ringing', '+15550001000', 'pn-A', '+15551230077', 'inbound', t0 + interval '1 minute', null);
  perform zella_record_inbound_call('p4-3', '+15550001000', 'pn-A', '+15551230077', t0 + interval '1 minute', t0 + interval '62 seconds', 2, 'customer-ended-call', null, null, null, false);
  select count(*) into n from callbacks where business_id = A and reason = 'missed_call' and zella_digits(contact_number) = zella_digits('+15551230077') and status not in ('completed', 'cancelled');
  assert (select status from calls where external_call_id = 'p4-2') = 'missed' and n = 1, 'missed: ' || n;
  raise notice 'PASS a 3-second silent call is missed and queues one callback; a second missed call from the number does not add another';
  -- no duration from the provider: decided from its own start and end times, never assumed 0
  perform zella_record_call_status('p4-4', 'in-progress', '+15550001000', 'pn-A', '+15551230088', 'inbound', t0, null);
  perform zella_record_inbound_call('p4-4', '+15550001000', 'pn-A', '+15551230088', t0, t0 + interval '40 seconds', null, 'customer-ended-call', null, null, null, false);
  assert (select status from calls where external_call_id = 'p4-4') <> 'missed', 'no duration';
  raise notice 'PASS report without a duration: 40 s from the provider''s times, not treated as missed';

  -- ---- 2. transfers: connected = no leftover callback; failed = one urgent callback
  r := zella_ai_voice('p4-t1', A, 'transfer', '{"reason": "wants a person", "caller_number": "+15551230009"}');
  assert r ->> 'status' = 'transfer', 'transfer ' || r::text;
  assert exists (select 1 from callbacks b join calls x on x.id = b.call_id where x.external_call_id = 'p4-t1' and b.reason = 'needs_human' and b.status not in ('completed', 'cancelled')), 'attempt queues a callback';
  perform zella_record_inbound_call('p4-t1', '+15550001000', 'pn-A', '+15551230009', t0, t0 + interval '60 seconds', 60, 'assistant-forwarded-call', 'Put through.', null, 'AI: connecting', false);
  select x.transfer_status, (select count(*) from callbacks b where b.call_id = x.id and b.status not in ('completed', 'cancelled')) as open_cb into v, n from calls x where x.external_call_id = 'p4-t1';
  assert v = 'connected' and n = 0, 'connected: ' || v || ' ' || n;
  raise notice 'PASS transfer connected: the automatic "needs a person" callback is closed (none left open)';
  r := zella_ai_voice('p4-t2', A, 'transfer', '{"reason": "wants a person", "caller_number": "+15551230010"}');
  perform zella_record_inbound_call('p4-t2', '+15550001000', 'pn-A', '+15551230010', t0, t0 + interval '70 seconds', 70, 'customer-ended-call', 'Transfer did not go through.', null, 'AI: connecting', false);
  select string_agg(b.reason || '/' || b.priority, ',') into v from callbacks b join calls x on x.id = b.call_id where x.external_call_id = 'p4-t2' and b.status not in ('completed', 'cancelled');
  assert v = 'transfer_failed/urgent', 'failed: ' || coalesce(v, 'none');
  raise notice 'PASS transfer failed: exactly one open callback, urgent (transfer_failed)';

  -- ---- 3. unanswered questions: recorded once per call, owners told once, answered in the CRM, then used
  perform zella_record_call_status('p4-k1', 'in-progress', '+15550001000', 'pn-A', '+15551230001', 'inbound', now(), null);
  r := zella_ai_tool('p4-k1', A, 'search_knowledge', '{"query": "Do you validate parking?"}');
  assert r ->> 'status' = 'no_information' and r ->> 'say' like '%Do not guess%', 'search ' || r::text;
  r := zella_ai_tool('p4-k1', A, 'report_unanswered_question', '{"question": "Do you validate parking?"}');
  select id, times_asked into g, n from knowledge_gaps where business_id = A and question_key = 'do you validate parking';
  assert n = 1, 'times_asked ' || n;
  assert (select count(*) from staff_notifications where business_id = A and kind = 'knowledge_gap') >= 1 and (select notified_at is not null from knowledge_gaps where id = g), 'notice';
  n := (select count(*) from staff_notifications where business_id = A and kind = 'knowledge_gap');
  raise notice 'PASS unknown answer: "do not guess" instruction, question recorded once for the call (searched + reported), owners notified (% notice rows)', n;
  perform zella_record_call_status('p4-k2', 'in-progress', '+15550001000', 'pn-A', '+15551230002', 'inbound', now(), null);
  perform zella_ai_tool('p4-k2', A, 'search_knowledge', '{"query": "Do you validate parking?"}');
  assert (select times_asked from knowledge_gaps where id = g) = 2 and (select count(*) from staff_notifications where business_id = A and kind = 'knowledge_gap') = n, 'second call';
  assert not exists (select 1 from knowledge_gaps where business_id = B), 'other business';
  raise notice 'PASS the same question on another call counts 2, without another notice; nothing in the other business''s records';
  -- a member of another business can't answer it; an owner of this business can
  insert into business_members (business_id, user_id, role, status) values (A, u, 'owner', 'active');
  perform set_config('request.jwt.claim.sub', 'ffffffff-0000-4000-8000-00000000000f', true);
  begin perform zella_answer_knowledge_gap(g, 'x', 'faq', 'x'); raise exception 'outsider answered'; exception when others then assert sqlerrm = 'NOT_ALLOWED', sqlerrm; end;
  perform set_config('request.jwt.claim.sub', u::text, true);
  item := zella_answer_knowledge_gap(g, 'Yes, we validate parking for up to 2 hours at the front desk.', 'policy', 'Parking validation');
  perform set_config('request.jwt.claim.sub', '', true);
  assert (select status from knowledge_items where id = item) = 'processing' and (select status from knowledge_gaps where id = g) = 'answered', 'answered';
  r := zella_ai_tool('p4-k3', A, 'search_knowledge', '{"query": "parking validation"}');
  assert r ->> 'status' = 'no_information', 'not used before it is published: ' || r::text;
  v := zella_complete_knowledge_update(item, (select version from knowledge_items where id = item), true, null);
  r := zella_ai_tool('p4-k4', A, 'search_knowledge', '{"query": "parking validation"}');
  assert v = 'ready' and r ->> 'status' = 'confirmed' and r::text like '%validate parking for up to 2 hours%', 'published: ' || v || ' ' || r::text;
  assert zella_ai_tool('p4-k5', B, 'search_knowledge', '{"query": "parking validation"}') ->> 'status' = 'no_information', 'B sees A';
  raise notice 'PASS owner answers in Knowledge -> published -> the receptionist answers from it; another business''s caller does not get it';

  -- ---- 4. automatic callbacks: consent, calling hours, bounded retries, no loops
  select name into v from pg_timezone_names where name ~ '^[A-Z][a-z]+/[A-Za-z_]+$' and extract(hour from now() at time zone name) between 11 and 15
     and extract(isodow from now() at time zone name) between 2 and 4 order by name limit 1;
  if v is null then raise notice 'skip  callback claims: no time zone is mid-week midday right now'; return; end if;
  update businesses set timezone = v where id = A;
  update customers set do_not_call = true where id = 'cccccccc-0000-4000-8000-000000000002';
  insert into contact_consents (business_id, phone_digits, channel, purpose, status, source) values (A, zella_digits('+15559998888'), 'call', 'transactional', 'opted_out', 'test');
  update callbacks set status = 'cancelled' where status not in ('completed', 'cancelled');
  insert into callbacks (id, business_id, customer_id, reason, status, contact_number, due_at, auto_call, max_attempts, retry_delay_minutes, created_by) values
    ('c1000000-0000-4000-8000-000000000001', A, 'cccccccc-0000-4000-8000-000000000001', 'missed_call', 'scheduled', '+15551230001', now() - interval '1 minute', true, 3, 5, 'system'),
    ('c1000000-0000-4000-8000-000000000002', A, 'cccccccc-0000-4000-8000-000000000002', 'missed_call', 'scheduled', '+15551230002', now() - interval '1 minute', true, 3, 5, 'system'),
    ('c1000000-0000-4000-8000-000000000003', A, null, 'missed_call', 'scheduled', '+15559998888', now() - interval '1 minute', true, 3, 5, 'system'),
    ('c1000000-0000-4000-8000-000000000004', A, null, 'requested', 'scheduled', '+15559997777', now() + interval '1 hour', true, 3, 5, 'system');
  r := zella_claim_callbacks(10);
  assert jsonb_array_length(r) = 1 and r -> 0 ->> 'callback_id' = 'c1000000-0000-4000-8000-000000000001', 'claimed ' || r::text;
  assert (select status || '/' || outcome from callbacks where id = 'c1000000-0000-4000-8000-000000000002') = 'cancelled/do_not_contact'
     and (select status || '/' || outcome from callbacks where id = 'c1000000-0000-4000-8000-000000000003') = 'cancelled/do_not_contact', 'consent';
  raise notice 'PASS callbacks: due one claimed (time zone %); do-not-call customer and opted-out unknown number cancelled, never dialled; future one left', v;
  v := zella_record_callback_attempt('c1000000-0000-4000-8000-000000000001', 'no_answer');
  assert v = 'retry_scheduled' and jsonb_array_length(zella_claim_callbacks(10)) = 0, 'retry later';
  update callbacks set due_at = now() - interval '1 minute' where id = 'c1000000-0000-4000-8000-000000000001';
  assert jsonb_array_length(zella_claim_callbacks(10)) = 1 and zella_record_callback_attempt('c1000000-0000-4000-8000-000000000001', 'busy') = 'retry_scheduled', 'attempt 2';
  update callbacks set due_at = now() - interval '1 minute' where id = 'c1000000-0000-4000-8000-000000000001';
  assert jsonb_array_length(zella_claim_callbacks(10)) = 1, 'attempt 3';
  v := zella_record_callback_attempt('c1000000-0000-4000-8000-000000000001', 'no_answer');
  select * into c from callbacks where id = 'c1000000-0000-4000-8000-000000000001';
  assert v = 'needs_review' and not c.auto_call and c.attempts = 3 and (select count(*) from callback_attempts where callback_id = c.id) = 3
     and exists (select 1 from staff_notifications where kind = 'callback_review' and entity_id = c.id), 'limit ' || v;
  update callbacks set due_at = now() - interval '1 minute' where id = c.id;
  assert jsonb_array_length(zella_claim_callbacks(10)) = 0, 'stopped';
  raise notice 'PASS no answer: retried later, at most 3 attempts (each recorded), then handed to staff with a notice; never called again automatically';
  v := zella_record_callback_attempt('c1000000-0000-4000-8000-000000000004', 'connected');
  assert v = 'contacted', 'connected';
  -- outside calling hours: not dialled, moved to the next opening
  select name into v from pg_timezone_names where name ~ '^[A-Z][a-z]+/[A-Za-z_]+$' and extract(hour from now() at time zone name) between 1 and 4 order by name limit 1;
  update businesses set timezone = v where id = B;
  insert into callbacks (id, business_id, reason, status, contact_number, due_at, auto_call, created_by) values ('c1000000-0000-4000-8000-000000000005', B, 'missed_call', 'scheduled', '+15551230003', now() - interval '1 minute', true, 'system');
  r := zella_claim_callbacks(10);
  assert jsonb_array_length(r) = 0 and (select due_at > now() from callbacks where id = 'c1000000-0000-4000-8000-000000000005'), 'hours ' || r::text || ' ' || (select status || ' ' || due_at from callbacks where id = 'c1000000-0000-4000-8000-000000000005');
  raise notice 'PASS outside calling hours (3 a.m. in %): not dialled, moved to the next opening', v;
  -- the call Zella places can never create another callback (no loops)
  insert into calls (business_id, direction, status, from_number, external_call_id, started_at, ended_at, duration_seconds) values (A, 'outbound', 'missed', '+15551230001', 'p4-out', now(), now(), 0);
  assert not exists (select 1 from callbacks b join calls x on x.id = b.call_id where x.external_call_id = 'p4-out'), 'loop';
  raise notice 'PASS an unanswered outbound callback call creates no new callback (no loop)';
end $$;

-- ---- 5. the Vapi assistant configuration
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; B uuid := 'bbbbbbbb-0000-4000-8000-000000000002';
        r jsonb; cfg jsonb; t jsonb; names text[]; p text; n int := 0; ind record; bid uuid;
        url text := 'https://pffqxlumqhjdbzvvoszm.supabase.co/functions/v1/voice-rules';
begin
  update businesses set timezone = 'America/New_York' where id in (A, B);
  update businesses set industry_id = (select id from industries where slug = 'dental') where id = A;
  insert into platform_settings (key, value) values ('voice_llm_model', '"claude-sonnet-5-5"') on conflict (key) do update set value = excluded.value;
  r := zella_assistant_config(A);
  assert r ->> 'ready_to_send' = 'false' and r -> 'problems' @> '["vapi_server_url is not set"]' and (r ->> 'problems') like '%vapi_credential_id is not set%'
     and (r ->> 'problems') like '%claude-sonnet-5-5 is not in Vapi%' and (r ->> 'problems') like '%voice_tts_voice_id is not set%'
     and not (r -> 'assistant' ? 'voice'), 'unconfigured ' || (r -> 'problems')::text;
  raise notice 'PASS not configured: not ready, with every reason (no server URL, no credential, model claude-sonnet-5-5 not in Vapi''s list, no voice chosen); no voice is guessed';
  insert into platform_settings (key, value) values ('voice_stt_model', '"nova-9-imaginary"'), ('voice_max_call_seconds', '99999'), ('voice_tts_provider', '"playht"')
    on conflict (key) do update set value = excluded.value;
  r := zella_assistant_config(A);
  assert (r ->> 'problems') like '%nova-9-imaginary is not a Deepgram model Vapi lists%' and (r ->> 'problems') like '%voice_max_call_seconds 99999%'
     and (r ->> 'problems') like '%voice_tts_provider playht has not been checked%', 'bad settings ' || (r -> 'problems')::text;
  delete from platform_settings where key in ('voice_stt_model', 'voice_max_call_seconds', 'voice_tts_provider');
  raise notice 'PASS unsupported transcriber model, call length or voice provider: reported, not accepted';
  insert into platform_settings (key, value) values ('vapi_server_url', to_jsonb(url)), ('vapi_credential_id', '"cred-test-123"'), ('voice_llm_model', '"claude-sonnet-5"'),
    ('voice_tts_voice_id', '"test-voice-id"') on conflict (key) do update set value = excluded.value;
  r := zella_assistant_config(A); cfg := r -> 'assistant';
  assert r ->> 'ready_to_send' = 'true' and jsonb_array_length(r -> 'problems') = 0, 'ready ' || (r -> 'problems')::text;
  assert cfg -> 'voice' = '{"provider": "11labs", "voiceId": "test-voice-id"}' and cfg -> 'transcriber' = '{"model": "nova-2-phonecall", "language": "en-US", "provider": "deepgram"}'
     and (cfg ->> 'maxDurationSeconds')::int = 600 and cfg #>> '{model,model}' = 'claude-sonnet-5' and cfg #>> '{model,provider}' = 'anthropic', 'voice/transcriber/model';
  assert cfg -> 'server' = jsonb_build_object('url', url, 'credentialId', 'cred-test-123', 'timeoutSeconds', 20) and not (cfg ? 'tools')
     and cfg -> 'serverMessages' = '["tool-calls", "transfer-destination-request", "status-update", "end-of-call-report"]', 'assistant server';
  select array_agg(y order by y collate "C") into names from (select coalesce(x #>> '{function,name}', x ->> 'type') y from jsonb_array_elements(cfg #> '{model,tools}') x) z;
  assert names = (select array_agg(y order by y collate "C") from unnest(array['book_appointment', 'call_rules', 'cancel_appointment', 'check_availability', 'check_open_hours', 'find_my_appointments', 'lookup_caller',
    'reschedule_appointment', 'report_emergency', 'report_unanswered_question', 'request_follow_up', 'search_knowledge', 'take_message', 'transferCall', 'transfer_to_human', 'update_caller']) y), 'tools ' || names::text;
  for t in select x from jsonb_array_elements(cfg #> '{model,tools}') x where x ->> 'type' = 'function' loop
    assert t -> 'server' = cfg -> 'server' and t ->> 'async' = 'false', 'tool server ' || (t #>> '{function,name}');
  end loop;
  assert (select x #> '{function,parameters,required}' from jsonb_array_elements(cfg #> '{model,tools}') x where x #>> '{function,name}' = 'book_appointment') ? 'confirmed'
     and (select x #> '{function,parameters,required}' from jsonb_array_elements(cfg #> '{model,tools}') x where x #>> '{function,name}' = 'cancel_appointment') ? 'confirmed'
     and (select x #> '{function,parameters,required}' from jsonb_array_elements(cfg #> '{model,tools}') x where x #>> '{function,name}' = 'reschedule_appointment') ? 'confirmed', 'confirmed';
  assert (select x from jsonb_array_elements(cfg #> '{model,tools}') x where x ->> 'type' = 'transferCall') = '{"type": "transferCall"}', 'transfer tool';
  assert (select x #> '{function,parameters,properties,action,enum}' from jsonb_array_elements(cfg #> '{model,tools}') x where x #>> '{function,name}' = 'call_rules') = '["rules"]', 'call_rules';
  raise notice 'PASS ready: assistant and every one of the 15 function tools use the voice-rules URL with the credential, synchronously; book/move/cancel require confirmed; transfer tool has no fixed number';
  p := cfg #>> '{model,messages,0,content}';
  assert p like 'You are Ava, the phone receptionist for Bright Smile Dental%' and p like '%America/New_York%' and p like '%RULES THAT DO NOT CHANGE%' and p like '%WHAT YOU SAY HAPPENED%'
     and p like '%transferCall%' and p like '%cannot confirm that%' and p like '%You are not a clinician%' and position('+15550101111' in cfg::text) = 0 and position('Other Business' in cfg::text) = 0, 'prompt';
  raise notice 'PASS prompt: this business only, its time zone, truthful-outcome and unknown-answer rules, injection rules, dental safety; no transfer number anywhere in the config';
  -- what the business switched off is not offered; transfers off = no transfer tool
  update ai_agent_configs set business_context = '{"disabled_tools": ["update_caller", "book_appointment"]}' where agent_id = 'a0000000-0000-4000-8000-00000000000a';
  cfg := zella_assistant_config(A) -> 'assistant';
  assert not exists (select 1 from jsonb_array_elements(cfg #> '{model,tools}') x where x #>> '{function,name}' in ('update_caller', 'book_appointment')), 'disabled';
  assert not exists (select 1 from jsonb_array_elements(zella_assistant_config(B) #> '{assistant,model,tools}') x where x ->> 'type' = 'transferCall'), 'B transfer';
  update ai_agent_configs set business_context = '{}' where agent_id = 'a0000000-0000-4000-8000-00000000000a';
  raise notice 'PASS tools the business switched off are not offered; a business with transfers off gets no transfer tool';
  update platform_settings set value = '"http://pffqxlumqhjdbzvvoszm.supabase.co/functions/v1/voice-rules"' where key = 'vapi_server_url';
  assert zella_assistant_config(A) ->> 'problems' like '%https%', 'http';
  update platform_settings set value = to_jsonb(url) where key = 'vapi_server_url';
  -- every industry
  for ind in select i.id, i.name, i.slug from industries i order by i.slug loop
    bid := gen_random_uuid();
    insert into businesses (id, name, timezone, onboarding_status, industry_id) values (bid, 'Test ' || ind.name, 'America/Chicago', 'active', ind.id);
    r := zella_assistant_config(bid); p := r #>> '{assistant,model,messages,0,content}';
    assert r ->> 'ready_to_send' = 'true' and p like '%Test ' || ind.name || '%' and p like '%America/Chicago%'
       and jsonb_array_length(r #> '{assistant,model,tools}') = 16 and position('Bright Smile' in r::text) = 0, 'industry ' || ind.slug;
    if ind.slug in ('dental', 'healthcare') then assert p like '%not a clinician%', ind.slug; end if;
    if ind.slug in ('legal', 'financial-services', 'insurance') then assert p like '%no legal, tax or financial advice%', ind.slug; end if;
    if ind.slug = 'pet-care-veterinary' then assert p like '%You are not a vet%', ind.slug; end if;
    if ind.slug = 'childcare' then assert p like '%Never share any detail about a child%', ind.slug; end if;
    delete from businesses where id = bid; n := n + 1;
  end loop;
  assert n = 28, 'industries ' || n;
  raise notice 'PASS all % industries: ready, own name and time zone, 16 tools, industry safety rules (clinical, legal/financial, vet, childcare)', n;
end $$;
