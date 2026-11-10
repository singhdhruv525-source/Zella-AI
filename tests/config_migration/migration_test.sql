-- Regression tests for sql/zella_config_migration.sql (tests/config_migration/run.sh). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
-- businesses set up BEFORE zella_setup_enforcement: their setup answers are saved but not live. The knowledge trigger
-- would sync on insert, so it is switched off while the old state is recreated.
alter table ai_agent_configs disable trigger zella_setup_knowledge_trg;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status, setup_data)
select v.id::uuid, v.n, i.id, 'UTC', true, 'active', v.sd::jsonb from industries i, (values
  ('ef000000-0000-0000-0000-000000000001', 'Lang Salon', '{}'),
  ('ef000000-0000-0000-0000-000000000002', 'Owner Lang Salon', '{}'),
  ('ef000000-0000-0000-0000-000000000003', 'Bad Greeting Salon', '{}'),
  ('ef000000-0000-0000-0000-000000000004', 'FAQ Salon', '{}'),
  ('ef000000-0000-0000-0000-000000000005', 'Admin Routing Salon', '{"integrations":{"transfer_number":"+15125550505"}}'),
  ('ef000000-0000-0000-0000-000000000006', 'Owner Phone Salon', '{"owner":{"phone":"+15125550606"}}'),
  ('ef000000-0000-0000-0000-000000000007', 'Up To Date Salon', '{}')) v(id, n, sd)
 where i.slug = 'beauty-salon';
insert into ai_agents (id, business_id, name, agent_type, status, is_default)
select ('ef1' || substr(b.id::text, 4))::uuid, b.id, 'Ava', 'receptionist', 'active', true from businesses b where b.id::text like 'ef000000-%';
insert into ai_agent_configs (agent_id, voice_config, knowledge_base, escalation_rules) values
  ('ef100000-0000-0000-0000-000000000001', '{"language":"en-US+es-US","greeting":"Hello from Lang Salon!"}', '{}', '{}'),
  ('ef100000-0000-0000-0000-000000000002', '{"language":"en-US+es-US","greeting":"Hi there"}', '{}', '{}'),
  ('ef100000-0000-0000-0000-000000000003', '{"language":"en-US","greeting":"Visit https://evil.example now"}', '{}', '{}'),
  ('ef100000-0000-0000-0000-000000000004', '{}', '{"faqs":[{"question":"Parking?","answer":"Free behind the shop."}],"about":"Since 1998."}', '{}'),
  ('ef100000-0000-0000-0000-000000000005', '{}', '{}', '{"transfer_number":"+15125550599","transfer_to":{"type":"phone_number","phone":"+15125550500"}}'),
  ('ef100000-0000-0000-0000-000000000006', '{}', '{}', '{"transfer_to":{"type":"owner"}}'),
  ('ef100000-0000-0000-0000-000000000007', '{}', '{}', '{}');
insert into business_languages (business_id, primary_language, extra_languages, greeting) values ('ef000000-0000-0000-0000-000000000002', 'es', '{}', 'Hola, ¿en qué puedo ayudarle?');
alter table ai_agent_configs enable trigger zella_setup_knowledge_trg;

create temp table t_before as select jsonb_agg(x order by x ->> 'name') j from jsonb_array_elements(public.zella_config_migration_preview()) x where x ->> 'business_id' like 'ef000000-%';
do $$ declare p jsonb := (select j from t_before); f jsonb; begin
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'Lang Salon');
  assert (f ->> 'stale')::boolean and f #>> '{items,0,action}' = 'apply_setup' and f #>> '{items,0,proposed,primary}' = 'en-US' and f #>> '{items,0,proposed,extras,0}' = 'es', 'language: ' || f::text;
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'Owner Lang Salon');
  assert f #>> '{items,0,action}' = 'keep_override' and not (f ->> 'stale')::boolean, 'owner choice: ' || f::text;
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'Bad Greeting Salon');
  assert f #>> '{items,0,action}' = 'needs_fix' and f #>> '{items,0,reason}' like '%GREETING_TEXT%', 'validation: ' || f::text;
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'FAQ Salon');
  assert f #>> '{items,0,setting}' = 'setup_knowledge' and f #>> '{items,0,action}' = 'apply_setup' and (f #>> '{items,0,setup}')::int = 2 and (f #>> '{items,0,live}')::int = 0, 'knowledge: ' || f::text;
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'Admin Routing Salon');
  assert f #>> '{items,0,action}' = 'keep_override' and f #>> '{items,0,live}' = '…99' and f::text not like '%5125550599%', 'admin routing: ' || f::text;
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'Owner Phone Salon');
  assert f #>> '{items,0,action}' = 'apply_setup' and f #>> '{items,0,setup}' = '…06', 'owner phone: ' || f::text;
  f := (select x from jsonb_array_elements(p) x where x ->> 'name' = 'Up To Date Salon');
  assert not (f ->> 'stale')::boolean, 'nothing to do flagged stale';
  raise notice 'PASS preview: old and proposed values, source precedence (owner''s Settings and admin routing kept), validation (needs_fix), masked numbers, businesses with nothing to do';
