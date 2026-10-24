-- Zella - the receptionist brain. Safe to run more than once.
-- Needs zella_run_all.sql, zella_knowledge.sql, zella_ai_booking.sql, zella_voice_rules.sql, zella_industry_rule_list.sql (for zella_industry_key_for).
--
-- What this adds (the phone assistant itself - Vapi plus a language model - is configured from here, never from the browser):
--   1. zella_brain_context(biz)   what the assistant may know about ONE business (hours, rules, wording, a list of what it can answer)
--   2. zella_brain_prompt(biz)    the instructions the assistant starts a call with, built from that context + safety rules for the industry
--   3. zella_brain_search(biz, q) finds approved knowledge for a question, for THIS business only, and says whether it is confirmed or missing
--   4. zella_ai_tool(...)         the ONE door every assistant tool goes through: checks the business and the tool, asks for the caller's
--                                 yes before anything consequential, checks the result is really saved, logs it, and never double-acts
--   5. zella_assistant_config(biz) the assistant definition (model, instructions, tools) ready to send to Vapi at go-live
--   6. accuracy checks: zella_brain_run_evals(biz) asks saved questions and compares with the business's own facts
-- The language model only chooses words and tools. The database decides what is true and what was done.

insert into public.platform_settings (key, value) values ('voice_llm_provider', '"anthropic"'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('voice_llm_model', '"claude-sonnet-5-5"'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('brain_tools_url', 'null'::jsonb) on conflict (key) do nothing;

-- ---------------------------------------------------------------------------------------------------------
-- Knowledge search: plain text search is enough for FAQ-sized knowledge and keeps data inside the database.
-- ---------------------------------------------------------------------------------------------------------
alter table public.knowledge_items add column if not exists search tsvector
  generated always as (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(question, '') || ' ' || coalesce(answer, ''))) stored;
create index if not exists knowledge_items_search_idx on public.knowledge_items using gin (search);

create or replace function public.zella_brain_search(p_business_id uuid, p_query text, p_limit integer default 3)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_lex text[]; v_total integer; v_hits jsonb; v_best numeric := 0;
begin
  if p_business_id is null then raise exception 'UNKNOWN_BUSINESS'; end if;
  select coalesce(array_agg(l), '{}') into v_lex from unnest(tsvector_to_array(to_tsvector('english', left(coalesce(p_query, ''), 300)))) l where length(l) >= 2;
  v_total := coalesce(array_length(v_lex, 1), 0);
  if v_total = 0 then
    return jsonb_build_object('confidence', 'none', 'results', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(x.j order by x.score desc), '[]'::jsonb), coalesce(max(x.score), 0)
    into v_hits, v_best
    from (
      select s.score, jsonb_build_object('item_id', s.id, 'kind', s.kind, 'title', s.title, 'answer', left(s.answer, 700),
               'score', round(s.score, 2), 'source', jsonb_build_object('item_id', s.id, 'version', s.version, 'updated_at', s.updated_at, 'url', s.source_url)) j
        from (
          select k.id, k.kind, k.title, k.answer, k.version, k.updated_at, k.source_url,
                 (select count(*) from unnest(v_lex) w where k.search @@ quote_literal(w)::tsquery)::numeric / v_total as score
            from public.knowledge_items k
           where k.business_id = p_business_id and k.status = 'ready' and k.search @@ (select string_agg(quote_literal(w), ' | ')::tsquery from unnest(v_lex) w)
        ) s
       order by s.score desc, s.updated_at desc
       limit greatest(1, least(coalesce(p_limit, 3), 5))
    ) x;
  return jsonb_build_object('confidence', case when v_best >= 0.6 or (v_best >= 0.34 and v_total <= 2) then 'confirmed' when v_best > 0 then 'partial' else 'none' end,
                            'results', v_hits);
end $$;
revoke execute on function public.zella_brain_search(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.zella_brain_search(uuid, text, integer) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- Tool list: the only things the assistant may do. Anything not here is refused.
-- consequential = changes data, so it needs the caller's yes (where it says so), is logged, and cannot repeat.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_brain_tool_defs() returns jsonb
language sql immutable as $$
select jsonb_build_array(
  jsonb_build_object('name', 'search_knowledge', 'consequential', false,
    'description', 'Look up approved information about this business (services, policies, prices if supplied, FAQs). Use before answering any factual question about the business. Never answer business facts from memory.',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('query'), 'properties', jsonb_build_object('query', jsonb_build_object('type', 'string', 'description', 'The caller''s question in a few words')))),
  jsonb_build_object('name', 'check_open_hours', 'consequential', false,
    'description', 'Find out whether the business is open right now, today''s hours, and any holiday closure.',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object())),
  jsonb_build_object('name', 'lookup_caller', 'consequential', false,
    'description', 'Recognise the caller by the number they are calling from. Returns their first name and number of upcoming appointments, or says the caller is not recognised.',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object())),
  jsonb_build_object('name', 'update_caller', 'consequential', true, 'needs_confirmation', false,
    'description', 'Save the caller''s name, email or preferred way to be contacted (call, text or email) after they have said it. Creates a record if the caller is new.',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object('first_name', jsonb_build_object('type', 'string'), 'last_name', jsonb_build_object('type', 'string'),
      'email', jsonb_build_object('type', 'string'), 'phone', jsonb_build_object('type', 'string'), 'preferred_contact_method', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('call', 'sms', 'email'))))),
  jsonb_build_object('name', 'check_availability', 'consequential', false,
    'description', 'Get real open appointment times. Never offer a time that did not come from this tool.',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object('date', jsonb_build_object('type', 'string', 'description', 'YYYY-MM-DD, optional'),
      'days', jsonb_build_object('type', 'integer'), 'duration_minutes', jsonb_build_object('type', 'integer')))),
  jsonb_build_object('name', 'book_appointment', 'consequential', true, 'needs_confirmation', true,
    'description', 'Book an appointment at a time returned by check_availability. First read the details back and ask the caller to confirm; only then call this with confirmed=true. Say it is booked ONLY if the result status is booked.',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('start', 'first_name', 'confirmed'), 'properties', jsonb_build_object('start', jsonb_build_object('type', 'string', 'description', 'Exactly as returned by check_availability'),
      'first_name', jsonb_build_object('type', 'string'), 'last_name', jsonb_build_object('type', 'string'), 'phone', jsonb_build_object('type', 'string'), 'email', jsonb_build_object('type', 'string'),
      'title', jsonb_build_object('type', 'string'), 'notes', jsonb_build_object('type', 'string'), 'duration_minutes', jsonb_build_object('type', 'integer'),
      'confirmed', jsonb_build_object('type', 'boolean', 'description', 'true only after the caller said yes to the read-back')))),
  jsonb_build_object('name', 'find_my_appointments', 'consequential', false,
    'description', 'List the caller''s own upcoming appointments (matched by the number they are calling from).',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object())),
  jsonb_build_object('name', 'reschedule_appointment', 'consequential', true, 'needs_confirmation', true,
    'description', 'Move one of the caller''s appointments to a time from check_availability, after the caller confirms (confirmed=true).',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('appointment_id', 'start', 'confirmed'), 'properties', jsonb_build_object('appointment_id', jsonb_build_object('type', 'string'),
      'start', jsonb_build_object('type', 'string'), 'confirmed', jsonb_build_object('type', 'boolean')))),
  jsonb_build_object('name', 'cancel_appointment', 'consequential', true, 'needs_confirmation', true,
    'description', 'Cancel one of the caller''s appointments after the caller confirms (confirmed=true).',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('appointment_id', 'confirmed'), 'properties', jsonb_build_object('appointment_id', jsonb_build_object('type', 'string'),
      'confirmed', jsonb_build_object('type', 'boolean')))),
  jsonb_build_object('name', 'take_message', 'consequential', true, 'needs_confirmation', false,
    'description', 'Take a message for the team; they will call back.',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('message'), 'properties', jsonb_build_object('message', jsonb_build_object('type', 'string'),
      'name', jsonb_build_object('type', 'string'), 'phone', jsonb_build_object('type', 'string')))),
  jsonb_build_object('name', 'report_emergency', 'consequential', true, 'needs_confirmation', false,
    'description', 'Flag an emergency to the team right away. For danger to life tell the caller to call 911 first.',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object('summary', jsonb_build_object('type', 'string')))),
  jsonb_build_object('name', 'transfer_to_human', 'consequential', true, 'needs_confirmation', false,
    'description', 'Hand the call to a person when the caller asks, or when you cannot help.',
    'parameters', jsonb_build_object('type', 'object', 'properties', jsonb_build_object('reason', jsonb_build_object('type', 'string')))),
  jsonb_build_object('name', 'request_follow_up', 'consequential', true, 'needs_confirmation', false,
    'description', 'Ask the team to follow up with the caller (call back, send details, quote).',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('reason'), 'properties', jsonb_build_object('reason', jsonb_build_object('type', 'string'),
      'when', jsonb_build_object('type', 'string', 'description', 'Optional, as the caller said it')))),
  jsonb_build_object('name', 'report_unanswered_question', 'consequential', false,
    'description', 'Log a question you could not answer from approved information, then tell the caller the team will get back to them.',
    'parameters', jsonb_build_object('type', 'object', 'required', jsonb_build_array('question'), 'properties', jsonb_build_object('question', jsonb_build_object('type', 'string'))))
);
$$;

