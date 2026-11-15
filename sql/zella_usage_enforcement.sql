-- Zella Voice: usage limits that actually act, behind two switches that stay OFF until the owner approves each one.
--   calls     at 100% of minutes, a new call is forwarded to the business's own phone number (businesses.phone), unless
--             the business chose pay as you go (business_usage_preferences.overage_mode pay_as_you_go or auto_top_up, and a per minute rate on
--             its plan). A paused, cancelled or unpaid business is forwarded the same way. A call already in progress is
--             never cut off; with no valid number to forward to, the call is answered as before (a call is never dropped).
--   messages  at 100% of texts or emails, routine messages to customers stop; appointment confirmations and reminders
--             keep going from the 5% reserve until it is used too (D-43). Stopped messages are reported with the reason
--             allowance_used, like any other refusal, and nothing is lost: the item stays in its queue as refused.
-- Supabase decides; nothing else does. The decision is made where every call and every message already passes:
--   zella_assistant_for_call (the start of every call: voice-rules asks it what to do) and zella_prepare_sms /
--   zella_prepare_email (every text and email to a customer). Each patch is version guarded (zella_patch_function:
--   changed only if its anchor is there exactly once) and safe to run twice.
-- Switches: platform_settings.usage_enforcement = {"calls": false, "messages": false}. While a switch is off, the gate
-- still reports what it would do (would_forward, would_block) so admins can see the effect before switching on.
-- voice-rules answers a forward with Vapi's transfer destination (web/supabase/functions/voice-rules/logic.ts); that
-- edge change needs its own deploy with approval and a staging call before the calls switch is turned on.
-- Rollback: sql/rollback/zella_usage_enforcement_rollback.sql
begin;

do $$ begin
  if to_regprocedure('public.zella_call_entitlement_check(uuid)') is null or to_regprocedure('public.zella_message_allowance(uuid,text,text)') is null
     or to_regprocedure('public.zella_billing_plan_current(uuid)') is null
     or to_regprocedure('public.zella_assistant_for_call(text,text,text)') is null or to_regprocedure('public.zella_prepare_sms(uuid,uuid,text,jsonb,text)') is null
     or to_regprocedure('public.zella_prepare_email(uuid,uuid,text,jsonb,text)') is null or to_regprocedure('public.zella_patch_function(text,text,text,text)') is null
     or to_regclass('public.business_usage_preferences') is null then
    raise exception 'VERSION_MISMATCH: a function this file needs is missing (apply sql/zella_billing_allowances.sql first)';
  end if;
end $$;

insert into public.platform_settings (key, value) values ('usage_enforcement', '{"calls": false, "messages": false}'::jsonb) on conflict (key) do nothing;

create or replace function public.zella_usage_enforced(p_what text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (value ->> p_what)::boolean from public.platform_settings where key = 'usage_enforcement' and jsonb_typeof(value) = 'object'), false)
$$;

