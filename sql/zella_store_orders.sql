-- E-commerce: order status from the business's Shopify store, for the AI receptionist and the team (5 Nov 2026).
-- E-commerce's launch promise is answering "where is my order?" without inventing a status. Until now nothing could
-- connect a store, so the Orders capability always said "No store is connected" and the AI could only take a message.
--
--   * Connecting (owners and admins): the store's address (<name>.myshopify.com) and the Admin API access token of a
--     custom app the owner creates in Shopify with read-only order scopes (read_orders, read_customers, and
--     read_fulfillments for tracking). The store-connect edge function checks the token with Shopify first, then stores
--     it through zella_store_connect (server only) in integration_secrets, which no signed-in person can read. The
--     integration row (integrations, provider shopify) is what the Orders capability already looks for.
--   * The AI's lookup_order tool runs in the voice-rules edge function: zella_store_lookup_context gives it the store
--     and the caller's number (server only; refused unless the business has Orders on and a store connected); it
--     answers only when the caller's number or the email they give matches the order, and only with status and
--     tracking (never address, items or amounts); zella_store_lookup_log records the outcome, never the content.
--   * Disconnecting deletes the stored token at once.
--   * Connecting and disconnecting are audited (store address, never the token).
-- Needs zella_capabilities.sql and zella_brain.sql. Safe to run twice. Needs the owner's approval.

create unique index if not exists integrations_one_store on public.integrations (business_id) where integration_type = 'store' and status = 'active';

create or replace function public.zella_store_can_manage(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                  and m.status = 'active' and m.role in ('owner', 'admin'))
     and exists (select 1 from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null) $$;

-- server only (store-connect, after Shopify accepted the token)
create or replace function public.zella_store_connect(p_business_id uuid, p_actor uuid, p_shop_domain text, p_access_token text, p_shop_name text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_domain text := lower(trim(coalesce(p_shop_domain, ''))); v_id uuid;
begin
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_actor and m.status = 'active' and m.role in ('owner', 'admin'))
     or not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_domain !~ '^[a-z0-9][a-z0-9-]{0,60}\.myshopify\.com$' then raise exception 'BAD_SHOP_DOMAIN'; end if;
  if length(coalesce(p_access_token, '')) not between 20 and 200 then raise exception 'BAD_TOKEN'; end if;
  select id into v_id from public.integrations where business_id = p_business_id and integration_type = 'store' and provider = 'shopify' order by created_at limit 1;
  if v_id is null then
    insert into public.integrations (business_id, provider, integration_type, status, external_account_id, configuration)
    values (p_business_id, 'shopify', 'store', 'active', v_domain, jsonb_build_object('shop_domain', v_domain, 'shop_name', left(p_shop_name, 120)))
    returning id into v_id;
  else
    update public.integrations set status = 'active', external_account_id = v_domain, configuration = jsonb_build_object('shop_domain', v_domain, 'shop_name', left(p_shop_name, 120)),
           last_error = null, error_message = null, error_count = 0, updated_at = now() where id = v_id;
  end if;
  insert into public.integration_secrets (integration_id, credentials) values (v_id, jsonb_build_object('access_token', p_access_token))
  on conflict (integration_id) do update set credentials = excluded.credentials, updated_at = now();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, p_actor, 'store_connected', 'integration', v_id, jsonb_build_object('provider', 'shopify', 'shop', v_domain));
  return v_id;
end $$;

create or replace function public.zella_store_disconnect(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare g record; n integer := 0;
begin
  if not public.zella_store_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  for g in select * from public.integrations where business_id = p_business_id and integration_type = 'store' and status <> 'disconnected' loop
    update public.integrations set status = 'disconnected', updated_at = now() where id = g.id;
    delete from public.integration_secrets where integration_id = g.id;
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data)
    values (p_business_id, auth.uid(), 'store_disconnected', 'integration', g.id, jsonb_build_object('provider', g.provider, 'shop', g.external_account_id));
    n := n + 1;
  end loop;
  return n;
end $$;

