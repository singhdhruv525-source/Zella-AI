-- Zella: which phone number belongs to which business.
-- Inbound calls arrive on a business's number. The phone assistant tools use this to find the business, so a call
-- never has to carry a business id in its settings (a registered number always wins over anything in the call).
-- Numbers are added by the platform team (service role) when a business is set up; businesses can only read their own.

create table if not exists public.business_phone_numbers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  e164 text not null unique check (e164 ~ '^\+[1-9][0-9]{7,14}$'),
  vapi_phone_number_id text unique,
  label text,
  status text not null default 'active' check (status in ('active', 'paused')),
  created_at timestamptz not null default now()
);
create index if not exists business_phone_numbers_business_idx on public.business_phone_numbers (business_id);
alter table public.business_phone_numbers enable row level security;
revoke all on public.business_phone_numbers from anon, authenticated;
grant select (id, business_id, e164, label, status, created_at) on public.business_phone_numbers to authenticated;
do $$ begin
  create policy business_phone_numbers_member_read on public.business_phone_numbers for select to authenticated
    using (exists (select 1 from public.business_members m where m.business_id = business_phone_numbers.business_id and m.user_id = auth.uid() and m.status = 'active'));
exception when duplicate_object then null; end $$;

-- Turn what a provider sends ("(415) 555-0123", "4155550123", "+14155550123") into +14155550123 (US numbers default to +1).
create or replace function public.zella_normalize_e164(p_number text) returns text
language sql immutable set search_path = public as $$
  select case
    when p_number is null then null
    when regexp_replace(p_number, '[^0-9]', '', 'g') ~ '^[0-9]{10}$' then '+1' || regexp_replace(p_number, '[^0-9]', '', 'g')
    when regexp_replace(p_number, '[^0-9]', '', 'g') ~ '^1[0-9]{10}$' then '+' || regexp_replace(p_number, '[^0-9]', '', 'g')
    when p_number ~ '^\+[1-9][0-9]{7,14}$' then p_number
    else null end;
$$;

create or replace function public.zella_register_phone_number(p_business_id uuid, p_number text, p_vapi_phone_number_id text default null, p_label text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_e text := public.zella_normalize_e164(p_number); v_existing record; v_id uuid;
begin
  if v_e is null then raise exception 'INVALID_NUMBER'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  select * into v_existing from public.business_phone_numbers where e164 = v_e or (nullif(p_vapi_phone_number_id, '') is not null and vapi_phone_number_id = p_vapi_phone_number_id) limit 1;
  if found and v_existing.business_id <> p_business_id then raise exception 'NUMBER_IN_USE'; end if;
  if found then
    update public.business_phone_numbers set e164 = v_e, vapi_phone_number_id = coalesce(nullif(p_vapi_phone_number_id, ''), vapi_phone_number_id),
      label = coalesce(left(p_label, 80), label), status = 'active' where id = v_existing.id returning id into v_id;
  else
    insert into public.business_phone_numbers (business_id, e164, vapi_phone_number_id, label)
    values (p_business_id, v_e, nullif(p_vapi_phone_number_id, ''), left(p_label, 80)) returning id into v_id;
  end if;
  return v_id;
end $$;

-- Which business does this call belong to? A registered, active number always wins. If the number is not registered,
-- the business id that came with the call (p_fallback) is used only when that business is active. Otherwise null.
create or replace function public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text default null, p_fallback uuid default null)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_biz uuid; v_e text := public.zella_normalize_e164(p_called_number);
begin
  select n.business_id into v_biz from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
   where n.status = 'active' and b.suspended_at is null and b.cancelled_at is null
     and ((nullif(p_vapi_phone_number_id, '') is not null and n.vapi_phone_number_id = p_vapi_phone_number_id) or (v_e is not null and n.e164 = v_e))
   order by (n.vapi_phone_number_id = p_vapi_phone_number_id) desc nulls last limit 1;
  if v_biz is not null then return v_biz; end if;
  -- a number that is registered but paused, or belongs to a stopped business, must not fall back to call settings
  if exists (select 1 from public.business_phone_numbers n where (v_e is not null and n.e164 = v_e) or (nullif(p_vapi_phone_number_id, '') is not null and n.vapi_phone_number_id = p_vapi_phone_number_id)) then return null; end if;
  if p_fallback is not null and exists (select 1 from public.businesses b where b.id = p_fallback and b.suspended_at is null and b.cancelled_at is null) then return p_fallback; end if;
  return null;
end $$;

revoke execute on function public.zella_normalize_e164(text) from public, anon, authenticated;
revoke execute on function public.zella_register_phone_number(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.zella_business_for_number(text, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_normalize_e164(text), public.zella_register_phone_number(uuid, text, text, text), public.zella_business_for_number(text, text, uuid) to service_role;
