-- Zella - order lookup: how sure we are who is asking, and a record of it (5 Nov 2026). Safe to run twice. Not applied.
-- Audit: docs/ORDER_LOOKUP_ASSURANCE_2026-11-05.md. Run after sql/zella_store_orders.sql (one of the 17 pending).
-- Class V (what the AI receptionist says on a call). Goes with the voice-rules function's orders.ts of the same date;
-- either can go first: the older function ignores the new counts, and the newer one treats missing counts as 0.
--
-- O2  The record of each lookup said only found / not found; now a found lookup says which check let the caller hear
--     it (found_caller_id: calling from a number on the order; found_email: gave the order's email), so an owner or
--     admin can see on what grounds each order status was given out (zella_order_lookup_report).
-- O3  Nothing limited lookups that didn't match except the general 30 tool calls a minute, so one call could try
--     dozens of order numbers against an email it knew, or emails against an order number. zella_store_lookup_context
--     now gives the failed lookups of this call and of this caller's number in the last day; the function stops after
--     3 in a call or 6 from one number in a day, without asking the store (logged as 'limited').

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_store_lookup_context(text, uuid)'::regprocedure);
  if position('zella_order_lookup_assurance' in def) = 0 then
    def := replace(def, $a$  return jsonb_build_object('ok', true, 'integration_id', g.id, 'shop_domain', g.external_account_id, 'access_token', v_token, 'caller_number', v_caller);$a$,
      $a$  /* zella_order_lookup_assurance: lookups that didn't match, in this call and from this number in the last day */
  return jsonb_build_object('ok', true, 'integration_id', g.id, 'shop_domain', g.external_account_id, 'access_token', v_token, 'caller_number', v_caller,
    'failed_this_call', (select count(*) from public.ai_tool_calls t where t.business_id = p_business_id and t.tool = 'lookup_order'
                          and t.provider_call_id = left(p_provider_call_id, 200) and t.result_status in ('unverified', 'not_found', 'limited')),
    'failed_this_number_day', case when v_caller is null then 0 else (select count(*) from public.ai_tool_calls t join public.calls k
                          on k.business_id = t.business_id and k.external_call_id = t.provider_call_id
                         where t.business_id = p_business_id and t.tool = 'lookup_order' and t.created_at > now() - interval '1 day'
                           and t.result_status in ('unverified', 'not_found') and k.from_number = v_caller) end);$a$);
    if position('zella_order_lookup_assurance' in def) = 0 then raise exception 'zella_store_lookup_context has changed; review this patch'; end if;
    execute def;
  end if;

  -- a lookup stopped by the limit never reached the store, so it says nothing about the store's health
  def := pg_get_functiondef('public.zella_store_lookup_log(uuid, text, uuid, text, boolean)'::regprocedure);
  if position('zella_order_lookup_assurance' in def) = 0 then
    def := replace(def, $a$  if p_integration_id is not null then$a$, $a$  if p_integration_id is not null and p_result <> 'limited' then /* zella_order_lookup_assurance */$a$);
    if position('zella_order_lookup_assurance' in def) = 0 then raise exception 'zella_store_lookup_log has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

create index if not exists ai_tool_calls_lookup_idx on public.ai_tool_calls (business_id, provider_call_id) where tool = 'lookup_order';

-- O2: what order lookups gave out, and on what grounds, per day (owners and admins of the business, and platform staff
-- through the service role). Counts only: no order numbers, no callers.
create or replace function public.zella_order_lookup_report(p_business_id uuid, p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' and not exists (select 1 from public.business_members m where m.business_id = p_business_id
       and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  return coalesce((select jsonb_agg(d order by d ->> 'day' desc) from (
    select jsonb_build_object('day', created_at::date,
      'given_caller_id', count(*) filter (where result_status = 'found_caller_id'),
      'given_email', count(*) filter (where result_status = 'found_email'),
      'given_before_levels', count(*) filter (where result_status = 'found'),   -- recorded before this change
      'not_matched', count(*) filter (where result_status in ('unverified', 'not_found')),
      'stopped_by_limit', count(*) filter (where result_status = 'limited'),
      'store_problem', count(*) filter (where result_status in ('store_error', 'store_unauthorized'))) d
      from public.ai_tool_calls where business_id = p_business_id and tool = 'lookup_order'
       and created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 366))
     group by created_at::date) x), '[]'::jsonb);
end $$;
revoke execute on function public.zella_order_lookup_report(uuid, integer) from public, anon;
grant execute on function public.zella_order_lookup_report(uuid, integer) to authenticated, service_role;
