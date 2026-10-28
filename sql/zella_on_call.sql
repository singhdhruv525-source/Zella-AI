-- Zella - on-call rota for after-hours and emergency transfers (2026-10-28). Safe to re-run.
-- Needs sql/zella_voice_rules.sql and sql/zella_voice_reliability.sql (zella_ai_voice, zella_transfer_destination,
-- zella_patch_function).
--
-- A business lists who is on call: a weekly rota (for example "Sam, Mon-Fri 18:00-08:00") and one-off cover
-- ("Alex, 24-26 Dec"). Cover beats the weekly rota. While the business is closed, the phone assistant transfers to
-- whoever is on call instead of the normal transfer number:
--   scope 'after_hours'      - any transfer request after hours goes to the on-call person
--   scope 'emergencies_only' - only emergencies go to them; other after-hours callers get the usual message/callback
-- During opening hours nothing changes. With nobody on call, nothing changes either. The number is resolved on the
-- server (zella_transfer_destination); the AI never sees it. Transfers still need transfer_enabled in the
-- receptionist settings.
-- Rollback: drop table public.on_call_shifts, public.on_call_settings; drop the zella_on_call_* functions; re-run
--   sql/zella_voice_reliability.sql's zella_transfer_destination and remove the "zella_on_call" block from
--   zella_ai_voice (re-run sql/zella_voice_rules.sql then sql/zella_voice_reliability.sql).

create table if not exists public.on_call_settings (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  enabled boolean not null default false,
  scope text not null default 'after_hours' check (scope in ('after_hours', 'emergencies_only')),
  updated_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.on_call_shifts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  staff_id uuid not null references public.staff_members (id) on delete cascade,
  kind text not null check (kind in ('weekly', 'cover')),
  -- weekly: weekday 0 = Sunday .. 6 = Saturday, in the business's time zone; ends <= starts means it runs past midnight
  weekday smallint check (weekday between 0 and 6),
  starts time,
  ends time,
  -- cover: an exact period
  starts_at timestamptz,
  ends_at timestamptz,
  note text check (note is null or length(note) <= 200),
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint on_call_shifts_shape check (
    (kind = 'weekly' and weekday is not null and starts is not null and ends is not null and starts <> ends and starts_at is null and ends_at is null)
    or (kind = 'cover' and starts_at is not null and ends_at is not null and ends_at > starts_at and ends_at <= starts_at + interval '31 days'
        and weekday is null and starts is null and ends is null))
);
create index if not exists on_call_shifts_business_idx on public.on_call_shifts (business_id, kind);

alter table public.on_call_settings enable row level security;
alter table public.on_call_shifts enable row level security;
drop policy if exists on_call_settings_read on public.on_call_settings;
create policy on_call_settings_read on public.on_call_settings for select to authenticated using (public.zella_is_member(business_id));
drop policy if exists on_call_shifts_read on public.on_call_shifts;
create policy on_call_shifts_read on public.on_call_shifts for select to authenticated using (public.zella_is_member(business_id));
revoke insert, update, delete on public.on_call_settings, public.on_call_shifts from anon, authenticated;

