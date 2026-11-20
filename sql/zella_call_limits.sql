-- Zella Voice: the AI receptionist stops when a business's minutes run out, and each business has a limit on calls
-- at the same time (security audit 18 Nov 2026, 8.1, M12; owner decisions 18 Nov 2026).
-- zella_call_gate let the AI keep answering when the minutes were used up and there was no number to forward to, and
-- when the allowance was not set up or could not be read. Now, once usage enforcement for calls is switched on
-- (platform setting usage_enforcement.calls, off today, unchanged by this file):
--   * minutes left: answer, as before;
--   * used up, and the business has auto reload on for minutes (or chose auto top up): keep answering only while a
--     reload can still happen: payments live (zella_payments_live, lane F's switch), an active subscription, the
--     reload pack still sold, and the month's reload spend plus one more pack within the owner's cap, or a reload
--     in flight for at most 30 minutes. Anything else counts as a failed reload;
--   * used up with pay as you go (an overage price on the plan in force now, zella_billing_plan_at): keep answering;
--   * otherwise, and also when the allowance is unknown (not set up, unreadable, or the subscription isn't active):
--     forward to the business's own number if it has a valid one, else play "Sorry, we can't take your call right
--     now. Please try again later." and end the call (action closed);
--   * while it is stopped, the owners get an in app reminder (and an email, when email is live) to buy minutes or turn
--     on auto reload, at most once every 6 hours; an unknown allowance or a subscription that isn't active raises a
--     platform alert for Zella Voice instead (buying minutes wouldn't help).
-- While the switch is off nothing changes for callers (the documented design: calls continue until admission is
-- deliberately connected, docs/MINUTE_USAGE_DESIGN.md); the gate reports what it would do (would_close).
-- Calls at the same time: zella_assistant_for_call counts the business's calls in progress under a per business lock:
-- a served call with a call record counts until it ends (at most 2 hours); a served call whose record never arrived
-- counts only for its first 10 minutes, so a lost report frees its place. At the limit (businesses.
-- voice_max_concurrent_calls, else platform setting voice_max_concurrent_calls, 10) the call is forwarded when the
-- minutes check would forward it, otherwise the caller hears the same closed message. This applies whatever the
-- switch, from the moment this file is applied.
-- Both functions are archived first and must match production (18 Nov 2026), otherwise VERSION_MISMATCH. Needs lane F's
-- zella_payments_live and zella_billing_plan_at (sql/zella_stripe_pipeline.sql, sql/zella_billing_allowances.sql).
-- Rollback: sql/rollback/zella_call_limits_rollback.sql
begin;

do $$
declare
  s text; d text;
  known constant jsonb := jsonb_build_object(
    'public.zella_call_gate(uuid)',                     jsonb_build_array('03d62be229c6407bbd33dd83be32e397', '6afc3f110b731620a5ffc5fc9cab0dca'),
    'public.zella_assistant_for_call(text,text,text)',  jsonb_build_array('4463128ecde8dbb1edfa132d048796c6', '03ee44c36607ca56782820a30bffee82'));
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.auto_reload_settings') is null
     or to_regclass('public.assistant_deliveries') is null or to_regprocedure('public.zella_call_entitlement_check(uuid)') is null
     or to_regprocedure('public.zella_payments_live()') is null or to_regprocedure('public.zella_billing_plan_at(uuid,timestamptz)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for s in select jsonb_object_keys(known) loop
    if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_call_limits', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
end $$;

alter table public.businesses add column if not exists voice_max_concurrent_calls integer
  check (voice_max_concurrent_calls is null or voice_max_concurrent_calls between 1 and 100);
comment on column public.businesses.voice_max_concurrent_calls is
  'Calls the AI receptionist answers at the same time for this business (null: platform setting voice_max_concurrent_calls)';
-- the settings this file adds, recorded so the rollback removes only those (never a value someone set before)
create table if not exists public.zella_migration_settings (migration text not null, key text not null, primary key (migration, key));
alter table public.zella_migration_settings enable row level security;
revoke all on public.zella_migration_settings from public, anon, authenticated;
with i as (insert into public.platform_settings (key, value) values ('voice_max_concurrent_calls', '10'::jsonb) on conflict (key) do nothing returning key)
insert into public.zella_migration_settings (migration, key) select 'zella_call_limits', key from i on conflict do nothing;

alter table public.assistant_deliveries drop constraint if exists assistant_deliveries_outcome_check;
alter table public.assistant_deliveries add constraint assistant_deliveries_outcome_check
  check (outcome in ('served', 'not_ready', 'unknown_number', 'forwarded_usage', 'closed_usage', 'over_call_limit'));

CREATE OR REPLACE FUNCTION public.zella_call_gate(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e jsonb; v_payg boolean; v_reload boolean; v_can_reload boolean := false; v_mode text; v_raw text; v_number text; v_stop boolean; v_reason text; v_status text;
        a public.auto_reload_settings; c public.billing_pack_catalog; v_spent bigint;
        v_on boolean := public.zella_usage_enforced('calls');
begin
  e := public.zella_call_entitlement_check(p_business_id);
  v_status := coalesce(e ->> 'status', 'error');
  if v_status = 'active' then v_stop := false; v_reason := coalesce(e ->> 'reason', 'within_allowance');
  elsif v_status = 'inactive' then v_stop := true; v_reason := coalesce(e ->> 'reason', 'subscription_inactive');
  elsif v_status = 'exhausted' then
    /* zella_call_limits: auto reload first (owner, 18 Nov 2026); reloads run only once payments can charge */
    select coalesce(u.overage_mode, 'stop') into v_mode from public.business_usage_preferences u where u.business_id = p_business_id;
    select * into a from public.auto_reload_settings x where x.business_id = p_business_id and x.resource = 'minutes' and x.enabled;
    v_reload := a.business_id is not null or v_mode = 'auto_top_up';
    -- a reload can still happen: the same conditions lane F's zella_billing_maybe_reload checks before buying a pack
    if a.business_id is not null and public.zella_payments_live()
       and (select s.status from public.subscriptions s where s.business_id = p_business_id) = 'active' then
      -- a reload in flight counts for 30 minutes at most: a purchase stuck pending (a lost provider reply) never keeps
      -- calls open without payment
      if exists (select 1 from public.pack_purchases p where p.business_id = p_business_id and p.resource = 'minutes' and p.source = 'auto_reload' and p.status = 'pending'
                   and p.purchased_at > now() - interval '30 minutes') then
        v_can_reload := true;
      else
        select * into c from public.billing_pack_catalog k where k.code = a.pack_code and k.active and k.resource = 'minutes';
        select coalesce(sum(p.price_cents), 0) into v_spent from public.pack_purchases p
         where p.business_id = p_business_id and p.source = 'auto_reload' and p.status in ('pending', 'granted') and p.purchased_at >= date_trunc('month', now());
        v_can_reload := c.code is not null and v_spent + c.price_cents <= a.monthly_cap_cents;
      end if;
    end if;
    -- pay as you go is its own choice (auto top up is a reload), priced by the plan in force now, not a later version
    v_payg := v_mode = 'pay_as_you_go' and coalesce((public.zella_billing_plan_at(p_business_id, now())).overage_cents_per_minute, 0) > 0;
    if v_can_reload then v_stop := false; v_reason := 'auto_reload';
    elsif v_payg then v_stop := false; v_reason := 'pay_as_you_go';
    else v_stop := true; v_reason := case when v_reload then 'auto_reload_unavailable' else 'allowance_used' end;
    end if;
  else
    -- not set up, unreadable or anything else: the same as used up (owner, 18 Nov 2026); never "unlimited"
    v_stop := true; v_reason := 'allowance_unknown';
  end if;
  if v_stop then
    select cfg.escalation_rules ->> 'fallback_number' into v_raw
      from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id
     where ag.business_id = p_business_id and ag.is_default limit 1;
    -- E.164 only (what voice-rules will dial)
    v_number := public.zella_strict_e164(v_raw);
    -- never a line that rings back into Zella Voice (a Zella Voice number, or the business line that forwards to it):
    -- the call would come straight back here and loop
    if v_number is not null and (public.zella_business_for_number(v_number, null, null) is not null
        or exists (select 1 from public.businesses b where b.id = p_business_id
                    and public.zella_strict_e164(b.setup_data #>> '{integrations,phone,forward_from}') = v_number)) then
      v_number := null;
    end if;
  end if;
  return jsonb_build_object(
    'action', case when not v_on or not v_stop then 'answer' when v_number is not null then 'forward' else 'closed' end,
    'enforced', v_on, 'would_forward', coalesce(v_stop, false) and v_number is not null,
    'would_close', coalesce(v_stop, false) and v_number is null, 'usage_status', v_status, 'usage_reason', v_reason,
    'reason', case when v_stop and v_number is null then 'no_number_to_forward_to' else v_reason end, 'number', v_number);
end $function$;

CREATE OR REPLACE FUNCTION public.zella_assistant_for_call(p_called_number text, p_vapi_phone_number_id text, p_provider_call_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_biz uuid := public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null);   -- no fallback: the number decides
  v_cfg jsonb; v_version uuid; v_gate jsonb; v_cap integer; v_live integer;
  v_fallback text := nullif(public.zella_setting('assistant_fallback_id', 'null'::jsonb) #>> '{}', '');
begin
  if v_fallback is not null and v_fallback !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_fallback := null; end if;
  if v_biz is null then
    insert into assistant_deliveries (business_id, provider_call_id, outcome) values (null, left(p_provider_call_id, 120), 'unknown_number');
    return jsonb_build_object('ok', false, 'outcome', 'unknown_number', 'fallback_assistant_id', v_fallback);
  end if;
  /* zella_call_limits: calls at the same time, counted one call start at a time per business */
  perform pg_advisory_xact_lock(hashtextextended('zella_call_limit:' || v_biz::text, 0));
  select coalesce(b.voice_max_concurrent_calls,
           case when (public.zella_setting('voice_max_concurrent_calls', '10'::jsonb) #>> '{}') ~ '^[0-9]{1,3}$'
                then greatest(1, (public.zella_setting('voice_max_concurrent_calls', '10'::jsonb) #>> '{}')::integer) else 10 end)
    into v_cap from businesses b where b.id = v_biz;
  -- a call with a record counts until it ends; one whose record never arrived (a lost report) only for 10 minutes
  select count(distinct d.provider_call_id) into v_live from assistant_deliveries d
   left join calls c on c.external_call_id = d.provider_call_id
   where d.business_id = v_biz and d.outcome = 'served' and d.created_at > now() - interval '2 hours' and d.provider_call_id is not null
     and d.provider_call_id <> coalesce(left(p_provider_call_id, 120), '')
     and case when c.id is null then d.created_at > now() - interval '10 minutes'
              else c.ended_at is null and c.status not in ('completed', 'missed', 'failed') end;
  v_gate := public.zella_call_gate(v_biz);   /* zella_usage_enforcement */
  if v_live >= coalesce(v_cap, 10) and v_gate ->> 'action' <> 'forward' then
    insert into assistant_deliveries (business_id, provider_call_id, outcome) values (v_biz, left(p_provider_call_id, 120), 'over_call_limit');
    return jsonb_build_object('ok', false, 'outcome', 'closed', 'reason', 'over_call_limit');
  end if;
  if v_gate ->> 'action' in ('forward', 'closed') then
    insert into assistant_deliveries (business_id, provider_call_id, outcome)
    values (v_biz, left(p_provider_call_id, 120), case when v_gate ->> 'action' = 'forward' then 'forwarded_usage' else 'closed_usage' end);
    -- reminders, at most once every 6 hours: the owners (in app, and email once email is live), or Zella Voice when
    -- the allowance can't be read
    begin
      if v_gate ->> 'usage_status' <> 'exhausted' then   -- unknown allowance or a subscription that isn't active
        perform public.zella_platform_alert('usage_allowance_unknown', case when v_gate ->> 'usage_status' = 'inactive'
            then 'Calls stopped: subscription not active' else 'Calls stopped: minutes allowance unknown' end,
          case when v_gate ->> 'usage_status' = 'inactive' then 'A call to this business was not answered by the AI receptionist because its subscription is not active.'
               else 'A call to this business was not answered by the AI receptionist because its minutes allowance is not set up or could not be read.' end,
          'warning', v_biz, to_char(now(), 'YYYYMMDD'), jsonb_build_object('status', v_gate ->> 'usage_status'));
      elsif not exists (select 1 from staff_notifications n where n.business_id = v_biz and n.kind = 'minutes_used_up' and n.created_at > now() - interval '6 hours') then
        perform public.zella_notify_owners(v_biz, 'minutes_used_up', 'Your receptionist minutes are used up',
          'Calls are ' || case when v_gate ->> 'action' = 'forward' then 'being forwarded to your own number' else 'not being answered' end
          || '. Buy more minutes or turn on auto reload in Billing to start answering again.', 'warning', 'billing');
      end if;
    exception when others then null;   -- a reminder never stops the call decision
    end;
    if v_gate ->> 'action' = 'forward' then
      return jsonb_build_object('ok', false, 'outcome', 'forward', 'reason', v_gate ->> 'reason', 'forward_number', v_gate ->> 'number');
    end if;
    return jsonb_build_object('ok', false, 'outcome', 'closed', 'reason', v_gate ->> 'usage_reason');
  end if;
  v_cfg := public.zella_assistant_config(v_biz);
  select v.id into v_version from agent_config_versions v where v.business_id = v_biz and v.status = 'published' order by v.published_at desc nulls last limit 1;
  if coalesce((v_cfg ->> 'ready_to_send')::boolean, false) then
    update agent_config_versions set sync_status = 'live', sync_error = null where id = v_version and (sync_status <> 'live' or sync_error is not null);
    insert into assistant_deliveries (business_id, version_id, provider_call_id, outcome, config_hash)   /* zella_delivery_evidence */
    values (v_biz, v_version, left(p_provider_call_id, 120), 'served', md5((v_cfg -> 'assistant')::text));
    return jsonb_build_object('ok', true, 'outcome', 'served', 'version_id', v_version, 'config_hash', md5((v_cfg -> 'assistant')::text), 'assistant', v_cfg -> 'assistant');
  end if;
  update agent_config_versions set sync_status = 'failed', sync_error = left(array_to_string(array(select jsonb_array_elements_text(v_cfg -> 'problems')), '; '), 500)
   where id = v_version and sync_status <> 'failed';
  insert into assistant_deliveries (business_id, version_id, provider_call_id, outcome, problems)
  values (v_biz, v_version, left(p_provider_call_id, 120), 'not_ready', coalesce(v_cfg -> 'problems', '[]'));
  -- the owners hear about it once a day at most; the problems are platform settings the Zella team fixes
  if not exists (select 1 from staff_notifications n where n.business_id = v_biz and n.kind = 'assistant_not_ready' and n.created_at > now() - interval '24 hours') then
    begin
      perform public.zella_notify_owners(v_biz, 'assistant_not_ready', 'A call could not use your receptionist settings',
        'The Zella Voice team has been told what to fix. Calls are ' || case when v_fallback is null then 'not being answered by the AI receptionist' else 'using the standby receptionist' end || ' until then.', 'warning', 'receptionist');
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', false, 'outcome', 'not_ready', 'problems', coalesce(v_cfg -> 'problems', '[]'), 'fallback_assistant_id', v_fallback);
end $function$;

commit;
