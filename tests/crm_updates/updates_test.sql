-- Ongoing CRM updates reach the receptionist (tests/crm_updates/run.sh): knowledge (sql/zella_knowledge_live.sql) and the
-- settings that are read on every call. Writes are made as the signed-in owner, the way the CRM pages make them; what
-- the receptionist gets is read through the functions the call handler uses. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'ea000000-0000-0000-0000-000000000001', 'Updates Salon', i.id, 'UTC', true, 'active' from industries i where i.slug = 'beauty-salon';
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('ea100000-0000-0000-0000-000000000001', 'ea000000-0000-0000-0000-000000000001', 'Ava', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, knowledge_base, appointment_rules) values ('ea100000-0000-0000-0000-000000000001', 'You are the receptionist of Updates Salon. Be brief and kind.', '{}', '{}');
insert into business_hours (business_id, weekday, opens, closes) select 'ea000000-0000-0000-0000-000000000001', d, '09:00', '17:00' from generate_series(0, 6) d;
insert into auth.users (id, email, email_confirmed_at) values ('ea300000-0000-0000-0000-000000000001', 'owner@updates.test', now());
insert into business_members (business_id, user_id, role, status) values ('ea000000-0000-0000-0000-000000000001', 'ea300000-0000-0000-0000-000000000001', 'owner', 'active');
create function pg_temp.answer(q text) returns text language sql as $$
  select public.zella_brain_search('ea000000-0000-0000-0000-000000000001', q, 3) -> 'results' -> 0 ->> 'answer' $$;
