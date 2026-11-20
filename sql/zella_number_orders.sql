-- Zella Voice: buying and releasing phone numbers through Telnyx and Vapi, one approved order at a time
-- (docs/ADMIN_AUDIT_2026-11-16.md VOICE-PROVIDERS). Until now numbers were bought by hand in the Telnyx or Vapi
-- dashboard and only assigned in Zella Voice; nothing recorded who asked for a number, who approved the spend, or what
-- the provider answered.
--   1. A server only table, number_orders: one row per purchase or release, with the number, the business it is for,
--      who asked and why, who decided and why, the provider's order and number ids and the outcome. Row security on,
--      no policies, no grants to signed in people.
--   2. Every step is a function only the server (owner-provision-business, service role) can run, given the admin's
--      id, which the function checks again here: request (telephony.manage, a reason, an idempotency key: the same key
--      gives back the same order), decide (a Zella Voice owner who is not the person who asked: two people for every
--      order), claim (approved to placing, once, only by the approver: a double click can't buy twice), finish (the
--      provider's answer), cancel (the requester or an owner, before a decision). Every step writes audit_logs in the
--      same transaction.
--   3. A release is refused while the number is still assigned in Zella Voice (release it on Numbers first), and a
--      purchase is refused for a number Zella Voice already has. One open order per number.
--   4. The platform setting number_orders_enabled is added as false. The server refuses every order while it is
--      false or while TELNYX_API_KEY or VAPI_API_KEY is unset ("Not connected yet"). Only the owner switches it.
-- Nothing here calls a provider: owner-provision-business (providers.ts) does, between claim and finish.
-- Every function here is new. If one already exists it must be exactly this file's version (VERSION_MISMATCH otherwise).
-- Rollback: sql/rollback/zella_number_orders_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_actor_role(uuid)": "6f620081a6b3d0196982c2ded1e226ac",
    "public.zella_actor_can(uuid,text)": "22a35fae85afbe6926c8bda79f4d0a80",
    "public.zella_actor_audit(uuid,text,text,uuid,uuid,jsonb,jsonb)": "d825b1a4c346740b752802896e7656c9",
    "public.zella_number_order_request(uuid,text,text,uuid,text,text,uuid)": "6b077df156b56b6b2f12e89b926ff295",
    "public.zella_number_order_decide(uuid,uuid,boolean,text)": "6bed4bb76fb04d690d6dba0bcf878556",
    "public.zella_number_order_claim(uuid,uuid)": "5be0217661298653400125c01497dd52",
    "public.zella_number_order_finish(uuid,uuid,text,text,text,text,text)": "2f70695a5cb57a24e454d0c19fbc99ed",
    "public.zella_number_order_cancel(uuid,uuid,text)": "2e3996e7bc6f13664d73e5a476c1abc9",
    "public.zella_number_orders_list(uuid,integer)": "2bfd73dc45d808eb281915eef75bf426",
    "public.zella_number_order_resolve(uuid,uuid,text,text,text,text)": "06f3385235c28d535a1bcf5b26d8a379",
    "public.zella_number_assign_guard()": "d7a31838b195ac243da4247adb4caca1"
  }';
