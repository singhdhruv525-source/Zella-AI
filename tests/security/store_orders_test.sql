-- Shopify store connection and the AI's order lookup context (zella_store_orders.sql).
\set ON_ERROR_STOP on
begin;
insert into public.industries (id, name, slug) values ('ed000000-0000-0000-0000-000000000001', 'E-commerce', 'ecommerce') on conflict do nothing;
insert into public.industry_crm_presets (key, match, config) values ('ecommerce', '{ecommerce}', '{"types":[]}') on conflict (key) do nothing;
-- e-commerce's capability defaults, as zella_capabilities.sql writes them (the bare schema has no reference data)
insert into public.industry_configurations (industry_id, terminology, statuses, features)
select i.id, '{}', '{}', '{"capabilities": {"on": ["orders", "money"], "optional": ["scheduling"]}}' from public.industries i where i.slug = 'ecommerce'
  and not exists (select 1 from public.industry_configurations c where c.industry_id = i.id);
insert into auth.users (id, email, email_confirmed_at) values ('ed000000-0000-0000-0000-00000000000a', 'own@shop.test', now()),
 ('ed000000-0000-0000-0000-00000000000c', 'stf@shop.test', now()), ('ed000000-0000-0000-0000-00000000000d', 'other@shop.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('ed000000-0000-0000-0000-0000000000a1', 'Shop', 'UTC', true, 'active', (select id from public.industries where slug = 'ecommerce')),
 ('ed000000-0000-0000-0000-0000000000b1', 'Other', 'UTC', true, 'active', null);
insert into public.business_members (business_id, user_id, role, status) values
 ('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000c', 'staff', 'active'),
 ('ed000000-0000-0000-0000-0000000000b1', 'ed000000-0000-0000-0000-00000000000d', 'owner', 'active');
insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled) values ('ed000000-0000-0000-0000-0000000000a1', 'inbound', 'answered', '+15125550101', 'shop-call-1', true);

do $$ declare r jsonb; begin
  -- before a store is connected: the context says so, and Orders asks for setup
  r := public.zella_store_lookup_context('shop-call-1', 'ed000000-0000-0000-0000-0000000000a1');
  assert r ->> 'status' in ('no_store', 'not_available'), 'no store: ' || r::text;
  -- bad input refused
  begin perform public.zella_store_connect('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000a', 'evil.example.com', 'test_store_token_not_real_0001'); raise exception 'non-Shopify host accepted';
  exception when others then if sqlerrm <> 'BAD_SHOP_DOMAIN' then raise; end if; end;
  begin perform public.zella_store_connect('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000c', 'demo.myshopify.com', 'test_store_token_not_real_0001'); raise exception 'staff connected';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_store_connect('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000d', 'demo.myshopify.com', 'test_store_token_not_real_0001'); raise exception 'outsider connected';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  -- the owner's store (the function checked it with Shopify first)
  perform public.zella_store_connect('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000a', 'Demo.myshopify.com', 'test_store_token_not_real_0001', 'Demo');
  assert (select public.zella_capabilities('ed000000-0000-0000-0000-0000000000a1') -> 'orders' ->> 'state') = 'on', 'orders capability on once a store is connected: ' || (public.zella_capabilities('ed000000-0000-0000-0000-0000000000a1') -> 'orders')::text;
  r := public.zella_store_lookup_context('shop-call-1', 'ed000000-0000-0000-0000-0000000000a1');
  assert r ->> 'shop_domain' = 'demo.myshopify.com' and r ->> 'access_token' = 'test_store_token_not_real_0001' and r ->> 'caller_number' = '+15125550101', 'context: ' || r::text;
  assert not exists (select 1 from public.integrations where row_to_json(integrations)::text like '%test_store_token%'), 'no token in integrations';
  -- another business's call gets nothing from this store
  assert public.zella_store_lookup_context('shop-call-1', 'ed000000-0000-0000-0000-0000000000b1') ->> 'ok' = 'false', 'other business';
  -- outcome logged without content; a refused token flags the store
  perform public.zella_store_lookup_log('ed000000-0000-0000-0000-0000000000a1', 'shop-call-1', (r ->> 'integration_id')::uuid, 'found', true);
  perform public.zella_store_lookup_log('ed000000-0000-0000-0000-0000000000a1', 'shop-call-1', (r ->> 'integration_id')::uuid, 'store_unauthorized', false);
  assert (select status || ':' || last_error from public.integrations where id = (r ->> 'integration_id')::uuid) = 'error:store_unauthorized', 'flagged';
  assert (select count(*) from public.ai_tool_calls where tool = 'lookup_order' and business_id = 'ed000000-0000-0000-0000-0000000000a1') = 2, 'logged';
  -- the assistant has the tool where Orders is on, and not where it's off
  assert public.zella_brain_tool_defs() @> '[{"name": "lookup_order"}]', 'tool defined';
  assert public.zella_ai_tool('shop-call-1', 'ed000000-0000-0000-0000-0000000000a1', 'lookup_order', '{"order_number": "1001"}') ->> 'status' = 'not_available', 'direct database path takes a message';
  assert not (public.zella_brain_context('ed000000-0000-0000-0000-0000000000b1') -> 'tools') ? 'lookup_order', 'no order lookup without Orders';
end $$;

-- members never see the token; staff can't connect or disconnect; the owner disconnects and the token is gone
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ed000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform 1 from public.integration_secrets; raise exception 'staff read secrets'; exception when insufficient_privilege then null; end;
  assert not public.zella_store_can_manage('ed000000-0000-0000-0000-0000000000a1'), 'staff can''t manage';
  begin perform public.zella_store_disconnect('ed000000-0000-0000-0000-0000000000a1'); raise exception 'staff disconnected'; exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_store_lookup_context('shop-call-1', 'ed000000-0000-0000-0000-0000000000a1'); raise exception 'member read the context'; exception when insufficient_privilege then null; end;
  begin perform public.zella_store_connect('ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-00000000000a', 'x.myshopify.com', 'test_store_token_not_real_0001'); raise exception 'member called connect'; exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"ed000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert public.zella_store_disconnect('ed000000-0000-0000-0000-0000000000a1') = 1, 'owner disconnected'; end $$;
reset role;
do $$ begin
  assert not exists (select 1 from public.integration_secrets s join public.integrations g on g.id = s.integration_id where g.business_id = 'ed000000-0000-0000-0000-0000000000a1'), 'token deleted';
  assert public.zella_store_lookup_context('shop-call-1', 'ed000000-0000-0000-0000-0000000000a1') ->> 'ok' = 'false', 'no lookups after disconnect';
  assert (select count(*) from public.audit_logs where business_id = 'ed000000-0000-0000-0000-0000000000a1' and action in ('store_connected', 'store_disconnected')) = 2, 'audited';
  assert not exists (select 1 from public.audit_logs where business_id = 'ed000000-0000-0000-0000-0000000000a1' and coalesce(new_data::text, '') || coalesce(old_data::text, '') like '%test_store_token%'), 'no token in audit';
end $$;
select 'PASS store orders: Shopify addresses only, owner/admin only (checked again when stored), token only in server-only secrets and deleted on disconnect, Orders on once connected, lookup context per business and server only, outcomes logged without content, refused tokens flag the store, tool offered only with Orders';
rollback;
