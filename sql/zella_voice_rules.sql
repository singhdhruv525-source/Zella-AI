-- Zella - phone rules: business hours, holidays, taking messages, emergencies, and passing a caller to a person.
-- Safe to run more than once. Needs zella_run_all.sql (calls, callbacks, ai_agent_configs) and zella_ai_booking.sql.
-- The phone assistant (Vapi) calls ONE tool, "call_rules", during a call. Everything is decided here:
--   * rules   : is the business open now? is it a holiday? what should the assistant say / offer?
--   * message : take a message (voicemail-style). Saved, linked to the caller, a callback is created for staff.
--   * emergency: flag the call for a person at once, tell the owners (urgent), create an urgent callback.
--   * transfer: is a person reachable right now? If yes the number is handed back, otherwise a callback is created.
-- Transfer / emergency / after-hours choices are kept in the agent's escalation_rules (already versioned and published
-- with the agent): transfer_number, fallback_number, transfer_enabled, transfer_open_hours_only, emergency_enabled,
-- emergency_keywords, after_hours_mode ('take_message' | 'book_only' | 'info_only').

-- 1. Weekly opening hours (several rows per day = split shifts; no rows at all = hours not set, never "closed")
create table if not exists public.business_hours (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),   -- 0 = Sunday
  opens time not null,
  closes time not null,
  created_at timestamptz not null default now(),
  check (closes > opens)
);
create index if not exists business_hours_biz_idx on public.business_hours (business_id, weekday);
alter table public.business_hours enable row level security;
drop policy if exists business_hours_read on public.business_hours;
create policy business_hours_read on public.business_hours for select to authenticated using (public.zella_is_member(business_id));

-- 2. Holidays and one-off closures (opens/closes empty = closed all day; filled = special hours that day)
create table if not exists public.business_closures (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  starts_on date not null,
  ends_on date not null,
  label text not null default 'Closed',
  opens time,
  closes time,
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  check ((opens is null) = (closes is null))
);
create index if not exists business_closures_biz_idx on public.business_closures (business_id, starts_on, ends_on);
alter table public.business_closures enable row level security;
drop policy if exists business_closures_read on public.business_closures;
create policy business_closures_read on public.business_closures for select to authenticated using (public.zella_is_member(business_id));