-- Who is on call at a moment: cover first (the most recently added wins), then the weekly rota (the shift that
-- started most recently wins). Only active staff with a valid phone number count. Returns {} when nobody is.
create or replace function public.zella_on_call_now(p_business_id uuid, p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_local timestamp; v_dow smallint; v_t time; r record; v_scope text; v_on boolean;
begin
  select s.enabled, s.scope into v_on, v_scope from public.on_call_settings s where s.business_id = p_business_id;
  if not coalesce(v_on, false) then return '{}'::jsonb; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  if v_tz is null then return '{}'::jsonb; end if;
  v_local := p_at at time zone v_tz; v_dow := extract(dow from v_local)::smallint; v_t := v_local::time;

  select sh.id, sm.id as staff_id, sm.name, public.zella_normalize_e164(sm.phone) as phone, 'cover' as via into r
    from public.on_call_shifts sh join public.staff_members sm on sm.id = sh.staff_id and sm.business_id = sh.business_id
   where sh.business_id = p_business_id and sh.kind = 'cover' and p_at >= sh.starts_at and p_at < sh.ends_at
     and sm.is_active and public.zella_normalize_e164(sm.phone) is not null
   order by sh.created_at desc limit 1;
  if r.staff_id is null then
    -- a weekly shift covers today's part (from its start, or all of it past midnight) or, if it runs past midnight,
    -- the early part of the next day
    select sh.id, sm.id as staff_id, sm.name, public.zella_normalize_e164(sm.phone) as phone, 'weekly' as via into r
      from public.on_call_shifts sh join public.staff_members sm on sm.id = sh.staff_id and sm.business_id = sh.business_id
     where sh.business_id = p_business_id and sh.kind = 'weekly' and sm.is_active and public.zella_normalize_e164(sm.phone) is not null
       and ((sh.weekday = v_dow and ((sh.ends > sh.starts and v_t >= sh.starts and v_t < sh.ends) or (sh.ends < sh.starts and v_t >= sh.starts)))
         or (sh.weekday = (v_dow + 6) % 7 and sh.ends < sh.starts and v_t < sh.ends))
     order by case when sh.weekday = v_dow then 0 else 1 end, sh.starts desc limit 1;
  end if;
  if r.staff_id is null then return '{}'::jsonb; end if;
  return jsonb_build_object('staff_id', r.staff_id, 'name', r.name, 'phone', r.phone, 'via', r.via, 'scope', coalesce(v_scope, 'after_hours'));
end $$;
revoke all on function public.zella_on_call_now(uuid, timestamptz) from public, anon, authenticated;

-- The rota for the Team screen (members). Phone numbers are shown masked; managers see who is on call now.
create or replace function public.zella_on_call_list(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_now jsonb;
begin
  if auth.uid() is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  v_now := public.zella_on_call_now(p_business_id);
  return jsonb_build_object(
    'settings', coalesce((select jsonb_build_object('enabled', s.enabled, 'scope', s.scope, 'updated_at', s.updated_at)
                            from public.on_call_settings s where s.business_id = p_business_id),
                         jsonb_build_object('enabled', false, 'scope', 'after_hours')),
    'can_edit', public.zella_can_manage(p_business_id),
    'now', case when v_now ? 'staff_id' then jsonb_build_object('staff_id', v_now -> 'staff_id', 'name', v_now -> 'name', 'via', v_now -> 'via') end,
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('id', sh.id, 'staff_id', sh.staff_id, 'staff_name', sm.name, 'kind', sh.kind,
                         'weekday', sh.weekday, 'starts', to_char(sh.starts, 'HH24:MI'), 'ends', to_char(sh.ends, 'HH24:MI'),
                         'starts_at', sh.starts_at, 'ends_at', sh.ends_at, 'note', sh.note,
                         'has_phone', public.zella_normalize_e164(sm.phone) is not null, 'staff_active', sm.is_active)
                         order by sh.kind desc, sh.weekday, sh.starts, sh.starts_at)
                        from public.on_call_shifts sh join public.staff_members sm on sm.id = sh.staff_id
                       where sh.business_id = p_business_id and (sh.kind = 'weekly' or sh.ends_at > now() - interval '1 day')), '[]'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', sm.id, 'name', sm.name, 'has_phone', public.zella_normalize_e164(sm.phone) is not null)
                         order by sm.sort_order, sm.name)
                        from public.staff_members sm where sm.business_id = p_business_id and sm.is_active), '[]'::jsonb));
end $$;
revoke all on function public.zella_on_call_list(uuid) from public, anon;
grant execute on function public.zella_on_call_list(uuid) to authenticated;

