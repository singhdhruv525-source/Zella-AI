-- Business lifecycle and admin functions, on a restored baseline (tests/security/run.sh). Test data only.
-- Functions whose definitions were only in the live database (now in sql/baseline, identical to live by checksum on
-- 2026-11-04): is_platform_admin, zella_advance_onboarding, zella_change_business_industry,
-- zella_create_business_draft, zella_process_cancellations, zella_reactivate_business, zella_set_business_modules,
-- zella_suspend_business.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.act(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal2')::text, false);
  set role authenticated;
end $$;
create or replace function pg_temp.raises(p_sql text, p_code text) returns boolean language plpgsql as $$
begin execute p_sql; return false;
exception when others then return sqlerrm like '%' || p_code || '%';
end $$;

insert into industries (id, name, slug, is_active) values
  ('11000000-0000-0000-0000-000000000001', 'Salon', 'salon', true),
  ('11000000-0000-0000-0000-000000000002', 'Dental', 'dental', true),
  ('11000000-0000-0000-0000-000000000003', 'Retired', 'retired', false);
insert into industry_modules (id, industry_id, name, slug, is_active) values
  ('12000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', 'Calendar', 'calendar', true),
  ('12000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000001', 'Calls', 'calls', true),
  ('12000000-0000-0000-0000-000000000003', '11000000-0000-0000-0000-000000000001', 'Old', 'old', false),
  ('12000000-0000-0000-0000-000000000004', '11000000-0000-0000-0000-000000000002', 'Recalls', 'recalls', true);

-- 1. who may call them
reset role;
do $$ declare f text; bad text := '';
begin
  foreach f in array array['zella_advance_onboarding(uuid,text)', 'zella_change_business_industry(uuid,uuid)', 'zella_create_business_draft(jsonb)',
    'zella_process_cancellations()', 'zella_reactivate_business(uuid)', 'zella_set_business_modules(uuid,uuid[])', 'zella_suspend_business(uuid,text)'] loop
    if has_function_privilege('authenticated', 'public.' || f, 'execute') or has_function_privilege('anon', 'public.' || f, 'execute') then bad := bad || f || ' '; end if;
  end loop;
  assert bad = '', 'callable by signed-in users or visitors: ' || bad;
  raise notice 'PASS lifecycle functions are server-only (service role); signed-in users and visitors cannot call them';
end $$;

insert into auth.users (id, email, email_confirmed_at) select ('13000000-0000-0000-0000-00000000000' || i)::uuid, 'pa' || i || '@zella.test', now() from generate_series(1, 5) i;
insert into platform_admins (user_id, role, is_active) values
  ('13000000-0000-0000-0000-000000000001', 'zella_owner', true), ('13000000-0000-0000-0000-000000000002', 'super_admin', true),
  ('13000000-0000-0000-0000-000000000003', 'read_only_admin', true), ('13000000-0000-0000-0000-000000000004', 'zella_owner', false);
do $$ declare r text := ''; u int;
begin
  for u in 1..5 loop
    perform pg_temp.act(('13000000-0000-0000-0000-00000000000' || u)::uuid);
    r := r || case when public.is_platform_admin() then 'Y' else 'n' end;
    reset role;
  end loop;
  assert r = 'YYnnn', 'is_platform_admin for owner, super, read-only, inactive owner, nobody: ' || r;
  raise notice 'PASS is_platform_admin: active zella_owner and super_admin only (restricted, inactive and non-admins: no)';
end $$;

do $$ begin
  begin insert into platform_admins (user_id, role, is_active) values ('13000000-0000-0000-0000-000000000005', 'made_up_role', true);
    assert false, 'unknown admin role accepted';
  exception when others then assert sqlerrm like '%INVALID_ADMIN_ROLE%' or sqlerrm like '%check%', sqlerrm; end;
  raise notice 'PASS restricted admin roles can be granted (read_only_admin above); unknown roles are refused';
end $$;

-- 2. draft creation
reset role;
do $$ declare r jsonb; b record; n int;
begin
  assert pg_temp.raises($q$select public.zella_create_business_draft('{"name":"X","industry_id":"11000000-0000-0000-0000-000000000003"}')$q$, 'INDUSTRY_NOT_FOUND'), 'inactive industry accepted';
  r := public.zella_create_business_draft('{"name":"Glow","industry_id":"11000000-0000-0000-0000-000000000001","timezone":""}');
  select * into b from businesses where id = (r ->> 'business_id')::uuid;
  assert not b.is_active and b.onboarding_status = 'business_info' and b.timezone = 'America/New_York', 'draft state';
  select count(*) into n from business_modules where business_id = b.id and enabled;
  assert n = 2 and (r ->> 'modules_enabled')::int = 2, 'only the industry''s active modules start on: ' || n;
  assert (select status from ai_agents where id = (r ->> 'agent_id')::uuid) = 'disabled', 'receptionist starts disabled';
  perform set_config('zsec.biz', b.id::text, false);
  raise notice 'PASS draft: inactive, at business_info, industry''s active modules on, receptionist disabled; inactive industry refused';
end $$;

-- 3. onboarding moves forward only
do $$ declare b uuid := current_setting('zsec.biz')::uuid;
begin
  perform public.zella_advance_onboarding(b, 'industry_setup');
  perform public.zella_advance_onboarding(b, 'owner_setup');        -- backwards: ignored
  assert (select onboarding_status from businesses where id = b) = 'industry_setup', 'went backwards';
  assert pg_temp.raises(format('select public.zella_advance_onboarding(%L, %L)', b, 'bogus'), 'INVALID_STATUS'), 'unknown status accepted';
  raise notice 'PASS onboarding status only moves forward; unknown status refused';
end $$;

-- 4. modules: only this business's industry; other businesses untouched
do $$ declare b uuid := current_setting('zsec.biz')::uuid; other uuid; n int;
begin
  other := (public.zella_create_business_draft('{"name":"Other","industry_id":"11000000-0000-0000-0000-000000000001"}') ->> 'business_id')::uuid;
  assert pg_temp.raises(format('select public.zella_set_business_modules(%L, %L::uuid[])', b, '{12000000-0000-0000-0000-000000000004}'), 'MODULE_NOT_AVAILABLE'), 'another industry''s module accepted';
  assert pg_temp.raises(format('select public.zella_set_business_modules(%L, %L::uuid[])', b, '{12000000-0000-0000-0000-000000000003}'), 'MODULE_NOT_AVAILABLE'), 'inactive module accepted';
  n := public.zella_set_business_modules(b, '{12000000-0000-0000-0000-000000000001}');
  assert n = 1, 'enabled count ' || n;
  assert (select count(*) from business_modules where business_id = other and enabled) = 2, 'the other business changed';
  raise notice 'PASS modules: another industry''s or inactive module refused; only this business changes';
end $$;

-- 5. industry change resets modules and words
do $$ declare b uuid := current_setting('zsec.biz')::uuid;
begin
  update businesses set terminology_overrides = '{"customer":"Client"}' where id = b;
  perform public.zella_change_business_industry(b, '11000000-0000-0000-0000-000000000002');
  assert (select terminology_overrides from businesses where id = b) = '{}'::jsonb, 'words not reset';
  assert (select array_agg(module_id) from business_modules where business_id = b and enabled) = '{12000000-0000-0000-0000-000000000004}', 'modules not the new industry''s';
  assert pg_temp.raises(format('select public.zella_change_business_industry(%L, %L)', b, '11000000-0000-0000-0000-000000000003'), 'INDUSTRY_NOT_FOUND'), 'inactive industry accepted';
  raise notice 'PASS industry change: modules become the new industry''s, custom words cleared; inactive industry refused';
end $$;

-- 6. suspend / reactivate restores exactly what was running
do $$ declare b uuid := current_setting('zsec.biz')::uuid; a1 uuid; a2 uuid; au1 uuid; au2 uuid;
begin
  update businesses set is_active = true where id = b;
  update ai_agents set status = 'active' where business_id = b returning id into a1;
  insert into ai_agents (business_id, name, agent_type, status) values (b, 'Off agent', 'sales', 'disabled') returning id into a2;
  insert into automations (business_id, name, trigger_type, status) values (b, 'On', 'missed_call', 'active') returning id into au1;
  insert into automations (business_id, name, trigger_type, status) values (b, 'Paused already', 'no_show', 'paused') returning id into au2;
  assert pg_temp.raises(format('select public.zella_reactivate_business(%L)', b), 'NOT_SUSPENDED'), 'reactivated an active business';
  perform public.zella_suspend_business(b, 'unpaid');
  assert (select not is_active and suspended_at is not null and suspension_reason = 'unpaid' from businesses where id = b), 'suspend state';
  assert (select status from ai_agents where id = a1) = 'paused' and (select status from automations where id = au1) = 'paused', 'running things not paused';
  assert pg_temp.raises(format('select public.zella_suspend_business(%L, %L)', b, 'x'), 'ALREADY_SUSPENDED'), 'double suspend';
  perform public.zella_reactivate_business(b);
  assert (select is_active and suspended_at is null and not (setup_data ? 'suspended_state') from businesses where id = b), 'reactivate state';
  assert (select status from ai_agents where id = a1) = 'active' and (select status from automations where id = au1) = 'active', 'not restored';
  assert (select status from ai_agents where id = a2) = 'disabled' and (select status from automations where id = au2) = 'paused', 'something that was off came back on';
  raise notice 'PASS suspend/reactivate: running agents and automations pause and come back; ones already off stay off; double suspend and reactivating an active business refused';
end $$;

-- 7. scheduled cancellation: only due businesses; everything stops; then no suspend/reactivate
do $$ declare b uuid := current_setting('zsec.biz')::uuid; later uuid; plan uuid; n int;
begin
  insert into plans (name, slug) values ('Starter', 'starter') returning id into plan;
  insert into subscriptions (business_id, plan_id, status) values (b, plan, 'active');
  later := (public.zella_create_business_draft('{"name":"Later","industry_id":"11000000-0000-0000-0000-000000000001"}') ->> 'business_id')::uuid;
  update businesses set cancel_at = now() - interval '1 minute', cancellation_reason = 'asked' where id = b;
  update businesses set cancel_at = now() + interval '10 days' where id = later;
  n := public.zella_process_cancellations();
  assert n = 1, 'cancelled ' || n;
  assert (select cancelled_at is not null and not is_active from businesses where id = b), 'not cancelled';
  assert (select bool_and(status = 'disabled') from ai_agents where business_id = b) and (select bool_and(status = 'disabled') from automations where business_id = b), 'still running';
  assert (select status from subscriptions where business_id = b) = 'cancelled', 'subscription';
  assert (select cancelled_at is null from businesses where id = later), 'a future cancellation ran early';
  assert exists (select 1 from audit_logs where business_id = b and action = 'business.cancelled'), 'not audited';
  assert public.zella_process_cancellations() = 0, 'ran twice';
  assert pg_temp.raises(format('select public.zella_suspend_business(%L, %L)', b, 'x'), 'BUSINESS_CANCELLED'), 'suspended a cancelled business';
  raise notice 'PASS cancellation: only due businesses, agents/automations/subscription stopped, audited, runs once; a cancelled business cannot be suspended';
end $$;
