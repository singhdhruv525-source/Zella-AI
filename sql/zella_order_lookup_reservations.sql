-- Apply after zella_order_lookup_v2.sql and before deploying the updated voice-rules.
-- A pending reservation never expires: uncertain outcomes must not allow another guess.
begin;
create table if not exists public.store_lookup_guards (
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_call_id text not null,
  reservation_id uuid,
  primary key (business_id, provider_call_id)
);
alter table public.store_lookup_guards enable row level security;
revoke all on public.store_lookup_guards from public, anon, authenticated, service_role;

create or replace function public.zella_store_lookup_begin(p_provider_call_id text, p_business_id uuid, p_order_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb; pending uuid; token uuid;
begin
  if p_business_id is null or nullif(trim(p_provider_call_id), '') is null or length(p_provider_call_id) > 200 then
    return jsonb_build_object('ok', false, 'status', 'limited');
  end if;
  insert into public.store_lookup_guards(business_id, provider_call_id)
    values(p_business_id, p_provider_call_id) on conflict do nothing;
  select reservation_id into pending from public.store_lookup_guards
    where business_id = p_business_id and provider_call_id = p_provider_call_id for update;
  if pending is not null then return jsonb_build_object('ok', false, 'status', 'limited'); end if;
  c := public.zella_store_lookup_context(p_provider_call_id, p_business_id, p_order_ref);
  if (c->>'ok')::boolean is distinct from true then return c; end if;
  -- Missing counters cannot establish that a caller is within the policy.
  if c->>'failed_this_call' is null or c->>'failed_this_number_day' is null
     or c->>'failed_this_order_day' is null or c->>'failed_business_hour' is null
     or (c->>'failed_this_call')::integer >= 3 or (c->>'failed_this_number_day')::integer >= 6
     or (c->>'failed_this_order_day')::integer >= 5 or (c->>'failed_business_hour')::integer >= 30 then
    return jsonb_build_object('ok', false, 'status', 'limited');
  end if;
  token := gen_random_uuid();
  update public.store_lookup_guards set reservation_id = token
    where business_id = p_business_id and provider_call_id = p_provider_call_id;
  return c || jsonb_build_object('reservation_id', token);
end $$;

create or replace function public.zella_store_lookup_finish(p_business_id uuid, p_provider_call_id text,
  p_integration_id uuid, p_result text, p_verified boolean, p_order_ref text, p_reservation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pending uuid;
begin
  select reservation_id into pending from public.store_lookup_guards
    where business_id = p_business_id and provider_call_id = p_provider_call_id for update;
  -- Idempotent retry after a committed write whose response was lost; never release a newer reservation.
  if pending is null or pending is distinct from p_reservation_id then return; end if;
  perform public.zella_store_lookup_log(p_business_id, p_provider_call_id, p_integration_id, p_result, p_verified, p_order_ref);
  update public.store_lookup_guards set reservation_id = null
    where business_id = p_business_id and provider_call_id = p_provider_call_id;
end $$;
revoke all on function public.zella_store_lookup_begin(text, uuid, text),
  public.zella_store_lookup_finish(uuid, text, uuid, text, boolean, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_store_lookup_begin(text, uuid, text),
  public.zella_store_lookup_finish(uuid, text, uuid, text, boolean, text, uuid) to service_role;
commit;
