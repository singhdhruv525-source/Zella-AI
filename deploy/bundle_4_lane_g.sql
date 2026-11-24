-- Zella Voice production deploy: paste this whole file into Supabase SQL Editor and click Run. Files in the tested order; each records itself as applied.

-- ===== zella_number_orders =====
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


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '01', 'zella_number_orders' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_number_orders');

-- ===== zella_recording_policy =====
-- Zella Voice: a recording on or off policy per business, off for everyone until legal review
-- (docs/ADMIN_AUDIT_2026-11-16.md SET-RECORDING-POLICY; D-27, REQ-VOX-09, REQ-BIL-48). There was no recording switch
-- at all: whether a call is recorded was left to the voice provider's own settings.
--   1. A server only table, business_recording_policies: one row per business that has a policy (no row means off),
--      with who changed it, why and when. Row security on, no policies, no grants to signed in people.
--   2. Two platform settings, added as the safe values: recording_legal_approved = false and
--      recording_disclosure_text = "" (the line the receptionist says to callers, left empty until legal provides it).
--      A guard on platform_settings refuses any change to either one except through zella_recording_legal_set, which
--      only a Zella Voice owner can run, with a reason; turning approval on needs the disclosure text. Turning
--      approval off also switches every business's recording off. All of it audited in the same transaction.
--   3. zella_recording_policy_set(admin, business, on, reason): businesses.manage. Off is always allowed; on is refused
--      (RECORDING_NOT_APPROVED) while legal approval is off or the disclosure text is empty. A trigger on the table
--      refuses the same thing for any other writer.
--   4. zella_recording_effective(business): true only when legal approval is on, the disclosure text is set and the
--      business's policy is on. False for everyone today. It is NOT read by voice-rules or the assistant config yet:
--      connecting it to the live call path is a separate change that needs its own approval.
-- Every function here is new. If one already exists it must be exactly this file's version (VERSION_MISMATCH otherwise).
-- Needs sql/zella_number_orders.sql (the zella_actor_* helpers). Rollback: sql/rollback/zella_recording_policy_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_recording_setting_guard()": "6d3ebb3ae696080e27205a1f6d326e77",
    "public.zella_recording_policy_guard()": "8fd784b180e1bbffa4095521ba2b4bb5",
    "public.zella_recording_effective(uuid)": "104511e50db0dc4c549ce555d2578b74",
    "public.zella_recording_policies(uuid)": "24008889cb73a40039aff433a86b53b8",
    "public.zella_recording_policy_set(uuid,uuid,boolean,text)": "0ff2ec7daff9eccf80673afb75d62fa4",
    "public.zella_recording_legal_set(uuid,boolean,text,text)": "83bfdee3e86d2829ba3f68de02a7e7f0"
  }';
