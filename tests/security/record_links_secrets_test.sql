-- Record links, sensitive fields and capacity (zella_record_links_secrets.sql).
\set ON_ERROR_STOP on
begin;
insert into public.industries (id, name, slug) values ('e4000000-0000-0000-0000-000000000001', 'Plumbing T', 'plumbing') on conflict do nothing;
insert into auth.users (id, email, email_confirmed_at) values
 ('e4000000-0000-0000-0000-00000000000a', 'own@l.test', now()), ('e4000000-0000-0000-0000-00000000000b', 'mgr@l.test', now()),
 ('e4000000-0000-0000-0000-00000000000c', 'tech1@l.test', now()), ('e4000000-0000-0000-0000-00000000000d', 'tech2@l.test', now()),
 ('e4000000-0000-0000-0000-00000000000e', 'view@l.test', now()), ('e4000000-0000-0000-0000-00000000000f', 'other@l.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('e4000000-0000-0000-0000-0000000000a1', 'Pipe Co', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing')),
 ('e4000000-0000-0000-0000-0000000000b1', 'Other Pipe', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing'));
insert into public.business_members (business_id, user_id, role, status)
select 'e4000000-0000-0000-0000-0000000000a1'::uuid, u::uuid, r, 'active' from (values
 ('e4000000-0000-0000-0000-00000000000a', 'owner'), ('e4000000-0000-0000-0000-00000000000b', 'manager'), ('e4000000-0000-0000-0000-00000000000c', 'staff'),
 ('e4000000-0000-0000-0000-00000000000d', 'staff'), ('e4000000-0000-0000-0000-00000000000e', 'viewer')) v(u, r)
union all select 'e4000000-0000-0000-0000-0000000000b1', 'e4000000-0000-0000-0000-00000000000f', 'owner', 'active';
insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, fields, enabled, capability, capacity)
select b::uuid, k, k, k, s::jsonb, c::text[], f::jsonb, true, cap, capa::jsonb from (values
 ('e4000000-0000-0000-0000-0000000000a1', 'properties', '[{"key":"active","label":"Active"}]', '{}',
   '[{"key":"address","label":"Address","type":"text"},{"key":"access","label":"Access instructions","type":"text","sensitive":true}]', null, null),
 ('e4000000-0000-0000-0000-0000000000a1', 'jobs', '[{"key":"new","label":"New"},{"key":"done","label":"Done"}]', '{done}',
   '[{"key":"property","label":"Property","type":"record","target":"properties"}]', null, null),
 ('e4000000-0000-0000-0000-0000000000a1', 'classes', '[{"key":"open","label":"Open"}]', '{}', '[{"key":"places","label":"Places","type":"number"}]', 'classes', null),
 ('e4000000-0000-0000-0000-0000000000a1', 'bookings', '[{"key":"booked","label":"Booked"},{"key":"waitlist","label":"Waitlist"}]', '{}',
   '[{"key":"class","label":"Class","type":"record","target":"classes"}]', null,
   '{"parent_field":"class","capacity_field":"places","counted":["booked"],"waitlist_status":"waitlist"}'),
 ('e4000000-0000-0000-0000-0000000000b1', 'properties', '[{"key":"active","label":"Active"}]', '{}', '[]', null, null)
) v(b, k, s, c, f, cap, capa);
insert into public.crm_records (id, business_id, type_key, title, status) values
 ('e4000000-0000-0000-0000-0000000000f1', 'e4000000-0000-0000-0000-0000000000b1', 'properties', 'B house', 'active');
-- classes: unsupported for plumbing, so insert as postgres for the capacity test and check refusal below
create temp table ids (k text primary key, id uuid) on commit drop;
grant all on ids to authenticated;
set local role authenticated;

-- manager stores an access code: not in data, only in secrets
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
insert into ids select 'prop', (public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'properties', null, '1 Main St', null, null, null, null,
  '{"address":"1 Main St","access":"Gate 4321"}') ->> 'id')::uuid;
