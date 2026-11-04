-- Preset upgrades (zella_presets_v2.sql): existing businesses get new fields and privacy, never lose their own changes,
-- get new types switched off; new businesses get everything on; industry split (insurance) moves to its own preset.
\set ON_ERROR_STOP on
begin;
insert into public.industries (id, name, slug) values
 ('e7000000-0000-0000-0000-000000000001', 'Plumbing', 'plumbing'), ('e7000000-0000-0000-0000-000000000002', 'Insurance', 'insurance') on conflict (slug) do nothing;
insert into public.industry_crm_presets (key, match, config) values
 ('plumbing', '{plumbing,plumber}', '{"types":[{"key":"properties","singular":"Property","plural":"Properties","title_label":"Property","statuses":[{"key":"active","label":"Active"}],"closed_statuses":[],
   "fields":[{"key":"address","label":"Address","type":"text"},{"key":"access","label":"Access instructions","type":"longtext"}]},
  {"key":"jobs","singular":"Job","plural":"Jobs","statuses":[{"key":"new","label":"New"}],"closed_statuses":[],"fields":[{"key":"issue","label":"Issue","type":"text"}]}]}'),
 ('financial_services', '{financialservices,insurance}', '{"types":[{"key":"opportunities","singular":"Opportunity","plural":"Opportunities","statuses":[{"key":"open","label":"Open"}],"closed_statuses":[],"fields":[]},
  {"key":"requests","singular":"Request","plural":"Requests","statuses":[{"key":"open","label":"Open"}],"closed_statuses":[],"fields":[]}]}'),
 ('other', '{other}', '{"types":[]}')
on conflict (key) do update set match = excluded.match, config = excluded.config;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('e7000000-0000-0000-0000-0000000000a1', 'Old Plumber', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing')),
 ('e7000000-0000-0000-0000-0000000000a2', 'Insure Co', 'UTC', true, 'active', (select id from public.industries where slug = 'insurance'));
select public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a1'), public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a2');
-- the owner's own changes: a renamed field label, an extra field, an own type; a plain access code; an insurance record
update public.crm_record_types set fields = '[{"key":"address","label":"Street address","type":"text"},{"key":"access","label":"Access instructions","type":"longtext"},{"key":"own","label":"Own field","type":"text"}]'
 where business_id = 'e7000000-0000-0000-0000-0000000000a1' and key = 'properties';
insert into public.crm_record_types (business_id, key, singular, plural, statuses, fields) values
 ('e7000000-0000-0000-0000-0000000000a1', 'mine', 'Mine', 'Mine', '[{"key":"open","label":"Open"}]', '[{"key":"access","label":"Access","type":"longtext"}]');
insert into public.crm_records (business_id, type_key, title, status, data) values
 ('e7000000-0000-0000-0000-0000000000a1', 'properties', '1 Main', 'active', '{"address":"1 Main","access":"Code 2468"}'),
 ('e7000000-0000-0000-0000-0000000000a1', 'mine', 'x', 'open', '{"access":"kept plain"}'),
 ('e7000000-0000-0000-0000-0000000000a2', 'opportunities', 'Lead', 'open', '{}');
update public.crm_record_types set fields_seen = array(select f ->> 'key' from jsonb_array_elements(fields) f) where business_id in ('e7000000-0000-0000-0000-0000000000a1', 'e7000000-0000-0000-0000-0000000000a2');

-- version 2: access private, a new field, a property link on jobs, a new type; insurance gets its own preset
select public.zella_preset_v2_merge('{
 "plumbing": {"types": [
   {"key":"properties","add_fields":[{"key":"water_heater","label":"Water heater","type":"text"}],"sensitive":["access"]},
   {"key":"jobs","add_fields":[{"key":"property","label":"Property","type":"record","target":"properties"}],"capability":"dispatch"},
   {"key":"permits","singular":"Permit","plural":"Permits","statuses":[{"key":"open","label":"Open"}],"closed_statuses":[],"fields":[]}]},
 "financial_services": {"match": ["financialservices"], "types": []},
 "insurance": {"new": true, "match": ["insurance"], "types": [
   {"key":"policies","singular":"Policy","plural":"Policies","statuses":[{"key":"active","label":"Active"}],"closed_statuses":[],"fields":[{"key":"policy_number","label":"Policy number","type":"text"}]}]}}');

do $$ declare f jsonb; begin
  assert public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a1') > 0, 'upgrade ran';
  f := (select fields from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a1' and key = 'properties');
  assert (select x ->> 'label' from jsonb_array_elements(f) x where x ->> 'key' = 'address') = 'Street address', 'owner''s label kept';
  assert exists (select 1 from jsonb_array_elements(f) x where x ->> 'key' = 'own'), 'owner''s field kept';
  assert exists (select 1 from jsonb_array_elements(f) x where x ->> 'key' = 'water_heater'), 'new field added';
  assert (select (x ->> 'sensitive')::boolean from jsonb_array_elements(f) x where x ->> 'key' = 'access'), 'access now private';
  assert not exists (select 1 from public.crm_records where type_key = 'properties' and data ? 'access'), 'plain code moved out';
  assert (select value from public.crm_record_secrets s join public.crm_records r on r.id = s.record_id where r.title = '1 Main') = 'Code 2468', 'code kept, privately';
  assert (select data ->> 'access' from public.crm_records where type_key = 'mine') = 'kept plain', 'business''s own type untouched';
  assert (select capability from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a1' and key = 'jobs') = 'dispatch', 'capability set';
  assert exists (select 1 from public.crm_record_types t, jsonb_array_elements(t.fields) x where t.business_id = 'e7000000-0000-0000-0000-0000000000a1' and t.key = 'jobs' and x ->> 'type' = 'record'), 'link added';
  assert (select not enabled from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a1' and key = 'permits'), 'new type off for an existing business';
  assert public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a1') = 0, 'second run changes nothing';
end $$;
-- a field the business had and removed (simulated) is never re-added
update public.crm_record_types set fields = (select jsonb_agg(x) from jsonb_array_elements(fields) x where x ->> 'key' <> 'water_heater')
 where business_id = 'e7000000-0000-0000-0000-0000000000a1' and key = 'properties';
do $$ begin
  perform public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a1');
  assert not exists (select 1 from public.crm_record_types t, jsonb_array_elements(t.fields) x where t.business_id = 'e7000000-0000-0000-0000-0000000000a1' and t.key = 'properties' and x ->> 'key' = 'water_heater'),
    'removed field not re-added';
end $$;
-- a new business gets everything on
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('e7000000-0000-0000-0000-0000000000a3', 'New Plumber', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing'));
do $$ begin
  perform public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a3');
  assert (select bool_and(enabled) from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a3'), 'new business: all on';
  assert (select count(*) from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a3') = 3, 'new business: three types';
end $$;
-- insurance: its own records on; the old type with records stays, the empty one goes off; nothing deleted
do $$ begin
  perform public.zella_apply_crm_preset('e7000000-0000-0000-0000-0000000000a2');
  assert (select enabled from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a2' and key = 'policies'), 'insurance policies on';
  assert (select enabled from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a2' and key = 'opportunities'), 'type with records stays';
  assert (select not enabled from public.crm_record_types where business_id = 'e7000000-0000-0000-0000-0000000000a2' and key = 'requests'), 'empty old type off';
  assert (select count(*) from public.crm_records where business_id = 'e7000000-0000-0000-0000-0000000000a2') = 1, 'nothing deleted';
end $$;
select 'PASS preset upgrades: owner changes kept, new fields and privacy added, removed fields not re-added, new types off for existing / on for new, insurance split, idempotent';
rollback;
