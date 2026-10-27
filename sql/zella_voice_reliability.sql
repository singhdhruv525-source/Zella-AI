-- Zella - voice reliability, phase 1 (2026-10-27). Safe to re-run. NOT applied to production yet: back up first.
-- Needs: zella_workflows.sql (booking functions), zella_ai_booking.sql, zella_brain.sql, zella_voice_rules.sql,
-- zella_inbound_calls.sql, zella_phone_numbers.sql. Run AFTER them: re-running any of those files replaces a patched
-- function with its unpatched version; zella_voice_reliability_status() shows what is in place.
--
-- What it fixes (each verified against the live database on 2026-10-27):
--   A. Booking concurrency. zella_book_appointment, zella_hold_slot, zella_confirm_requested_appointment and
--      zella_reschedule_appointment checked availability and then wrote, with no lock: 20 simultaneous bookings of one
--      free slot produced 7 appointments in a staging copy of the live functions. Every customer-, AI-, link- and
--      waitlist-facing booking goes through these four, so each now takes a per-business transaction lock before it
--      checks availability. Availability rules (hours, staff, holds, durations, time zones) are untouched.
--      Identical AI tool requests that are still running are serialised too (zella_ai_tool), so a retry gets the
--      first result instead of "that time is taken".
--      Staff bookings made directly in the CRM are not changed: staff may still deliberately double-book.
--   B/D. Call records. calls.external_call_id had no unique index and two writers did check-then-insert, so parallel
--      tool calls could create two rows for one call. Now one row per provider call id, provider status updates
--      (ringing, in-progress, forwarding, ended) are recorded in order and only once, and calls whose end-of-call
--      report never arrived are listed for reconciliation against the provider's API (zella_calls_to_reconcile /
--      zella_reconcile_call). Nothing is invented: missing times stay empty and are marked as estimated where used.
--   C. Transfers. The destination is resolved on the server for the call's own business (zella_transfer_destination,
--      answering Vapi's transfer-destination-request), never taken from what the model or caller says. The number is
--      no longer handed to the model in tool results, and the transfer outcome is recorded from the provider's
--      ended reason (assistant-forwarded-call = forwarded; otherwise failed), which feeds zella_detect_transfer_failures.
--
-- Undo: re-run the source files listed above (restores the unpatched functions), then
--   drop index if exists public.calls_external_call_id_key;
--   drop function if exists public.zella_booking_lock(uuid), public.zella_record_call_status(text, text, text, text, text, text, timestamptz, text),
--     public.zella_calls_to_reconcile(integer), public.zella_call_reconcile_waiting(), public.zella_reconcile_call(text, integer, jsonb),
--     public.zella_transfer_destination(text, text, text, text), public.zella_voice_reliability_status();

-- ---------------------------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------------------------

-- One booking writer at a time per business, until its transaction ends. Bookings are a few a minute per business,
-- so the wait is milliseconds; it makes "check the slot, then write" safe under concurrency.
create or replace function public.zella_booking_lock(p_business_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_business_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('zella_booking:' || p_business_id::text, 0));
  end if;
end $$;
revoke all on function public.zella_booking_lock(uuid) from public, anon, authenticated;

-- Replace one exact piece of a live function body and re-create it. Fails if the anchor isn't there exactly once,
-- so a changed function is never patched blindly. Skipped when the marker shows the patch is already in.
create or replace function public.zella_patch_function(p_signature text, p_marker text, p_anchor text, p_replacement text) returns text
language plpgsql set search_path = public as $$
declare d text; n integer;
begin
  if to_regprocedure(p_signature) is null then return 'missing'; end if;
  d := pg_get_functiondef(p_signature::regprocedure);
  if position(p_marker in d) > 0 then return 'already'; end if;
  n := (length(d) - length(replace(d, p_anchor, ''))) / greatest(length(p_anchor), 1);
  if n <> 1 then raise exception 'PATCH_ANCHOR % found % times in %', left(p_anchor, 60), n, p_signature; end if;
  execute replace(d, p_anchor, p_replacement);
  return 'patched';