end $$;

-- apply everything, keep the snapshots
create temp table t_snaps as select x ->> 'business_id' bid, public.zella_config_migration_apply((x ->> 'business_id')::uuid) r
  from jsonb_array_elements((select j from t_before)) x;
do $$ declare p jsonb; begin
  p := (select jsonb_agg(x) from jsonb_array_elements(public.zella_config_migration_preview()) x where x ->> 'business_id' like 'ef000000-%');
  assert (select count(*) from jsonb_array_elements(p) x where (x ->> 'stale')::boolean) = 1, 'still stale after apply: ' || p::text;
  assert (select x ->> 'name' from jsonb_array_elements(p) x where (x ->> 'stale')::boolean) = 'Bad Greeting Salon', 'the one left must be the invalid one';
  assert (select primary_language || '+' || array_to_string(extra_languages, ',') from business_languages where business_id = 'ef000000-0000-0000-0000-000000000001') = 'en-US+es', 'language not live';
  assert (select greeting from business_languages where business_id = 'ef000000-0000-0000-0000-000000000002') = 'Hola, ¿en qué puedo ayudarle?', 'owner override overwritten';
  assert not exists (select 1 from business_languages where business_id = 'ef000000-0000-0000-0000-000000000003'), 'invalid greeting applied';
  assert (public.zella_brain_search('ef000000-0000-0000-0000-000000000004', 'parking', 3) -> 'results' -> 0 ->> 'answer') like 'Free behind%', 'FAQ not answerable';
  assert (select escalation_rules ->> 'transfer_number' from ai_agent_configs where agent_id = 'ef100000-0000-0000-0000-000000000005') = '+15125550599', 'admin number replaced';
  assert (select escalation_rules ->> 'transfer_number' from ai_agent_configs where agent_id = 'ef100000-0000-0000-0000-000000000006') = '+15125550606', 'owner phone not used';
  assert (select count(*) from staff_notifications where kind = 'settings_migrated' and business_id::text like 'ef000000-%') = 3, 'owners not told what changed';
  raise notice 'PASS apply: every business is up to date except the one whose setup value fails validation (still reported); owner and admin overrides kept; owners told';
end $$;

-- restore puts each business back exactly
do $$ declare s record; begin
  for s in select r ->> 'snapshot_id' sid from t_snaps loop perform public.zella_config_migration_restore(s.sid::uuid); end loop;
  assert (select jsonb_agg(x order by x ->> 'name') from jsonb_array_elements(public.zella_config_migration_preview()) x where x ->> 'business_id' like 'ef000000-%') = (select j from t_before),
    'restore is not exact';
  assert not exists (select 1 from business_languages where business_id = 'ef000000-0000-0000-0000-000000000001'), 'language not removed';
  assert (public.zella_brain_search('ef000000-0000-0000-0000-000000000004', 'parking', 3) ->> 'confidence') = 'none', 'FAQ still answered after restore';
  assert (select greeting from business_languages where business_id = 'ef000000-0000-0000-0000-000000000002') = 'Hola, ¿en qué puedo ayudarle?', 'owner row lost on restore';
  raise notice 'PASS restore: the preview after restoring is identical to the one before applying; owner choices survive';
end $$;
