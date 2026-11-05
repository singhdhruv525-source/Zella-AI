-- AI receptionist: saving the caller (update_caller), found by the end-to-end launch workflow test (5 Nov 2026).
--
-- What was wrong:
--   1. The tool tells the assistant the caller may choose "call, text or email", but only 'call', 'sms' and 'email' were
--      accepted, so "text" was silently dropped; and 'call' is not an allowed value of the column (it is 'voice'), so an
--      existing caller who asked to be called made the save fail and the assistant say it couldn't be done.
--   2. A new caller's preference was never saved at all (only the name, phone and email went into the new lead).
--   3. The preference went to preferred_contact_method, but texts and emails choose their channel from
--      preferred_channel: a caller who said "email me" was still texted.
--   4. The call being handled was linked to the caller only when it ended, so the team watching a live call saw no name.
-- After this: call → voice, text / sms → sms, email → email; saved for new and existing callers; "text" and "email"
-- also set the channel messages use; the live call is linked to the caller at once.
-- Safe to run twice. Changes what the AI receptionist's tool does from the next call: needs the owner's approval.

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_ai_tool(text, uuid, text, jsonb, text)'::regprocedure);
  if position('zella_ai_caller_fixes' in def) > 0 then return; end if;

  def := replace(def, $a$v_pref := case when v_args ->> 'preferred_contact_method' in ('call', 'sms', 'email') then v_args ->> 'preferred_contact_method' end;$a$,
    $a$v_pref := case lower(coalesce(v_args ->> 'preferred_contact_method', '')) when 'call' then 'voice' when 'phone' then 'voice' when 'voice' then 'voice'
                      when 'text' then 'sms' when 'sms' then 'sms' when 'email' then 'email' end; /* zella_ai_caller_fixes */$a$);

  def := replace(def, $a$            perform public.zella_capture_lead(v_biz, v_first, v_last, coalesce(nullif(v_args ->> 'phone', ''), v_caller), v_email, 'phone_call', 'Saved by the phone assistant', null);
            v_res := jsonb_build_object('ok', true, 'status', 'saved', 'say', 'Saved. Carry on helping the caller.');$a$,
    $a$            v_cust := nullif(public.zella_capture_lead(v_biz, v_first, v_last, coalesce(nullif(v_args ->> 'phone', ''), v_caller), v_email, 'phone_call', 'Saved by the phone assistant', null) ->> 'customer_id', '')::uuid;
            if v_cust is not null then
              update public.customers set preferred_contact_method = coalesce(v_pref, preferred_contact_method),
                     preferred_channel = case when v_pref in ('sms', 'email') then v_pref else preferred_channel end, updated_at = now()
               where id = v_cust and business_id = v_biz;
              update public.calls set customer_id = v_cust, updated_at = now()
               where external_call_id = p_provider_call_id and business_id = v_biz and customer_id is null;
            end if;
            v_res := jsonb_build_object('ok', true, 'status', 'saved', 'say', 'Saved. Carry on helping the caller.');$a$);

  def := replace(def, $a$                 preferred_contact_method = coalesce(v_pref, preferred_contact_method), updated_at = now()
           where id = v_cust and business_id = v_biz;$a$,
    $a$                 preferred_contact_method = coalesce(v_pref, preferred_contact_method),
                 preferred_channel = case when v_pref in ('sms', 'email') then v_pref else preferred_channel end, updated_at = now()
           where id = v_cust and business_id = v_biz;
          update public.calls set customer_id = v_cust, updated_at = now()
           where external_call_id = p_provider_call_id and business_id = v_biz and customer_id is null;$a$);

  if position('zella_ai_caller_fixes' in def) = 0 or position('preferred_channel = case when v_pref' in def) = 0
     or (length(def) - length(replace(def, 'update public.calls set customer_id = v_cust', ''))) / length('update public.calls set customer_id = v_cust') <> 2 then
    raise exception 'zella_ai_tool has changed; review this patch';
  end if;
  execute def;
end $$;

-- 5. A caller who asked for a call back and was new: the end of the call created the callback first and the lead after
--    it, so the callback showed only a phone number, apart from the lead. Now the callback (and anything else made for
--    this call, such as a message) is linked to the lead as soon as it exists.
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_record_inbound_call(text, text, text, text, timestamptz, timestamptz, integer, text, text, text, text, boolean)'::regprocedure);
  if position('zella_ai_caller_fixes_callback' in def) > 0 then return; end if;
  def := replace(def, $a$    v_cust := nullif(v_lead ->> 'customer_id', '')::uuid;
  end if;$a$, $a$    v_cust := nullif(v_lead ->> 'customer_id', '')::uuid;
    /* zella_ai_caller_fixes_callback */
    if v_cust is not null then
      update public.callbacks set customer_id = v_cust where call_id = c.id and customer_id is null;
      update public.call_messages set customer_id = v_cust where call_id = c.id and customer_id is null;
    end if;
  end if;$a$);
  if position('zella_ai_caller_fixes_callback' in def) = 0 then raise exception 'zella_record_inbound_call has changed; review this patch'; end if;
  execute def;
end $$;

-- 6. A business that doesn't take bookings (e-commerce, or any business with Appointments switched off) still had the
--    assistant offer times: the database then refused the booking mid-call and the caller heard it couldn't be
--    confirmed. Found by the 28-industry launch checks (tests/workflows/industry_matrix.mjs). Now the scheduling tools
--    are left out of the assistant's tool list and refused if called; finding and cancelling existing bookings still
--    works (earlier bookings are kept when bookings are switched off).
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_ai_tool(text, uuid, text, jsonb, text)'::regprocedure);
  if position('zella_ai_caller_fixes_scheduling' in def) = 0 then
    def := replace(def, $a$  if v_disabled is not null and jsonb_typeof(v_disabled) = 'array' and v_disabled ? p_tool then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'This business does not use that. Offer to take a message instead.');
  end if;$a$, $a$  if v_disabled is not null and jsonb_typeof(v_disabled) = 'array' and v_disabled ? p_tool then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'This business does not use that. Offer to take a message instead.');
  end if;
  /* zella_ai_caller_fixes_scheduling */
  if p_tool in ('check_availability', 'book_appointment', 'reschedule_appointment') and not public.zella_capability_on(v_biz, 'scheduling') then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'This business does not take bookings by phone. Offer to take a message for the team instead.');
  end if;$a$);
    if position('zella_ai_caller_fixes_scheduling' in def) = 0 then raise exception 'zella_ai_tool has changed; review this patch'; end if;
    execute def;
  end if;

  def := pg_get_functiondef('public.zella_brain_context(uuid)'::regprocedure);
  if position('zella_ai_caller_fixes_scheduling' in def) = 0 then
    def := replace(def, $a$  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);$a$,
      $a$  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);
  /* zella_ai_caller_fixes_scheduling */
  if not public.zella_capability_on(p_business_id, 'scheduling') then v_disabled := v_disabled || '["check_availability", "book_appointment", "reschedule_appointment"]'::jsonb; end if;$a$);
    if position('zella_ai_caller_fixes_scheduling' in def) = 0 then raise exception 'zella_brain_context has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