end $$;
revoke all on function public.zella_patch_function(text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- A. Booking concurrency
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_slot_anchor text := 'select * into v_slot from public.zella_available_slots(';
        v_row_anchor text := 'select * into a from public.appointments where id = p_appointment_id for update;';
begin
  -- new bookings and holds: lock, then check the slot
  perform public.zella_patch_function('public.zella_book_appointment(uuid,uuid,text,timestamptz,integer,uuid,integer,text)', 'zella_booking_lock',
    v_slot_anchor, 'perform public.zella_booking_lock(p_business_id); -- zella_booking_lock' || E'\n  ' || v_slot_anchor);
  perform public.zella_patch_function('public.zella_hold_slot(uuid,uuid,text,timestamptz,integer,uuid,integer)', 'zella_booking_lock',
    v_slot_anchor, 'perform public.zella_booking_lock(p_business_id); -- zella_booking_lock' || E'\n  ' || v_slot_anchor);
  -- moves and confirmations: the business lock is taken before the row lock, in the same order as every other writer
  perform public.zella_patch_function('public.zella_confirm_requested_appointment(uuid,timestamptz,integer,uuid)', 'zella_booking_lock',
    v_row_anchor, 'perform public.zella_booking_lock((select x.business_id from public.appointments x where x.id = p_appointment_id)); -- zella_booking_lock'
                  || E'\n  ' || v_row_anchor);
  perform public.zella_patch_function('public.zella_reschedule_appointment(uuid,timestamptz,uuid,text)', 'zella_booking_lock',
    v_row_anchor, 'perform public.zella_booking_lock((select x.business_id from public.appointments x where x.id = p_appointment_id)); -- zella_booking_lock'
                  || E'\n  ' || v_row_anchor);
  -- the phone assistant's booking: the "already booked for this person at this time?" check happens under the same lock
  perform public.zella_patch_function('public.zella_ai_booking(text,uuid,text,jsonb)', 'zella_booking_lock',
    'if p_action <> ''book'' then raise exception ''BAD_ACTION''; end if;',
    'if p_action <> ''book'' then raise exception ''BAD_ACTION''; end if;' || E'\n  perform public.zella_booking_lock(v_biz); -- zella_booking_lock');
  -- identical consequential tool requests: the second waits for the first and returns its saved result
  perform public.zella_patch_function('public.zella_ai_tool(text,uuid,text,jsonb,text)', 'zella_ai_tool_inflight',
    E'if v_key is not null then\n    select l.result into v_prev',
    E'if v_key is not null then\n    perform pg_advisory_xact_lock(hashtextextended(''zella_ai_tool:'' || v_biz::text || '':'' || v_key, 0)); -- zella_ai_tool_inflight\n    select l.result into v_prev');
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- B/D. One call row per provider call, status updates, reconciliation
-- ---------------------------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.calls where external_call_id is not null group by external_call_id having count(*) > 1) then
    raise exception 'DUPLICATE_CALL_ROWS: merge rows sharing an external_call_id before running this file (nothing was changed)';
  end if;
end $$;
create unique index if not exists calls_external_call_id_key on public.calls (external_call_id) where external_call_id is not null;

do $$
begin
  -- the assistant's first tool call creates the call row; a parallel tool call now reuses it
  perform public.zella_patch_function('public.zella_ai_voice(text,uuid,text,jsonb)', 'zella_one_call_row',
    'p_provider_call_id, now(), true);',
    E'p_provider_call_id, now(), true)\n    on conflict (external_call_id) where external_call_id is not null do nothing; -- zella_one_call_row');
  -- end-of-call report: same, plus real durations only, and the transfer outcome from the provider's ended reason
  perform public.zella_patch_function('public.zella_record_inbound_call(text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean)', 'zella_one_call_row',
    E'    returning * into c;\n  end if;',
    E'    on conflict (external_call_id) where external_call_id is not null do nothing -- zella_one_call_row\n    returning * into c;\n'
    || E'    if c.id is null then select * into c from public.calls where external_call_id = p_provider_call_id for update; end if;\n  end if;');
  perform public.zella_patch_function('public.zella_record_inbound_call(text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean)', 'zella_real_times',
    'ended_at = coalesce(p_ended_at, now()), duration_seconds = v_secs,',
    E'ended_at = coalesce(p_ended_at, ended_at, now()), duration_seconds = case when p_seconds is null then duration_seconds else v_secs end, -- zella_real_times\n'
    || E'      transfer_status = case when p_reason = ''assistant-forwarded-call'' then ''connected'' when transfer_status = ''attempted'' then ''failed'' else transfer_status end,');
  perform public.zella_patch_function('public.zella_record_inbound_call(text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean)', 'ended_at_source',
    'jsonb_build_object(''ended_reason'', left(p_reason, 80)),',
    'jsonb_build_object(''ended_reason'', left(p_reason, 80), ''ended_at_source'', case when p_ended_at is not null then ''provider'' when ended_at is not null then ''status_update'' else ''received_time'' end, ''awaiting_report'', false),');
  -- the model is no longer given the transfer number; the system resolves it (zella_transfer_destination)
  perform public.zella_patch_function('public.zella_ai_voice(text,uuid,text,jsonb)', 'zella_server_transfer',
    '''say'', ''Tell the caller you are connecting them to a person, then transfer the call to the given number.'');',
    '''say'', ''Tell the caller you are connecting them to a person, then use the transfer tool. Do not say a number; the system chooses it.''); -- zella_server_transfer');
  perform public.zella_patch_function('public.zella_ai_voice(text,uuid,text,jsonb)', 'system chooses the number',
    'Tell the caller you are connecting them to a person now, and transfer the call to the given number. Stay calm and short.',
    'Tell the caller you are connecting them to a person now, then use the transfer tool (the system chooses the number). Stay calm and short.');