begin
  if to_regprocedure('public.zella_actor_can(uuid,text)') is null or to_regprocedure('public.zella_actor_audit(uuid,text,text,uuid,uuid,jsonb,jsonb)') is null
     or to_regclass('public.platform_settings') is null or to_regclass('public.businesses') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_number_orders.sql first)';
  end if;
  if to_regclass('public.business_recording_policies') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'business_recording_policies' and column_name = 'recording_on') then
    raise exception 'VERSION_MISMATCH: a different business_recording_policies table already exists';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.business_recording_policies (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  recording_on boolean not null default false,
  reason text not null check (length(btrim(reason)) between 3 and 300),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.business_recording_policies enable row level security;
revoke all on table public.business_recording_policies from public, anon, authenticated;
grant all on table public.business_recording_policies to service_role;

-- Only zella_recording_legal_set (which sets zella.recording_legal for its own transaction) may change these two.
create or replace function public.zella_recording_setting_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(new.key, old.key) in ('recording_legal_approved', 'recording_disclosure_text')
     and coalesce(current_setting('zella.recording_legal', true), '') <> 'on' then
    raise exception 'RECORDING_SETTING_OWNER_ONLY: only a Zella Voice owner changes this, through the recording policy';
  end if;
  return coalesce(new, old);
end $$;

-- No writer can switch a business's recording on while legal approval is off or the disclosure is empty.
create or replace function public.zella_recording_policy_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.recording_on and not (
       coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'recording_legal_approved'), false)
       and length(btrim(coalesce((select value #>> '{}' from public.platform_settings where key = 'recording_disclosure_text'), ''))) > 0) then
    raise exception 'RECORDING_NOT_APPROVED: recording stays off until legal review is recorded and the caller disclosure is set';
  end if;
  return new;
end $$;

select set_config('zella.recording_legal', 'on', true);
insert into public.platform_settings (key, value) values ('recording_legal_approved', 'false'::jsonb), ('recording_disclosure_text', '""'::jsonb)
on conflict (key) do nothing;
select set_config('zella.recording_legal', '', true);

drop trigger if exists zella_recording_setting_guard on public.platform_settings;
create trigger zella_recording_setting_guard before insert or update or delete on public.platform_settings
  for each row execute function public.zella_recording_setting_guard();
drop trigger if exists zella_recording_policy_guard on public.business_recording_policies;
create trigger zella_recording_policy_guard before insert or update on public.business_recording_policies
  for each row execute function public.zella_recording_policy_guard();

create or replace function public.zella_recording_effective(p_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'recording_legal_approved'), false)
     and length(btrim(coalesce((select value #>> '{}' from public.platform_settings where key = 'recording_disclosure_text'), ''))) > 0
     and coalesce((select recording_on from public.business_recording_policies where business_id = p_business), false);
$$;

-- The legal state, the disclosure and every business whose policy says on (today: none).
create or replace function public.zella_recording_policies(p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_actor_can(p_actor, 'businesses.view') then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'legal_approved', coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'recording_legal_approved'), false),
    'disclosure', coalesce((select value #>> '{}' from public.platform_settings where key = 'recording_disclosure_text'), ''),
    'businesses', coalesce((select jsonb_agg(jsonb_build_object('business_id', p.business_id, 'name', b.name, 'recording_on', p.recording_on,
        'effective', public.zella_recording_effective(p.business_id), 'reason', p.reason, 'updated_at', p.updated_at) order by b.name)
      from public.business_recording_policies p join public.businesses b on b.id = p.business_id), '[]'::jsonb),
    'live_call_path', false);
end $$;

create or replace function public.zella_recording_policy_set(p_actor uuid, p_business uuid, p_on boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_before boolean; r public.business_recording_policies;
begin
  if not public.zella_actor_can(p_actor, 'businesses.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_on is null then raise exception 'DECISION_REQUIRED'; end if;
  if not exists (select 1 from public.businesses where id = p_business) then raise exception 'BUSINESS_NOT_FOUND'; end if;
  -- one lock for every policy change and for legal approval, so a withdrawal can never miss a policy saved at the same
  -- time (including a business that had no row yet)
  perform pg_advisory_xact_lock(hashtextextended('zella_recording_policy', 0));
  select recording_on into v_before from public.business_recording_policies where business_id = p_business for update;
  insert into public.business_recording_policies (business_id, recording_on, reason, updated_by, updated_at)
  values (p_business, p_on, v_reason, p_actor, now())
  on conflict (business_id) do update set recording_on = excluded.recording_on, reason = excluded.reason, updated_by = excluded.updated_by, updated_at = now()
  returning * into r;
  perform public.zella_actor_audit(p_actor, 'business.recording_policy_set', 'business', p_business, p_business,
    jsonb_build_object('recording_on', coalesce(v_before, false)), jsonb_build_object('recording_on', r.recording_on, 'reason', v_reason));
  return jsonb_build_object('business_id', p_business, 'recording_on', r.recording_on, 'effective', public.zella_recording_effective(p_business));
end $$;

-- The owner records the legal answer and the disclosure wording. Approval off switches every business's recording off.
create or replace function public.zella_recording_legal_set(p_actor uuid, p_approved boolean, p_disclosure text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_text text := left(btrim(coalesce(p_disclosure, '')), 500);
        v_was boolean; v_old_text text; v_off int := 0;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_approved is null then raise exception 'DECISION_REQUIRED'; end if;
  if p_approved and length(v_text) = 0 then raise exception 'DISCLOSURE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('zella_recording_policy', 0));
  select coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'recording_legal_approved'), false),
         coalesce((select value #>> '{}' from public.platform_settings where key = 'recording_disclosure_text'), '') into v_was, v_old_text;
  if not p_approved then
    update public.business_recording_policies set recording_on = false, reason = 'Legal approval withdrawn: ' || left(v_reason, 270),
           updated_by = p_actor, updated_at = now() where recording_on;
    get diagnostics v_off = row_count;
  end if;
  perform set_config('zella.recording_legal', 'on', true);
  insert into public.platform_settings (key, value, updated_at) values ('recording_legal_approved', to_jsonb(p_approved), now()),
    ('recording_disclosure_text', to_jsonb(v_text), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  perform set_config('zella.recording_legal', '', true);
  perform public.zella_actor_audit(p_actor, 'platform.recording_legal_set', 'platform_setting', null, null,
    jsonb_build_object('legal_approved', v_was, 'disclosure', v_old_text),
    jsonb_build_object('legal_approved', p_approved, 'disclosure', v_text, 'reason', v_reason, 'businesses_switched_off', v_off));
  return jsonb_build_object('legal_approved', p_approved, 'disclosure', v_text, 'businesses_switched_off', v_off);
end $$;

revoke all on function public.zella_recording_setting_guard(), public.zella_recording_policy_guard(), public.zella_recording_effective(uuid),
  public.zella_recording_policies(uuid), public.zella_recording_policy_set(uuid, uuid, boolean, text),
  public.zella_recording_legal_set(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.zella_recording_effective(uuid), public.zella_recording_policies(uuid),
  public.zella_recording_policy_set(uuid, uuid, boolean, text), public.zella_recording_legal_set(uuid, boolean, text, text) to service_role;

commit;


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '02', 'zella_recording_policy' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_recording_policy');

-- ===== zella_data_retention =====
-- Zella Voice: retention periods per kind of data, legal holds and a dry run of what a purge would remove
-- (docs/ADMIN_AUDIT_2026-11-16.md SET-RETENTION, BIZ-18b; ARCHITECTURE.md REQ-PRV-01, D-13, D-27). Only one period
-- existed (retention_days, for a cancelled business's records) and nothing listed what is past its period.
--   1. A server only table, data_retention_policies: one row per kind of data with its period in days, the
--      architecture's proposed period, and its legal status. Every row starts as the architecture's value and
--      "pending_legal_review": call recordings 30 days, call transcripts 90, message bodies 730 (2 years), audit and
--      security logs 2555 (7 years), replaced verification documents 30 days after they were replaced, owner identity
--      files 90 days after they were verified (the outcome is kept), a cancelled business's verification documents and
--      the cancelled business itself 30 days after cancellation. Only a Zella Voice owner changes a period or records
--      legal approval, with a reason, audited (zella_retention_policy_set).
--   2. A server only table, legal_holds: a business on hold is never listed for removal. security.manage places a
--      hold; only a Zella Voice owner releases one. Audited.
--   3. zella_retention_preview(admin, kind, limit): the DRY RUN. It counts and lists (ids, business, date: never any
--      content) what is past its period, leaving out businesses on hold, and deletes nothing. security.view.
--      zella_retention_candidates(kind, cutoff) is the one definition of "past its period" that the purge (a later
--      migration) uses too.
--   4. A server only table, retention_removed_files: verification files a purge removed (the row and its outcome stay).
--      Filled by sql/zella_retention_purge.sql; files listed there are not listed again.
--   5. retention_purge_enabled = false: the switch a real purge will need (sql/zella_retention_purge.sql). Only a
--      Zella Voice owner can change it (zella_retention_switch_set, a guard refuses any other change). No job is
--      scheduled, here or anywhere.
-- Nothing here deletes or changes any call, message, audit row or document.
-- Every function here is new. If one already exists it must be exactly this file's version (VERSION_MISMATCH otherwise).
-- Needs sql/zella_number_orders.sql (the zella_actor_* helpers). Rollback: sql/rollback/zella_data_retention_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_retention_setting_guard()": "bb4c21aaa0137af97dd3d22e6edc9b96",
    "public.zella_retention_on_hold(uuid)": "aa38f978a7484df0cd06decf0e7b13d6",
    "public.zella_retention_candidates(text,timestamp with time zone)": "80d1a34ab624d8d4acbc882818a829c2",
    "public.zella_retention_preview(uuid,text,integer)": "1fd49ad9a112ebd390d36d13b89b80ea",
    "public.zella_retention_overview(uuid)": "c7b1717cdeaf2e725a70ec15b23fc18b",
    "public.zella_retention_policy_set(uuid,text,integer,text,text)": "dd3f7ba07966beb77b57e0354a3ad345",
    "public.zella_retention_switch_set(uuid,boolean,text)": "fce745114b992f3977beae3a74876f46",
    "public.zella_legal_hold_place(uuid,uuid,text)": "36b7984955df89696bdd811d92048c21",
    "public.zella_legal_hold_release(uuid,uuid,text)": "906697b3714e1fcebe61a7ae74cc49b0"
  }';
begin
  if to_regprocedure('public.zella_actor_can(uuid,text)') is null or to_regprocedure('public.zella_actor_audit(uuid,text,text,uuid,uuid,jsonb,jsonb)') is null
     or to_regclass('public.business_verification_documents') is null or to_regclass('public.calls') is null or to_regclass('public.sms_messages') is null
     or to_regclass('public.email_messages') is null or to_regclass('public.conversation_messages') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_number_orders.sql first)';
  end if;
  if (to_regclass('public.data_retention_policies') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'data_retention_policies' and column_name = 'architecture_days'))
     or (to_regclass('public.retention_removed_files') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'retention_removed_files' and column_name = 'run_id'))
     or (to_regclass('public.legal_holds') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'legal_holds' and column_name = 'released_at')) then
    raise exception 'VERSION_MISMATCH: a different data_retention_policies or legal_holds table already exists';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.data_retention_policies (
  data_class text primary key check (data_class in ('call_recordings', 'call_transcripts', 'message_bodies', 'audit_logs',
    'documents_replaced', 'documents_owner_id_verified', 'documents_cancelled_business', 'cancelled_business')),
  days integer not null check (days between 1 and 36500),
  architecture_days integer not null,
  legal_status text not null default 'pending_legal_review' check (legal_status in ('pending_legal_review', 'approved')),
  note text check (note is null or length(note) <= 300),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.data_retention_policies enable row level security;
revoke all on table public.data_retention_policies from public, anon, authenticated;
grant all on table public.data_retention_policies to service_role;

insert into public.data_retention_policies (data_class, days, architecture_days, note) values
  ('call_recordings', 30, 30, 'D-13, D-27. Recording is off until legal review, so there are none yet.'),
  ('call_transcripts', 90, 90, 'D-13.'),
  ('message_bodies', 730, 730, 'Texts, emails and conversation messages: the words are removed, the record of the message stays.'),
  ('audit_logs', 2555, 2555, 'Audit and security logs, 7 years unless the legal policy requires otherwise.'),
  ('documents_replaced', 30, 30, 'Files of verification documents replaced by a newer copy, counted from the replacement.'),
  ('documents_owner_id_verified', 90, 90, 'Owner identity files, counted from verification. The outcome (status, reviewer, date) is kept.'),
  ('documents_cancelled_business', 30, 30, 'Every verification file of a cancelled business, counted from cancellation.'),
  ('cancelled_business', 30, 30, 'The whole business, after a final export offer. Never earlier than its retention date (retention_days, 90 today).')
on conflict (data_class) do nothing;

-- Verification files removed under retention (by sql/zella_retention_purge.sql): the document row and its outcome stay,
-- and the dry run doesn't list the file again.
create table if not exists public.retention_removed_files (
  document_id uuid primary key,
  file_path text not null,
  run_id uuid,
  removed_at timestamptz not null default now()
);
alter table public.retention_removed_files enable row level security;
revoke all on table public.retention_removed_files from public, anon, authenticated;
grant all on table public.retention_removed_files to service_role;

create table if not exists public.legal_holds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 3 and 300),
  placed_by uuid not null,
  placed_at timestamptz not null default now(),
  released_by uuid,
  released_at timestamptz,
  release_reason text check (release_reason is null or length(release_reason) <= 300)
);
create unique index if not exists legal_holds_one_active on public.legal_holds (business_id) where released_at is null;
alter table public.legal_holds enable row level security;
revoke all on table public.legal_holds from public, anon, authenticated;
grant all on table public.legal_holds to service_role;

-- Only zella_retention_switch_set (which sets zella.retention_switch for its own transaction) may change the switch.
create or replace function public.zella_retention_setting_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  -- the old and the new key both count, so an update can't rename the switch away
  if 'retention_purge_enabled' in (new.key, old.key) and coalesce(current_setting('zella.retention_switch', true), '') <> 'on' then
    raise exception 'RETENTION_SWITCH_OWNER_ONLY: only a Zella Voice owner changes this, from Data retention';
  end if;
  return coalesce(new, old);
end $$;

select set_config('zella.retention_switch', 'on', true);
insert into public.platform_settings (key, value) values ('retention_purge_enabled', 'false'::jsonb) on conflict (key) do nothing;
select set_config('zella.retention_switch', '', true);
drop trigger if exists zella_retention_setting_guard on public.platform_settings;
create trigger zella_retention_setting_guard before insert or update or delete on public.platform_settings
  for each row execute function public.zella_retention_setting_guard();

create or replace function public.zella_retention_on_hold(p_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.legal_holds where business_id = p_business and released_at is null);
$$;

-- What is past its period for one kind of data, as (table, id, business, date). Never any content. Businesses on a
-- legal hold are left out. The single definition used by the dry run and by the purge.
-- A purged transcript is replaced by 'Removed under the retention policy.', not emptied: an empty transcript on a short
-- call would make zella_call_integrity re-mark the old call as missed and start a missed call callback.
create or replace function public.zella_retention_candidates(p_class text, p_cutoff timestamptz)
returns table (source text, row_id uuid, business_id uuid, dated timestamptz)
language sql stable security definer set search_path = public as $$
  select 'calls', c.id, c.business_id, coalesce(c.ended_at, c.created_at) from public.calls c
   where p_class = 'call_recordings' and c.recording_url is not null and coalesce(c.ended_at, c.created_at) < p_cutoff
     and not public.zella_retention_on_hold(c.business_id)
  union all
  select 'calls', c.id, c.business_id, coalesce(c.ended_at, c.created_at) from public.calls c
   where p_class = 'call_transcripts' and c.transcript is not null and c.transcript <> 'Removed under the retention policy.'
     and coalesce(c.ended_at, c.created_at) < p_cutoff
     and not public.zella_retention_on_hold(c.business_id)
  union all
  select 'sms_messages', m.id, m.business_id, m.created_at from public.sms_messages m
   where p_class = 'message_bodies' and m.message_body is not null and m.created_at < p_cutoff and not public.zella_retention_on_hold(m.business_id)
  union all
  select 'email_messages', m.id, m.business_id, m.created_at from public.email_messages m
   where p_class = 'message_bodies' and (m.body_text is not null or m.body_html is not null) and m.created_at < p_cutoff
     and not public.zella_retention_on_hold(m.business_id)
  union all
  select 'conversation_messages', m.id, m.business_id, m.created_at from public.conversation_messages m
   where p_class = 'message_bodies' and m.content is not null and m.created_at < p_cutoff and not public.zella_retention_on_hold(m.business_id)
  union all
  select 'audit_logs', a.id, a.business_id, a.created_at from public.audit_logs a
   where p_class = 'audit_logs' and a.created_at < p_cutoff and (a.business_id is null or not public.zella_retention_on_hold(a.business_id))
  union all
  select 'business_verification_documents', d.id, d.business_id, d.updated_at from public.business_verification_documents d
   where p_class = 'documents_replaced' and d.status = 'replaced' and d.updated_at < p_cutoff and not public.zella_retention_on_hold(d.business_id)
     and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id)
  union all
  select 'business_verification_documents', d.id, d.business_id, d.reviewed_at from public.business_verification_documents d
   where p_class = 'documents_owner_id_verified' and d.kind = 'owner_identity' and d.status = 'verified' and d.reviewed_at < p_cutoff
     and not public.zella_retention_on_hold(d.business_id) and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id)
  union all
  select 'business_verification_documents', d.id, d.business_id, b.cancelled_at from public.business_verification_documents d
    join public.businesses b on b.id = d.business_id
   where p_class = 'documents_cancelled_business' and b.cancelled_at is not null and b.cancelled_at < p_cutoff
     and not public.zella_retention_on_hold(d.business_id) and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id)
  union all
  select 'businesses', b.id, b.id, b.cancelled_at from public.businesses b
   where p_class = 'cancelled_business' and b.cancelled_at is not null and b.cancelled_at < p_cutoff
     and (b.retention_until is null or b.retention_until < now()) and not public.zella_retention_on_hold(b.id);
$$;

-- The dry run: how many, and the first ones, oldest first. Deletes nothing.
create or replace function public.zella_retention_preview(p_actor uuid, p_class text, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.data_retention_policies; v_cutoff timestamptz;
begin
  if not public.zella_actor_can(p_actor, 'security.view') then raise exception 'NOT_ALLOWED'; end if;
  select * into p from public.data_retention_policies where data_class = p_class;
  if p.data_class is null then raise exception 'UNKNOWN_CLASS'; end if;
  v_cutoff := now() - make_interval(days => p.days);
  return jsonb_build_object('data_class', p.data_class, 'days', p.days, 'cutoff', v_cutoff, 'legal_status', p.legal_status, 'dry_run', true,
    'count', (select count(*) from public.zella_retention_candidates(p.data_class, v_cutoff)),
    'by_source', coalesce((select jsonb_object_agg(source, n) from (select source, count(*) n from public.zella_retention_candidates(p.data_class, v_cutoff) group by source) s), '{}'::jsonb),
    'held_businesses', (select count(*) from public.legal_holds where released_at is null),
    'sample', coalesce((select jsonb_agg(jsonb_build_object('source', c.source, 'id', c.row_id, 'business_id', c.business_id, 'business_name', b.name, 'dated', c.dated) order by c.dated)
       from (select * from public.zella_retention_candidates(p.data_class, v_cutoff) order by dated limit least(greatest(coalesce(p_limit, 25), 1), 100)) c
       left join public.businesses b on b.id = c.business_id), '[]'::jsonb));
end $$;

create or replace function public.zella_retention_overview(p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_actor_can(p_actor, 'security.view') then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'policies', (select jsonb_agg(to_jsonb(p) - 'updated_by' order by array_position(array['call_recordings', 'call_transcripts', 'message_bodies', 'audit_logs',
        'documents_replaced', 'documents_owner_id_verified', 'documents_cancelled_business', 'cancelled_business'], p.data_class)) from public.data_retention_policies p),
    'purge_enabled', coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false),
    'retention_days', (select value from public.platform_settings where key = 'retention_days'),
    'holds', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'business_id', h.business_id, 'business_name', b.name, 'reason', h.reason,
        'placed_at', h.placed_at, 'placed_by_email', u.email) order by h.placed_at desc)
      from public.legal_holds h join public.businesses b on b.id = h.business_id left join auth.users u on u.id = h.placed_by where h.released_at is null), '[]'::jsonb),
    'scheduled', false);
