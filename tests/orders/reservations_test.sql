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
  assert not has_function_privilege('authenticated', 'zella_store_lookup_begin(text,uuid,text)', 'execute'), 'RPC exposed';
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