-- 3. Messages taken by the assistant (voicemail and message taking)
create table if not exists public.call_messages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  call_id uuid references public.calls(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  kind text not null default 'message' check (kind in ('message', 'voicemail', 'emergency')),
  caller_name text,
  caller_phone text,
  message text not null,
  after_hours boolean not null default false,
  status text not null default 'new' check (status in ('new', 'read', 'handled')),
  handled_by uuid,
  handled_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists call_messages_biz_idx on public.call_messages (business_id, status, created_at desc);
alter table public.call_messages enable row level security;
drop policy if exists call_messages_read on public.call_messages;
create policy call_messages_read on public.call_messages for select to authenticated using (public.zella_is_member(business_id));

create or replace function public.zella_update_call_message(p_message_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_biz uuid;
begin
  if p_status not in ('read', 'handled') then raise exception 'BAD_STATUS'; end if;
  select business_id into v_biz from public.call_messages where id = p_message_id;
  if v_biz is null or not public.zella_has_role(v_biz, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  update public.call_messages set status = p_status, handled_by = case when p_status = 'handled' then auth.uid() else handled_by end,
         handled_at = case when p_status = 'handled' then now() else handled_at end where id = p_message_id;
end $$;
revoke execute on function public.zella_update_call_message(uuid, text) from public, anon;
grant execute on function public.zella_update_call_message(uuid, text) to authenticated, service_role;

-- 4. Is the business open?  -> { open, reason: open | closed_hours | holiday | no_hours_set, label, next_open }
create or replace function public.zella_business_open(p_business_id uuid, p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_local timestamp; v_day date; v_dow smallint; v_t time;
  v_clo record; v_open boolean; v_next timestamptz; d integer; v_first time;
begin
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = p_business_id;
  if v_tz is null then return jsonb_build_object('open', true, 'reason', 'no_hours_set'); end if;
  v_local := p_at at time zone v_tz; v_day := v_local::date; v_dow := extract(dow from v_local)::smallint; v_t := v_local::time;

  select * into v_clo from public.business_closures c
   where c.business_id = p_business_id and v_day between c.starts_on and c.ends_on order by (c.opens is null) desc limit 1;
  if found then
    v_open := v_clo.opens is not null and v_t >= v_clo.opens and v_t < v_clo.closes;
    if v_open then return jsonb_build_object('open', true, 'reason', 'open', 'label', v_clo.label); end if;
    -- closed for the holiday: find the next open moment below
    v_next := null;
    for d in 1..60 loop
      if exists (select 1 from public.business_closures c where c.business_id = p_business_id and (v_day + d) between c.starts_on and c.ends_on and c.opens is null) then continue; end if;
      select min(h.opens) into v_first from public.business_hours h where h.business_id = p_business_id and h.weekday = extract(dow from (v_day + d))::smallint;
      if v_first is not null then v_next := ((v_day + d) + v_first) at time zone v_tz; exit; end if;
    end loop;
    return jsonb_build_object('open', false, 'reason', 'holiday', 'label', v_clo.label, 'next_open', v_next);
  end if;

  if not exists (select 1 from public.business_hours h where h.business_id = p_business_id) then
    return jsonb_build_object('open', true, 'reason', 'no_hours_set');
  end if;

  if exists (select 1 from public.business_hours h where h.business_id = p_business_id and h.weekday = v_dow and v_t >= h.opens and v_t < h.closes) then
    return jsonb_build_object('open', true, 'reason', 'open');
  end if;

  -- next opening: later today, otherwise the next days
  select min(h.opens) into v_first from public.business_hours h where h.business_id = p_business_id and h.weekday = v_dow and h.opens > v_t;
  if v_first is not null then
    v_next := (v_day + v_first) at time zone v_tz;
  else
    for d in 1..60 loop
      if exists (select 1 from public.business_closures c where c.business_id = p_business_id and (v_day + d) between c.starts_on and c.ends_on and c.opens is null) then continue; end if;
      select min(h.opens) into v_first from public.business_hours h where h.business_id = p_business_id and h.weekday = extract(dow from (v_day + d))::smallint;
      if v_first is not null then v_next := ((v_day + d) + v_first) at time zone v_tz; exit; end if;
    end loop;
  end if;
  return jsonb_build_object('open', false, 'reason', 'closed_hours', 'next_open', v_next);
end $$;
revoke execute on function public.zella_business_open(uuid, timestamptz) from public, anon;
grant execute on function public.zella_business_open(uuid, timestamptz) to authenticated, service_role;

-- 5. The one tool the assistant uses on a call.
create or replace function public.zella_ai_voice(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_args jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_call public.calls%rowtype; v_biz uuid; v_tz text; v_name text;
  v_rules jsonb; v_open jsonb; v_is_open boolean; v_mode text;
  v_transfer_on boolean; v_hours_only boolean; v_number text; v_fallback text;
  v_em_on boolean; v_keywords text[];
  v_msg text; v_cname text; v_cphone text; v_cust uuid; v_mid uuid; v_why text; v_next text;
begin
  if nullif(p_provider_call_id, '') is not null then
    select * into v_call from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call.business_id, p_business_id);
  select b.id, coalesce(b.timezone, 'America/New_York'), b.name into v_biz, v_tz, v_name from public.businesses b
   where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true);
  if v_biz is null then raise exception 'UNKNOWN_BUSINESS'; end if;

  -- the call row: created the first time the assistant speaks to us if nothing has made it yet
  if v_call.id is null and nullif(p_provider_call_id, '') is not null then
    insert into public.calls (business_id, direction, status, from_number, external_call_id, started_at, ai_handled)
    values (v_biz, 'inbound', 'answered', nullif(left(coalesce(v_args ->> 'caller_number', ''), 30), ''), p_provider_call_id, now(), true);
    select * into v_call from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;

  select coalesce(cfg.escalation_rules, '{}'::jsonb) into v_rules
    from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id
   where ag.business_id = v_biz and ag.is_default limit 1;
  v_rules := coalesce(v_rules, '{}'::jsonb);
  v_mode := coalesce(nullif(v_rules ->> 'after_hours_mode', ''), 'take_message');
  if v_mode not in ('take_message', 'book_only', 'info_only') then v_mode := 'take_message'; end if;
  v_transfer_on := coalesce((v_rules ->> 'transfer_enabled')::boolean, true);
  v_hours_only := coalesce((v_rules ->> 'transfer_open_hours_only')::boolean, true);
  v_number := coalesce(nullif(v_rules ->> 'transfer_number', ''), nullif(v_rules #>> '{transfer_to,phone}', ''));
  v_fallback := nullif(v_rules ->> 'fallback_number', '');
  if coalesce(v_rules ->> 'transfer_route', '') = 'fallback' and v_fallback is not null then v_number := v_fallback; end if;
  v_em_on := coalesce((v_rules ->> 'emergency_enabled')::boolean, case when jsonb_typeof(v_rules -> 'triggers') = 'array' then v_rules -> 'triggers' ? 'emergency' else false end);
  select coalesce(array_agg(lower(trim(k))) filter (where length(trim(k)) between 2 and 40), array[]::text[]) into v_keywords
    from jsonb_array_elements_text(case when jsonb_typeof(v_rules -> 'emergency_keywords') = 'array' then v_rules -> 'emergency_keywords' else '[]'::jsonb end) k;

  v_open := public.zella_business_open(v_biz);
  v_is_open := coalesce((v_open ->> 'open')::boolean, true);
  v_next := case when v_open ->> 'next_open' is not null then to_char((v_open ->> 'next_open')::timestamptz at time zone v_tz, 'FMDay "at" FMHH12:MI AM') end;

  -- ------------------------------------------------------------------ rules (start of the call)
  if p_action = 'rules' then
    return jsonb_build_object('ok', true, 'status', case when v_is_open then 'open' else v_open ->> 'reason' end,
      'open', v_is_open, 'after_hours_mode', v_mode, 'can_transfer', (v_transfer_on and v_number is not null and (v_is_open or not v_hours_only)),
      'emergency_keywords', to_jsonb(v_keywords),
      'say', case
        when v_is_open then coalesce(v_name, 'The business') || ' is open now.'
        when v_open ->> 'reason' = 'holiday' then coalesce(v_name, 'The business') || ' is closed today (' || coalesce(v_open ->> 'label', 'holiday') || ').' || coalesce(' They open again ' || v_next || '.', '')
        else coalesce(v_name, 'The business') || ' is closed right now.' || coalesce(' They open again ' || v_next || '.', '') end
        || case when v_is_open then ''
             when v_mode = 'take_message' then ' Offer to take a message and call_rules with action "message".'
             when v_mode = 'book_only' then ' You can book an appointment, but do not promise a person right now.'
             else ' Give general information only and say the team will be back at opening time.' end
        || case when v_em_on and cardinality(v_keywords) > 0 then ' If the caller describes an emergency, use action "emergency" straight away.' else '' end);
  end if;

  -- ------------------------------------------------------------------ message / voicemail
  if p_action = 'message' then
    v_msg := nullif(trim(regexp_replace(left(coalesce(v_args ->> 'message', ''), 1500), '\s+', ' ', 'g')), '');
    if v_msg is null or length(v_msg) < 3 then
      return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller what the message is.');
    end if;
    v_cname := nullif(trim(left(coalesce(v_args ->> 'name', ''), 80)), '');
    v_cphone := coalesce(nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), ''), v_call.from_number);
    if public.zella_digits(v_cphone) is null then
      return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for a phone number so the team can call back.');
    end if;
    -- link to a customer only on an exact match, never create one from a message
    begin
      select m.customer_id into v_cust from public.zella_match_customer(v_biz, v_cphone, null) m where m.certainty = 'exact' limit 1;
    exception when others then v_cust := null; end;
    insert into public.call_messages (business_id, call_id, customer_id, kind, caller_name, caller_phone, message, after_hours)
    values (v_biz, v_call.id, v_cust, 'message', v_cname, v_cphone, v_msg, not v_is_open) returning id into v_mid;
    perform public.zella_create_callback(v_biz, v_cphone, case when v_is_open then 'requested' else 'after_hours' end, 'normal',
      left(coalesce(v_cname || ': ', '') || v_msg, 500), null, v_cust, v_call.id, null, 'phone_assistant', null);
    return jsonb_build_object('ok', true, 'status', 'message_saved', 'message_id', v_mid,
      'say', 'The message was saved and the team will call back' || coalesce(case when not v_is_open then ' when they open ' || v_next end, '') || '. Thank the caller.');
  end if;

  -- ------------------------------------------------------------------ emergency
  if p_action = 'emergency' then
    if not v_em_on then
      return jsonb_build_object('ok', true, 'status', 'not_enabled', 'say', 'Emergency handling is not set up. Take a message instead and say the team will be told.');
    end if;
    v_msg := coalesce(nullif(trim(regexp_replace(left(coalesce(v_args ->> 'summary', ''), 800), '\s+', ' ', 'g')), ''), 'Caller reported an emergency.');
    v_cname := nullif(trim(left(coalesce(v_args ->> 'name', ''), 80)), '');
    v_cphone := coalesce(nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), ''), v_call.from_number);
    begin
      select m.customer_id into v_cust from public.zella_match_customer(v_biz, v_cphone, null) m where m.certainty = 'exact' limit 1;
    exception when others then v_cust := null; end;
    insert into public.call_messages (business_id, call_id, customer_id, kind, caller_name, caller_phone, message, after_hours)
    values (v_biz, v_call.id, v_cust, 'emergency', v_cname, v_cphone, v_msg, not v_is_open) returning id into v_mid;
    if v_call.id is not null then
      update public.calls set needs_human = true, escalation_reason = 'emergency', escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call.id;
    end if;
    perform public.zella_notify_owners(v_biz, 'emergency_call', 'Emergency call', left(coalesce(v_cname, 'A caller') || ': ' || v_msg, 300), 'urgent', 'calls');
    if public.zella_digits(v_cphone) is not null then
      perform public.zella_create_callback(v_biz, v_cphone, 'needs_human', 'urgent', left('EMERGENCY - ' || v_msg, 500), null, v_cust, v_call.id, null, 'phone_assistant', null);
    end if;
    if v_transfer_on and v_number is not null then
      if v_call.id is not null then update public.calls set transfer_status = 'attempted' where id = v_call.id; end if;
      return jsonb_build_object('ok', true, 'status', 'transfer', 'transfer_number', v_number,
        'say', 'The owners have been alerted. Tell the caller you are connecting them to a person now, and transfer the call to the given number. Stay calm and short.');
    end if;
    return jsonb_build_object('ok', true, 'status', 'alerted',
      'say', 'The owners have been alerted and will call back as soon as possible. Tell the caller that, and if anyone is in danger tell them to hang up and call emergency services.');
  end if;

  -- ------------------------------------------------------------------ transfer to a person
  if p_action = 'transfer' then
    v_why := nullif(trim(left(coalesce(v_args ->> 'reason', ''), 300)), '');
    if v_transfer_on and v_number is not null and (v_is_open or not v_hours_only) then
      if v_call.id is not null then
        update public.calls set transfer_status = 'attempted', needs_human = true, escalation_reason = coalesce(escalation_reason, 'asked_for_person'), escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call.id;
      end if;
      return jsonb_build_object('ok', true, 'status', 'transfer', 'transfer_number', v_number,
        'say', 'Tell the caller you are connecting them to a person, then transfer the call to the given number.');
    end if;
    -- nobody can take the call: save a callback so the caller is not lost
    if v_call.id is not null then update public.calls set transfer_status = 'no_one_available', needs_human = true, updated_at = now() where id = v_call.id; end if;
    v_cphone := coalesce(nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), ''), v_call.from_number);
    if public.zella_digits(v_cphone) is not null then
      perform public.zella_create_callback(v_biz, v_cphone, 'needs_human', 'high', left(coalesce(v_why, 'Caller asked for a person.'), 500), null, null, v_call.id, null, 'phone_assistant', null);
    end if;
    return jsonb_build_object('ok', true, 'status', 'no_one_available',
      'say', 'Nobody can take the call right now. Say sorry, tell the caller the team will call back' || coalesce(case when not v_is_open then ' when they open ' || v_next end, '') || ', and offer to take a message.');
  end if;

  raise exception 'BAD_ACTION';
end $$;
revoke execute on function public.zella_ai_voice(text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_ai_voice(text, uuid, text, jsonb) to service_role;