create temp table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;
select set_config('request.jwt.claims', '{"sub":"ea300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);

-- K1 addition (Knowledge page: insert with status processing)
set role authenticated;
with x as (insert into knowledge_items (business_id, kind, title, question, answer, status)
  values ('ea000000-0000-0000-0000-000000000001', 'faq', 'Parking', 'Is there parking?', 'Free parking behind the salon.', 'processing') returning id) insert into t_ids select 'parking', id from x;
reset role;
do $$ begin
  assert (select status from knowledge_items where id = (select id from t_ids where k = 'parking')) = 'ready', 'added answer still waiting: ' || (select status from knowledge_items where id = (select id from t_ids where k = 'parking'));
  assert pg_temp.answer('parking') like 'Free parking%', 'added answer not answerable on the next call';
  raise notice 'PASS K1 an answer the owner adds is answerable on the next call (was: waiting for a workflow that is not running)';
end $$;

-- K2 edit (Knowledge page: update of the content)
set role authenticated;
update knowledge_items set answer = 'Parking is on Elm Street, two minutes away.' where id = (select id from t_ids where k = 'parking');
reset role;
do $$ begin
  assert pg_temp.answer('parking') like 'Parking is on Elm Street%', 'edited answer not used: ' || coalesce(pg_temp.answer('parking'), '(nothing)');
  assert (select version from knowledge_items where id = (select id from t_ids where k = 'parking')) = 2, 'version not bumped';
  assert exists (select 1 from knowledge_versions where item_id = (select id from t_ids where k = 'parking')), 'no version history';
  raise notice 'PASS K2 an edit replaces the answer in the same save, with a new version in the history (was: neither old nor new answer until checked)';
end $$;

-- processing failure: a bad edit is refused and the good answer stays
set role authenticated;
do $$ begin
  update knowledge_items set answer = '   ' where id = (select id from t_ids where k = 'parking');
  raise exception 'empty answer accepted';
exception when raise_exception then
  if sqlerrm <> 'KNOWLEDGE_ANSWER_EMPTY' then raise; end if;
end $$;
do $$ begin
  insert into knowledge_items (business_id, kind, title, answer, status) values ('ea000000-0000-0000-0000-000000000001', 'faq', 'Too long', repeat('x', 4001), 'processing');
  raise exception 'long answer accepted';
exception when raise_exception then
  if sqlerrm <> 'KNOWLEDGE_ANSWER_TOO_LONG' then raise; end if;
end $$;
reset role;
do $$ begin
  assert pg_temp.answer('parking') like 'Parking is on Elm Street%', 'a refused edit took the good answer offline';
  raise notice 'PASS failures: an empty or too-long answer is refused with the reason, and the live answer stays in use';
end $$;

-- rollback to an earlier version, then deletion (archive) and a hard delete
set role authenticated;
select public.zella_knowledge_rollback((select id from t_ids where k = 'parking'), 1);
reset role;
do $$ begin
  assert pg_temp.answer('parking') like 'Free parking%', 'rolled-back answer not live: ' || coalesce(pg_temp.answer('parking'), '(nothing)');
end $$;
set role authenticated;
update knowledge_items set status = 'archived' where id = (select id from t_ids where k = 'parking');
reset role;
do $$ begin
  assert pg_temp.answer('parking') is null and (public.zella_brain_search('ea000000-0000-0000-0000-000000000001', 'parking', 3) ->> 'confidence') = 'none', 'removed answer still used';
  raise notice 'PASS rollback brings the earlier answer back at once; removing it stops it being used at once';
end $$;

-- drafts are not used until sent
set role authenticated;
with x as (insert into knowledge_items (business_id, kind, title, answer, status)
  values ('ea000000-0000-0000-0000-000000000001', 'faq', 'Gift cards', 'Gift cards in any amount.', 'draft') returning id) insert into t_ids select 'draft', id from x;
reset role;
do $$ begin assert pg_temp.answer('gift cards') is null, 'draft used'; end $$;
set role authenticated;
update knowledge_items set status = 'processing' where id = (select id from t_ids where k = 'draft');
reset role;
do $$ begin
  assert pg_temp.answer('gift cards') like 'Gift cards%', 'sent draft not used';
  raise notice 'PASS publication of a draft: not used while a draft, used on the next call once sent';
end $$;

-- settings read on every call: no cache to clear
do $$ declare d timestamptz := date_trunc('day', now()) + interval '2 days'; n_before int; n_after int; begin
  select count(*) into n_before from public.zella_available_slots('ea000000-0000-0000-0000-000000000001', d, d + interval '1 day', 30, null, 30, 50);
  perform set_config('request.jwt.claims', '{"sub":"ea300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
  perform public.zella_save_business_hours('ea000000-0000-0000-0000-000000000001',
    (select jsonb_agg(jsonb_build_object('weekday', wd, 'opens', '09:00', 'closes', '12:00')) from generate_series(0, 6) wd));
  perform set_config('request.jwt.claims', '', true);
  select count(*) into n_after from public.zella_available_slots('ea000000-0000-0000-0000-000000000001', d, d + interval '1 day', 30, null, 30, 50);
  assert n_after < n_before and n_after > 0, 'hours change not used: ' || n_before || ' -> ' || n_after;
  raise notice 'PASS opening hours changed in Settings change the times offered on the next call (% -> % slots)', n_before, n_after;
end $$;

-- the receptionist's published settings: rules apply on the next call; the wording waits for the provider sync
do $$ declare v uuid; r jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"ea300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
  v := public.zella_save_agent_config_draft('ea100000-0000-0000-0000-000000000001', jsonb_build_object('system_prompt', 'You are the receptionist of Updates Salon. Be brief and kind.',
         'escalation_rules', '{"transfer_enabled": false, "after_hours_mode": "take_message"}'::jsonb, 'appointment_rules', '{"can_book": false}'::jsonb, 'knowledge_base', '{"faqs":[{"question":"Do you sell gift vouchers?","answer":"Vouchers at the front desk."}]}'::jsonb));
  r := public.zella_validate_agent_config(v);
  if jsonb_array_length(r) > 0 then raise exception 'not valid: %', r; end if;
  perform public.zella_publish_agent_config(v);
  perform set_config('request.jwt.claims', '', true);
  r := public.zella_ai_tool(null, 'ea000000-0000-0000-0000-000000000001', 'book_appointment', '{"start":"2030-01-01T10:00:00Z"}');
  assert r ->> 'status' = 'not_available', 'published "no booking" not applied on the next call: ' || r::text;
  assert pg_temp.answer('gift vouchers') like 'Vouchers at the front desk%', 'published setup FAQ not answerable';
  assert (select sync_status from agent_config_versions where id = v) = 'pending', 'sync status';
  raise notice 'PASS published receptionist settings: booking switched off and a setup FAQ apply on the next call; the version waits as "pending" for the provider sync (nothing consumes it yet: see the audit)';
end $$;