begin
  if to_regclass('public.platform_admins') is null or to_regclass('public.audit_logs') is null or to_regclass('public.business_phone_numbers') is null
     or to_regclass('public.platform_role_permissions') is null or to_regclass('public.platform_settings') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regclass('public.number_orders') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'number_orders' and column_name = 'idempotency_key') then
    raise exception 'VERSION_MISMATCH: a different number_orders table already exists';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.number_orders (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('purchase', 'release')),
  provider text not null default 'telnyx' check (provider = 'telnyx'),
  e164 text not null check (e164 ~ '^\+[1-9][0-9]{7,14}$'),
  business_id uuid references public.businesses(id) on delete set null,
  vapi_phone_number_id text check (vapi_phone_number_id is null or length(vapi_phone_number_id) between 1 and 100),
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'rejected', 'cancelled', 'placing', 'completed', 'failed', 'needs_check')),
  idempotency_key uuid not null unique,
  requested_by uuid not null,
  request_reason text not null check (length(btrim(request_reason)) between 3 and 300),
  decided_by uuid,
  decided_at timestamptz,
  decision_reason text check (decision_reason is null or length(decision_reason) <= 300),
  provider_order_id text check (provider_order_id is null or length(provider_order_id) <= 100),
  provider_number_id text check (provider_number_id is null or length(provider_number_id) <= 100),
  error text check (error is null or length(error) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists number_orders_one_open on public.number_orders (e164)
  where status in ('requested', 'approved', 'placing', 'needs_check');
create index if not exists number_orders_created_idx on public.number_orders (created_at desc);
alter table public.number_orders enable row level security;
revoke all on table public.number_orders from public, anon, authenticated;
grant all on table public.number_orders to service_role;

insert into public.platform_settings (key, value) values ('number_orders_enabled', 'false'::jsonb) on conflict (key) do nothing;

-- The active platform role of a given admin, and whether it holds a permission (the rules of zella_admin_can, for a
-- user id the server has already verified instead of auth.uid()).
create or replace function public.zella_actor_role(p_actor uuid)
returns text language sql stable security definer set search_path = public as $$
  select pa.role from public.platform_admins pa where pa.user_id = p_actor and pa.is_active;
$$;

create or replace function public.zella_actor_can(p_actor uuid, p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select case
    when r = 'zella_owner' then true
    when r = 'super_admin' then p_permission not in ('admins.manage', 'roles.manage')
    else exists (select 1 from public.platform_role_permissions p where p.role = r and p.permission = p_permission)
  end from (select public.zella_actor_role(p_actor) as r) x where r is not null), false);
$$;

create or replace function public.zella_actor_audit(p_actor uuid, p_action text, p_entity_type text, p_entity_id uuid, p_business uuid,
                                                   p_old jsonb, p_new jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business, p_actor, p_action, p_entity_type, p_entity_id, p_old, p_new);
$$;

