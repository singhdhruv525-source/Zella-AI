-- Zella - inbound call wrap-up (checklist 5, 10, 14, 15, 19). Safe to run more than once.
-- Needs zella_calls.sql, zella_voice_rules.sql, zella_phone_numbers.sql, zella_run_all.sql (callbacks).
--   15  the assistant is told, at the start of a call, whether the caller is known (first name only, never details)
--   5   when a call ends the result is worked out from what happened on it (booking, message, callback, hang-up)
--   14  the call keeps its summary, length, recording and transcript, is linked to the customer, and the customer's last contact is updated
--   10  if the caller asked for a call back and nobody saved one during the call, a callback is created
--   19  the person looking after a callback is reminded shortly before it is due

-- 1. Who is calling? Used by the assistant only to greet by name; it must not read out details before checking who it is talking to.
create or replace function public.zella_caller_context(p_business_id uuid, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cust uuid; v_first text; v_calls integer; v_last timestamptz; v_up boolean; v_cb boolean;
begin
  if public.zella_digits(p_phone) is null then return jsonb_build_object('known', false); end if;
  select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_phone, null) m where m.certainty = 'exact' limit 1;
  select count(*), max(started_at) into v_calls, v_last from public.calls
   where business_id = p_business_id and direction = 'inbound' and (customer_id = v_cust and v_cust is not null or public.zella_digits(from_number) = public.zella_digits(p_phone));
  if v_cust is null then
    return jsonb_build_object('known', false, 'previous_calls', v_calls, 'repeat_caller', v_calls > 0,
      'say', case when v_calls > 0 then 'This number has called before but is not a saved customer. Do not assume a name; ask for it.' else 'New caller. Ask for their name.' end);
  end if;
  select nullif(trim(first_name), '') into v_first from public.customers where id = v_cust;
  select exists (select 1 from public.appointments where customer_id = v_cust and business_id = p_business_id and start_time > now() and status not in ('cancelled', 'no_show', 'completed')) into v_up;
  select exists (select 1 from public.callbacks where customer_id = v_cust and business_id = p_business_id and status not in ('completed', 'cancelled')) into v_cb;
  return jsonb_build_object('known', true, 'first_name', v_first, 'previous_calls', v_calls, 'repeat_caller', v_calls > 0,
    'last_call_days_ago', case when v_last is null then null else greatest(0, floor(extract(epoch from now() - v_last) / 86400))::int end,
    'has_upcoming_appointment', v_up, 'has_open_callback', v_cb,
    'say', 'Known customer' || coalesce(' (' || v_first || ')', '') || '. You may greet them by first name. Caller ID can be wrong, so ask them to confirm their name before you share or change anything about an appointment.'
           || case when v_cb then ' The team already has a callback open for them; mention that someone will be in touch rather than creating another.' else '' end);