-- ---------------------------------------------------------------------------------------------------------
-- Log of every tool use: audit trail and the memory that stops a repeated action from happening twice.
-- Arguments are stored without phone numbers, emails or free text.
-- ---------------------------------------------------------------------------------------------------------
create table if not exists public.ai_tool_calls (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_call_id text,
  tool text not null,
  idempotency_key text,
  arg_keys text[] not null default '{}',
  status text not null default 'started',
  result_status text,
  verified boolean,
  error text,
  result jsonb,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists ai_tool_calls_business_idx on public.ai_tool_calls (business_id, created_at desc);
create unique index if not exists ai_tool_calls_idem_idx on public.ai_tool_calls (business_id, idempotency_key) where idempotency_key is not null and status = 'done';
alter table public.ai_tool_calls enable row level security;
drop policy if exists ai_tool_calls_read on public.ai_tool_calls;
create policy ai_tool_calls_read on public.ai_tool_calls for select to authenticated
  using (public.is_platform_admin() or public.zella_has_role(business_id, array['owner', 'admin']));
revoke all on public.ai_tool_calls from anon;
revoke insert, update, delete on public.ai_tool_calls from authenticated;

-- ---------------------------------------------------------------------------------------------------------
-- The one door for tools.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_ai_tool(p_provider_call_id text, p_business_id uuid, p_tool text, p_args jsonb default '{}'::jsonb, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_args jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_def jsonb; v_call_biz uuid; v_biz uuid; v_tz text; v_caller text; v_cust uuid; v_n integer;
  v_cons boolean; v_needs boolean; v_key text; v_log uuid; v_prev jsonb; v_res jsonb; v_disabled jsonb; v_appt uuid;
  v_sub text; v_ok boolean; v_verified boolean; v_status text; v_err text; v_hit jsonb; v_q text; v_first text; v_last text; v_email text; v_pref text; v_task uuid; v_due timestamptz;
begin
  select d into v_def from jsonb_array_elements(public.zella_brain_tool_defs()) d where d ->> 'name' = p_tool;
  if v_def is null then return jsonb_build_object('ok', false, 'status', 'unknown_tool', 'say', 'That is not something you can do. Offer to take a message instead.'); end if;
  v_cons := coalesce((v_def ->> 'consequential')::boolean, false);
  v_needs := coalesce((v_def ->> 'needs_confirmation')::boolean, false);

  if nullif(p_provider_call_id, '') is not null then
    select c.business_id, c.from_number into v_call_biz, v_caller from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call_biz, p_business_id);
  select b.id, coalesce(b.timezone, 'America/New_York') into v_biz, v_tz from public.businesses b
   where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true);
  if v_biz is null then return jsonb_build_object('ok', false, 'status', 'unknown_business', 'say', 'This could not be completed. Say the team will call back.'); end if;
  -- the caller's number comes from the phone network (the call record or n8n), never from what is said
  v_caller := coalesce(v_caller, nullif(v_args ->> 'caller_number', ''));

  -- tools a business has switched off
  select coalesce(c.business_context -> 'disabled_tools', '[]'::jsonb) into v_disabled
    from public.ai_agents a join public.ai_agent_configs c on c.agent_id = a.id where a.business_id = v_biz and a.is_default limit 1;
  if v_disabled is not null and jsonb_typeof(v_disabled) = 'array' and v_disabled ? p_tool then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'This business does not use that. Offer to take a message instead.');
  end if;

  -- the caller must say yes before a booking, move or cancellation
  if v_needs and coalesce(v_args ->> 'confirmed', '') <> 'true' then
    return jsonb_build_object('ok', false, 'status', 'need_confirmation', 'say', 'Read the details back to the caller and ask them to confirm. Call this again with confirmed=true only after they say yes.');
  end if;

  -- repeating the same consequential action returns the first result
  v_key := case when v_cons then coalesce(nullif(p_idempotency_key, ''), md5(coalesce(p_provider_call_id, '') || '|' || p_tool || '|' || (v_args - 'confirmed' - 'caller_number')::text)) end;
  if v_key is not null then
    select l.result into v_prev from public.ai_tool_calls l where l.business_id = v_biz and l.idempotency_key = v_key and l.status = 'done' limit 1;
    if v_prev is not null then return v_prev || jsonb_build_object('repeated', true); end if;
  end if;
  insert into public.ai_tool_calls (business_id, provider_call_id, tool, idempotency_key, arg_keys)
  values (v_biz, left(p_provider_call_id, 200), p_tool, v_key, array(select jsonb_object_keys(v_args))) returning id into v_log;

  begin
    if p_tool = 'search_knowledge' then
      v_q := left(coalesce(v_args ->> 'query', ''), 300);
      v_hit := public.zella_brain_search(v_biz, v_q, 3);
      if v_hit ->> 'confidence' = 'none' then
        begin perform public.zella_report_unanswered(p_provider_call_id, v_biz, v_q); exception when others then null; end;
        v_res := jsonb_build_object('ok', true, 'status', 'no_information', 'say', 'There is no approved information about this. Do not guess. Say you will pass the question to the team and they will get back to the caller.');
      else
        v_res := jsonb_build_object('ok', true, 'status', v_hit ->> 'confidence', 'results', v_hit -> 'results',
          'say', case when v_hit ->> 'confidence' = 'confirmed' then 'Answer ONLY from these results, in your own words. Do not add details that are not in them.'
                      else 'These results may only partly answer the question. Use only what they say; for the rest say you will check with the team.' end);
      end if;

    elsif p_tool = 'check_open_hours' then
      v_res := public.zella_ai_voice(p_provider_call_id, v_biz, 'rules', v_args);
    elsif p_tool = 'take_message' then
      v_res := public.zella_ai_voice(p_provider_call_id, v_biz, 'message', v_args);
    elsif p_tool = 'report_emergency' then
      v_res := public.zella_ai_voice(p_provider_call_id, v_biz, 'emergency', v_args);
    elsif p_tool = 'transfer_to_human' then
      v_res := public.zella_ai_voice(p_provider_call_id, v_biz, 'transfer', v_args);
    elsif p_tool = 'report_unanswered_question' then
      perform public.zella_report_unanswered(p_provider_call_id, v_biz, v_args ->> 'question');
      v_res := jsonb_build_object('ok', true, 'status', 'logged', 'say', 'Tell the caller the team will get back to them with an answer.');

    elsif p_tool in ('lookup_caller', 'update_caller', 'request_follow_up') then
      -- only an exact match to exactly one customer counts as "known"
      v_cust := null; v_n := 0;
      if public.zella_digits(v_caller) is not null then
        select count(*), (array_agg(c.id))[1] into v_n, v_cust from public.customers c
         where c.business_id = v_biz and public.zella_digits(c.phone) = public.zella_digits(v_caller);
        if v_n <> 1 then v_cust := null; end if;
      end if;

      if p_tool = 'lookup_caller' then
        if v_cust is null then
          v_res := jsonb_build_object('ok', true, 'status', 'not_recognised', 'say', 'The caller is not recognised. Ask for their name. Do not guess who they are.');
        else
          select jsonb_build_object('ok', true, 'status', 'recognised', 'first_name', c.first_name,
                   'upcoming_appointments', (select count(*) from public.appointments a where a.customer_id = c.id and a.status in ('scheduled', 'confirmed') and a.start_time > now()),
                   'say', 'You may greet the caller by first name. Do not read out any other details about them.')
            into v_res from public.customers c where c.id = v_cust;
        end if;

      elsif p_tool = 'update_caller' then
        v_first := nullif(trim(left(coalesce(v_args ->> 'first_name', ''), 80)), '');
        v_last := nullif(trim(left(coalesce(v_args ->> 'last_name', ''), 80)), '');
        v_email := nullif(lower(trim(left(coalesce(v_args ->> 'email', ''), 200))), '');
        v_pref := case when v_args ->> 'preferred_contact_method' in ('call', 'sms', 'email') then v_args ->> 'preferred_contact_method' end;
        if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          v_res := jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'The email address did not look right. Ask the caller to repeat it, or skip it.');
        elsif v_cust is null then
          if v_first is null then
            v_res := jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask for the caller''s name first.');
          else
            perform public.zella_capture_lead(v_biz, v_first, v_last, coalesce(nullif(v_args ->> 'phone', ''), v_caller), v_email, 'phone_call', 'Saved by the phone assistant', null);
            v_res := jsonb_build_object('ok', true, 'status', 'saved', 'say', 'Saved. Carry on helping the caller.');
          end if;
        else
          -- a known customer: contact details can be added, but a name already on file is not overwritten by what is said on a call
          update public.customers set
                 first_name = case when nullif(first_name, '') is null then coalesce(v_first, first_name) else first_name end,
                 last_name = case when nullif(last_name, '') is null then coalesce(v_last, last_name) else last_name end,
                 email = coalesce(v_email, email),
                 preferred_contact_method = coalesce(v_pref, preferred_contact_method), updated_at = now()
           where id = v_cust and business_id = v_biz;
          v_res := jsonb_build_object('ok', true, 'status', 'saved', 'say', 'Saved. Carry on helping the caller.');
        end if;

      else -- request_follow_up
        v_q := left(regexp_replace(trim(coalesce(v_args ->> 'reason', '')), '\s+', ' ', 'g'), 400);
        if length(v_q) < 3 then
          v_res := jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller what the follow-up is for.');
        else
          v_due := now() + interval '4 hours';
          v_task := public.zella_create_task(v_biz, v_cust, 'follow_up', 'Phone assistant: follow up with caller', v_q || coalesce(E'\nCaller said: ' || nullif(left(v_args ->> 'when', 100), ''), '') || coalesce(E'\nNumber: ' || v_caller, ''),
                                               'normal', v_due, null, 'ai', null);
          v_res := jsonb_build_object('ok', true, 'status', 'requested', 'task_id', v_task, 'say', 'Tell the caller the team will follow up with them.');
        end if;
      end if;

    elsif p_tool in ('check_availability', 'book_appointment') then
      v_sub := case when p_tool = 'book_appointment' then 'book' else 'availability' end;
      v_res := public.zella_ai_booking(p_provider_call_id, v_biz, v_sub, v_args);
      -- "booked" is only said when the calendar really holds it
      if p_tool = 'book_appointment' and v_res ->> 'status' = 'booked' then
        v_appt := nullif(v_res ->> 'appointment_id', '')::uuid;
        select exists (select 1 from public.appointments a where a.id = v_appt and a.business_id = v_biz and a.status in ('scheduled', 'confirmed')) into v_verified;
        if not coalesce(v_verified, false) then
          v_res := jsonb_build_object('ok', false, 'status', 'unverified', 'say', 'The booking could not be confirmed. Do not say it is booked. Tell the caller the team will call to confirm.');
          perform public.zella_create_task(v_biz, null, 'follow_up', 'Booking could not be verified', 'A booking made by the phone assistant was not found afterwards. Caller: ' || coalesce(v_caller, 'unknown'), 'high', now() + interval '1 hour', null, 'ai', v_appt);
        end if;
      end if;

    elsif p_tool in ('find_my_appointments', 'reschedule_appointment', 'cancel_appointment') then
      v_sub := case p_tool when 'find_my_appointments' then 'find' when 'reschedule_appointment' then 'reschedule' else 'cancel' end;
      v_res := public.zella_ai_manage_booking(p_provider_call_id, v_biz, v_sub, v_args || jsonb_build_object('caller_number', v_caller));
      begin v_appt := nullif(v_args ->> 'appointment_id', '')::uuid; exception when others then v_appt := null; end;
      if v_res ->> 'status' = 'cancelled' then
        select exists (select 1 from public.appointments a where a.id = v_appt and a.business_id = v_biz and a.status = 'cancelled') into v_verified;
      elsif v_res ->> 'status' = 'rescheduled' then
        select exists (select 1 from public.appointments a where a.id = v_appt and a.business_id = v_biz and a.status in ('scheduled', 'confirmed')
                          and abs(extract(epoch from (a.start_time - nullif(v_args ->> 'start', '')::timestamptz))) < 60) into v_verified;
      end if;
      if v_verified is not null and not v_verified then
        v_res := jsonb_build_object('ok', false, 'status', 'unverified', 'say', 'The change could not be confirmed. Do not say it is done. Tell the caller the team will call to confirm.');
        perform public.zella_create_task(v_biz, null, 'follow_up', 'Appointment change could not be verified', 'A change made by the phone assistant was not found afterwards. Caller: ' || coalesce(v_caller, 'unknown'), 'high', now() + interval '1 hour', null, 'ai', v_appt);
      end if;
    end if;

    v_status := coalesce(v_res ->> 'status', 'done');
    v_ok := coalesce((v_res ->> 'ok')::boolean, false);
    update public.ai_tool_calls set status = case when v_ok then 'done' else 'failed' end,
           result_status = v_status, verified = v_verified, result = case when v_cons then v_res end, finished_at = now() where id = v_log;
    return v_res;
  exception when others then
    get stacked diagnostics v_err = message_text;
    update public.ai_tool_calls set status = 'failed', result_status = 'error', error = left(v_err, 300), finished_at = now() where id = v_log;
    return jsonb_build_object('ok', false, 'status', 'error', 'say', 'This could not be completed right now. Tell the caller the team will call them back. Do not say it was done.');
  end;
