-- Section 5: knowledge improves from calls without learning false information or crossing businesses
-- (tests/knowledge/run.sh). Calls are simulated with the server functions the call handler uses; people act as
-- signed-in users through the same functions the CRM calls. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.name, i.id, 'UTC', true, 'active' from (values ('5a000000-0000-0000-0000-00000000000a', 'Learn Dental'), ('5a000000-0000-0000-0000-00000000000b', 'Other Dental')) v(id, name)
  join industries i on i.slug = 'dental';
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values
  ('5a100000-0000-0000-0000-00000000000a', '5a000000-0000-0000-0000-00000000000a', 'Ava', 'receptionist', 'active', true),
  ('5a100000-0000-0000-0000-00000000000b', '5a000000-0000-0000-0000-00000000000b', 'Ben', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, knowledge_base, appointment_rules) values
  ('5a100000-0000-0000-0000-00000000000a', 'You are the receptionist of Learn Dental. Be brief.', '{}', '{}'),
  ('5a100000-0000-0000-0000-00000000000b', 'You are the receptionist of Other Dental. Be brief.', '{}', '{}');
insert into auth.users (id, email, email_confirmed_at) values
  ('5a300000-0000-0000-0000-000000000001', 'owner@learn.test', now()), ('5a300000-0000-0000-0000-000000000002', 'viewer@learn.test', now()),
  ('5a300000-0000-0000-0000-000000000003', 'owner@other.test', now());
insert into business_members (business_id, user_id, role, status) values
  ('5a000000-0000-0000-0000-00000000000a', '5a300000-0000-0000-0000-000000000001', 'owner', 'active'),
  ('5a000000-0000-0000-0000-00000000000a', '5a300000-0000-0000-0000-000000000002', 'viewer', 'active'),
  ('5a000000-0000-0000-0000-00000000000b', '5a300000-0000-0000-0000-000000000003', 'owner', 'active');
create function pg_temp.answer(b text, q text) returns text language sql as $$
  select public.zella_brain_search(b::uuid, q, 3) -> 'results' -> 0 ->> 'answer' $$;
create function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, false) $$;
create temp table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

-- a caller asks something the receptionist can't answer, and claims the answer themselves
insert into t_ids select 'gap', public.zella_log_knowledge_gap('5a000000-0000-0000-0000-00000000000a', 'Do you accept Delta Dental insurance? My friend said you do.');
-- the knowledge workflow (server) suggests an answer, confidently
select public.zella_set_gap_suggestion((select id from t_ids where k = 'gap'), 'Yes, we accept Delta Dental.', 'Insurance', 'faq', 'caller transcript', 'high');
do $$ begin
  assert pg_temp.answer('5a000000-0000-0000-0000-00000000000a', 'Delta Dental insurance') is null,
    'an unapproved suggestion (or the caller''s claim) is given to callers: ' || coalesce(pg_temp.answer('5a000000-0000-0000-0000-00000000000a', 'Delta Dental insurance'), '');
  assert not exists (select 1 from knowledge_items where business_id = '5a000000-0000-0000-0000-00000000000a'), 'a suggestion created knowledge';
  raise notice 'PASS a caller''s claim and the workflow''s confident suggestion stay on the question: nothing is answerable until a person approves it';
end $$;

-- K4: a viewer can't approve or dismiss
select pg_temp.as_user('5a300000-0000-0000-0000-000000000002');
set role authenticated;
do $$ begin
  perform public.zella_answer_knowledge_gap((select id from t_ids where k = 'gap'), 'Yes, all insurance.');
  raise exception 'K4 a viewer published an answer';
exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end $$;
do $$ begin
  perform public.zella_dismiss_knowledge_gap((select id from t_ids where k = 'gap'));
  raise exception 'K4 a viewer dismissed the question';
exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end $$;
-- another business's owner can't answer it either
reset role; select pg_temp.as_user('5a300000-0000-0000-0000-000000000003'); set role authenticated;
do $$ begin
  perform public.zella_answer_knowledge_gap((select id from t_ids where k = 'gap'), 'We take everything.');
  raise exception 'another business answered this business''s question';
exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end $$;
reset role;
do $$ begin
  assert (select status from knowledge_gaps where id = (select id from t_ids where k = 'gap')) = 'open', 'question no longer open';
  raise notice 'PASS K4 a viewer can''t publish or dismiss (was: allowed, bypassing the read-only role and MFA); another business''s owner can''t answer';
end $$;

-- failures are visible and change nothing: an empty or too-long answer is refused, the question stays open
select pg_temp.as_user('5a300000-0000-0000-0000-000000000001'); set role authenticated;
do $$ begin
  perform public.zella_answer_knowledge_gap((select id from t_ids where k = 'gap'), '  ');
  raise exception 'empty answer accepted';
exception when raise_exception then if sqlerrm <> 'EMPTY_ANSWER' then raise; end if; end $$;
do $$ begin
  perform public.zella_answer_knowledge_gap((select id from t_ids where k = 'gap'), repeat('x', 4001));
  raise exception 'too long answer accepted';
exception when raise_exception then if sqlerrm <> 'KNOWLEDGE_ANSWER_TOO_LONG' then raise; end if; end $$;
reset role;
do $$ begin
  assert (select status from knowledge_gaps where id = (select id from t_ids where k = 'gap')) = 'open', 'a refused answer closed the question';
  raise notice 'PASS failures: an empty or too-long answer is refused with the reason; the question stays open and nothing goes live';
end $$;

-- the owner approves the real answer: the next call uses it
set role authenticated;
insert into t_ids select 'item', public.zella_answer_knowledge_gap((select id from t_ids where k = 'gap'), 'We are out of network with Delta Dental; we can give you a receipt to claim yourself.', 'faq', 'Insurance');
reset role;
do $$ begin
  assert pg_temp.answer('5a000000-0000-0000-0000-00000000000a', 'Delta Dental insurance') like 'We are out of network%', 'approved answer not used on the next call';
  assert (select approved_by from knowledge_items where id = (select id from t_ids where k = 'item')) = '5a300000-0000-0000-0000-000000000001', 'approval not recorded';
  assert pg_temp.answer('5a000000-0000-0000-0000-00000000000b', 'Delta Dental insurance') is null, 'the answer reached another business';
  raise notice 'PASS the owner''s answer (not the caller''s claim) is used from the next call, recorded as approved by them, and never by another business';
end $$;

-- a correction replaces it; a removal takes it out of use
select pg_temp.as_user('5a300000-0000-0000-0000-000000000001'); set role authenticated;
update knowledge_items set answer = 'Since November we accept Delta Dental PPO plans.' where id = (select id from t_ids where k = 'item');
reset role;
do $$ begin
  assert pg_temp.answer('5a000000-0000-0000-0000-00000000000a', 'Delta Dental insurance') like 'Since November%', 'correction not used';
  assert (select count(*) from knowledge_items where business_id = '5a000000-0000-0000-0000-00000000000a' and status = 'ready') = 1, 'old and new answers both live';
end $$;
set role authenticated;
update knowledge_items set status = 'archived' where id = (select id from t_ids where k = 'item');
reset role;
do $$ begin
  assert pg_temp.answer('5a000000-0000-0000-0000-00000000000a', 'Delta Dental insurance') is null, 'a removed answer is still given';
  raise notice 'PASS a correction replaces the answer (one live version); a removed answer is no longer given';
end $$;
