-- Regression tests for sql/zella_order_lookup_assurance.sql on an isolated copy (tests/orders/run.sh). Test data only;
-- the store token is a placeholder, and nothing calls Shopify.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'e9000000-0000-0000-0000-000000000001', 'Order Shop', i.id, 'UTC', true, 'active' from industries i where i.slug = 'ecommerce';
insert into business_capabilities (business_id, capability, enabled) values ('e9000000-0000-0000-0000-000000000001', 'orders', true)
  on conflict (business_id, capability) do update set enabled = true;
insert into integrations (id, business_id, provider, integration_type, status, external_account_id, configuration)
values ('e9100000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-000000000001', 'shopify', 'store', 'active', 'demo-store.myshopify.com', '{}');
insert into integration_secrets (integration_id, credentials) values ('e9100000-0000-0000-0000-000000000001', '{"access_token": "placeholder_token_not_real_000000"}');
insert into calls (business_id, direction, status, from_number, external_call_id, ai_handled) values
  ('e9000000-0000-0000-0000-000000000001', 'inbound', 'answered', '+15125550177', 'ocall-1', true),
  ('e9000000-0000-0000-0000-000000000001', 'inbound', 'answered', '+15125550177', 'ocall-2', true),
  ('e9000000-0000-0000-0000-000000000001', 'inbound', 'answered', '+15125550188', 'ocall-3', true);

do $$ declare c jsonb; begin
  c := public.zella_store_lookup_context('ocall-1', 'e9000000-0000-0000-0000-000000000001');
  assert c ->> 'ok' = 'true' and (c ->> 'failed_this_call')::int = 0 and (c ->> 'failed_this_number_day')::int = 0, 'fresh: ' || (c - 'access_token')::text;
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000001', 'ocall-1', 'e9100000-0000-0000-0000-000000000001', r, false)
     from unnest(array['unverified', 'not_found', 'unverified']) r;
  c := public.zella_store_lookup_context('ocall-1', 'e9000000-0000-0000-0000-000000000001');
  assert (c ->> 'failed_this_call')::int = 3 and (c ->> 'failed_this_number_day')::int = 3, 'after 3: ' || (c - 'access_token')::text;
  -- the same caller ringing again: a new call, but the day's count follows the number
  c := public.zella_store_lookup_context('ocall-2', 'e9000000-0000-0000-0000-000000000001');
  assert (c ->> 'failed_this_call')::int = 0 and (c ->> 'failed_this_number_day')::int = 3, 'redial: ' || (c - 'access_token')::text;
  -- another caller is not affected
  c := public.zella_store_lookup_context('ocall-3', 'e9000000-0000-0000-0000-000000000001');
  assert (c ->> 'failed_this_call')::int = 0 and (c ->> 'failed_this_number_day')::int = 0, 'other caller: ' || (c - 'access_token')::text;
  -- a found lookup is not a failure
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000001', 'ocall-3', 'e9100000-0000-0000-0000-000000000001', 'found_email', true);
  c := public.zella_store_lookup_context('ocall-3', 'e9000000-0000-0000-0000-000000000001');
  assert (c ->> 'failed_this_call')::int = 0, 'found counted as failed';
  raise notice 'PASS O3 failed lookups are counted per call and per caller number for a day; other callers and found lookups are not';
end $$;

do $$ declare before record; after record; begin
  update integrations set error_count = 2, last_error = 'store_error', last_checked_at = '2026-01-01' where id = 'e9100000-0000-0000-0000-000000000001';
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000001', 'ocall-1', 'e9100000-0000-0000-0000-000000000001', 'limited', false);
  select error_count, last_error, last_checked_at into after from integrations where id = 'e9100000-0000-0000-0000-000000000001';
  assert after.error_count = 2 and after.last_error = 'store_error' and after.last_checked_at = '2026-01-01', 'limited touched store health';
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000001', 'ocall-1', 'e9100000-0000-0000-0000-000000000001', 'found_caller_id', true);
  assert (select error_count from integrations where id = 'e9100000-0000-0000-0000-000000000001') = 0, 'a real lookup no longer clears health';
  raise notice 'PASS a lookup stopped by the limit leaves the store''s health alone; a real one still updates it';
end $$;

-- O2: the report, for the business's owner only
insert into auth.users (id, email, email_confirmed_at) values ('e9800000-0000-0000-0000-000000000001', 'owner@orders.test', now()), ('e9800000-0000-0000-0000-000000000002', 'stranger@orders.test', now());
insert into business_members (business_id, user_id, role, status) values ('e9000000-0000-0000-0000-000000000001', 'e9800000-0000-0000-0000-000000000001', 'owner', 'active');
select set_config('request.jwt.claims', '{"sub":"e9800000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare r jsonb; begin
  r := public.zella_order_lookup_report('e9000000-0000-0000-0000-000000000001', 30) -> 0;
  assert (r ->> 'given_caller_id')::int = 1 and (r ->> 'given_email')::int = 1 and (r ->> 'not_matched')::int = 3 and (r ->> 'stopped_by_limit')::int = 1, 'report: ' || r::text;
  assert r::text !~ 'ocall|\+1512|1001', 'report carries call or caller details: ' || r::text;
  raise notice 'PASS O2 the owner sees how many order statuses were given and on what grounds (counts only)';
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"e9800000-0000-0000-0000-000000000002","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ begin
  begin perform public.zella_order_lookup_report('e9000000-0000-0000-0000-000000000001', 30); raise exception 'stranger read the report';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_store_lookup_context('ocall-1', 'e9000000-0000-0000-0000-000000000001'); raise exception 'user called the lookup context';
  exception when insufficient_privilege then null; end;
  raise notice 'PASS someone outside the business can''t read the report, and no signed-in user can reach the lookup context';
end $$;
reset role;
do $$ begin
  assert not has_function_privilege('anon', 'public.zella_order_lookup_report(uuid,integer)', 'execute'), 'anon can run the report';
end $$;