end $$;

-- The owner sets a period and its legal status. Only after legal review should the status be "approved".
create or replace function public.zella_retention_policy_set(p_actor uuid, p_class text, p_days integer, p_status text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); o public.data_retention_policies; n public.data_retention_policies;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_status is null or p_status not in ('pending_legal_review', 'approved') then raise exception 'INVALID_STATUS'; end if;
  if p_days is null or p_days < 1 or p_days > 36500 then raise exception 'INVALID_DAYS'; end if;
  select * into o from public.data_retention_policies where data_class = p_class for update;
  if o.data_class is null then raise exception 'UNKNOWN_CLASS'; end if;
  update public.data_retention_policies set days = p_days, legal_status = p_status, updated_by = p_actor, updated_at = now()
   where data_class = p_class returning * into n;
  perform public.zella_actor_audit(p_actor, 'platform.retention_policy_set', 'data_retention_policy', null, null,
    jsonb_build_object('data_class', o.data_class, 'days', o.days, 'legal_status', o.legal_status),
    jsonb_build_object('data_class', n.data_class, 'days', n.days, 'legal_status', n.legal_status, 'reason', v_reason));
  return to_jsonb(n) - 'updated_by';
end $$;

create or replace function public.zella_retention_switch_set(p_actor uuid, p_on boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_was boolean;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_on is null then raise exception 'DECISION_REQUIRED'; end if;
  v_was := coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false);
  perform set_config('zella.retention_switch', 'on', true);
  insert into public.platform_settings (key, value, updated_at) values ('retention_purge_enabled', to_jsonb(p_on), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  perform set_config('zella.retention_switch', '', true);
  perform public.zella_actor_audit(p_actor, 'platform.retention_purge_switch', 'platform_setting', null, null,
    jsonb_build_object('enabled', v_was), jsonb_build_object('enabled', p_on, 'reason', v_reason));
  return jsonb_build_object('purge_enabled', p_on);
end $$;

create or replace function public.zella_legal_hold_place(p_actor uuid, p_business uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); h public.legal_holds;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.businesses where id = p_business) then raise exception 'BUSINESS_NOT_FOUND'; end if;
  -- the same lock as a purge's removal, so a hold never lands in the middle of one
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  if public.zella_retention_on_hold(p_business) then raise exception 'ALREADY_ON_HOLD'; end if;
  -- refused while a purge run is removing this business's files (sql/zella_retention_purge.sql); once it stops, the
  -- remaining files of a business on hold are never removed
  if to_regclass('public.retention_purge_runs') is not null then
    if (select exists (select 1 from public.retention_purge_runs r join public.business_verification_documents d on d.file_path = any (r.file_paths)
                        where r.status in ('running', 'files_pending') and d.business_id = p_business)) then
      raise exception 'PURGE_IN_PROGRESS';
    end if;
  end if;
  insert into public.legal_holds (business_id, reason, placed_by) values (p_business, v_reason, p_actor) returning * into h;
  perform public.zella_actor_audit(p_actor, 'business.legal_hold_placed', 'legal_hold', h.id, p_business, null, jsonb_build_object('reason', v_reason));
  return to_jsonb(h);
