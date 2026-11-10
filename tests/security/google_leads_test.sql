-- Google Ads lead forms (zella_google_leads.sql).
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('ec000000-0000-0000-0000-00000000000a', 'own@g.test', now()), ('ec000000-0000-0000-0000-00000000000b', 'mgr@g.test', now()),
 ('ec000000-0000-0000-0000-00000000000c', 'stf@g.test', now()), ('ec000000-0000-0000-0000-00000000000d', 'out@g.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values
 ('ec000000-0000-0000-0000-0000000000a1', 'Salon G', 'UTC', true, 'active'), ('ec000000-0000-0000-0000-0000000000b1', 'Other G', 'UTC', true, 'active');
insert into public.business_members (business_id, user_id, role, status) values
 ('ec000000-0000-0000-0000-0000000000a1', 'ec000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('ec000000-0000-0000-0000-0000000000a1', 'ec000000-0000-0000-0000-00000000000b', 'manager', 'active'),
 ('ec000000-0000-0000-0000-0000000000a1', 'ec000000-0000-0000-0000-00000000000c', 'staff', 'active'),
 ('ec000000-0000-0000-0000-0000000000b1', 'ec000000-0000-0000-0000-00000000000d', 'owner', 'active');
insert into public.customers (id, business_id, first_name, phone) values ('ec000000-0000-0000-0000-0000000000c1', 'ec000000-0000-0000-0000-0000000000a1', 'Known', '+15125550701');
create temp table k (v text) on commit drop;
grant all on k to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_google_lead_key_create('ec000000-0000-0000-0000-0000000000a1'); raise exception 'staff created a key';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  begin perform public.zella_capture_google_lead('{}'); raise exception 'signed-in user called the server path';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_google_lead_status('ec000000-0000-0000-0000-0000000000a1'); raise exception 'other business read the status';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
insert into k select public.zella_google_lead_key_create('ec000000-0000-0000-0000-0000000000a1') ->> 'key';
reset role;
do $$ declare key text := (select v from k); r jsonb; base jsonb; begin
  assert not exists (select 1 from public.google_lead_keys where key_hash = key or key_hint = key), 'only the hash is kept';
  base := jsonb_build_object('google_key', key, 'form_id', 111, 'campaign_id', 222, 'adgroup_id', 333);
  -- wrong key
  r := public.zella_capture_google_lead(base || '{"google_key": "zg_wrong", "lead_id": "L0"}');
  assert r ->> 'error' = 'bad_key', 'wrong key refused';
  -- Google's "send test data"
  r := public.zella_capture_google_lead(base || '{"lead_id": "TEST", "is_test": true, "user_column_data": [{"column_id": "FULL_NAME", "string_value": "Test Lead"}]}');
  assert (r ->> 'test')::boolean and not exists (select 1 from public.customers where first_name = 'Test'), 'test acknowledged, nobody created';
  assert (select test_received_at is not null from public.google_lead_keys where business_id = 'ec000000-0000-0000-0000-0000000000a1'), 'test shown as received';
  -- a real lead
  r := public.zella_capture_google_lead(base || '{"lead_id": "L1", "gcl_id": "abc", "user_column_data": [
      {"column_id": "FULL_NAME", "string_value": "Lena Park"}, {"column_id": "PHONE_NUMBER", "string_value": "+1 512 555 0702"},
      {"column_id": "EMAIL", "string_value": "Lena@Example.test"}, {"column_name": "Which service?", "string_value": "Balayage"}]}');
  assert (r ->> 'ok')::boolean, r::text;
  assert (select first_name || ' ' || last_name || ' ' || source || ' ' || lead_stage || ' ' || email || ' ' || phone from public.customers where id = (r ->> 'customer_id')::uuid)
         = 'Lena Park google_ads new lena@example.test +15125550702', 'lead created with the source, number in one form';
  assert exists (select 1 from public.callbacks where customer_id = (r ->> 'customer_id')::uuid), 'callback for the team';
  assert (select summary from public.lead_submissions where id = (r ->> 'submission_id')::uuid) like '%Which service?: Balayage%', 'answers kept';
  assert (select source ->> 'campaign_id' from public.lead_submissions where id = (r ->> 'submission_id')::uuid) = '222', 'campaign kept';
  assert not exists (select 1 from public.contact_consents where customer_id = (r ->> 'customer_id')::uuid and purpose = 'marketing'), 'no marketing consent assumed';
  -- Google retries the same lead
  r := public.zella_capture_google_lead(base || '{"lead_id": "L1", "user_column_data": [{"column_id": "PHONE_NUMBER", "string_value": "+15125550702"}]}');
  assert (r ->> 'duplicate')::boolean and (select count(*) from public.customers where phone like '%5550702') = 1, 'retry counted once';
  -- an existing customer is matched, not duplicated
  r := public.zella_capture_google_lead(base || '{"lead_id": "L2", "user_column_data": [{"column_id": "PHONE_NUMBER", "string_value": "+15125550701"}]}');
  assert (r ->> 'customer_id')::uuid = 'ec000000-0000-0000-0000-0000000000c1', 'matched the existing customer';
  -- no way to contact them: logged, nobody created
  r := public.zella_capture_google_lead(base || '{"lead_id": "L3", "user_column_data": [{"column_id": "FULL_NAME", "string_value": "No Contact"}]}');
  assert r ->> 'ignored' = 'no_contact' and not exists (select 1 from public.customers where first_name = 'No'), 'no contact ignored';
end $$;
-- the team sees it; a revoked key stops working
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ declare s jsonb := public.zella_google_lead_status('ec000000-0000-0000-0000-0000000000a1'); begin
  assert (s ->> 'has_key')::boolean and (s ->> 'leads_30d')::int = 2 and s ->> 'last_lead_at' is not null, s::text;
  assert not (s ? 'key'), 'the key is never shown again';
end $$;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
select public.zella_google_lead_key_revoke('ec000000-0000-0000-0000-0000000000a1');
reset role;
do $$ begin
  assert public.zella_capture_google_lead(jsonb_build_object('google_key', (select v from k), 'lead_id', 'L9')) ->> 'error' = 'bad_key', 'revoked key refused';
  assert (select count(*) from public.audit_logs where action like 'google_lead_key_%') = 2, 'key changes audited';
end $$;
select 'PASS google leads: owner-only key (hash kept, shown once), wrong/revoked key refused, test data acknowledged, lead created with source and answers, retry once, existing customer matched, no contact ignored, no marketing consent, server-only intake';
rollback;
