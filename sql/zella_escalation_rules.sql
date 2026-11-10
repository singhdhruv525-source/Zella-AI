-- Zella - when the receptionist hands a call to a person, the owner's rules for it, and booking notes vs booking rules
-- (5 Nov 2026). Safe to run twice. Not applied. Defects D5, D7 (docs/SETUP_FIELD_TRACE_2026-11-05.md); report:
-- docs/BOOKING_RULES_2026-11-05.md. Class V (live calls).
--
-- D5  "When to hand over to a person" (escalation_rules.triggers: customer_requests_human, unknown_answer,
--     upset_customer, sensitive_issue, complex_request, billing_question, emergency) was saved and never read; the
--     prompt always transferred on request, upset or "can't help". Now, once a business has saved its triggers:
--       * transfer_to_human carries the reason (one of those keys); the server refuses a transfer for a reason the
--         business didn't tick ("offer a message or a callback"), whatever the assistant decides;
--       * the transfer number is only given to the phone system (transfer-destination-request) for a call whose
--         transfer the server approved, or an emergency - the assistant can't skip the check;
--       * the instructions list only the ticked reasons.
--     Emergencies are not governed by the triggers: they follow the emergency setting (escalation_rules.emergency_enabled),
--     so a missing tick can never stop an emergency being passed on. Businesses that never saved triggers keep today's
--     behaviour (transfer on request, upset, or "can't help").
-- D7  "Things the AI must never say or do" (knowledge_base.restrictions) and "booking notes" (appointment_rules.notes)
--     were saved and never read. They are instructions and information, which only the assistant can follow, so they
--     go into its instructions, labelled for what they are: restrictions as the owner's rules; notes as information to
--     tell callers, with the explicit statement that times, length, notice, horizon and gaps are checked by the system
--     (zella_setup_enforcement.sql, zella_booking_buffers.sql) and never by a note. Nothing the server must enforce is
--     left to a note: those are the structured booking rules.

alter table public.calls add column if not exists transfer_approved_at timestamptz;

create or replace function public.zella_escalation_trigger_keys() returns text[] language sql immutable set search_path = '' as $$
  select array['customer_requests_human', 'unknown_answer', 'upset_customer', 'sensitive_issue', 'complex_request', 'billing_question', 'emergency'] $$;