end $$;

create or replace function public.zella_legal_hold_release(p_actor uuid, p_hold uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); h public.legal_holds;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update public.legal_holds set released_by = p_actor, released_at = now(), release_reason = v_reason
   where id = p_hold and released_at is null returning * into h;
  if h.id is null then raise exception 'NOT_FOUND'; end if;
  perform public.zella_actor_audit(p_actor, 'business.legal_hold_released', 'legal_hold', h.id, h.business_id,
    jsonb_build_object('reason', h.reason), jsonb_build_object('reason', v_reason));
  return to_jsonb(h);
end $$;

revoke all on function public.zella_retention_setting_guard(), public.zella_retention_on_hold(uuid),
  public.zella_retention_candidates(text, timestamptz), public.zella_retention_preview(uuid, text, integer), public.zella_retention_overview(uuid),
  public.zella_retention_policy_set(uuid, text, integer, text, text), public.zella_retention_switch_set(uuid, boolean, text),
  public.zella_legal_hold_place(uuid, uuid, text), public.zella_legal_hold_release(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.zella_retention_on_hold(uuid), public.zella_retention_preview(uuid, text, integer), public.zella_retention_overview(uuid),
  public.zella_retention_policy_set(uuid, text, integer, text, text), public.zella_retention_switch_set(uuid, boolean, text),
  public.zella_legal_hold_place(uuid, uuid, text), public.zella_legal_hold_release(uuid, uuid, text) to service_role;

commit;


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '03', 'zella_data_retention' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_data_retention');

-- ===== zella_retention_purge =====
-- Zella Voice: an approved purge of data past its retention period, run by hand, one run at a time, by two people
-- (docs/ADMIN_AUDIT_2026-11-16.md SET-RETENTION, BIZ-18b; REQ-PRV-01). sql/zella_data_retention.sql lists what is past
-- its period (the dry run); this file lets it be removed, and only when every guard agrees:
--   1. a server only table, retention_purge_runs: one row per run, holding the exact rows listed when it was asked for
--      (at most 1000, oldest first), so approving a run approves those rows and nothing that appears later;
--   2. request (security.manage, a reason): refused while the kind's period is still pending legal review
--      (LEGAL_REVIEW_PENDING) or when nothing is past its period. Whole businesses are not purged here
--      (sql/zella_business_purge.sql);
--   3. approve: two different people, one of them a Zella Voice owner, the other an owner or holds security.manage
--      (the person who asked may be one of them);
--   4. execute: only one of the two approvers, only while retention_purge_enabled is true (PURGE_SWITCHED_OFF), only
--      while the kind is still legally approved, and only with the typed confirmation "PURGE <number of rows>". Rows
--      that are no longer past their period, or whose business went on a legal hold, are left alone. Recordings and
--      message words are removed from their row (the row stays); a transcript is replaced by 'Removed under the
--      retention policy.' (emptying it would make zella_call_integrity re-mark a short old call as missed and start a
--      callback); old audit rows are deleted;
--      document rows are kept (the verification outcome) and their files are handed to the server to remove from
--      storage, then recorded in retention_removed_files (files_done);
--   5. every step is audited in the same transaction, with counts and never content.
-- Nothing is scheduled, here or anywhere: a run happens only when two people approve it and one of them runs it.
-- Every function here is new. If one already exists it must be exactly this file's version (VERSION_MISMATCH otherwise).
-- Needs sql/zella_data_retention.sql. Rollback: sql/rollback/zella_retention_purge_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_retention_run_request(uuid,text,text)": "5b7a202c8301b7bc61b91027a0a4df21",
    "public.zella_retention_run_approve(uuid,uuid,text)": "eb2ce3685d80968db535e35930b93a93",
    "public.zella_retention_run_execute(uuid,uuid,text)": "ba48c56b8077b51afb6e7b17f6150fd4",
    "public.zella_retention_run_files_done(uuid,uuid,text[],text)": "dac2d38238f1817aa8500a152382e6b5",
    "public.zella_retention_run_cancel(uuid,uuid,text)": "f7808954fe2da8c900c77f9c1827fb29",
    "public.zella_retention_runs(uuid,integer)": "64a8d562f80cdf654e0cc185804c58ac",
    "public.zella_retention_run_files_resume(uuid,uuid)": "2daf163e4a47b309ad52d92c382ec4ec"
  }';
