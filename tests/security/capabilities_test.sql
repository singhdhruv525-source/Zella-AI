-- Industry capabilities (zella_capabilities.sql): industry defaults, business choices kept apart, dependencies,
-- states, owner-only changes, and server refusal of appointments / waitlist when the capability is off.
\set ON_ERROR_STOP on
begin;
insert into public.industries (name, slug) select s, s from unnest(array['automotive','beauty-salon','childcare','cleaning-services','dental','ecommerce','education','electrical','financial-services','fitness','healthcare','home-services','hospitality','hvac','insurance','landscaping-lawn-care','legal','other','pest-control','pet-care-veterinary','photography-events','plumbing','professional-services','property-management','real-estate','restaurant','spa-wellness','travel']) s where not exists (select 1 from public.industries i where i.slug = s);
select public.zella_seed_capability_defaults() as seeded;
insert into auth.users (id, email, email_confirmed_at) values
 ('e3000000-0000-0000-0000-00000000000a', 'own@cap.test', now()), ('e3000000-0000-0000-0000-00000000000b', 'stf@cap.test', now()), ('e3000000-0000-0000-0000-00000000000c', 'out@cap.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('e3000000-0000-0000-0000-0000000000b1', 'Shop Co', 'UTC', true, 'active', (select id from public.industries where slug = 'ecommerce')),
 ('e3000000-0000-0000-0000-0000000000b2', 'Plumb Co', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing')),
 ('e3000000-0000-0000-0000-0000000000b3', 'Dent Co', 'UTC', true, 'active', (select id from public.industries where slug = 'dental'));
insert into public.business_members (business_id, user_id, role, status)
select b, u, r, 'active' from (values
 ('e3000000-0000-0000-0000-0000000000b1'::uuid, 'e3000000-0000-0000-0000-00000000000a'::uuid, 'owner'),
 ('e3000000-0000-0000-0000-0000000000b2', 'e3000000-0000-0000-0000-00000000000a', 'owner'),
 ('e3000000-0000-0000-0000-0000000000b3', 'e3000000-0000-0000-0000-00000000000a', 'owner'),
 ('e3000000-0000-0000-0000-0000000000b1', 'e3000000-0000-0000-0000-00000000000b', 'staff')) v(b, u, r);
insert into public.business_hours (business_id, weekday, opens, closes) values ('e3000000-0000-0000-0000-0000000000b3', 1, '09:00', '17:00');

do $$ declare c jsonb; begin
  assert (select count(*) from public.industries i join public.industry_configurations ic on ic.industry_id = i.id where ic.features ? 'capabilities') >= 28, 'every industry has capability defaults';
  c := public.zella_capabilities('e3000000-0000-0000-0000-0000000000b1');
  assert c #>> '{scheduling,state}' = 'off' and (c #>> '{scheduling,supported}')::boolean, 'shop: scheduling optional and off';
  assert c #>> '{checkins,state}' = 'unsupported' and c #>> '{waitlist,state}' = 'unsupported', 'shop: no check-ins or waitlist';
  assert c #>> '{orders,state}' = 'needs_setup', 'shop: orders on but no store connected';
  c := public.zella_capabilities('e3000000-0000-0000-0000-0000000000b2');
  assert (c #>> '{dispatch,enabled}')::boolean and c #>> '{checkins,state}' = 'unsupported', 'plumbing: dispatch on, no check-ins';
  c := public.zella_capabilities('e3000000-0000-0000-0000-0000000000b3');
  assert c #>> '{scheduling,state}' = 'on' and c #>> '{checkins,state}' = 'on', 'dental: scheduling and check-ins on';
  assert c #>> '{dispatch,state}' = 'unsupported', 'dental: no dispatch';
end $$;

-- server refuses appointments where scheduling is off (every path, including service role)
do $$ begin
  begin
    insert into public.appointments (business_id, title, start_time, end_time) values ('e3000000-0000-0000-0000-0000000000b1', 'x', now(), now() + interval '1 hour');
    raise exception 'shop booked an appointment';
  exception when others then if sqlerrm not like '%CAPABILITY_OFF:scheduling%' then raise; end if; end;
  insert into public.appointments (business_id, title, start_time, end_time) values ('e3000000-0000-0000-0000-0000000000b3', 'ok', now(), now() + interval '1 hour');
end $$;

set local role authenticated;
-- staff can't change capabilities; outsiders can't read them
select set_config('request.jwt.claims', '{"sub":"e3000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_capability('e3000000-0000-0000-0000-0000000000b1', 'scheduling', true); raise exception 'staff changed a capability';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"e3000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_capabilities('e3000000-0000-0000-0000-0000000000b1'); raise exception 'outsider read capabilities';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  assert (select count(*) from public.business_capabilities) = 0, 'outsider sees no capability rows';
end $$;

-- owner: unsupported refused, dependency enforced, choice kept and survives a re-run of defaults
select set_config('request.jwt.claims', '{"sub":"e3000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ declare c jsonb; begin
  begin perform public.zella_set_capability('e3000000-0000-0000-0000-0000000000b1', 'checkins', true); raise exception 'shop turned on check-ins';
  exception when others then if sqlerrm not like '%NOT_FOR_THIS_INDUSTRY%' then raise; end if; end;
  c := public.zella_set_capability('e3000000-0000-0000-0000-0000000000b1', 'scheduling', true);
  assert (c #>> '{scheduling,enabled}')::boolean and (c #>> '{scheduling,chosen}')::boolean, 'shop owner turned scheduling on';
  c := public.zella_set_capability('e3000000-0000-0000-0000-0000000000b3', 'scheduling', false);
  assert not (c #>> '{checkins,enabled}')::boolean and not (c #>> '{waitlist,enabled}')::boolean, 'check-ins and waitlist follow scheduling';
  begin perform public.zella_set_capability('e3000000-0000-0000-0000-0000000000b3', 'waitlist', true); raise exception 'waitlist on without scheduling';
  exception when others then if sqlerrm not like '%NEEDS:scheduling%' then raise; end if; end;
  assert (select count(*) from public.appointments where business_id = 'e3000000-0000-0000-0000-0000000000b3') = 1, 'turning scheduling off deletes nothing';
  assert (select count(*) from public.audit_logs where action = 'capability_changed' and business_id in ('e3000000-0000-0000-0000-0000000000b1', 'e3000000-0000-0000-0000-0000000000b3')) = 2, 'changes audited';
end $$;
reset role;
-- re-applying the industry defaults doesn't overwrite the business choice
update public.industry_configurations set features = features || '{}'::jsonb;
do $$ begin
  assert public.zella_capability_on('e3000000-0000-0000-0000-0000000000b1', 'scheduling'), 'shop choice kept';
  assert not public.zella_capability_on('e3000000-0000-0000-0000-0000000000b3', 'checkins'), 'dental choice kept';
  insert into public.appointments (business_id, title, start_time, end_time) values ('e3000000-0000-0000-0000-0000000000b1', 'now allowed', now(), now() + interval '1 hour');
end $$;
-- waitlist refused once scheduling is off
do $$ begin
  begin perform public.zella_join_waitlist('e3000000-0000-0000-0000-0000000000b3', null); raise exception 'waitlist joined while off';
  exception when others then if sqlerrm not like '%CAPABILITY_OFF:waitlist%' then raise; end if; end;
end $$;
-- check-ins refused once scheduling (and so check-ins) is off; finishing the visit still works; navigation carries capabilities
do $$ declare v uuid; begin
  select id into v from public.appointments where business_id = 'e3000000-0000-0000-0000-0000000000b3';
  begin perform public.zella_set_attendance(v, 'arrived'); raise exception 'checked in while off';
  exception when others then if sqlerrm not like '%CAPABILITY_OFF:checkins%' then raise; end if; end;
  perform public.zella_set_attendance(v, 'completed');
  assert public.zella_workspace_navigation('e3000000-0000-0000-0000-0000000000b1') ? 'capabilities', 'navigation includes capabilities';
end $$;
-- Today counts open work per enabled type in the business's time zone; closed, archived and other businesses excluded
reset role;
insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, enabled, position) values
 ('e3000000-0000-0000-0000-0000000000b2', 'jobs', 'Job', 'Jobs', '["new","done"]', '{done}', true, 1),
 ('e3000000-0000-0000-0000-0000000000b2', 'old', 'Old', 'Olds', '["new"]', '{}', false, 2),
 ('e3000000-0000-0000-0000-0000000000b1', 'jobs', 'Job', 'Jobs', '["new","done"]', '{done}', true, 1);
insert into public.crm_records (business_id, type_key, title, status, due_at, archived_at) values
 ('e3000000-0000-0000-0000-0000000000b2', 'jobs', 'late', 'new', now() - interval '2 days', null),
 ('e3000000-0000-0000-0000-0000000000b2', 'jobs', 'open', 'new', null, null),
 ('e3000000-0000-0000-0000-0000000000b2', 'jobs', 'finished', 'done', now() - interval '2 days', null),
 ('e3000000-0000-0000-0000-0000000000b2', 'jobs', 'archived', 'new', now() - interval '2 days', now()),
 ('e3000000-0000-0000-0000-0000000000b1', 'jobs', 'other business', 'new', null, null);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e3000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ declare t jsonb; begin
  t := public.zella_today_operations('e3000000-0000-0000-0000-0000000000b2');
  assert jsonb_array_length(t) = 1, 'only enabled types';
  assert (t -> 0 ->> 'open')::int = 2 and (t -> 0 ->> 'overdue')::int = 1, format('open 2, overdue 1: %s', t);
end $$;
select set_config('request.jwt.claims', '{"sub":"e3000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_today_operations('e3000000-0000-0000-0000-0000000000b2'); raise exception 'outsider read Today counts';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
reset role;
select 'PASS capabilities: industry defaults, owner choices kept, dependencies, server refusal of bookings/waitlist when off, no deletion';
rollback;
