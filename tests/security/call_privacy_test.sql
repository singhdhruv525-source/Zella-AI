-- Call transcripts and recordings (zella_call_content_privacy.sql): staff and viewers can't read them from the table
-- or the view; managers can through the view; the owner may open transcripts to staff except in sensitive industries;
-- other businesses' calls stay invisible.
\set ON_ERROR_STOP on
begin;
insert into public.industries (id, name, slug) values ('e2000000-0000-0000-0000-000000000001', 'Salon T', 'beauty-salon-t'), ('e2000000-0000-0000-0000-000000000002', 'Dental T', 'dental') on conflict do nothing;
insert into auth.users (id, email, email_confirmed_at) values
 ('e2000000-0000-0000-0000-00000000000a', 'mgr@c.test', now()), ('e2000000-0000-0000-0000-00000000000b', 'stf@c.test', now()), ('e2000000-0000-0000-0000-00000000000c', 'own@c.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('e2000000-0000-0000-0000-0000000000b1', 'Call Co', 'UTC', true, 'active', 'e2000000-0000-0000-0000-000000000001'),
 ('e2000000-0000-0000-0000-0000000000b2', 'Other Co', 'UTC', true, 'active', 'e2000000-0000-0000-0000-000000000001');
insert into public.business_members (business_id, user_id, role, status) values
 ('e2000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-00000000000a', 'manager', 'active'),
 ('e2000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-00000000000b', 'staff', 'active'),
 ('e2000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-00000000000c', 'owner', 'active');
insert into public.industry_modules (id, industry_id, name, slug) values
 ('e2000000-0000-0000-0000-0000000000d1', 'e2000000-0000-0000-0000-000000000001', 'Calls', 'calls'),
 ('e2000000-0000-0000-0000-0000000000d2', 'e2000000-0000-0000-0000-000000000002', 'Calls', 'calls') on conflict do nothing;
insert into public.business_modules (business_id, module_id, enabled) values
 ('e2000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-0000000000d1', true),
 ('e2000000-0000-0000-0000-0000000000b2', 'e2000000-0000-0000-0000-0000000000d1', true);
insert into public.calls (business_id, direction, status, transcript, recording_url) values
 ('e2000000-0000-0000-0000-0000000000b1', 'inbound', 'completed', 'private words', 'https://rec/1'),
 ('e2000000-0000-0000-0000-0000000000b2', 'inbound', 'completed', 'other business', 'https://rec/2');
set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"e2000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform transcript from public.calls limit 1; raise exception 'staff read transcript from the table';
  exception when insufficient_privilege then null; end;
  assert (select count(*) from public.calls) = 1, 'staff still reads ordinary call columns (own business only)';
  assert (select count(*) from public.calls_view where transcript is not null or recording_url is not null) = 0, 'staff: no content in the view';
  assert (select count(*) from public.calls_view) = 1, 'staff sees own business calls only';
  begin perform public.zella_set_call_content_access('e2000000-0000-0000-0000-0000000000b1', true); raise exception 'staff changed the setting';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"e2000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select transcript from public.calls_view) = 'private words', 'manager reads the transcript through the view';
end $$;

-- owner opens transcripts to staff (not a sensitive industry)
select set_config('request.jwt.claims', '{"sub":"e2000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
select public.zella_set_call_content_access('e2000000-0000-0000-0000-0000000000b1', true);
select set_config('request.jwt.claims', '{"sub":"e2000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert (select transcript from public.calls_view) = 'private words', 'staff reads once the owner allows it'; end $$;

-- a sensitive industry can't open it
reset role;
update public.businesses set industry_id = 'e2000000-0000-0000-0000-000000000002' where id = 'e2000000-0000-0000-0000-0000000000b1';
insert into public.business_modules (business_id, module_id, enabled) values ('e2000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-0000000000d2', true);
set local role authenticated;
do $$ begin assert (select transcript from public.calls_view) is null, 'dental: staff never reads transcripts, whatever the setting'; end $$;
select set_config('request.jwt.claims', '{"sub":"e2000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_call_content_access('e2000000-0000-0000-0000-0000000000b1', true); raise exception 'dental allowed staff transcripts';
  exception when others then if sqlerrm not like '%NOT_FOR_THIS_INDUSTRY%' then raise; end if; end;
end $$;
select 'PASS call transcripts and recordings: table columns closed, view by role, staff opt-in only outside sensitive industries';
rollback;