end $$;

-- Provider call status (Vapi status-update: ringing, in-progress, forwarding, ended). Creates the call record as soon as
-- the call starts, so a lost end-of-call report can't erase it. Each status is applied once and in order; a repeated or
-- late one changes nothing. The business comes only from the registered phone number, never from call settings.
create or replace function public.zella_record_call_status(p_provider_call_id text, p_status text, p_called_number text,
  p_vapi_phone_number_id text, p_from_number text, p_direction text, p_event_at timestamptz, p_ended_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare
  c public.calls; v_biz uuid;
  v_rank integer := case p_status when 'ringing' then 2 when 'in-progress' then 3 when 'forwarding' then 4 when 'ended' then 5 end;
  v_cur integer;
begin
  if nullif(p_provider_call_id, '') is null or length(p_provider_call_id) > 200 then return 'ignored'; end if;
  if v_rank is null then return 'ignored_status'; end if;                 -- scheduled / queued: nothing to record yet
  if coalesce(p_direction, 'inbound') <> 'inbound' then return 'ignored_outbound'; end if;   -- outbound has its own record
  if p_event_at is not null and (p_event_at > now() + interval '5 minutes' or p_event_at < now() - interval '30 days') then p_event_at := null; end if;

  select * into c from public.calls where external_call_id = p_provider_call_id for update;
  if not found then
    v_biz := public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null);
    if v_biz is null then return 'unknown_business'; end if;
    insert into public.calls (business_id, direction, status, from_number, to_number, external_call_id, started_at, ai_handled, metadata)
    values (v_biz, 'inbound', 'ringing', nullif(left(coalesce(p_from_number, ''), 30), ''), nullif(left(coalesce(p_called_number, ''), 30), ''),
            p_provider_call_id, p_event_at, true, jsonb_build_object('created_from', 'status_update'))
    on conflict (external_call_id) where external_call_id is not null do nothing;
    select * into c from public.calls where external_call_id = p_provider_call_id for update;
  end if;

  v_cur := coalesce((c.metadata ->> 'provider_status_rank')::integer, 0);
  if v_rank <= v_cur then return 'duplicate'; end if;
  if c.outcome_at is not null and c.ended_at is not null then return 'already_final'; end if;

  update public.calls set
      status = case when p_status = 'ringing' and status = 'initiated' then 'ringing'
                    when p_status in ('in-progress', 'forwarding') and status in ('initiated', 'ringing') then 'answered'
                    else status end,
      started_at = coalesce(started_at, p_event_at),
      answered_at = case when p_status in ('in-progress', 'forwarding') then coalesce(answered_at, p_event_at) else answered_at end,
      transfer_status = case when p_status = 'forwarding' and transfer_status is null then 'attempted' else transfer_status end,
      ended_at = case when p_status = 'ended' then coalesce(ended_at, p_event_at) else ended_at end,
      from_number = coalesce(from_number, nullif(left(coalesce(p_from_number, ''), 30), '')),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('provider_status', p_status, 'provider_status_rank', v_rank,
                   'provider_status_at', p_event_at, 'awaiting_report', p_status = 'ended')
                 || case when p_status = 'ended' and nullif(p_ended_reason, '') is not null then jsonb_build_object('ended_reason', left(p_ended_reason, 80)) else '{}'::jsonb end,
      updated_at = now()
   where id = c.id;
  return 'recorded';
end $$;

