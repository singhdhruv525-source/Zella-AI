-- Regression tests for sql/zella_order_lookup_v2.sql (tests/orders/run_v2.sh). Test data only; nothing calls Shopify.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'e9000000-0000-0000-0000-000000000002', 'Order Shop 2', i.id, 'UTC', true, 'active' from industries i where i.slug = 'ecommerce';
insert into business_capabilities (business_id, capability, enabled) values ('e9000000-0000-0000-0000-000000000002', 'orders', true) on conflict (business_id, capability) do update set enabled = true;
insert into integrations (id, business_id, provider, integration_type, status, external_account_id, configuration)
values ('e9100000-0000-0000-0000-000000000002', 'e9000000-0000-0000-0000-000000000002', 'shopify', 'store', 'active', 'demo2.myshopify.com', '{}');
insert into integration_secrets (integration_id, credentials) values ('e9100000-0000-0000-0000-000000000002', '{"access_token": "placeholder_token_not_real_000000"}');
insert into calls (business_id, direction, status, from_number, external_call_id, ai_handled)
select 'e9000000-0000-0000-0000-000000000002', 'inbound', 'answered', '+1512555' || lpad(g::text, 4, '0'), 'v2call-' || g, true from generate_series(1, 40) g;

do $$ declare c jsonb; begin
  -- five phones each guess an email against the same order
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000002', 'v2call-' || g, 'e9100000-0000-0000-0000-000000000002', 'unverified', false, 'ref-order-1001')
     from generate_series(1, 5) g;
  c := public.zella_store_lookup_context('v2call-6', 'e9000000-0000-0000-0000-000000000002', 'ref-order-1001');
  assert (c ->> 'failed_this_order_day')::int = 5 and (c ->> 'failed_this_call')::int = 0 and (c ->> 'failed_this_number_day')::int = 0, 'per order: ' || (c - 'access_token')::text;
  c := public.zella_store_lookup_context('v2call-6', 'e9000000-0000-0000-0000-000000000002', 'ref-order-2002');
  assert (c ->> 'failed_this_order_day')::int = 0, 'another order counted';
  -- many phones, many order numbers
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000002', 'v2call-' || g, null, 'not_found', false, 'ref-' || g) from generate_series(7, 31) g;
  c := public.zella_store_lookup_context('v2call-40', 'e9000000-0000-0000-0000-000000000002', 'ref-x');
  assert (c ->> 'failed_business_hour')::int = 30, 'business hour: ' || (c ->> 'failed_business_hour');
  -- the old two-argument context still works for the deployed function
  assert public.zella_store_lookup_context('v2call-40', 'e9000000-0000-0000-0000-000000000002') ->> 'ok' = 'true', 'old context broken';
  raise notice 'PASS O5 failed lookups are counted per order number (across phones) and per business per hour; the deployed function''s calls still work';
end $$;

do $$ declare r jsonb; begin
  perform public.zella_store_lookup_log('e9000000-0000-0000-0000-000000000002', 'v2call-32', 'e9100000-0000-0000-0000-000000000002', x, true, 'ref-ok')
     from unnest(array['found_two_factor', 'found_one_factor', 'found_one_factor', 'found_recipient']) x;
  r := public.zella_order_lookup_report('e9000000-0000-0000-0000-000000000002', 30) -> 0;
  assert (r ->> 'given_two_factor')::int = 1 and (r ->> 'given_one_factor')::int = 2 and (r ->> 'given_recipient')::int = 1, 'report: ' || r::text;
  assert not exists (select 1 from ai_tool_calls where lookup_ref like '%1001%' and lookup_ref <> 'ref-order-1001'), 'order number stored as given';
  assert (public.zella_brain_tool_defs())::text like '%Never read out a tracking number%', 'tool description not updated';
  raise notice 'PASS O4 lookups are recorded and reported by level; the assistant is told tracking numbers are never read out';
end $$;

do $$ begin
  assert not has_function_privilege('authenticated', 'public.zella_store_lookup_context(text,uuid,text)', 'execute'), 'users can reach the new context';
  assert not has_function_privilege('authenticated', 'public.zella_store_lookup_log(uuid,text,uuid,text,boolean,text)', 'execute'), 'users can write the log';
  raise notice 'PASS the new lookup functions are server-only';
end $$;
