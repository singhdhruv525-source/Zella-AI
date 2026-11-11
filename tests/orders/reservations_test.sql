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


do $$
declare c jsonb; token uuid; b uuid := 'e9000000-0000-0000-0000-000000000002';
begin
  for i in 1..3 loop
    c := zella_store_lookup_begin('v2call-1', b, 'ref-limit');
    assert c->>'ok' = 'true', 'allowed guess refused';
    token := (c->>'reservation_id')::uuid;
    assert zella_store_lookup_begin('v2call-1', b, 'ref-other')->>'status' = 'limited', 'pending lookup admitted';
    perform zella_store_lookup_finish(b, 'v2call-1', null, 'not_found', false, 'ref-limit', token);
    perform zella_store_lookup_finish(b, 'v2call-1', null, 'not_found', false, 'ref-limit', token);
  end loop;
  assert zella_store_lookup_begin('v2call-1', b, 'ref-other')->>'status' = 'limited', 'fourth guess admitted';
  assert (select count(*) from ai_tool_calls where provider_call_id = 'v2call-1') = 3, 'retry double counted';
  c := zella_store_lookup_begin('v2call-4', b, 'ref-success');
  token := (c->>'reservation_id')::uuid;
  perform zella_store_lookup_finish(b, 'v2call-4', null, 'found_one_factor', true, 'ref-success', token);
  c := zella_store_lookup_begin('v2call-4', b, 'ref-next');
  assert c->>'ok' = 'true', 'successful lookup blocks next attempt';
  perform zella_store_lookup_finish(b, 'v2call-4', null, 'found_one_factor', true, 'ref-success', token);
  assert zella_store_lookup_begin('v2call-4', b, 'ref-next')->>'status' = 'limited', 'stale retry released newer reservation';
  assert zella_store_lookup_begin(null, b, 'ref')->>'status' = 'limited', 'missing identity admitted';
  assert not has_table_privilege('authenticated', 'store_lookup_guards', 'select'), 'guard exposed';
  assert not has_function_privilege('authenticated', 'zella_store_lookup_begin(text,uuid,text,text)', 'execute'), 'RPC exposed';
  raise notice 'PASS three guesses, pending refusal, idempotence and permissions';
end $$;

create function public.fail_lookup_test() returns trigger language plpgsql as $$
begin raise exception 'simulated outcome failure'; end $$;
create trigger fail_lookup_test before insert on public.ai_tool_calls for each row execute function public.fail_lookup_test();
do $$
declare c jsonb; b uuid := 'e9000000-0000-0000-0000-000000000002';
begin
  c := zella_store_lookup_begin('v2call-2', b, 'ref-failure');
  for i in 1..2 loop
    begin
      perform zella_store_lookup_finish(b, 'v2call-2', null, 'not_found', false, 'ref-failure', (c->>'reservation_id')::uuid);
      raise exception 'expected write failure';
    exception when raise_exception then
      if sqlerrm <> 'simulated outcome failure' then raise; end if;
    end;
  end loop;
  assert zella_store_lookup_begin('v2call-2', b, 'ref-new')->>'status' = 'limited', 'failed outcome unlocked call';
  raise notice 'PASS both outcome writes fail and reservation remains locked';
end $$;
drop trigger fail_lookup_test on public.ai_tool_calls;
drop function public.fail_lookup_test();

-- Pre-upgrade unresolved rows lack bucket identities and must still consume capacity.
do $$
declare b uuid := 'e9000000-0000-0000-0000-000000000002'; c jsonb;
begin
  insert into store_lookup_guards(business_id, provider_call_id, reservation_id)
    select b, 'legacy-' || g, gen_random_uuid() from generate_series(1, 5) g;
  assert zella_store_lookup_begin('v2call-5', b, 'new-ref')->>'status' = 'limited',
    'legacy pending reservations lost order capacity';
  delete from store_lookup_guards where provider_call_id like 'legacy-%';
  c := zella_store_lookup_begin('v2call-5', b, 'ref-release');
  assert c->>'ok' = 'true', 'fresh lookup refused';
  perform zella_store_lookup_finish(b, 'v2call-5', null, 'not_found', false, 'ref-release', (c->>'reservation_id')::uuid);
  c := zella_store_lookup_begin('v2call-6', b, 'ref-release');
  assert (c->>'failed_this_order_day')::int = 1, 'finish did not convert pending to one failure';
  perform zella_store_lookup_finish(b, 'v2call-6', null, 'found_one_factor', true, 'ref-release', (c->>'reservation_id')::uuid);
  c := zella_store_lookup_begin('v2call-7', b, 'ref-release');
  assert (c->>'failed_this_order_day')::int = 1, 'success did not release pending capacity';
  raise notice 'PASS legacy pending capacity and completion transitions';