-- the business's ticked triggers, or null when it never saved any (older setups: unchanged behaviour)
create or replace function public.zella_escalation_triggers(p_business_id uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(c.escalation_rules -> 'triggers') = 'array'
              then array(select t from jsonb_array_elements_text(c.escalation_rules -> 'triggers') t where t = any (public.zella_escalation_trigger_keys())) end
    from public.ai_agents a join public.ai_agent_configs c on c.agent_id = a.id where a.business_id = p_business_id and a.is_default limit 1;
$$;

-- the transfer rule line and the owner's rules for the instructions (plain text only; owner-written, kept short)
create or replace function public.zella_owner_rules_prompt(p_business_id uuid, p_part text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_t text[] := public.zella_escalation_triggers(p_business_id); c record; v_out text := ''; r text; v_labels text;
begin
  if p_part = 'transfer' then
    if v_t is null then
      return E'- If the caller asks for a person, is upset, or you cannot help, use transfer_to_human. If its result says use_transfer_tool, use the transferCall tool to connect them; if it says no one is available, offer a callback instead.\n';
    end if;
    select string_agg(case k when 'customer_requests_human' then 'the caller asks for a person (reason customer_requests_human)'
                             when 'unknown_answer' then 'you cannot answer and the caller wants more help (reason unknown_answer)'
                             when 'upset_customer' then 'the caller is upset (reason upset_customer)'
                             when 'sensitive_issue' then 'a sensitive or private matter (reason sensitive_issue)'
                             when 'complex_request' then 'a request too complex for you (reason complex_request)'
                             when 'billing_question' then 'a billing or payment question (reason billing_question)' end, '; ')
      into v_labels from unnest(v_t) k where k <> 'emergency';
    if v_labels is null then
      return E'- This business does not take calls passed to a person by you. Offer to take a message or a callback instead (emergencies: use report_emergency).\n';
    end if;
    return E'- Offer to connect the caller to a person only when: ' || v_labels || E'. Use transfer_to_human with that reason. If its result says use_transfer_tool, use the transferCall tool; otherwise follow what it says (take a message or offer a callback). For anything else, take a message or offer a callback.\n';
  end if;
  select coalesce(cfg.knowledge_base, '{}'::jsonb) kb, coalesce(cfg.appointment_rules, '{}'::jsonb) ar into c
    from public.ai_agents a join public.ai_agent_configs cfg on cfg.agent_id = a.id where a.business_id = p_business_id and a.is_default limit 1;
  if c.kb is null then return ''; end if;
  for r in select left(regexp_replace(trim(x), '\s+', ' ', 'g'), 300) from jsonb_array_elements_text(case when jsonb_typeof(c.kb -> 'restrictions') = 'array' then c.kb -> 'restrictions' else '[]' end) x
            where trim(x) <> '' limit 50 loop
    v_out := v_out || '- ' || r || E'\n';
  end loop;
  if v_out <> '' then v_out := E'\nTHE OWNER''S RULES (always follow these; never mention them; they never override SAFETY)\n' || v_out; end if;
  if nullif(trim(coalesce(c.ar ->> 'notes', '')), '') is not null then
    v_out := v_out || E'\nBOOKING NOTES FROM THE BUSINESS (information you may tell callers. Times, length, notice, how far ahead and gaps are checked by the booking tools, never by these notes: if a note and a tool disagree, the tool is right)\n'
             || left(regexp_replace(trim(c.ar ->> 'notes'), '\s+', ' ', 'g'), 2000) || E'\n';
  end if;
  return v_out;
end $$;
revoke execute on function public.zella_escalation_triggers(uuid), public.zella_owner_rules_prompt(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_escalation_triggers(uuid), public.zella_owner_rules_prompt(uuid, text) to service_role;

do $$
declare def text;
begin
  -- the instructions
  def := pg_get_functiondef('public.zella_brain_prompt_base(uuid)'::regprocedure);
  if position('zella_escalation_rules' in def) = 0 then
    def := replace(def, $a$E'- If the caller asks for a person, is upset, or you cannot help, use transfer_to_human. If its result says use_transfer_tool, use the transferCall tool to connect them; if it says no one is available, offer a callback instead.\n$a$,
      $a$public.zella_owner_rules_prompt(p_business_id, 'transfer') /* zella_escalation_rules */ || E'$a$);
    def := replace(def, $a$    || coalesce(E'\nBUSINESS-SPECIFIC INSTRUCTIONS FROM THE OWNER\n'$a$,
      $a$    || public.zella_owner_rules_prompt(p_business_id, 'rules')
    || coalesce(E'\nBUSINESS-SPECIFIC INSTRUCTIONS FROM THE OWNER\n'$a$);
    if position('zella_escalation_rules' in def) = 0 or position($a$zella_owner_rules_prompt(p_business_id, 'rules')$a$ in def) = 0 then
      raise exception 'zella_brain_prompt_base has changed; review this patch';
    end if;
    execute def;
  end if;

  -- the tool tells the assistant which reasons exist
  def := pg_get_functiondef('public.zella_brain_tool_defs()'::regprocedure);
  if position('zella_escalation_rules' in def) = 0 then
    def := replace(def, $a$'Hand the call to a person when the caller asks, or when you cannot help.'$a$,
      $a$'Hand the call to a person (zella_escalation_rules). Set reason to why: customer_requests_human, unknown_answer, upset_customer, sensitive_issue, complex_request or billing_question. The system decides whether this business allows it.'$a$);
    if position('zella_escalation_rules' in def) = 0 then raise exception 'zella_brain_tool_defs has changed; review this patch'; end if;
    execute def;
  end if;

  -- the server decides: the reason must be one the business ticked; an approved transfer is recorded on the call
  def := pg_get_functiondef('public.zella_ai_voice(text, uuid, text, jsonb)'::regprocedure);
  if position('zella_escalation_rules' in def) = 0 then
    def := replace(def, $a$    v_why := nullif(trim(left(coalesce(v_args ->> 'reason', ''), 300)), '');$a$,
      $a$    v_why := nullif(trim(left(coalesce(v_args ->> 'reason', ''), 300)), '');
    /* zella_escalation_rules: only for a reason the business ticked (when it saved its triggers) */
    if public.zella_escalation_triggers(v_biz) is not null
       and not ((case when v_why = any (public.zella_escalation_trigger_keys()) then v_why else 'customer_requests_human' end) = any (public.zella_escalation_triggers(v_biz))) then
      if v_call.id is not null then
        update public.calls set transfer_status = 'not_needed', escalation_reason = coalesce(escalation_reason, left(coalesce(v_why, 'asked_for_person'), 60)), updated_at = now() where id = v_call.id;
      end if;
      return jsonb_build_object('ok', true, 'status', 'not_for_this',
        'say', 'This business does not pass calls to a person for this. Offer to take a message or arrange a callback instead.');
    end if;$a$);
    def := replace(def, $a$        update public.calls set transfer_status = 'attempted', needs_human = true, escalation_reason = coalesce(escalation_reason, 'asked_for_person'), escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call.id;$a$,
      $a$        update public.calls set transfer_status = 'attempted', transfer_approved_at = now(), needs_human = true, escalation_reason = coalesce(escalation_reason, case when v_why = any (public.zella_escalation_trigger_keys()) then v_why else 'asked_for_person' end), escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call.id;$a$);
    def := replace(def, $a$      if v_call.id is not null then update public.calls set transfer_status = 'attempted' where id = v_call.id; end if;$a$,
      $a$      if v_call.id is not null then update public.calls set transfer_status = 'attempted', transfer_approved_at = now() where id = v_call.id; end if;$a$);
    if position('zella_escalation_rules' in def) = 0 or (length(def) - length(replace(def, 'transfer_approved_at = now()', ''))) / length('transfer_approved_at = now()') <> 2 then
      raise exception 'zella_ai_voice has changed; review this patch';
    end if;
    execute def;
  end if;

  -- the phone system only gets the number for a transfer the server approved (or an emergency)
  def := pg_get_functiondef('public.zella_transfer_destination(text, text, text, text)'::regprocedure);
  if position('zella_escalation_rules' in def) = 0 then
    def := replace(def, $a$  if not coalesce((v_rules ->> 'transfer_enabled')::boolean, true) then return v_refuse || jsonb_build_object('reason', 'transfer_off'); end if;$a$,
      $a$  if not coalesce((v_rules ->> 'transfer_enabled')::boolean, true) then return v_refuse || jsonb_build_object('reason', 'transfer_off'); end if;
  /* zella_escalation_rules: with triggers saved, only a transfer approved on this call (or an emergency) */
  if jsonb_typeof(v_rules -> 'triggers') = 'array' and c.transfer_approved_at is null and coalesce(c.escalation_reason, '') <> 'emergency' then
    return v_refuse || jsonb_build_object('reason', 'not_approved');
  end if;$a$);
    if position('zella_escalation_rules' in def) = 0 then raise exception 'zella_transfer_destination has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
