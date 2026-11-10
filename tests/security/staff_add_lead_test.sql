-- Add lead from the CRM: goes through zella_capture_lead (stage, deadline, task, callback); viewers refused.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values ('d1000000-0000-0000-0000-00000000000a', 'v2@t.test', now()), ('d1000000-0000-0000-0000-00000000000b', 's2@t.test', now());
insert into public.profiles (id) values ('d1000000-0000-0000-0000-00000000000a'), ('d1000000-0000-0000-0000-00000000000b') on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values ('d1000000-0000-0000-0000-0000000000b1', 'Lead Test Co', 'UTC', true, 'active');
insert into public.business_members (business_id, user_id, role, status) values
  ('d1000000-0000-0000-0000-0000000000b1', 'd1000000-0000-0000-0000-00000000000a', 'viewer', 'active'),
  ('d1000000-0000-0000-0000-0000000000b1', 'd1000000-0000-0000-0000-00000000000b', 'staff', 'active');
insert into public.automations (business_id, name, trigger_type, status, trigger_config, actions, conditions)
  values ('d1000000-0000-0000-0000-0000000000b1', 'New-lead callback', 'new_lead_callback', 'active', '{"contact_within_minutes": 30}', '[]', '{}');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d1000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin perform public.zella_staff_add_lead('d1000000-0000-0000-0000-0000000000b1', 'Vic', null, '+15125550999');
  raise exception 'viewer added a lead'; exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end $$;
select set_config('request.jwt.claims', '{"sub":"d1000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ declare r jsonb; c record; begin
  r := public.zella_staff_add_lead('d1000000-0000-0000-0000-0000000000b1', 'Jamie', 'Rivera', '+15125550123', 'jamie@x.test', 'walk_in', 'Wants a quote');
  assert r ->> 'result' = 'created', 'created: ' || r::text;
  select lead_stage, contact_deadline_at, source into c from public.customers where id = (r ->> 'customer_id')::uuid;
  assert c.lead_stage = 'new' and c.contact_deadline_at is not null and c.source = 'walk_in', 'lead stage, deadline and source set';
  assert (select count(*) from public.callbacks where customer_id = (r ->> 'customer_id')::uuid) = 1, 'new-lead callback created';
  r := public.zella_staff_add_lead('d1000000-0000-0000-0000-0000000000b1', 'Jamie', 'Rivera', '+15125550123', 'jamie@x.test');
  assert r ->> 'result' = 'matched', 'second time: matched, not a duplicate: ' || r::text;
end $$;
select 'PASS Add lead uses the lead pipeline (stage, deadline, callback, duplicate check); viewers refused';
rollback;