end $$;

-- Provider fallback must consume the same number bucket before calls are persisted.
begin;
delete from store_lookup_guards;
delete from ai_tool_calls;
do $$
declare b uuid := 'e9000000-0000-0000-0000-000000000002'; c jsonb; first_token uuid;
begin
  for i in 1..6 loop
    c := zella_store_lookup_begin('early-' || i, b, 'early-ref-' || i, '+15125559999');
    assert c->>'ok' = 'true', 'fallback number refused within capacity';
    assert c->>'caller_number' = '+15125559999', 'fallback identity lost';
    if i = 1 then first_token := (c->>'reservation_id')::uuid; end if;
  end loop;
  assert zella_store_lookup_begin('early-7', b, 'early-ref-7', '+15125559999')->>'status' = 'limited',
    'pending fallback number limit bypassed';
  perform zella_store_lookup_finish(b, 'early-1', null, 'not_found', false, 'early-ref-1', first_token);
  assert zella_store_lookup_begin('early-7', b, 'early-ref-7', '+15125559999')->>'status' = 'limited',
    'completed fallback failure lost number capacity';
  delete from store_lookup_guards where reservation_id is not null;
  c := zella_store_lookup_begin('early-8', b, 'early-ref-8', '+15125559999');
  assert (c->>'failed_this_number_day')::int = 1, 'completed fallback failure not counted';
  c := zella_store_lookup_begin('v2call-8', b, 'persisted-ref', '+15125559999');
  assert c->>'caller_number' = '+15125550008', 'fallback overrode persisted identity';
  assert (c->>'failed_this_number_day')::int = 0, 'unrelated number charged';
  raise notice 'PASS fallback identity, pending and completed number limits, persisted identity precedence';
end $$;
rollback;

begin;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'e9000000-0000-0000-0000-000000000003', 'Other Shop', i.id, 'UTC', true, 'active' from industries i where i.slug = 'ecommerce';
insert into integrations (id, business_id, provider, integration_type, status, external_account_id, configuration)
values ('e9100000-0000-0000-0000-000000000003', 'e9000000-0000-0000-0000-000000000003', 'shopify', 'store', 'active', 'other.myshopify.com', '{}');
do $$
declare b uuid := 'e9000000-0000-0000-0000-000000000002'; c jsonb; before_count bigint;
begin
  c := zella_store_lookup_begin('v2call-9', b, 'integration-ref');
  assert c->>'ok' = 'true', 'integration test reservation refused';
  select count(*) into before_count from ai_tool_calls;
  begin
    perform zella_store_lookup_finish(b, 'v2call-9', 'e9100000-0000-0000-0000-000000000003',
      'store_unauthorized', false, 'integration-ref', (c->>'reservation_id')::uuid);
    raise exception 'expected integration rejection';
  exception when raise_exception then
    if sqlerrm <> 'INTEGRATION_BUSINESS_MISMATCH' then raise; end if;
  end;
  assert (select count(*) from ai_tool_calls) = before_count, 'mismatch recorded outcome';
  assert (select status = 'active' and error_count = 0 from integrations where id = 'e9100000-0000-0000-0000-000000000003'),
    'mismatch changed foreign integration';
  assert (select reservation_id = (c->>'reservation_id')::uuid from store_lookup_guards where business_id = b and provider_call_id = 'v2call-9'),
    'mismatch released reservation';
  perform zella_store_lookup_finish(b, 'v2call-9', 'e9100000-0000-0000-0000-000000000002',
    'store_error', false, 'integration-ref', (c->>'reservation_id')::uuid);
  assert (select count(*) from ai_tool_calls) = before_count + 1, 'matching integration did not log';
  assert (select error_count = 1 from integrations where id = 'e9100000-0000-0000-0000-000000000002'),
    'matching integration did not update health';
  raise notice 'PASS integration ownership rejection and matching logging path';
end $$;
rollback;
