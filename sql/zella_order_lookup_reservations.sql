-- Apply after zella_order_lookup_v2.sql and before deploying the updated voice-rules.
-- A pending reservation never expires: uncertain outcomes must not allow another guess.
begin;
create table if not exists public.store_lookup_guards (
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_call_id text not null,
  reservation_id uuid,
  primary key (business_id, provider_call_id)
);
-- Persist bucket identities so unresolved work remains charged even beyond a time window.
-- Null identities on reservations from an earlier deployment count conservatively in every bucket.
alter table public.store_lookup_guards add column if not exists caller_number text;
alter table public.store_lookup_guards add column if not exists lookup_ref text;
alter table public.store_lookup_guards enable row level security;
revoke all on public.store_lookup_guards from public, anon, authenticated, service_role;

-- Replace the old signature so three-argument callers use the default fallback too.
drop function if exists public.zella_store_lookup_begin(text, uuid, text);
create or replace function public.zella_store_lookup_begin(p_provider_call_id text, p_business_id uuid, p_order_ref text,
  p_caller_number text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb; pending uuid; token uuid; pending_number bigint; pending_order bigint; pending_business bigint; v_caller text;
begin
  if p_business_id is null or nullif(trim(p_provider_call_id), '') is null or length(p_provider_call_id) > 200 then
    return jsonb_build_object('ok', false, 'status', 'limited');
  end if;
  -- Every bucket is scoped to a business. Lock it before any guard, in begin and finish,
  -- so admissions and pending-to-completed transitions see a consistent set of counters.
  -- NO KEY UPDATE remains compatible with foreign-key checks on the business.
  perform 1 from public.businesses where id = p_business_id for no key update;
  if not found then return jsonb_build_object('ok', false, 'status', 'limited'); end if;
  insert into public.store_lookup_guards(business_id, provider_call_id)
    values(p_business_id, p_provider_call_id) on conflict do nothing;
  select reservation_id into pending from public.store_lookup_guards
    where business_id = p_business_id and provider_call_id = p_provider_call_id for update;
  if pending is not null then return jsonb_build_object('ok', false, 'status', 'limited'); end if;
  c := public.zella_store_lookup_context(p_provider_call_id, p_business_id, p_order_ref);
  if (c->>'ok')::boolean is distinct from true then return c; end if;
  -- The service supplies only the signed provider number; persisted call identity wins.
  v_caller := coalesce(c->>'caller_number', nullif(left(p_caller_number, 30), ''));
  c := c || jsonb_build_object('caller_number', v_caller,
    'failed_this_number_day', (select count(*) from public.ai_tool_calls t
      left join public.calls k on k.business_id = t.business_id and k.external_call_id = t.provider_call_id
      left join public.store_lookup_guards g on g.business_id = t.business_id and g.provider_call_id = t.provider_call_id
      where t.business_id = p_business_id and t.tool = 'lookup_order'
        and t.created_at > now() - interval '1 day' and t.result_status in ('unverified', 'not_found')
        and coalesce(k.from_number, g.caller_number) = v_caller));
  select count(*) filter (where g.caller_number is null or g.caller_number = c->>'caller_number'),
         count(*) filter (where g.lookup_ref is null or g.lookup_ref = left(p_order_ref, 64)), count(*)
    into pending_number, pending_order, pending_business
    from public.store_lookup_guards g
    where g.business_id = p_business_id and g.reservation_id is not null;
  c := c || jsonb_build_object(
    'failed_this_number_day', (c->>'failed_this_number_day')::bigint + pending_number,
    'failed_this_order_day', (c->>'failed_this_order_day')::bigint + pending_order,
    'failed_business_hour', (c->>'failed_business_hour')::bigint + pending_business);
  -- Missing counters cannot establish that a caller is within the policy.
  if c->>'failed_this_call' is null or c->>'failed_this_number_day' is null
     or c->>'failed_this_order_day' is null or c->>'failed_business_hour' is null
     or (c->>'failed_this_call')::integer >= 3 or (c->>'failed_this_number_day')::integer >= 6
     or (c->>'failed_this_order_day')::integer >= 5 or (c->>'failed_business_hour')::integer >= 30 then
    return jsonb_build_object('ok', false, 'status', 'limited');
  end if;
  token := gen_random_uuid();
  update public.store_lookup_guards set reservation_id = token, caller_number = c->>'caller_number',
    lookup_ref = left(p_order_ref, 64)
    where business_id = p_business_id and provider_call_id = p_provider_call_id;
  return c || jsonb_build_object('reservation_id', token);
end $$;

create or replace function public.zella_store_lookup_finish(p_business_id uuid, p_provider_call_id text,
  p_integration_id uuid, p_result text, p_verified boolean, p_order_ref text, p_reservation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pending uuid;
begin
  perform 1 from public.businesses where id = p_business_id for no key update;
  select reservation_id into pending from public.store_lookup_guards
    where business_id = p_business_id and provider_call_id = p_provider_call_id for update;
  -- Idempotent retry after a committed write whose response was lost; never release a newer reservation.
  if pending is null or pending is distinct from p_reservation_id then return; end if;
  if p_integration_id is not null then
    perform 1 from public.integrations where id = p_integration_id and business_id = p_business_id for share;
    if not found then raise exception 'INTEGRATION_BUSINESS_MISMATCH'; end if;
  end if;
  perform public.zella_store_lookup_log(p_business_id, p_provider_call_id, p_integration_id, p_result, p_verified, p_order_ref);
  update public.store_lookup_guards set reservation_id = null
    where business_id = p_business_id and provider_call_id = p_provider_call_id;
end $$;
revoke all on function public.zella_store_lookup_begin(text, uuid, text, text),
  public.zella_store_lookup_finish(uuid, text, uuid, text, boolean, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_store_lookup_begin(text, uuid, text, text),
  public.zella_store_lookup_finish(uuid, text, uuid, text, boolean, text, uuid) to service_role;
commit;