create or replace function public.zella_on_call_settings_save(p_business_id uuid, p_enabled boolean, p_scope text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if coalesce(p_scope, '') not in ('after_hours', 'emergencies_only') then raise exception 'INVALID_SCOPE'; end if;
  insert into public.on_call_settings (business_id, enabled, scope, updated_by, updated_at)
  values (p_business_id, coalesce(p_enabled, false), p_scope, auth.uid(), now())
  on conflict (business_id) do update set enabled = excluded.enabled, scope = excluded.scope, updated_by = excluded.updated_by, updated_at = now();
  return true;
end $$;
revoke all on function public.zella_on_call_settings_save(uuid, boolean, text) from public, anon;
grant execute on function public.zella_on_call_settings_save(uuid, boolean, text) to authenticated;

-- Add or change one shift. p_shift: {id?, staff_id, kind, weekday, starts, ends, starts_at, ends_at, note}.
create or replace function public.zella_on_call_save(p_business_id uuid, p_shift jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_staff uuid; v_kind text; v_note text; v_count integer;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_shift) <> 'object' then raise exception 'INVALID_SHIFT'; end if;
  v_kind := p_shift ->> 'kind';
  if coalesce(v_kind, '') not in ('weekly', 'cover') then raise exception 'INVALID_KIND'; end if;
  begin v_staff := (p_shift ->> 'staff_id')::uuid; exception when others then raise exception 'INVALID_STAFF'; end;
  if not exists (select 1 from public.staff_members sm where sm.id = v_staff and sm.business_id = p_business_id and sm.is_active) then raise exception 'INVALID_STAFF'; end if;
  if not exists (select 1 from public.staff_members sm where sm.id = v_staff and public.zella_normalize_e164(sm.phone) is not null) then raise exception 'STAFF_NEEDS_PHONE'; end if;
  v_note := nullif(trim(left(coalesce(p_shift ->> 'note', ''), 200)), '');
  if p_shift ? 'id' and nullif(p_shift ->> 'id', '') is not null then
    begin v_id := (p_shift ->> 'id')::uuid; exception when others then raise exception 'NOT_FOUND'; end;
    if not exists (select 1 from public.on_call_shifts where id = v_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  end if;
  select count(*) into v_count from public.on_call_shifts where business_id = p_business_id;
  if v_id is null and v_count >= 200 then raise exception 'TOO_MANY_SHIFTS'; end if;

  begin
    if v_kind = 'weekly' then
      if v_id is null then
        insert into public.on_call_shifts (business_id, staff_id, kind, weekday, starts, ends, note, created_by)
        values (p_business_id, v_staff, 'weekly', (p_shift ->> 'weekday')::smallint, (p_shift ->> 'starts')::time, (p_shift ->> 'ends')::time, v_note, auth.uid())
        returning id into v_id;
      else
        update public.on_call_shifts set staff_id = v_staff, kind = 'weekly', weekday = (p_shift ->> 'weekday')::smallint, starts = (p_shift ->> 'starts')::time,
               ends = (p_shift ->> 'ends')::time, starts_at = null, ends_at = null, note = v_note where id = v_id;
      end if;
    else
      if v_id is null then
        insert into public.on_call_shifts (business_id, staff_id, kind, starts_at, ends_at, note, created_by)
        values (p_business_id, v_staff, 'cover', (p_shift ->> 'starts_at')::timestamptz, (p_shift ->> 'ends_at')::timestamptz, v_note, auth.uid())
        returning id into v_id;
      else
        update public.on_call_shifts set staff_id = v_staff, kind = 'cover', weekday = null, starts = null, ends = null,
               starts_at = (p_shift ->> 'starts_at')::timestamptz, ends_at = (p_shift ->> 'ends_at')::timestamptz, note = v_note where id = v_id;
      end if;
    end if;
  exception
    when check_violation or invalid_datetime_format or datetime_field_overflow or invalid_text_representation or numeric_value_out_of_range then
      raise exception 'INVALID_TIMES';
  end;
  return v_id;
end $$;
revoke all on function public.zella_on_call_save(uuid, jsonb) from public, anon;
grant execute on function public.zella_on_call_save(uuid, jsonb) to authenticated;

create or replace function public.zella_on_call_delete(p_business_id uuid, p_shift_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  delete from public.on_call_shifts where id = p_shift_id and business_id = p_business_id;
  return found;
end $$;
revoke all on function public.zella_on_call_delete(uuid, uuid) from public, anon;
grant execute on function public.zella_on_call_delete(uuid, uuid) to authenticated;

-- The phone assistant's own rules (zella_ai_voice): while closed, the on-call person becomes the transfer number, and
-- with scope 'after_hours' after-hours transfers are allowed. Emergencies already transfer whenever transfers are on.
select public.zella_patch_function('public.zella_ai_voice(text,uuid,text,jsonb)', 'zella_on_call',
  E'  v_is_open := coalesce((v_open ->> ''open'')::boolean, true);\n',
  E'  v_is_open := coalesce((v_open ->> ''open'')::boolean, true);\n'
  || E'  if not v_is_open then -- zella_on_call: whoever is on call takes after-hours transfers\n'
  || E'    declare v_oc jsonb;\n'
  || E'    begin\n'
  || E'      v_oc := public.zella_on_call_now(v_biz);\n'
  || E'      if v_oc ->> ''phone'' is not null then\n'
  || E'        v_number := v_oc ->> ''phone'';\n'
  || E'        if v_oc ->> ''scope'' = ''after_hours'' then v_hours_only := false; end if;\n'
  || E'      end if;\n'
  || E'    exception when others then null;\n'
  || E'    end;\n'
  || E'  end if;\n');

-- The transfer itself (Vapi's transfer-destination-request): the same choice, made on the server.
create or replace function public.zella_transfer_destination(p_provider_call_id text, p_called_number text, p_vapi_phone_number_id text, p_from_number text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.calls; v_biz uuid; v_rules jsonb; v_number text; v_fallback text; v_open jsonb; v_is_open boolean; v_scr jsonb; v_e164 text;
  v_oc jsonb; v_on_call boolean := false;
  v_refuse jsonb := jsonb_build_object('ok', false, 'message', 'I''m sorry, I can''t connect you to someone right now. I can take a message and the team will call you back.');
begin
  if nullif(p_provider_call_id, '') is not null then
    select * into c from public.calls where external_call_id = p_provider_call_id;
  end if;
  v_biz := coalesce(c.business_id, public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null));
  if v_biz is null or not exists (select 1 from public.businesses b where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true)) then
    return v_refuse || jsonb_build_object('reason', 'unknown_business');
  end if;

  -- a caller screened out by spam protection is not put through (zella_caller_context adds screening when that file is applied)
  begin
    v_scr := public.zella_caller_context(v_biz, coalesce(nullif(p_from_number, ''), c.from_number)) -> 'screening';
  exception when others then v_scr := null; end;
  if v_scr ->> 'decision' in ('blocked', 'restricted', 'screened') then return v_refuse || jsonb_build_object('reason', 'screened'); end if;

  select coalesce(cfg.escalation_rules, '{}'::jsonb) into v_rules
    from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id where ag.business_id = v_biz and ag.is_default limit 1;
  v_rules := coalesce(v_rules, '{}'::jsonb);
  if not coalesce((v_rules ->> 'transfer_enabled')::boolean, true) then return v_refuse || jsonb_build_object('reason', 'transfer_off'); end if;
  v_number := coalesce(nullif(v_rules ->> 'transfer_number', ''), nullif(v_rules #>> '{transfer_to,phone}', ''));
  v_fallback := nullif(v_rules ->> 'fallback_number', '');
  if coalesce(v_rules ->> 'transfer_route', '') = 'fallback' and v_fallback is not null then v_number := v_fallback; end if;

  v_open := public.zella_business_open(v_biz);
  v_is_open := coalesce((v_open ->> 'open')::boolean, true);
  -- zella_on_call: closed -> the on-call person, for every transfer (scope after_hours) or for emergencies only
  if not v_is_open then
    begin v_oc := public.zella_on_call_now(v_biz); exception when others then v_oc := '{}'::jsonb; end;
    if v_oc ->> 'phone' is not null and (v_oc ->> 'scope' = 'after_hours' or c.escalation_reason = 'emergency') then
      v_number := v_oc ->> 'phone'; v_on_call := true;
    end if;
  end if;

  v_e164 := public.zella_normalize_e164(v_number);
  if v_e164 is null then return v_refuse || jsonb_build_object('reason', 'no_valid_number'); end if;
  if not v_is_open and not v_on_call and coalesce((v_rules ->> 'transfer_open_hours_only')::boolean, true)
     and coalesce(c.escalation_reason, '') <> 'emergency' then
    return v_refuse || jsonb_build_object('reason', 'closed');
  end if;

  if c.id is not null then
    update public.calls set transfer_status = 'attempted', needs_human = true, escalation_reason = coalesce(escalation_reason, 'asked_for_person'),
           escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = c.id;
  end if;
  return jsonb_build_object('ok', true, 'number', v_e164, 'message', 'Please hold while I connect you.')
         || case when v_on_call then jsonb_build_object('on_call', true) else '{}'::jsonb end;
end $$;
revoke all on function public.zella_transfer_destination(text, text, text, text) from public, anon, authenticated;

create or replace function public.zella_on_call_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tables', to_regclass('public.on_call_shifts') is not null and to_regclass('public.on_call_settings') is not null,
    'ai_voice', pg_get_functiondef('public.zella_ai_voice(text,uuid,text,jsonb)'::regprocedure) like '%zella_on_call%',
    'transfer_destination', pg_get_functiondef('public.zella_transfer_destination(text,text,text,text)'::regprocedure) like '%zella_on_call%');
$$;
revoke all on function public.zella_on_call_status() from public, anon, authenticated;
grant execute on function public.zella_on_call_status() to service_role;