begin
  if to_regprocedure('public.zella_retention_candidates(text,timestamp with time zone)') is null or to_regclass('public.data_retention_policies') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_data_retention.sql first)';
  end if;
  if (to_regclass('public.retention_purge_runs') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'retention_purge_runs' and column_name = 'second_approved_by'))
     or to_regclass('public.retention_removed_files') is null then
    raise exception 'VERSION_MISMATCH: a different retention_purge_runs table exists, or retention_removed_files is missing';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.retention_purge_runs (
  id uuid primary key default gen_random_uuid(),
  data_class text not null references public.data_retention_policies(data_class),
  business_id uuid,
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'running', 'files_pending', 'done', 'failed', 'cancelled')),
  requested_by uuid not null,
  request_reason text not null check (length(btrim(request_reason)) between 3 and 300),
  cutoff timestamptz not null,
  items jsonb not null default '[]'::jsonb,
  item_count integer not null check (item_count between 0 and 1000),
  export_offered_at timestamptz,
  export_offer_note text check (export_offer_note is null or length(export_offer_note) <= 300),
  owner_approved_by uuid,
  owner_approved_at timestamptz,
  second_approved_by uuid,
  second_approved_at timestamptz,
  executed_by uuid,
  executed_at timestamptz,
  removed_count integer,
  file_paths text[] not null default '{}',
  files_removed integer,
  error text check (error is null or length(error) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (owner_approved_by is null or second_approved_by is null or owner_approved_by <> second_approved_by)
);
-- every listed file the server has confirmed gone (removed now or already absent), so a stopped removal can be finished
alter table public.retention_purge_runs add column if not exists removed_paths text[] not null default '{}';
create unique index if not exists retention_purge_runs_one_open on public.retention_purge_runs (data_class, coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('requested', 'approved', 'running', 'files_pending');
alter table public.retention_purge_runs enable row level security;
revoke all on table public.retention_purge_runs from public, anon, authenticated;
grant all on table public.retention_purge_runs to service_role;

create or replace function public.zella_retention_run_request(p_actor uuid, p_class text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.data_retention_policies; r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
        v_cutoff timestamptz; v_items jsonb;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into p from public.data_retention_policies where data_class = p_class;
  if p.data_class is null then raise exception 'UNKNOWN_CLASS'; end if;
  if p.data_class = 'cancelled_business' then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  if exists (select 1 from public.retention_purge_runs where data_class = p_class and business_id is null and status in ('requested', 'approved', 'running', 'files_pending')) then
    raise exception 'RUN_OPEN';
  end if;
  v_cutoff := now() - make_interval(days => p.days);
  select coalesce(jsonb_agg(jsonb_build_object('source', source, 'id', row_id) order by dated, row_id), '[]'::jsonb) into v_items
    from (select * from public.zella_retention_candidates(p_class, v_cutoff) order by dated, row_id limit 1000) c;
  if jsonb_array_length(v_items) = 0 then raise exception 'NOTHING_TO_PURGE'; end if;
  insert into public.retention_purge_runs (data_class, requested_by, request_reason, cutoff, items, item_count)
  values (p_class, p_actor, v_reason, v_cutoff, v_items, jsonb_array_length(v_items)) returning * into r;
  perform public.zella_actor_audit(p_actor, 'retention.purge_requested', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('data_class', p_class, 'items', r.item_count, 'cutoff', v_cutoff, 'days', p.days, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

-- Two different people: one a Zella Voice owner, the other an owner or someone holding security.manage.
create or replace function public.zella_retention_run_approve(p_actor uuid, p_run uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_slot text;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'requested' then raise exception 'NOT_PENDING'; end if;
  if coalesce(p_actor = any (array_remove(array[r.owner_approved_by, r.second_approved_by], null)), false) then raise exception 'ALREADY_APPROVED'; end if;
  if public.zella_actor_role(p_actor) = 'zella_owner' and r.owner_approved_by is null then
    v_slot := 'owner';
    update public.retention_purge_runs set owner_approved_by = p_actor, owner_approved_at = now(), updated_at = now() where id = r.id returning * into r;
  elsif r.second_approved_by is null then
    v_slot := 'second';
    update public.retention_purge_runs set second_approved_by = p_actor, second_approved_at = now(), updated_at = now() where id = r.id returning * into r;
  else
    raise exception 'OWNER_REQUIRED';
  end if;
  if r.owner_approved_by is not null and r.second_approved_by is not null then
    update public.retention_purge_runs set status = 'approved', updated_at = now() where id = r.id returning * into r;
  end if;
  perform public.zella_actor_audit(p_actor, 'retention.purge_approved', 'retention_purge_run', r.id, r.business_id, null,
    jsonb_build_object('as', v_slot, 'status', r.status, 'data_class', r.data_class, 'items', r.item_count, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

-- The purge itself. Every guard is checked here, whoever calls it.
create or replace function public.zella_retention_run_execute(p_actor uuid, p_run uuid, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; p public.data_retention_policies; v_now jsonb; v_n int := 0; v_k int; v_paths text[] := '{}';
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.owner_approved_by, r.second_approved_by], null)), false) then raise exception 'APPROVER_REQUIRED'; end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    raise exception 'PURGE_SWITCHED_OFF';
  end if;
  if r.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  if r.data_class = 'cancelled_business' or r.business_id is not null then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  select * into p from public.data_retention_policies where data_class = r.data_class;
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  if coalesce(btrim(p_confirm), '') <> 'PURGE ' || r.item_count then raise exception 'CONFIRM_MISMATCH'; end if;
  update public.retention_purge_runs set status = 'running', executed_by = p_actor, executed_at = now(), updated_at = now() where id = r.id;
  -- legal holds are placed and released under the same lock, so a hold can't land between this read and the removal
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));

  -- only the rows listed when the run was asked for that are still past their period (the earlier of the approved
  -- cutoff and the cutoff of the period as it is now, so a longer period never removes a row it now keeps) and not on
  -- hold
  select coalesce(jsonb_agg(jsonb_build_object('source', c.source, 'id', c.row_id)), '[]'::jsonb) into v_now
    from public.zella_retention_candidates(r.data_class, least(r.cutoff, now() - make_interval(days => p.days))) c
   where exists (select 1 from jsonb_array_elements(r.items) i where i ->> 'source' = c.source and (i ->> 'id')::uuid = c.row_id);

  if r.data_class = 'call_recordings' then
    update public.calls set recording_url = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'calls'); get diagnostics v_n = row_count;
  elsif r.data_class = 'call_transcripts' then
    update public.calls set transcript = 'Removed under the retention policy.' where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'calls'); get diagnostics v_n = row_count;
  elsif r.data_class = 'message_bodies' then
    update public.sms_messages set message_body = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'sms_messages'); get diagnostics v_k = row_count; v_n := v_k;
    update public.email_messages set body_text = null, body_html = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'email_messages'); get diagnostics v_k = row_count; v_n := v_n + v_k;
    update public.conversation_messages set content = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'conversation_messages'); get diagnostics v_k = row_count; v_n := v_n + v_k;
  elsif r.data_class = 'audit_logs' then
    delete from public.audit_logs where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'audit_logs'); get diagnostics v_n = row_count;
  elsif r.data_class like 'documents_%' then
    select coalesce(array_agg(d.file_path order by d.file_path), '{}') into v_paths from public.business_verification_documents d
     where d.id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'business_verification_documents')
       and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id);
    v_n := coalesce(array_length(v_paths, 1), 0);
  end if;

  update public.retention_purge_runs set status = case when r.data_class like 'documents_%' and v_n > 0 then 'files_pending' else 'done' end,
         removed_count = case when r.data_class like 'documents_%' then 0 else v_n end, file_paths = v_paths, updated_at = now()
   where id = r.id returning * into r;
  perform public.zella_actor_audit(p_actor, 'retention.purge_executed', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('data_class', r.data_class, 'listed', r.item_count, 'removed', r.removed_count, 'files_to_remove', coalesce(array_length(v_paths, 1), 0),
                       'skipped', r.item_count - v_n));
  return to_jsonb(r) - 'items';