do $$ begin
  assert not exists (select 1 from public.crm_records where data::text like '%4321%'), 'access code kept out of record data';
  begin perform * from public.crm_record_secrets; raise exception 'signed-in user read the secrets table';
  exception when insufficient_privilege then null; end;
  assert (public.zella_record_secrets((select id from ids where k = 'prop')) #>> '{values,access}') = 'Gate 4321', 'manager reads the code';
end $$;

-- staff: can edit other fields (code unchanged) but can't change the code
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ declare p uuid := (select id from ids where k = 'prop'); begin
  perform public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'properties', p, '1 Main Street', null, null, null, null, '{"address":"1 Main Street"}');
  begin perform public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'properties', p, '1 Main Street', null, null, null, null, '{"access":"0000"}');
    raise exception 'staff changed the code';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
  assert not (public.zella_record_secrets(p) ->> 'allowed')::boolean, 'unassigned staff can''t read the code';
  assert public.zella_record_secrets(p) -> 'values' is null, 'no values returned to unassigned staff';
end $$;

-- links: other business, wrong type, not an id, all refused
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'jobs', null, 'x', null, null, null, null, '{"property":"e4000000-0000-0000-0000-0000000000f1"}');
    raise exception 'linked another business''s record';
  exception when others then if sqlerrm not like 'BAD_LINK%' then raise; end if; end;
  begin perform public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'jobs', null, 'x', null, null, null, null, '{"property":"not-an-id"}');
    raise exception 'bad id accepted';
  exception when others then if sqlerrm not like 'BAD_LINK%' then raise; end if; end;
  begin perform public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'jobs', null, 'x', null, 'e4000000-0000-0000-0000-00000000000f', null, null, '{}');
    raise exception 'assigned to a non-member';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
end $$;
-- a job for tech1 today at that property
insert into ids select 'job', (public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'jobs', null, 'Leak', null, null,
  'e4000000-0000-0000-0000-00000000000c', now() + interval '2 hours', jsonb_build_object('property', (select id from ids where k = 'prop'))) ->> 'id')::uuid;
do $$ begin
  assert jsonb_array_length(public.zella_record_related((select id from ids where k = 'prop'))) = 1, 'property shows its job';
  begin perform public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'jobs', null, 'x', null, null, null, null,
      jsonb_build_object('property', (select id from ids where k = 'job'))); raise exception 'wrong type linked';
  exception when others then if sqlerrm not like 'BAD_LINK%' then raise; end if; end;
end $$;