-- The decision for a new call: answer, or forward to the business's own number.
create or replace function public.zella_call_gate(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e jsonb; v_payg boolean; v_raw text; v_digits text; v_number text; v_stop boolean; v_reason text;
begin
  e := public.zella_call_entitlement_check(p_business_id);
  if e ->> 'status' = 'inactive' then v_stop := true; v_reason := e ->> 'reason';
  elsif e ->> 'status' = 'exhausted' then
    select coalesce(u.overage_mode, 'stop') in ('pay_as_you_go', 'auto_top_up') into v_payg from public.business_usage_preferences u where u.business_id = p_business_id;
    v_payg := coalesce(v_payg, false) and coalesce((public.zella_billing_plan_current(p_business_id)).overage_cents_per_minute, 0) > 0;
    v_stop := not v_payg; v_reason := case when v_payg then 'pay_as_you_go' else 'allowance_used' end;
  else
    v_stop := false; v_reason := coalesce(e ->> 'reason', e ->> 'status');   -- within allowance, not configured or unknown: answer as before
  end if;
  if v_stop then
    select phone into v_raw from public.businesses where id = p_business_id;
    v_digits := regexp_replace(coalesce(v_raw, ''), '\D', '', 'g');
    v_number := case when v_raw like '+%' and length(v_digits) between 8 and 15 then '+' || v_digits
                     when length(v_digits) = 10 then '+1' || v_digits
                     when length(v_digits) = 11 and left(v_digits, 1) = '1' then '+' || v_digits end;
  end if;
  return jsonb_build_object(
    'action', case when v_stop and v_number is not null and public.zella_usage_enforced('calls') then 'forward' else 'answer' end,
    'enforced', public.zella_usage_enforced('calls'), 'would_forward', coalesce(v_stop, false) and v_number is not null,
    'reason', case when v_stop and v_number is null then 'no_number_to_forward_to' else v_reason end, 'number', v_number);
end $$;

-- The decision for a text or email to a customer: appointment messages may use the 5% reserve; routine ones stop at 100%.
create or replace function public.zella_message_gate(p_business_id uuid, p_channel text, p_template_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_kind text := case when coalesce(p_template_key, '') ~ '^(appointment|confirmation|reminder|resched)' then 'appointment' else 'routine' end;
        a jsonb; v_block boolean;
begin
  a := public.zella_message_allowance(p_business_id, p_channel, v_kind);
  v_block := coalesce((a ->> 'would_permit')::boolean, true) = false;   -- not configured: never blocked
  return jsonb_build_object('allow', not (v_block and public.zella_usage_enforced('messages')), 'enforced', public.zella_usage_enforced('messages'),
    'would_block', v_block, 'kind', v_kind, 'reason', a ->> 'reason');
end $$;

revoke all on function public.zella_usage_enforced(text) from public, anon, authenticated;
revoke all on function public.zella_call_gate(uuid) from public, anon, authenticated;
revoke all on function public.zella_message_gate(uuid,text,text) from public, anon, authenticated;
grant execute on function public.zella_usage_enforced(text) to service_role;
grant execute on function public.zella_call_gate(uuid) to service_role;
grant execute on function public.zella_message_gate(uuid,text,text) to service_role;

-- a forwarded call is recorded like any other delivery
do $$ declare c text; begin
  select conname into c from pg_constraint where conrelid = 'public.assistant_deliveries'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%outcome%';
  if c is not null and position('forwarded_usage' in pg_get_constraintdef((select oid from pg_constraint where conname = c and conrelid = 'public.assistant_deliveries'::regclass))) = 0 then
    execute format('alter table public.assistant_deliveries drop constraint %I', c);
    alter table public.assistant_deliveries add constraint assistant_deliveries_outcome_check
      check (outcome in ('served', 'not_ready', 'unknown_number', 'forwarded_usage'));
  end if;
end $$;

do $$ declare r text; begin
  -- every call: ask the gate before building the assistant
  r := public.zella_patch_function('public.zella_assistant_for_call(text,text,text)', 'v_gate jsonb;',
         'v_cfg jsonb; v_version uuid;', 'v_cfg jsonb; v_version uuid; v_gate jsonb;');
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_assistant_for_call declare (%)', r; end if;
  r := public.zella_patch_function('public.zella_assistant_for_call(text,text,text)', '/* zella_usage_enforcement */',
         '  v_cfg := public.zella_assistant_config(v_biz);',
         '  v_gate := public.zella_call_gate(v_biz);   /* zella_usage_enforcement */
  if v_gate ->> ''action'' = ''forward'' then
    insert into assistant_deliveries (business_id, provider_call_id, outcome) values (v_biz, left(p_provider_call_id, 120), ''forwarded_usage'');
    return jsonb_build_object(''ok'', false, ''outcome'', ''forward'', ''reason'', v_gate ->> ''reason'', ''forward_number'', v_gate ->> ''number'');
  end if;
  v_cfg := public.zella_assistant_config(v_biz);');
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_assistant_for_call (%)', r; end if;
  -- every text and email to a customer
  r := public.zella_patch_function('public.zella_prepare_sms(uuid,uuid,text,jsonb,text)', '/* zella_usage_enforcement */',
         '    return jsonb_build_object(''allowed'', false, ''reason'', ''business_not_available'', ''live'', v_live);
  end if;',
         '    return jsonb_build_object(''allowed'', false, ''reason'', ''business_not_available'', ''live'', v_live);
  end if;
  if not (public.zella_message_gate(p_business_id, ''sms'', p_template_key) ->> ''allow'')::boolean then   /* zella_usage_enforcement */
    return jsonb_build_object(''allowed'', false, ''reason'', ''allowance_used'', ''live'', v_live);
  end if;');
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_prepare_sms (%)', r; end if;
  r := public.zella_patch_function('public.zella_prepare_email(uuid,uuid,text,jsonb,text)', '/* zella_usage_enforcement */',
         '    return jsonb_build_object(''allowed'', false, ''reason'', ''business_not_available'', ''live'', v_live);
  end if;',
         '    return jsonb_build_object(''allowed'', false, ''reason'', ''business_not_available'', ''live'', v_live);
  end if;
  if not (public.zella_message_gate(p_business_id, ''email'', p_template_key) ->> ''allow'')::boolean then   /* zella_usage_enforcement */
    return jsonb_build_object(''allowed'', false, ''reason'', ''allowance_used'', ''live'', v_live);
  end if;');
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_prepare_email (%)', r; end if;
end $$;

commit;