-- Calls that need their final details fetched from the provider: ended without a report for 10 minutes, or no end at
-- all 2 hours after starting. Claimed with a growing wait (15 min x attempts); gives up after 6 tries, keeping the call.
create or replace function public.zella_calls_to_reconcile(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res jsonb := '[]'::jsonb; r record;
begin
  if not coalesce(public.zella_setting('call_reconcile_live', 'false'::jsonb) = 'true'::jsonb, false) then return v_res; end if;
  for r in select c.id, c.external_call_id from public.calls c
            where c.external_call_id is not null and c.direction = 'inbound' and c.ai_handled and c.outcome_at is null
              and ((c.metadata ->> 'awaiting_report' = 'true' and coalesce(c.ended_at, c.updated_at) < now() - interval '10 minutes')
                   or (c.ended_at is null and coalesce(c.answered_at, c.started_at, c.created_at) < now() - interval '2 hours'))
              and coalesce((c.metadata ->> 'reconcile_attempts')::integer, 0) < 6
              and coalesce((c.metadata ->> 'reconcile_claimed_at')::timestamptz, 'epoch')
                  < now() - make_interval(mins => 15 * greatest(1, coalesce((c.metadata ->> 'reconcile_attempts')::integer, 0)))
            order by c.created_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked loop
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_claimed_at', now(),
             'reconcile_attempts', coalesce((metadata ->> 'reconcile_attempts')::integer, 0) + 1) where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('provider_call_id', r.external_call_id));
  end loop;
  return v_res;
end $$;

create or replace function public.zella_call_reconcile_waiting() returns integer
language sql stable security definer set search_path = public as $$
  select case when not coalesce(public.zella_setting('call_reconcile_live', 'false'::jsonb) = 'true'::jsonb, false) then 0 else
    (select count(*)::integer from public.calls c
      where c.external_call_id is not null and c.direction = 'inbound' and c.ai_handled and c.outcome_at is null
        and ((c.metadata ->> 'awaiting_report' = 'true' and coalesce(c.ended_at, c.updated_at) < now() - interval '10 minutes')
             or (c.ended_at is null and coalesce(c.answered_at, c.started_at, c.created_at) < now() - interval '2 hours'))
        and coalesce((c.metadata ->> 'reconcile_attempts')::integer, 0) < 6
        and coalesce((c.metadata ->> 'reconcile_claimed_at')::timestamptz, 'epoch')
            < now() - make_interval(mins => 15 * greatest(1, coalesce((c.metadata ->> 'reconcile_attempts')::integer, 0)))) end;
$$;