end $$;
revoke execute on function public.zella_caller_context(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_caller_context(uuid, text) to service_role;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_ai_voice(text,uuid,text,jsonb)'::regprocedure);
  if d not like '%zella_caller_context%' then
    d := replace(d, E'''emergency_keywords'', to_jsonb(v_keywords),',
      E'''emergency_keywords'', to_jsonb(v_keywords),\n      ''caller'', public.zella_caller_context(v_biz, coalesce(nullif(v_args ->> ''caller_number'', ''''), v_call.from_number)),');
    if d not like '%zella_caller_context%' then raise exception 'PATCH_FAILED_VOICE'; end if;
    execute d;
  end if;
end $$;

-- 2. End of an inbound call (from Vapi's end-of-call report, through the Call Results workflow). Safe to receive twice.
create or replace function public.zella_record_inbound_call(
  p_provider_call_id text, p_called_number text, p_vapi_phone_number_id text, p_from_number text,
  p_started_at timestamptz, p_ended_at timestamptz, p_seconds integer, p_reason text,
  p_summary text, p_recording_url text, p_transcript text, p_wants_callback boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  c public.calls; v_biz uuid; v_cust uuid; v_out text; v_note text; v_secs integer := greatest(coalesce(p_seconds, 0), 0);
  v_phone text := nullif(left(coalesce(p_from_number, ''), 30), '');
  v_booked boolean := false; v_msg boolean := false; v_cb boolean := false; v_lead jsonb;
begin
  if nullif(p_provider_call_id, '') is null then return 'ignored'; end if;
  select * into c from public.calls where external_call_id = p_provider_call_id for update;
  if found and c.outcome_at is not null and c.ended_at is not null then return 'ignored'; end if;
  v_biz := c.business_id;
  if v_biz is null then v_biz := public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null); end if;
  if v_biz is null then return 'unknown_business'; end if;
  if not found then
    insert into public.calls (business_id, direction, status, from_number, to_number, external_call_id, started_at, ai_handled)
    values (v_biz, 'inbound', 'answered', v_phone, left(p_called_number, 30), p_provider_call_id, coalesce(p_started_at, now() - make_interval(secs => v_secs)), true)
    returning * into c;
  end if;
  v_phone := coalesce(v_phone, c.from_number);

  v_cust := c.customer_id;
  if v_cust is null and public.zella_digits(v_phone) is not null then
    begin select m.customer_id into v_cust from public.zella_match_customer(v_biz, v_phone, null) m where m.certainty = 'exact' limit 1;
    exception when others then v_cust := null; end;
  end if;

  v_msg := exists (select 1 from public.call_messages where call_id = c.id);
  v_cb := exists (select 1 from public.callbacks where call_id = c.id);
  v_booked := v_cust is not null and exists (select 1 from public.appointments a where a.customer_id = v_cust and a.business_id = v_biz
                 and a.created_at between coalesce(c.started_at, now() - interval '3 hours') - interval '1 minute' and coalesce(p_ended_at, now()) + interval '3 minutes' and a.status <> 'cancelled');

  -- 10: the caller asked to be called back but nothing was saved during the call
  if coalesce(p_wants_callback, false) and not v_cb and public.zella_digits(v_phone) is not null then
    perform public.zella_create_callback(v_biz, v_phone, 'requested', 'normal', left(coalesce(nullif(trim(p_summary), ''), 'Caller asked for a call back.'), 500), null, v_cust, c.id, null, 'phone_assistant', null);
    v_cb := true;
  end if;

  -- 5: outcome, only when nobody has set one
  if c.outcome is null then
    v_out := case
      when v_booked then 'booked'
      when v_msg then 'left_message'
      when v_cb or c.needs_human then 'callback_needed'
      when v_secs < 6 then 'other'
      when nullif(trim(p_summary), '') is not null then 'resolved'
      else 'other' end;
    v_note := case v_out when 'booked' then 'Booked during the call.' when 'left_message' then 'The caller left a message.' when 'callback_needed' then 'Needs a call back.'
                         when 'resolved' then 'Handled on the call.' else case when v_secs < 6 then 'Caller hung up quickly.' else 'No summary was returned.' end end;
  end if;

  -- an unknown caller who wanted something becomes a lead (matched or created by phone)
  if v_cust is null and v_out in ('booked', 'left_message', 'callback_needed') and public.zella_digits(v_phone) is not null then
    v_lead := public.zella_capture_lead(v_biz, null, null, v_phone, null, 'phone_call', left(p_summary, 500), null);
    v_cust := nullif(v_lead ->> 'customer_id', '')::uuid;
  end if;

  -- 14: keep the record
  update public.calls set
      status = case when v_secs = 0 and p_reason ~* 'did-not-answer|no-answer|busy' then 'missed' else 'completed' end,
      customer_id = coalesce(customer_id, v_cust), to_number = coalesce(to_number, left(p_called_number, 30)), from_number = coalesce(from_number, v_phone),
      ended_at = coalesce(p_ended_at, now()), duration_seconds = v_secs,
      summary = coalesce(nullif(left(trim(p_summary), 1500), ''), summary),
      transcript = coalesce(nullif(left(p_transcript, 60000), ''), transcript),
      recording_url = coalesce(nullif(left(p_recording_url, 1000), ''), recording_url),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('ended_reason', left(p_reason, 80)),
      outcome = coalesce(outcome, v_out), outcome_note = coalesce(outcome_note, v_note), outcome_at = coalesce(outcome_at, case when v_out is not null then now() end),
      updated_at = now()
   where id = c.id;
  if v_cust is not null then update public.customers set last_contacted_at = greatest(coalesce(last_contacted_at, '-infinity'), coalesce(p_ended_at, now())) where id = v_cust; end if;
  return 'recorded';
end $$;
revoke execute on function public.zella_record_inbound_call(text, text, text, text, timestamptz, timestamptz, integer, text, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.zella_record_inbound_call(text, text, text, text, timestamptz, timestamptz, integer, text, text, text, text, boolean) to service_role;

-- 3. Callback reminders (19): about 15 minutes before a callback is due, the person looking after it is told once.
alter table public.callbacks add column if not exists reminder_sent_at timestamptz;
create or replace function public.zella_remind_upcoming_callbacks() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select cb.id, cb.business_id, cb.assigned_to, cb.customer_id, coalesce(cb.preferred_at, cb.due_at) as at_time
             from public.callbacks cb
            where cb.status in ('new', 'scheduled', 'due', 'retry_scheduled') and cb.reminder_sent_at is null
              and coalesce(cb.preferred_at, cb.due_at) between now() and now() + interval '15 minutes' for update skip locked loop
    if r.assigned_to is not null then
      perform public.zella_notify(r.business_id, 'callback_soon', 'A callback is due soon', 'Call back within the next 15 minutes.', 'warning', 'calls', r.id, r.assigned_to);
    else
      perform public.zella_notify_owners(r.business_id, 'callback_soon', 'A callback is due soon', 'Nobody has taken it yet. Call back within the next 15 minutes.', 'warning', 'calls');
    end if;
    update public.callbacks set reminder_sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_remind_upcoming_callbacks() from public, anon, authenticated;
grant execute on function public.zella_remind_upcoming_callbacks() to service_role;
