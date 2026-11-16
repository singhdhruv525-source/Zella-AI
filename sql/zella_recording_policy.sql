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
    "public.zella_recording_policy_set(uuid,uuid,boolean,text)": "3cb4ba4d22b5fd87b6f02bc49df41266",
    "public.zella_recording_legal_set(uuid,boolean,text,text)": "25ddee21113eae69b5ae3b12c8598b0a"
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