create or replace function public.zella_number_order_request(p_actor uuid, p_kind text, p_e164 text, p_business uuid, p_vapi_id text,
                                                            p_reason text, p_key uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.number_orders; v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_e164 text := regexp_replace(coalesce(p_e164, ''), '[\s()-]', '', 'g');
begin
  if not public.zella_actor_can(p_actor, 'telephony.manage') then raise exception 'NOT_ALLOWED'; end if;
  if p_key is null then raise exception 'KEY_REQUIRED'; end if;
  select * into o from public.number_orders where idempotency_key = p_key;
  if o.id is not null then
    if o.requested_by <> p_actor or o.kind <> p_kind or o.e164 <> v_e164 then raise exception 'KEY_REUSED'; end if;
    return to_jsonb(o) || jsonb_build_object('repeated', true);
  end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_kind not in ('purchase', 'release') then raise exception 'INVALID_KIND'; end if;
  if v_e164 !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'INVALID_NUMBER'; end if;
  if p_business is not null and not exists (select 1 from public.businesses where id = p_business) then raise exception 'BUSINESS_NOT_FOUND'; end if;
  if exists (select 1 from public.business_phone_numbers where e164 = v_e164) then
    raise exception '%', case when p_kind = 'release' then 'RELEASE_IN_USE' else 'ALREADY_OURS' end;
  end if;
  if exists (select 1 from public.number_orders where e164 = v_e164 and status in ('requested', 'approved', 'placing', 'needs_check')) then
    raise exception 'ORDER_OPEN';
  end if;
  insert into public.number_orders (kind, e164, business_id, vapi_phone_number_id, idempotency_key, requested_by, request_reason)
  values (p_kind, v_e164, p_business, nullif(btrim(coalesce(p_vapi_id, '')), ''), p_key, p_actor, v_reason)
  returning * into o;
  perform public.zella_actor_audit(p_actor, 'telephony.number_order_requested', 'number_order', o.id, o.business_id, null,
    jsonb_build_object('kind', o.kind, 'e164', o.e164, 'reason', o.request_reason));
  return to_jsonb(o) || jsonb_build_object('repeated', false);
end $$;

-- Approve or reject. Only a Zella Voice owner, and never the person who asked (two people for every order).
create or replace function public.zella_number_order_decide(p_actor uuid, p_id uuid, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.number_orders; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_approve is null then raise exception 'DECISION_REQUIRED'; end if;
  select * into o from public.number_orders where id = p_id for update;
  if o.id is null then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'requested' then raise exception 'NOT_PENDING'; end if;
  if o.requested_by = p_actor then raise exception 'SECOND_PERSON_REQUIRED'; end if;
  update public.number_orders set status = case when p_approve then 'approved' else 'rejected' end, decided_by = p_actor, decided_at = now(),
         decision_reason = v_reason, updated_at = now()
   where id = o.id returning * into o;
  perform public.zella_actor_audit(p_actor, case when p_approve then 'telephony.number_order_approved' else 'telephony.number_order_rejected' end,
    'number_order', o.id, o.business_id, jsonb_build_object('status', 'requested'),
    jsonb_build_object('status', o.status, 'kind', o.kind, 'e164', o.e164, 'reason', v_reason));
  return to_jsonb(o);
end $$;

-- Approved to placing, once. Only the owner who approved it may place it; a second call is refused, so a double click
-- or a retried request never reaches the provider twice.
create or replace function public.zella_number_order_claim(p_actor uuid, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.number_orders;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  select * into o from public.number_orders where id = p_id;
  if o.id is null then raise exception 'NOT_APPROVED'; end if;
  -- a release is placed only while the number isn't assigned in Zella Voice (the same lock as an assignment)
  perform pg_advisory_xact_lock(hashtextextended('zella_number:' || o.e164, 0));
  if o.kind = 'release' and exists (select 1 from public.business_phone_numbers where e164 = o.e164) then raise exception 'RELEASE_IN_USE'; end if;
  update public.number_orders set status = 'placing', updated_at = now()
   where id = p_id and status = 'approved' and decided_by = p_actor returning * into o;
  if o.id is null then raise exception 'NOT_APPROVED'; end if;
  perform public.zella_actor_audit(p_actor, 'telephony.number_order_placing', 'number_order', o.id, o.business_id,
    jsonb_build_object('status', 'approved'), jsonb_build_object('status', 'placing', 'kind', o.kind, 'e164', o.e164));
  return to_jsonb(o);
end $$;

-- What the provider answered. needs_check means the request may have reached the provider but the answer was lost:
-- it is never retried automatically; someone checks the Telnyx dashboard and records the outcome.
create or replace function public.zella_number_order_finish(p_actor uuid, p_id uuid, p_outcome text, p_order_id text, p_number_id text,
                                                           p_vapi_id text, p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.number_orders;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if p_outcome not in ('completed', 'failed', 'needs_check') then raise exception 'INVALID_OUTCOME'; end if;
  update public.number_orders set status = p_outcome, provider_order_id = coalesce(left(p_order_id, 100), provider_order_id),
         provider_number_id = coalesce(left(p_number_id, 100), provider_number_id),
         vapi_phone_number_id = coalesce(left(p_vapi_id, 100), vapi_phone_number_id), error = left(p_error, 500), updated_at = now()
   where id = p_id and status = 'placing' and decided_by = p_actor returning * into o;
  if o.id is null then raise exception 'NOT_PLACING'; end if;
  perform public.zella_actor_audit(p_actor, 'telephony.number_order_' || p_outcome, 'number_order', o.id, o.business_id,
    jsonb_build_object('status', 'placing'),
    jsonb_build_object('status', o.status, 'kind', o.kind, 'e164', o.e164, 'provider_order_id', o.provider_order_id,
                       'provider_number_id', o.provider_number_id, 'vapi_phone_number_id', o.vapi_phone_number_id, 'error', o.error));
  return to_jsonb(o);
end $$;

create or replace function public.zella_number_order_cancel(p_actor uuid, p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.number_orders; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if not public.zella_actor_can(p_actor, 'telephony.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into o from public.number_orders where id = p_id for update;
  if o.id is null then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'requested' then raise exception 'NOT_PENDING'; end if;
  if o.requested_by <> p_actor and public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'NOT_ALLOWED'; end if;
  update public.number_orders set status = 'cancelled', decided_by = p_actor, decided_at = now(), decision_reason = v_reason, updated_at = now()
   where id = o.id returning * into o;
  perform public.zella_actor_audit(p_actor, 'telephony.number_order_cancelled', 'number_order', o.id, o.business_id,
    jsonb_build_object('status', 'requested'), jsonb_build_object('status', 'cancelled', 'reason', v_reason));
  return to_jsonb(o);
end $$;

-- Newest first, with names instead of ids. No secrets: the provider ids are references, not keys.
create or replace function public.zella_number_orders_list(p_actor uuid, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_actor_can(p_actor, 'businesses.view') then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'e164', o.e164, 'business_id', o.business_id,
      'business_name', b.name, 'status', o.status, 'requested_by', o.requested_by, 'requested_by_email', ru.email, 'request_reason', o.request_reason,
      'decided_by_email', du.email, 'decided_at', o.decided_at, 'decision_reason', o.decision_reason, 'provider_order_id', o.provider_order_id,
      'provider_number_id', o.provider_number_id, 'vapi_phone_number_id', o.vapi_phone_number_id, 'error', o.error,
      'created_at', o.created_at, 'updated_at', o.updated_at) order by o.created_at desc)
    from (select * from public.number_orders order by created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) o
    left join public.businesses b on b.id = o.business_id
    left join auth.users ru on ru.id = o.requested_by
    left join auth.users du on du.id = o.decided_by), '[]'::jsonb);
end $$;

-- an order waiting for a check is closed with what a Zella Voice owner saw in the provider dashboards; nothing is sent
-- again (the order can't go back to placing)
create or replace function public.zella_number_order_resolve(p_actor uuid, p_id uuid, p_outcome text, p_reason text, p_number_id text, p_vapi_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.number_orders; v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_was text;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_outcome is null or p_outcome not in ('completed', 'failed') then raise exception 'INVALID_OUTCOME'; end if;
  select * into o from public.number_orders where id = p_id for update;
  if o.id is null then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'needs_check' then raise exception 'NOT_NEEDS_CHECK'; end if;
  v_was := o.error;
  -- the provider's earlier message (kept in the audit below) is replaced by what the owner recorded
  update public.number_orders set status = p_outcome, error = left('Recorded after a check: ' || v_reason, 500),
         provider_number_id = coalesce(left(nullif(btrim(coalesce(p_number_id, '')), ''), 100), provider_number_id),
         vapi_phone_number_id = coalesce(left(nullif(btrim(coalesce(p_vapi_id, '')), ''), 100), vapi_phone_number_id), updated_at = now()
   where id = o.id returning * into o;
  perform public.zella_actor_audit(p_actor, 'telephony.number_order_resolved', 'number_order', o.id, o.business_id,
    jsonb_build_object('status', 'needs_check', 'error', v_was), jsonb_build_object('status', o.status, 'reason', v_reason, 'kind', o.kind, 'e164', o.e164));
  return to_jsonb(o);
end $$;

-- every way a number is assigned to a business is refused while a release of that number is open (the same lock as
-- the claim that places the release)
create or replace function public.zella_number_assign_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.e164 is not distinct from old.e164 then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('zella_number:' || new.e164, 0));
  if exists (select 1 from public.number_orders where e164 = new.e164 and kind = 'release' and status in ('requested', 'approved', 'placing', 'needs_check')) then
    raise exception 'NUMBER_RELEASE_OPEN';
  end if;
  return new;
end $$;
drop trigger if exists zella_number_assign_guard on public.business_phone_numbers;
create trigger zella_number_assign_guard before insert or update of e164 on public.business_phone_numbers
  for each row execute function public.zella_number_assign_guard();

revoke all on function public.zella_actor_role(uuid), public.zella_actor_can(uuid, text),
  public.zella_actor_audit(uuid, text, text, uuid, uuid, jsonb, jsonb),
  public.zella_number_order_request(uuid, text, text, uuid, text, text, uuid), public.zella_number_order_decide(uuid, uuid, boolean, text),
  public.zella_number_order_claim(uuid, uuid), public.zella_number_order_finish(uuid, uuid, text, text, text, text, text),
  public.zella_number_order_resolve(uuid, uuid, text, text, text, text), public.zella_number_assign_guard(),
  public.zella_number_order_cancel(uuid, uuid, text), public.zella_number_orders_list(uuid, integer) from public, anon, authenticated;
grant execute on function public.zella_actor_role(uuid), public.zella_actor_can(uuid, text),
  public.zella_actor_audit(uuid, text, text, uuid, uuid, jsonb, jsonb),
  public.zella_number_order_request(uuid, text, text, uuid, text, text, uuid), public.zella_number_order_decide(uuid, uuid, boolean, text),
  public.zella_number_order_claim(uuid, uuid), public.zella_number_order_finish(uuid, uuid, text, text, text, text, text),
  public.zella_number_order_resolve(uuid, uuid, text, text, text, text), public.zella_number_assign_guard(),
  public.zella_number_order_cancel(uuid, uuid, text), public.zella_number_orders_list(uuid, integer) to service_role;

commit;