end $$;

-- The server removed the document files from storage: record which, so the dry run doesn't list them again.
create or replace function public.zella_retention_run_files_done(p_actor uuid, p_run uuid, p_removed text[], p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_new int; v_total int; v_listed int;
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.data_class = 'cancelled_business' or r.business_id is not null then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  -- only the attempt in progress reports (execute, or files_resume after a stop); a late report once the run was
  -- recorded as failed changes nothing
  if r.status <> 'files_pending' or r.executed_at is null then raise exception 'NOT_RUNNING'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.executed_by, r.owner_approved_by, r.second_approved_by], null)), false) then
    raise exception 'APPROVER_REQUIRED';
  end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  insert into public.retention_removed_files (document_id, file_path, run_id)
  select d.id, d.file_path, r.id from public.business_verification_documents d
   where d.file_path = any (r.file_paths) and d.file_path = any (coalesce(p_removed, '{}'))
  on conflict (document_id) do nothing;
  get diagnostics v_new = row_count;
  v_listed := coalesce(array_length(r.file_paths, 1), 0);
  update public.retention_purge_runs
     set removed_paths = (select coalesce(array_agg(distinct x order by x), '{}') from unnest(removed_paths || array(
                            select f from unnest(r.file_paths) f where f = any (coalesce(p_removed, '{}')))) x),
         updated_at = now()
   where id = r.id returning * into r;
  v_total := coalesce(array_length(r.removed_paths, 1), 0);
  update public.retention_purge_runs set status = case when p_error is null and v_total = v_listed then 'done' else 'failed' end,
         files_removed = v_total, removed_count = v_total, error = left(p_error, 500), updated_at = now()
   where id = r.id returning * into r;
  perform public.zella_actor_audit(p_actor, 'retention.purge_files_removed', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('data_class', r.data_class, 'files_removed_now', v_new, 'files_removed', v_total, 'files_listed', v_listed, 'error', r.error));
  return to_jsonb(r) - 'items';
end $$;

-- resume a stopped file removal. One attempt at a time: refused (REMOVAL_IN_PROGRESS) while the run is files_pending
-- and was last changed less than 10 minutes ago, longer than any request to the server can run, so an earlier attempt
-- has ended before another starts. The same rules as execute apply again now: the purge switch on, the period still
-- legally approved, and only files of documents still past their period (the earlier of the approved cutoff and the
-- current period) and not on a legal hold. The run goes back to files_pending, so no hold can be placed for a business
-- whose files it lists until the attempt reports through files_done.
create or replace function public.zella_retention_run_files_resume(p_actor uuid, p_run uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; p public.data_retention_policies;
begin
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.data_class = 'cancelled_business' or r.business_id is not null then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  if r.status not in ('files_pending', 'failed') or r.executed_at is null then raise exception 'NOT_RUNNING'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.executed_by, r.owner_approved_by, r.second_approved_by], null)), false) then
    raise exception 'APPROVER_REQUIRED';
  end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if r.status = 'files_pending' and r.updated_at > now() - interval '10 minutes' then raise exception 'REMOVAL_IN_PROGRESS'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    raise exception 'PURGE_SWITCHED_OFF';
  end if;
  select * into p from public.data_retention_policies where data_class = r.data_class;
  if p.legal_status is distinct from 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  update public.retention_purge_runs set status = 'files_pending', updated_at = now() where id = r.id;
  return array(select d.file_path from public.business_verification_documents d
                where d.file_path = any (r.file_paths) and not (d.file_path = any (r.removed_paths))
                  and d.id in (select c.row_id from public.zella_retention_candidates(r.data_class, least(r.cutoff, now() - make_interval(days => p.days))) c
                                where c.source = 'business_verification_documents')
                order by d.file_path);
end $$;