-- server only (voice-rules, for one call's lookup_order): the store and the caller's number, or why not
create or replace function public.zella_store_lookup_context(p_provider_call_id text, p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g record; v_token text; v_caller text;
begin
  if p_business_id is null or not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null and coalesce(is_active, true)) then
    return jsonb_build_object('ok', false, 'status', 'unknown_business');
  end if;
  if not public.zella_capability_on(p_business_id, 'orders') then return jsonb_build_object('ok', false, 'status', 'not_available'); end if;
  select * into g from public.integrations where business_id = p_business_id and integration_type = 'store' and provider = 'shopify' and status = 'active' limit 1;
  select credentials ->> 'access_token' into v_token from public.integration_secrets where integration_id = g.id;
  if g.id is null or v_token is null then return jsonb_build_object('ok', false, 'status', 'no_store'); end if;
  select from_number into v_caller from public.calls where business_id = p_business_id and external_call_id = p_provider_call_id limit 1;
  return jsonb_build_object('ok', true, 'integration_id', g.id, 'shop_domain', g.external_account_id, 'access_token', v_token, 'caller_number', v_caller);
end $$;

-- server only: what the lookup concluded (no order content), and the store's health
create or replace function public.zella_store_lookup_log(p_business_id uuid, p_provider_call_id text, p_integration_id uuid, p_result text, p_verified boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.ai_tool_calls (business_id, provider_call_id, tool, arg_keys, status, result_status, verified, finished_at)
  values (p_business_id, left(p_provider_call_id, 200), 'lookup_order', array['order_number'], 'done', left(p_result, 40), p_verified, now());
  if p_integration_id is not null then
    if p_result in ('store_unauthorized', 'store_error') then
      update public.integrations set error_count = error_count + 1, last_error = p_result, last_checked_at = now(),
             status = case when p_result = 'store_unauthorized' then 'error' else status end where id = p_integration_id;
    else
      update public.integrations set error_count = 0, last_error = null, last_checked_at = now(), last_synced_at = now() where id = p_integration_id;
    end if;
  end if;
end $$;

-- the assistant's tool: declared in the tool list (so the assistant knows it) and handled by the voice-rules function.
-- Reaching the database directly (an older path, e.g. n8n Brain Tools) it takes a message instead of guessing.
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_brain_tool_defs()'::regprocedure);
  if position('lookup_order' in def) = 0 then
    def := replace(def, 'select jsonb_build_array(', $a$select jsonb_build_array(
  jsonb_build_object('name', 'lookup_order', 'consequential', false,
    'description', 'Look up the status of the caller''s order in the business''s store. Needs the order number; if the caller is not calling from the number on the order, also ask for the email address used for the order. Only status and tracking can be shared.',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('order_number'), 'properties', jsonb_build_object(
      'order_number', jsonb_build_object('type', 'string', 'description', 'The order number, e.g. 1001 or #1001'),
      'email', jsonb_build_object('type', 'string', 'description', 'The email address used for the order, if the caller gives it')))),$a$);
    if position('lookup_order' in def) = 0 then raise exception 'zella_brain_tool_defs has changed; review this patch'; end if;
    execute def;
  end if;

  def := pg_get_functiondef('public.zella_ai_tool(text, uuid, text, jsonb, text)'::regprocedure);
  if position('zella_store_orders_fallback' in def) = 0 then
    def := replace(def, $a$    if p_tool = 'search_knowledge' then$a$, $a$    if p_tool = 'lookup_order' then /* zella_store_orders_fallback: handled by voice-rules */
      v_res := jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'Order status can''t be checked on this line. Take a message with the order number and say the team will get back to them.');
    elsif p_tool = 'search_knowledge' then$a$);
    if position('zella_store_orders_fallback' in def) = 0 then raise exception 'zella_ai_tool has changed; review this patch'; end if;
    execute def;
  end if;

  -- the assistant isn't offered order lookup where the business has Orders off
  def := pg_get_functiondef('public.zella_brain_context(uuid)'::regprocedure);
  if position('zella_store_orders_tools' in def) = 0 then
    def := replace(def, $a$  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);$a$,
      $a$  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);
  /* zella_store_orders_tools */
  if not public.zella_capability_on(p_business_id, 'orders') then v_disabled := v_disabled || '["lookup_order"]'::jsonb; end if;$a$);
    if position('zella_store_orders_tools' in def) = 0 then raise exception 'zella_brain_context has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

revoke execute on function public.zella_store_connect(uuid, uuid, text, text, text), public.zella_store_lookup_context(text, uuid),
  public.zella_store_lookup_log(uuid, text, uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.zella_store_connect(uuid, uuid, text, text, text), public.zella_store_lookup_context(text, uuid),
  public.zella_store_lookup_log(uuid, text, uuid, text, boolean) to service_role;
revoke execute on function public.zella_store_can_manage(uuid), public.zella_store_disconnect(uuid) from public, anon;
grant execute on function public.zella_store_can_manage(uuid), public.zella_store_disconnect(uuid) to authenticated, service_role;