-- assigned tech reads the code while the job is open; the other tech, the viewer and another business don't
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert (public.zella_record_secrets((select id from ids where k = 'prop')) #>> '{values,access}') = 'Gate 4321', 'assigned tech reads the code'; end $$;
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert not (public.zella_record_secrets((select id from ids where k = 'prop')) ->> 'allowed')::boolean, 'other tech refused'; end $$;
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000e","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert not (public.zella_record_secrets((select id from ids where k = 'prop')) ->> 'allowed')::boolean, 'viewer refused'; end $$;
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000f","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_record_secrets((select id from ids where k = 'prop')); raise exception 'other business read the code';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  begin perform public.zella_record_related((select id from ids where k = 'prop')); raise exception 'other business read links';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
-- job done: the tech's access ends
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
select public.zella_save_record('e4000000-0000-0000-0000-0000000000a1', 'jobs', (select id from ids where k = 'job'), 'Leak', 'done', null,
  'e4000000-0000-0000-0000-00000000000c', now() + interval '2 hours', jsonb_build_object('property', (select id from ids where k = 'prop')));
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert not (public.zella_record_secrets((select id from ids where k = 'prop')) ->> 'allowed')::boolean, 'access ends when the job is done'; end $$;

reset role;
do $$ begin
  assert exists (select 1 from public.crm_record_events where kind = 'secret_viewed' and detail = 'access'), 'reads audited by field name';
  assert exists (select 1 from public.crm_record_events where kind = 'secret_changed' and detail = 'access'), 'changes audited by field name';
  assert not exists (select 1 from public.crm_record_events where detail like '%4321%'), 'values never in history';
end $$;
-- the AI receptionist can't set a code
select public.zella_crm_write_record(null, 'ai', 'e4000000-0000-0000-0000-0000000000a1', 'properties', null, 'AI house', null, null, null, null, '{"access":"9999"}');
do $$ begin assert not exists (select 1 from public.crm_record_secrets where value = '9999'), 'AI write ignored for sensitive fields'; end $$;

-- capability on the type: classes aren't offered for plumbing
do $$ begin
  begin perform public.zella_crm_write_record(null, 'staff', 'e4000000-0000-0000-0000-0000000000a1', 'classes', null, 'Yoga', null, null, null, null, '{"places":1}');
    raise exception 'record created while its capability is off';
  exception when others then if sqlerrm not like 'CAPABILITY_OFF:classes%' then raise; end if; end;
end $$;
-- capacity: one place, the second booking goes to the waitlist
update public.crm_record_types set capability = null where key = 'classes';
insert into ids select 'class', (public.zella_crm_write_record(null, 'staff', 'e4000000-0000-0000-0000-0000000000a1', 'classes', null, 'Yoga', null, null, null, null, '{"places":1}') ->> 'id')::uuid;
do $$ declare r1 jsonb; r2 jsonb; c text := (select id::text from ids where k = 'class'); begin
  r1 := public.zella_crm_write_record(null, 'staff', 'e4000000-0000-0000-0000-0000000000a1', 'bookings', null, 'A', 'booked', null, null, null, jsonb_build_object('class', c));
  r2 := public.zella_crm_write_record(null, 'staff', 'e4000000-0000-0000-0000-0000000000a1', 'bookings', null, 'B', 'booked', null, null, null, jsonb_build_object('class', c));
  assert r1 ->> 'status' = 'booked' and r2 ->> 'status' = 'waitlist' and (r2 ->> 'waitlisted')::boolean, format('capacity: %s %s', r1, r2);
end $$;

-- existing plain values move out of data
insert into public.crm_records (business_id, type_key, title, status, data) values ('e4000000-0000-0000-0000-0000000000a1', 'properties', 'Old', 'active', '{"access":"Key under mat"}');
do $$ begin
  assert public.zella_move_sensitive_values() = 1, 'one value moved';
  assert not exists (select 1 from public.crm_records where data ? 'access'), 'no plain codes left in data';
end $$;
-- Customize records: links accepted to own types only; a sensitive field can't be made plain
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e4000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_save_record_type('e4000000-0000-0000-0000-0000000000a1', 'jobs', '{"fields":[{"key":"property","label":"Property","type":"record","target":"nope"}]}');
    raise exception 'link to an unknown type accepted';
  exception when others then if sqlerrm not like 'BAD_LINK%' then raise; end if; end;
  begin perform public.zella_save_record_type('e4000000-0000-0000-0000-0000000000a1', 'properties',
      '{"fields":[{"key":"address","label":"Address","type":"text"},{"key":"access","label":"Access instructions","type":"text"}]}');
    raise exception 'sensitive field made plain';
  exception when others then if sqlerrm not like 'FIELD_LOCKED%' then raise; end if; end;
  perform public.zella_save_record_type('e4000000-0000-0000-0000-0000000000a1', 'jobs', '{"fields":[{"key":"property","label":"Property","type":"record","target":"properties"},{"key":"notes","label":"Notes","type":"text"}]}');
end $$;
reset role;
select 'PASS record links (same business, right type), sensitive fields (managers + assigned staff while open, audited without values, AI and staff can''t set), capacity waitlist';
rollback;