create or replace function public.zella_retention_run_cancel(p_actor uuid, p_run uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update public.retention_purge_runs set status = 'cancelled', error = left('Cancelled: ' || v_reason, 500), updated_at = now()
   where id = p_run and status in ('requested', 'approved') returning * into r;
  if r.id is null then raise exception 'NOT_PENDING'; end if;
  perform public.zella_actor_audit(p_actor, 'retention.purge_cancelled', 'retention_purge_run', r.id, r.business_id, null,
    jsonb_build_object('data_class', r.data_class, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

create or replace function public.zella_retention_runs(p_actor uuid, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_actor_can(p_actor, 'security.view') then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) - 'items' - 'file_paths' || jsonb_build_object(
      'requested_by_email', (select email from auth.users where id = r.requested_by),
      'owner_approved_by_email', (select email from auth.users where id = r.owner_approved_by),
      'second_approved_by_email', (select email from auth.users where id = r.second_approved_by),
      'business_name', (select name from public.businesses where id = r.business_id),
      'files_left', (select count(*) from unnest(r.file_paths) f where not (f = any (r.removed_paths)))) order by r.created_at desc)
    from (select * from public.retention_purge_runs order by created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) r), '[]'::jsonb);
end $$;

revoke all on function public.zella_retention_run_request(uuid, text, text), public.zella_retention_run_approve(uuid, uuid, text),
  public.zella_retention_run_execute(uuid, uuid, text), public.zella_retention_run_files_done(uuid, uuid, text[], text),
  public.zella_retention_run_cancel(uuid, uuid, text), public.zella_retention_runs(uuid, integer),
  public.zella_retention_run_files_resume(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_retention_run_request(uuid, text, text), public.zella_retention_run_approve(uuid, uuid, text),
  public.zella_retention_run_execute(uuid, uuid, text), public.zella_retention_run_files_done(uuid, uuid, text[], text),
  public.zella_retention_run_cancel(uuid, uuid, text), public.zella_retention_runs(uuid, integer),
  public.zella_retention_run_files_resume(uuid, uuid) to service_role;

commit;


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '04', 'zella_retention_purge' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_retention_purge');

-- ===== zella_business_purge =====
-- Zella Voice: an owner approved purge of a cancelled business past its retention date, the whole business at once
-- (docs/ADMIN_AUDIT_2026-11-16.md BIZ-13d; ARCHITECTURE.md REQ-LC-20, REQ-PRV-01). Cancelled businesses were kept
-- forever: nothing could delete one, and deleting one by hand would also have erased its audit history.
-- The same purge runs as sql/zella_retention_purge.sql (two different people, one a Zella Voice owner, approve with
-- zella_retention_run_approve), with these steps of its own:
--   1. zella_business_purge_request(admin, business, export offered at, how it was offered, reason): security.manage.
--      Only a business the dry run lists (cancelled, at least the "cancelled_business" period ago, past its
--      retention_until, not on a legal hold), only while that period is legally approved, and only with the final
--      export offer recorded (when and how the owner was offered their data). The whole business export job isn't
--      built yet (lane B, B8 and B9): until it is, the admin records the offer they made.
--   2. zella_business_purge_execute(admin, run, typed name): only one of the two approvers; only while
--      retention_purge_enabled is on, the period is still approved, the business is still listed (cancelled, past
--      retention, no hold) and at least 14 days have passed since the export offer; only with the business's name
--      typed exactly. Refused while:
--        * deleting would erase its audit history: audit_logs.business_id must not be ON DELETE CASCADE and
--          zella_audit_privileged must keep a deleted business's rows. Lane B's sql/zella_draft_delete.sql does both
--          (ACC-10, the owner's decision of 16 Nov 2026: audit history kept, business_id set null), so this refuses
--          until that file is applied (AUDIT_HISTORY_AT_RISK);
--        * it has payment or billing records (BILLING_RECORDS_KEPT): how long those are kept after a business is
--          deleted is a legal decision not taken yet;
--        * it has offer history (OFFER_HISTORY_KEPT) or phone numbers still in Zella Voice (NUMBERS_STILL_ASSIGNED:
--          release them first, which is also where the Telnyx and Vapi copies are dealt with).
--      Then, in one transaction: the purge is audited (name, dates, counts; never content), released legal holds of
--      the business are removed, and the business row is deleted, which removes everything that belongs to it. Its
--      storage files (verification documents, record files, brand images under the business's folder) are handed to
--      the server to remove, then recorded (zella_business_purge_files_done).
-- Nothing is scheduled. Every function here is new; if one already exists it must be exactly this file's version.
-- Needs sql/zella_retention_purge.sql. Rollback: sql/rollback/zella_business_purge_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_business_purge_request(uuid,uuid,timestamp with time zone,text,text)": "605fbfcb53d71fe8f9bdd0aa8df8d58a",
    "public.zella_business_purge_execute(uuid,uuid,text)": "e224a1fefa197dc7c3b2e7290cc7fb95",
    "public.zella_business_purge_files_done(uuid,uuid,text[],text)": "6dc51e59e4b148263f4eafbb79ea3fcc",
    "public.zella_business_purge_files_resume(uuid,uuid)": "3f56a42ffd4e8990c03610637f9150bc"
  }';
begin
  if to_regprocedure('public.zella_retention_run_approve(uuid,uuid,text)') is null or to_regclass('public.retention_purge_runs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_retention_purge.sql first)';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create or replace function public.zella_business_purge_request(p_actor uuid, p_business uuid, p_offered_at timestamptz, p_offer_note text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.data_retention_policies; r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
        v_note text := left(btrim(coalesce(p_offer_note, '')), 300); v_cutoff timestamptz; v_name text;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into p from public.data_retention_policies where data_class = 'cancelled_business';
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  if p_offered_at is null or p_offered_at > now() or length(v_note) < 3 then raise exception 'EXPORT_OFFER_REQUIRED'; end if;
  select name into v_name from public.businesses where id = p_business;
  if v_name is null then raise exception 'BUSINESS_NOT_FOUND'; end if;
  v_cutoff := now() - make_interval(days => p.days);
  if not exists (select 1 from public.zella_retention_candidates('cancelled_business', v_cutoff) where row_id = p_business) then
    raise exception 'NOT_PAST_RETENTION';
  end if;
  if exists (select 1 from public.retention_purge_runs where business_id = p_business and status in ('requested', 'approved', 'running', 'files_pending')) then
    raise exception 'RUN_OPEN';
  end if;
  insert into public.retention_purge_runs (data_class, business_id, requested_by, request_reason, cutoff, items, item_count, export_offered_at, export_offer_note)
  values ('cancelled_business', p_business, p_actor, v_reason, v_cutoff, jsonb_build_array(jsonb_build_object('source', 'businesses', 'id', p_business)), 1, p_offered_at, v_note)
  returning * into r;
  perform public.zella_actor_audit(p_actor, 'business.purge_requested', 'retention_purge_run', r.id, p_business, null,
    jsonb_build_object('business', v_name, 'export_offered_at', p_offered_at, 'export_offer', v_note, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

create or replace function public.zella_business_purge_execute(p_actor uuid, p_run uuid, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; p public.data_retention_policies; b public.businesses; v_paths text[]; v_audit int; v_released int;
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null or r.data_class <> 'cancelled_business' or r.business_id is null then raise exception 'NOT_FOUND'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.owner_approved_by, r.second_approved_by], null)), false) then raise exception 'APPROVER_REQUIRED'; end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then raise exception 'PURGE_SWITCHED_OFF'; end if;
  if r.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  select * into p from public.data_retention_policies where data_class = 'cancelled_business';
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  select * into b from public.businesses where id = r.business_id for update;
  if b.id is null then raise exception 'BUSINESS_NOT_FOUND'; end if;
  if coalesce(p_confirm_name, '') <> b.name then raise exception 'CONFIRM_MISMATCH'; end if;
  if not exists (select 1 from public.zella_retention_candidates('cancelled_business', now() - make_interval(days => p.days)) where row_id = b.id) then
    raise exception 'NOT_PAST_RETENTION';
  end if;
  if r.export_offered_at is null or r.export_offered_at > now() - interval '14 days' then raise exception 'EXPORT_OFFER_TOO_RECENT'; end if;
  if (select confdeltype from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey') is distinct from 'n'
     or position('deleted_business_id' in pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) = 0 then
    raise exception 'AUDIT_HISTORY_AT_RISK: needs sql/zella_draft_delete.sql and audit_logs.business_id not CASCADE (ACC-10)';
  end if;
  if exists (select 1 from public.payments where business_id = b.id) or exists (select 1 from public.billing_events where business_id = b.id)
     or exists (select 1 from public.customer_charge_payments where business_id = b.id) or exists (select 1 from public.usage_charges where business_id = b.id)
     or (to_regclass('public.billing_periods') is not null and exists (select 1 from public.billing_periods where business_id = b.id)) then
    raise exception 'BILLING_RECORDS_KEPT';
  end if;
  if exists (select 1 from public.offer_redemptions where business_id = b.id) then raise exception 'OFFER_HISTORY_KEPT'; end if;
  if exists (select 1 from public.business_phone_numbers where business_id = b.id) then raise exception 'NUMBERS_STILL_ASSIGNED'; end if;

  update public.retention_purge_runs set status = 'running', executed_by = p_actor, executed_at = now(), updated_at = now() where id = r.id;
  select coalesce(array_agg(distinct x order by x), '{}') into v_paths from (
    select 'business-documents/' || file_path as x from public.business_verification_documents where business_id = b.id
    union select 'record-files/' || path from public.crm_record_files where business_id = b.id
    union select o.bucket_id || '/' || o.name from storage.objects o
     where o.bucket_id in ('business-documents', 'record-files', 'brand-assets') and o.name like b.id::text || '/%') s;
  select count(*) into v_audit from public.audit_logs where business_id = b.id;
  perform public.zella_actor_audit(p_actor, 'business.purged', 'business', b.id, null,
    jsonb_build_object('name', b.name, 'industry_id', b.industry_id, 'created_at', b.created_at, 'cancelled_at', b.cancelled_at, 'retention_until', b.retention_until),
    jsonb_build_object('run', r.id, 'export_offered_at', r.export_offered_at, 'export_offer', r.export_offer_note, 'audit_rows_kept', v_audit,
                       'files_to_remove', coalesce(array_length(v_paths, 1), 0)));
  delete from public.legal_holds where business_id = b.id and released_at is not null;
  get diagnostics v_released = row_count;
  delete from public.businesses where id = b.id;
  update public.retention_purge_runs set status = case when coalesce(array_length(v_paths, 1), 0) > 0 then 'files_pending' else 'done' end,
         removed_count = 1, file_paths = v_paths, updated_at = now() where id = r.id returning * into r;
  return to_jsonb(r) - 'items';
end $$;

create or replace function public.zella_business_purge_files_done(p_actor uuid, p_run uuid, p_removed text[], p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_total int; v_listed int;
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null or r.data_class <> 'cancelled_business' then raise exception 'NOT_FOUND'; end if;
  -- only the attempt in progress reports (execute, or files_resume after a stop); a late report once the run was
  -- recorded as failed changes nothing
  if r.status <> 'files_pending' or r.executed_at is null then raise exception 'NOT_RUNNING'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.executed_by, r.owner_approved_by, r.second_approved_by], null)), false) then
    raise exception 'APPROVER_REQUIRED';
  end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  update public.retention_purge_runs
     set removed_paths = (select coalesce(array_agg(distinct x order by x), '{}') from unnest(removed_paths || array(
                            select f from unnest(r.file_paths) f where f = any (coalesce(p_removed, '{}')))) x),
         updated_at = now()
   where id = r.id returning * into r;
  v_total := coalesce(array_length(r.removed_paths, 1), 0);
  v_listed := coalesce(array_length(r.file_paths, 1), 0);
  update public.retention_purge_runs set status = case when p_error is null and v_total = v_listed then 'done' else 'failed' end,
         files_removed = v_total, error = left(p_error, 500), updated_at = now() where id = r.id returning * into r;
  perform public.zella_actor_audit(p_actor, 'business.purge_files_removed', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('business_id', r.business_id, 'files_removed', v_total, 'files_listed', v_listed, 'error', r.error));
  return to_jsonb(r) - 'items';
end $$;

-- resume a stopped file removal of a purged business. One attempt at a time, as for other purge runs
-- (REMOVAL_IN_PROGRESS while the run was changed less than 10 minutes ago). The purge switch must be on and the
-- cancelled_business period still legally approved. The business and every row it had are already deleted, so its
-- listed files are no longer covered by any period or hold: the files still listed are returned.
create or replace function public.zella_business_purge_files_resume(p_actor uuid, p_run uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs;
begin
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null or r.data_class <> 'cancelled_business' then raise exception 'NOT_FOUND'; end if;
  if r.status not in ('files_pending', 'failed') or r.executed_at is null then raise exception 'NOT_RUNNING'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.executed_by, r.owner_approved_by, r.second_approved_by], null)), false) then
    raise exception 'APPROVER_REQUIRED';
  end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if r.status = 'files_pending' and r.updated_at > now() - interval '10 minutes' then raise exception 'REMOVAL_IN_PROGRESS'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    raise exception 'PURGE_SWITCHED_OFF';
  end if;
  if (select legal_status from public.data_retention_policies where data_class = 'cancelled_business') is distinct from 'approved' then
    raise exception 'LEGAL_REVIEW_PENDING';
  end if;
  update public.retention_purge_runs set status = 'files_pending', updated_at = now() where id = r.id;
  return array(select f from unnest(r.file_paths) f where not (f = any (r.removed_paths)) order by f);
end $$;

revoke all on function public.zella_business_purge_request(uuid, uuid, timestamptz, text, text), public.zella_business_purge_execute(uuid, uuid, text),
  public.zella_business_purge_files_done(uuid, uuid, text[], text), public.zella_business_purge_files_resume(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_business_purge_request(uuid, uuid, timestamptz, text, text), public.zella_business_purge_execute(uuid, uuid, text),
  public.zella_business_purge_files_done(uuid, uuid, text[], text), public.zella_business_purge_files_resume(uuid, uuid) to service_role;

commit;


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '05', 'zella_business_purge' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_business_purge');