-- The provider's own record of the call (GET /call/{id}) completes what the lost report would have. Only an ended
-- call is recorded, with the provider's times; anything else is left for the next attempt.
create or replace function public.zella_reconcile_call(p_provider_call_id text, p_status_code integer, p_call jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  c public.calls; j jsonb := case when jsonb_typeof(p_call) = 'object' then p_call else '{}'::jsonb end;
  v_start timestamptz; v_end timestamptz; v_secs integer; v_res text;
  ts text;
begin
  select * into c from public.calls where external_call_id = p_provider_call_id;
  if c.id is null then return 'unknown_call'; end if;
  if c.outcome_at is not null then return 'already_final'; end if;
  if p_status_code = 404 then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status',
             case when coalesce((metadata ->> 'reconcile_attempts')::integer, 0) >= 6 then 'not_found' else 'retry' end) where id = c.id;
    return 'not_found';
  end if;
  if p_status_code is null or p_status_code < 200 or p_status_code >= 300 then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'provider_error', 'reconcile_error', p_status_code) where id = c.id;
    return 'provider_error';
  end if;
  if j ->> 'id' is distinct from p_provider_call_id then return 'mismatch'; end if;     -- never apply another call's data
  if j ->> 'status' is distinct from 'ended' then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'not_ended', 'provider_status_seen', left(j ->> 'status', 30)) where id = c.id;
    return 'not_ended';
  end if;
  begin v_start := nullif(j ->> 'startedAt', '')::timestamptz; exception when others then v_start := null; end;
  begin v_end := nullif(j ->> 'endedAt', '')::timestamptz; exception when others then v_end := null; end;
  v_secs := case when v_start is not null and v_end is not null and v_end >= v_start then extract(epoch from (v_end - v_start))::integer end;
  v_res := public.zella_record_inbound_call(p_provider_call_id,
    j #>> '{phoneNumber,number}', left(j ->> 'phoneNumberId', 100), j #>> '{customer,number}', v_start, v_end, v_secs,
    left(coalesce(j ->> 'endedReason', ''), 80),
    left(coalesce(j #>> '{analysis,summary}', j ->> 'summary', ''), 1500),
    case when coalesce(j #>> '{artifact,recordingUrl}', j ->> 'recordingUrl', '') ~ '^https://' then left(coalesce(j #>> '{artifact,recordingUrl}', j ->> 'recordingUrl'), 1000) end,
    left(coalesce(j #>> '{artifact,transcript}', j ->> 'transcript', ''), 60000),
    coalesce((j #>> '{analysis,structuredData,callback_requested}')::boolean, false));
  update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'reconciled', 'reconciled_at', now()) where id = c.id;
  return v_res;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- C. Transfer destination, decided on the server for the call's own business
-- ---------------------------------------------------------------------------------------------------------------
-- Vapi asks this (transfer-destination-request) when the assistant uses its transfer tool without a destination.
-- The number comes only from the business's own receptionist settings; the call's business comes from the call record
-- or the registered phone number, never from what the model or the caller says.
create or replace function public.zella_transfer_destination(p_provider_call_id text, p_called_number text, p_vapi_phone_number_id text, p_from_number text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.calls; v_biz uuid; v_rules jsonb; v_number text; v_fallback text; v_open jsonb; v_is_open boolean; v_scr jsonb; v_e164 text;
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
  v_e164 := public.zella_normalize_e164(v_number);
  if v_e164 is null then return v_refuse || jsonb_build_object('reason', 'no_valid_number'); end if;

  v_open := public.zella_business_open(v_biz);
  v_is_open := coalesce((v_open ->> 'open')::boolean, true);
  if not v_is_open and coalesce((v_rules ->> 'transfer_open_hours_only')::boolean, true) then return v_refuse || jsonb_build_object('reason', 'closed'); end if;

  if c.id is not null then
    update public.calls set transfer_status = 'attempted', needs_human = true, escalation_reason = coalesce(escalation_reason, 'asked_for_person'),
           escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = c.id;
  end if;
  return jsonb_build_object('ok', true, 'number', v_e164, 'message', 'Please hold while I connect you.');
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- What is in place (a re-run of an older source file silently removes a patch; this shows it)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_voice_reliability_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'book_appointment_locked', pg_get_functiondef('public.zella_book_appointment(uuid,uuid,text,timestamptz,integer,uuid,integer,text)'::regprocedure) like '%zella_booking_lock%',
    'hold_slot_locked', pg_get_functiondef('public.zella_hold_slot(uuid,uuid,text,timestamptz,integer,uuid,integer)'::regprocedure) like '%zella_booking_lock%',
    'confirm_requested_locked', pg_get_functiondef('public.zella_confirm_requested_appointment(uuid,timestamptz,integer,uuid)'::regprocedure) like '%zella_booking_lock%',
    'reschedule_locked', pg_get_functiondef('public.zella_reschedule_appointment(uuid,timestamptz,uuid,text)'::regprocedure) like '%zella_booking_lock%',
    'ai_booking_locked', pg_get_functiondef('public.zella_ai_booking(text,uuid,text,jsonb)'::regprocedure) like '%zella_booking_lock%',
    'ai_tool_inflight', pg_get_functiondef('public.zella_ai_tool(text,uuid,text,jsonb,text)'::regprocedure) like '%zella_ai_tool_inflight%',
    'one_call_row_voice', pg_get_functiondef('public.zella_ai_voice(text,uuid,text,jsonb)'::regprocedure) like '%zella_one_call_row%',
    'one_call_row_report', pg_get_functiondef('public.zella_record_inbound_call(text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean)'::regprocedure) like '%zella_one_call_row%',
    'server_transfer', pg_get_functiondef('public.zella_ai_voice(text,uuid,text,jsonb)'::regprocedure) like '%zella_server_transfer%',
    'unique_call_index', to_regclass('public.calls_external_call_id_key') is not null);
$$;

insert into public.platform_settings (key, value) values ('call_reconcile_live', 'false'::jsonb) on conflict (key) do nothing;

revoke all on function public.zella_record_call_status(text, text, text, text, text, text, timestamptz, text), public.zella_calls_to_reconcile(integer),
  public.zella_call_reconcile_waiting(), public.zella_reconcile_call(text, integer, jsonb), public.zella_transfer_destination(text, text, text, text),
  public.zella_voice_reliability_status() from public, anon, authenticated;
grant execute on function public.zella_record_call_status(text, text, text, text, text, text, timestamptz, text), public.zella_calls_to_reconcile(integer),
  public.zella_call_reconcile_waiting(), public.zella_reconcile_call(text, integer, jsonb), public.zella_transfer_destination(text, text, text, text),
  public.zella_voice_reliability_status() to service_role;
