-- Setup readiness (zella_readiness.sql): each rung only when every check below it passes, read from real records.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values ('e8000000-0000-0000-0000-00000000000a', 'own@r.test', now()), ('e8000000-0000-0000-0000-00000000000b', 'out@r.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values ('e8000000-0000-0000-0000-0000000000a1', 'Ready Co', 'UTC', false, 'business_info');
create temp table st (n int, state text) on commit drop;
create or replace function pg_temp.rung() returns text language sql as $$ select public.zella_business_readiness('e8000000-0000-0000-0000-0000000000a1') ->> 'state' $$;
do $$ begin assert pg_temp.rung() = 'saved', 'a draft is saved, nothing more'; end $$;
insert into public.business_members (business_id, user_id, role, status) values ('e8000000-0000-0000-0000-0000000000a1', 'e8000000-0000-0000-0000-00000000000a', 'owner', 'active');
update public.businesses set onboarding_status = 'testing' where id = 'e8000000-0000-0000-0000-0000000000a1';
insert into public.crm_record_types (business_id, key, singular, plural, statuses) values ('e8000000-0000-0000-0000-0000000000a1', 'jobs', 'Job', 'Jobs', '[{"key":"open","label":"Open"}]');
do $$ begin assert pg_temp.rung() = 'saved', 'no opening hours yet while it takes bookings'; end $$;
insert into public.business_hours (business_id, weekday, opens, closes) values ('e8000000-0000-0000-0000-0000000000a1', 1, '09:00', '17:00');
do $$ begin assert pg_temp.rung() = 'setup_complete', 'setup complete'; end $$;
insert into public.business_phone_numbers (business_id, e164) values ('e8000000-0000-0000-0000-0000000000a1', '+15125550100');
do $$ begin assert pg_temp.rung() = 'setup_complete', 'phone alone is not verified'; end $$;
insert into public.integrations (business_id, provider, integration_type) values ('e8000000-0000-0000-0000-0000000000a1', 'telnyx', 'voice');
do $$ begin assert pg_temp.rung() = 'integrations_verified', 'integrations verified'; end $$;
insert into public.ai_agents (business_id, name, agent_type, status) values ('e8000000-0000-0000-0000-0000000000a1', 'Receptionist', 'receptionist', 'paused');
do $$ begin assert pg_temp.rung() = 'integrations_verified', 'a paused receptionist is not ready'; end $$;
update public.ai_agents set status = 'active' where business_id = 'e8000000-0000-0000-0000-0000000000a1';
do $$ begin assert pg_temp.rung() = 'ready', 'ready'; end $$;
update public.businesses set onboarding_status = 'active', is_active = true where id = 'e8000000-0000-0000-0000-0000000000a1';
do $$ begin assert pg_temp.rung() = 'live', 'live'; end $$;
-- a lower rung breaking drops the state, whatever the status says
delete from public.business_hours where business_id = 'e8000000-0000-0000-0000-0000000000a1';
do $$ begin assert pg_temp.rung() = 'saved', 'never "live" while a setup check fails'; end $$;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e8000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_business_readiness('e8000000-0000-0000-0000-0000000000a1'); raise exception 'outsider read readiness';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select 'PASS readiness: saved → setup complete → integrations verified → ready → live, each from real records; a failing lower check drops it; outsiders refused';
rollback;