end $$;
revoke execute on function public.zella_ai_tool(text, uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.zella_ai_tool(text, uuid, text, jsonb, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- What the assistant may know about one business, and the instructions it starts with.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_brain_context(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_b record; v_ind text; v_term jsonb; v_cfg record; v_hours jsonb; v_closures jsonb; v_know jsonb; v_key text; v_disabled jsonb;
begin
  select b.* into v_b from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_b.id is null then raise exception 'UNKNOWN_BUSINESS'; end if;
  select i.name into v_ind from public.industries i where i.id = v_b.industry_id;
  select coalesce(ic.terminology, '{}'::jsonb) into v_term from public.industry_configurations ic where ic.industry_id = v_b.industry_id;
  v_term := coalesce(v_term, '{}'::jsonb) || coalesce(v_b.terminology_overrides, '{}'::jsonb);
  select a.name, c.* into v_cfg from public.ai_agents a left join public.ai_agent_configs c on c.agent_id = a.id where a.business_id = p_business_id and a.is_default limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('weekday', h.weekday, 'opens', h.opens, 'closes', h.closes) order by h.weekday, h.opens), '[]'::jsonb) into v_hours from public.business_hours h where h.business_id = p_business_id;
  select coalesce(jsonb_agg(jsonb_build_object('from', x.starts_on, 'to', x.ends_on, 'label', x.label) order by x.starts_on), '[]'::jsonb) into v_closures
    from public.business_closures x where x.business_id = p_business_id and x.ends_on >= current_date and x.starts_on <= current_date + 60;
  select coalesce(jsonb_agg(jsonb_build_object('kind', k.kind, 'title', k.title) order by k.kind, k.title), '[]'::jsonb) into v_know
    from (select kind, title from public.knowledge_items where business_id = p_business_id and status = 'ready' order by kind, title limit 60) k;
  v_key := public.zella_industry_key_for(p_business_id);
  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);
  return jsonb_build_object(
    'business', jsonb_build_object('id', v_b.id, 'name', v_b.name, 'industry', coalesce(v_ind, 'Business'), 'industry_key', v_key, 'timezone', coalesce(v_b.timezone, 'America/New_York'),
                                   'phone', v_b.phone, 'website', v_b.website, 'city', v_b.city, 'state', v_b.state),
    'terminology', v_term,
    'hours', v_hours, 'closures', v_closures,
    'agent', jsonb_build_object('name', coalesce(v_cfg.name, 'the assistant'), 'personality', v_cfg.personality, 'tone', v_cfg.tone, 'goals', v_cfg.goals,
                                'instructions', v_cfg.system_prompt, 'languages', coalesce(v_cfg.business_context -> 'languages', '["English"]'::jsonb),
                                'escalation', coalesce(v_cfg.escalation_rules, '{}'::jsonb) - 'transfer_number' - 'fallback_number' - 'transfer_to',
                                'appointment_rules', coalesce(v_cfg.appointment_rules, '{}'::jsonb)),
    'knowledge_topics', v_know,
    'tools', (select coalesce(jsonb_agg(d ->> 'name'), '[]'::jsonb) from jsonb_array_elements(public.zella_brain_tool_defs()) d where not (v_disabled ? (d ->> 'name'))));
