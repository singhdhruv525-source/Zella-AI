-- Undoes sql/zella_usage_enforcement.sql: takes the gate out of zella_assistant_for_call, zella_prepare_sms and
-- zella_prepare_email (exact reverse of each patch; refuses if a function was changed differently since), puts the
-- assistant_deliveries outcomes back, and drops the gate functions and the switch. Safe to run twice.
begin;
do $$
declare d text; f text; v_fwd int;
  ins_call text := '  v_gate := public.zella_call_gate(v_biz);   /* zella_usage_enforcement */
  if v_gate ->> ''action'' = ''forward'' then
    insert into assistant_deliveries (business_id, provider_call_id, outcome) values (v_biz, left(p_provider_call_id, 120), ''forwarded_usage'');
    return jsonb_build_object(''ok'', false, ''outcome'', ''forward'', ''reason'', v_gate ->> ''reason'', ''forward_number'', v_gate ->> ''number'');
  end if;
';
  ins_msg text;
begin
  if to_regprocedure('public.zella_assistant_for_call(text,text,text)') is not null then
    d := pg_get_functiondef('public.zella_assistant_for_call(text,text,text)'::regprocedure);
    if position('zella_usage_enforcement' in d) > 0 then
      if position(ins_call in d) = 0 then raise exception 'VERSION_MISMATCH: zella_assistant_for_call was changed after the migration; review it by hand'; end if;
      d := replace(replace(d, ins_call, ''), 'v_cfg jsonb; v_version uuid; v_gate jsonb;', 'v_cfg jsonb; v_version uuid;');
      execute d;
    end if;
  end if;
  foreach f in array array['sms', 'email'] loop
    ins_msg := '
  if not (public.zella_message_gate(p_business_id, ''' || f || ''', p_template_key) ->> ''allow'')::boolean then   /* zella_usage_enforcement */
    return jsonb_build_object(''allowed'', false, ''reason'', ''allowance_used'', ''live'', v_live);
  end if;';
    if to_regprocedure('public.zella_prepare_' || f || '(uuid,uuid,text,jsonb,text)') is not null then
      d := pg_get_functiondef(('public.zella_prepare_' || f || '(uuid,uuid,text,jsonb,text)')::regprocedure);
      if position('zella_usage_enforcement' in d) > 0 then
        if position(ins_msg in d) = 0 then raise exception 'VERSION_MISMATCH: zella_prepare_% was changed after the migration; review it by hand', f; end if;
        execute replace(d, ins_msg, '');
      end if;
    end if;
  end loop;
  select count(*) into v_fwd from public.assistant_deliveries where outcome = 'forwarded_usage';
  if v_fwd = 0 and exists (select 1 from pg_constraint where conrelid = 'public.assistant_deliveries'::regclass and conname = 'assistant_deliveries_outcome_check'
                             and pg_get_constraintdef(oid) like '%forwarded_usage%') then
    alter table public.assistant_deliveries drop constraint assistant_deliveries_outcome_check;
    alter table public.assistant_deliveries add constraint assistant_deliveries_outcome_check check (outcome in ('served', 'not_ready', 'unknown_number'));
  end if;   -- forwarded calls on record: the wider check stays so their history is kept
end $$;
drop function if exists public.zella_message_gate(uuid,text,text);
drop function if exists public.zella_call_gate(uuid);
drop function if exists public.zella_usage_enforced(text);
delete from public.platform_settings where key = 'usage_enforcement';
commit;