end $$;
revoke execute on function public.zella_brain_context(uuid) from public, anon, authenticated;
grant execute on function public.zella_brain_context(uuid) to service_role;

create or replace function public.zella_brain_prompt(p_business_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  c jsonb := public.zella_brain_context(p_business_id); v_key text; t text := ''; v_term jsonb; v_cust text; v_appt text; v_days text[] := array['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday']; h record; v_lines text := '';
begin
  v_key := c #>> '{business,industry_key}';
  v_term := coalesce(c -> 'terminology', '{}'::jsonb);
  v_cust := lower(coalesce(nullif(v_term ->> 'customer', ''), 'customer'));
  v_appt := lower(coalesce(nullif(v_term ->> 'appointment', ''), 'appointment'));
  for h in select (x ->> 'weekday')::int wd, x ->> 'opens' o, x ->> 'closes' cl from jsonb_array_elements(c -> 'hours') x order by 1, 2 loop
    v_lines := v_lines || '- ' || v_days[h.wd + 1] || ': ' || left(h.o, 5) || ' to ' || left(h.cl, 5) || E'\n';
  end loop;

  t := 'You are ' || (c #>> '{agent,name}') || ', the phone receptionist for ' || (c #>> '{business,name}') || ' (' || (c #>> '{business,industry}') || E'). You speak with callers on the phone.\n\n'
    || coalesce('Personality: ' || nullif(c #>> '{agent,personality}', '') || E'\n', '') || coalesce('Tone: ' || nullif(c #>> '{agent,tone}', '') || E'\n', '')
    || E'Keep replies short and natural, one question at a time. Say "' || v_cust || '" and "' || v_appt || E'" the way this business does.\n\n'
    || E'WHAT IS TRUE\n'
    || E'- Facts about the business (services, prices, policies) come ONLY from the search_knowledge tool. If it finds nothing, do not guess: say you will pass the question to the team, and use report_unanswered_question.\n'
    || E'- Never invent prices, availability, policies, services, staff names or promises. Prices are quoted only when the knowledge says so.\n'
    || E'- Offer appointment times ONLY from check_availability.\n'
    || E'- Time zone: ' || (c #>> '{business,timezone}') || E'. Opening hours:\n' || coalesce(nullif(v_lines, ''), E'- not set; use check_open_hours\n')
    || E'\nWHAT YOU DO\n'
    || E'- Before booking, moving or cancelling: read the details back and ask the caller to confirm. Only then call the tool with confirmed=true.\n'
    || E'- Say an appointment is booked, moved or cancelled ONLY when the tool result says so. If the result says requested, unverified, error or unavailable, say exactly that: the team will confirm or call back. Never say it is done on your own.\n'
    || E'- You recognise the caller only through lookup_caller (their phone number). Never reveal anything about other callers, and tell a recognised caller nothing beyond their first name and their own appointments.\n'
    || E'- If the caller asks for a person, is upset, or you cannot help, use transfer_to_human. If a tool fails, apologise briefly and offer a callback (request_follow_up or take_message).\n'
    || E'- Do not send or promise promotional messages, discounts or offers.\n\n'
    || E'SAFETY\n'
    || E'- If anyone is in danger of harm, tell them to hang up and call 911 first, then use report_emergency.\n'
    || case
         when v_key in ('dental', 'healthcare') then E'- You are not a clinician: never diagnose, advise on treatment, medication or symptoms, or say whether something is serious. For urgent symptoms, follow the emergency step above; otherwise book a visit or offer a callback from the team.\n- Do not promise insurance coverage or outcomes.\n'
         when v_key in ('plumbing', 'electrical', 'hvac', 'home_services', 'automotive') then E'- Never promise an arrival time or response time for emergencies; say the team will call right away. For gas smell, fire, flooding or electrical sparks, tell the caller to get to safety and call 911 or the utility first, then use report_emergency.\n- Give no quote unless the knowledge provides one; offer an estimate visit instead.\n'
         when v_key in ('legal', 'financial_services') then E'- You give no legal, tax or financial advice and do not judge anyone''s case. You can book a consultation or take a message.\n'
         when v_key = 'real_estate' then E'- Do not state property prices, availability or legal terms unless the knowledge says so; offer to book a viewing or have an agent call.\n'
         when v_key = 'pet_care' then E'- You are not a vet: never diagnose or advise on a pet''s symptoms, food or medication. If a pet seems in serious trouble, say to call an emergency vet now and use report_emergency.\n'
         when v_key = 'spa_wellness' then E'- Give no medical or health advice and make no treatment-result promises; for health questions offer a callback from the team.\n'
         when v_key = 'childcare' then E'- Never share any detail about a child, including whether they attend, with anyone you cannot verify as their parent or guardian; take a message instead.\n'
         when v_key = 'pest_control' then E'- For stinging insects, infestations in food areas or any danger to people, say the team will call right away and use report_emergency; never advise on handling chemicals.\n'
         else '' end
    || coalesce(E'\nBUSINESS-SPECIFIC INSTRUCTIONS FROM THE OWNER\n' || nullif(c #>> '{agent,instructions}', '') || E'\n', '')
    || case when jsonb_array_length(c -> 'closures') > 0 then E'\nUpcoming closures: ' || (select string_agg((x ->> 'label') || ' (' || (x ->> 'from') || ' to ' || (x ->> 'to') || ')', ', ') from jsonb_array_elements(c -> 'closures') x) || E'\n' else '' end
    || E'\nThe business can answer questions about: ' || coalesce((select string_agg(distinct x ->> 'title', '; ') from (select x from jsonb_array_elements(c -> 'knowledge_topics') x limit 40) y(x)), 'nothing has been added yet') || E'. Use search_knowledge for the details.\n';
  return t;
end $$;
revoke execute on function public.zella_brain_prompt(uuid) from public, anon, authenticated;
grant execute on function public.zella_brain_prompt(uuid) to service_role;

-- The assistant definition for Vapi, built from the above. Nothing is sent anywhere from here.
create or replace function public.zella_assistant_config(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.zella_brain_context(p_business_id); v_url text := nullif(public.zella_setting('brain_tools_url', 'null'::jsonb) #>> '{}', 'null');
begin
  return jsonb_build_object(
    'name', left((c #>> '{business,name}') || ' receptionist', 40),
    'firstMessage', 'Thank you for calling ' || (c #>> '{business,name}') || '. How can I help you?',
    'model', jsonb_build_object('provider', public.zella_setting('voice_llm_provider', '"anthropic"'::jsonb) #>> '{}',
                                'model', public.zella_setting('voice_llm_model', '"claude-sonnet-5-5"'::jsonb) #>> '{}',
                                'messages', jsonb_build_array(jsonb_build_object('role', 'system', 'content', public.zella_brain_prompt(p_business_id))),
                                'temperature', 0.3),
    'metadata', jsonb_build_object('business_id', p_business_id),
    'tools', (select coalesce(jsonb_agg(jsonb_build_object('type', 'function',
                 'function', jsonb_build_object('name', d ->> 'name', 'description', d ->> 'description', 'parameters', d -> 'parameters'),
                 'server', jsonb_build_object('url', v_url)) order by d ->> 'name'), '[]'::jsonb)
                from jsonb_array_elements(public.zella_brain_tool_defs()) d where (c -> 'tools') ? (d ->> 'name')),
    'ready_to_send', v_url is not null);
end $$;
revoke execute on function public.zella_assistant_config(uuid) from public, anon, authenticated;
grant execute on function public.zella_assistant_config(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- Accuracy checks: saved questions with what the answer must (or must not) contain, run against the business's own approved facts.
-- ---------------------------------------------------------------------------------------------------------
create table if not exists public.ai_eval_cases (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  question text not null,
  expect_contains text[] not null default '{}',
  expect_none boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.ai_eval_cases enable row level security;
drop policy if exists ai_eval_cases_all on public.ai_eval_cases;
create policy ai_eval_cases_all on public.ai_eval_cases for all to authenticated
  using (public.is_platform_admin() or public.zella_has_role(business_id, array['owner', 'admin']))
  with check (public.is_platform_admin() or public.zella_has_role(business_id, array['owner', 'admin']));
revoke all on public.ai_eval_cases from anon;

create or replace function public.zella_brain_run_evals(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e record; r jsonb; v_pass boolean; v_text text; v_total int := 0; v_passed int := 0; v_failed jsonb := '[]'::jsonb; w text;
begin
  if not (auth.role() = 'service_role' or public.is_platform_admin() or public.zella_has_role(p_business_id, array['owner', 'admin'])) then raise exception 'NOT_ALLOWED'; end if;
  for e in select * from public.ai_eval_cases where business_id = p_business_id order by created_at loop
    v_total := v_total + 1;
    r := public.zella_brain_search(p_business_id, e.question, 3);
    if e.expect_none then
      v_pass := r ->> 'confidence' = 'none';
    else
      v_text := lower(coalesce((r -> 'results' -> 0 ->> 'answer'), '') || ' ' || coalesce((r -> 'results' -> 0 ->> 'title'), ''));
      v_pass := r ->> 'confidence' <> 'none';
      foreach w in array e.expect_contains loop
        if position(lower(w) in v_text) = 0 then v_pass := false; end if;
      end loop;
    end if;
    if v_pass then v_passed := v_passed + 1; else v_failed := v_failed || jsonb_build_array(jsonb_build_object('question', e.question, 'confidence', r ->> 'confidence')); end if;
  end loop;
  return jsonb_build_object('total', v_total, 'passed', v_passed, 'failed', v_failed);
end $$;
revoke execute on function public.zella_brain_run_evals(uuid) from public, anon;
grant execute on function public.zella_brain_run_evals(uuid) to authenticated, service_role;

-- Owners and admins can see what the assistant did (arguments are never stored).
create or replace function public.zella_ai_tool_log(p_business_id uuid, p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.is_platform_admin() or public.zella_has_role(p_business_id, array['owner', 'admin'])) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', l.created_at, 'tool', l.tool, 'status', l.status, 'result', l.result_status, 'verified', l.verified, 'error', l.error) order by l.created_at desc)
                     from (select * from public.ai_tool_calls where business_id = p_business_id order by created_at desc limit greatest(1, least(coalesce(p_limit, 50), 200))) l), '[]'::jsonb);
end $$;
revoke execute on function public.zella_ai_tool_log(uuid, integer) from public, anon;
grant execute on function public.zella_ai_tool_log(uuid, integer) to authenticated, service_role;
