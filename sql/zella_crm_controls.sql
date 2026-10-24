-- Owner controls: switch automations on or off, change their options, and
-- turn off or remove integrations. The browser never writes these tables
-- directly; it calls these functions, which check who is asking.

-- Clean an automation's options. Only the values the setup wizard offers are accepted.
create or replace function public.zella_clean_automation_config(p_type text, p_cfg jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  v_out jsonb := '{}'::jsonb;
  k text; v jsonb;
  v_nums text[]; v_text text[];
begin
  if p_cfg is null or jsonb_typeof(p_cfg) <> 'object' then return '{}'::jsonb; end if;
  for k, v in select * from jsonb_each(p_cfg) loop
    v_nums := null; v_text := null;
    case
      when k = 'hours_before' and p_type = 'appointment_reminder' then
        if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then raise exception 'BAD_FIELD:hours_before'; end if;
        if exists (select 1 from jsonb_array_elements_text(v) e where e not in ('1','2','4','24','48')) then raise exception 'BAD_FIELD:hours_before'; end if;
        v_out := v_out || jsonb_build_object(k, (select jsonb_agg(distinct e::int order by e::int) from jsonb_array_elements_text(v) e));
        continue;
      when k = 'hours_before' and p_type = 'appointment_confirmation' then v_nums := array['24','48','72'];
      when k = 'minutes_after' and p_type = 'no_show_follow_up' then v_nums := array['10','15','30','60'];
      when k = 'minutes_after' and p_type = 'missed_call_follow_up' then v_nums := array['0','5','15','30'];
      when k = 'minutes_after' and p_type = 'new_lead_callback' then v_nums := array['0','5','15','60'];
      when k = 'max_attempts' and p_type in ('missed_call_follow_up','new_lead_callback') then v_nums := array['1','2','3'];
      when k = 'max_attempts' and p_type = 'quote_follow_up' then v_nums := array['1','2','3'];
      when k = 'contact_within_minutes' and p_type = 'new_lead_callback' then v_nums := array['5','15','30','60'];
      when k = 'escalate_after_minutes' and p_type = 'new_lead_callback' then v_nums := array['30','60','120','240'];
      when k = 'retry_after_hours' and p_type = 'new_lead_callback' then v_nums := array['1','4','24'];
      when k = 'hours_after' and p_type = 'post_appointment_follow_up' then v_nums := array['2','24','72'];
      when k = 'hours_after' and p_type = 'quote_follow_up' then v_nums := array['24','48','72'];
      when k = 'days_inactive' and p_type = 'lead_reactivation' then v_nums := array['14','30','60','90'];
      when k = 'offers' and p_type = 'waitlist_offer' then v_nums := array['1','2','3','5'];
      when k = 'offer_minutes' and p_type = 'waitlist_offer' then v_nums := array['15','30','60'];
      when k = 'fallback_sms' and p_type in ('missed_call_follow_up','new_lead_callback') then
        if jsonb_typeof(v) <> 'boolean' then raise exception 'BAD_FIELD:fallback_sms'; end if;
        v_out := v_out || jsonb_build_object(k, v);
        continue;
      when k = 'notify_via' then v_text := array['sms','email','both'];
      when k = 'channel' and p_type in ('appointment_reminder') then v_text := array['sms','call','sms_and_call'];
      when k = 'channel' and p_type in ('appointment_confirmation','no_show_follow_up','waitlist_offer','staff_unavailable') then v_text := array['sms','call'];
      when k = 'channel' and p_type in ('post_appointment_follow_up','quote_follow_up','lead_reactivation') then v_text := array['sms','email'];
      else raise exception 'BAD_FIELD:%', k;
    end case;
    if v_nums is not null then
      if jsonb_typeof(v) <> 'number' or not ((v #>> '{}') = any (v_nums)) then raise exception 'BAD_FIELD:%', k; end if;
      v_out := v_out || jsonb_build_object(k, (v #>> '{}')::int);
    else
      if jsonb_typeof(v) <> 'string' or not ((v #>> '{}') = any (v_text)) then raise exception 'BAD_FIELD:%', k; end if;
      v_out := v_out || jsonb_build_object(k, v);
    end if;
  end loop;
  return v_out;
end $$;

-- Switch one automation on or off and/or change its options.
-- Off = disabled (it stays off until the owner turns it on again).
-- On = running if the business is live, otherwise it starts when the business goes live.
create or replace function public.zella_set_automation(p_business_id uuid, p_automation_id uuid, p_enabled boolean default null, p_config jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a public.automations%rowtype;
  b public.businesses%rowtype;
  v_status text;
  v_cfg jsonb;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into b from public.businesses where id = p_business_id;
  if not found or b.cancelled_at is not null or b.suspended_at is not null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  select * into a from public.automations where id = p_automation_id and business_id = p_business_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  v_cfg := coalesce(a.trigger_config, '{}'::jsonb);
  if p_config is not null then
    v_cfg := v_cfg || public.zella_clean_automation_config(a.trigger_type, p_config);
  end if;

  v_status := a.status;
  if p_enabled is true then
    v_status := case when b.onboarding_status = 'active' then 'active' else 'paused' end;
  elsif p_enabled is false then
    v_status := 'disabled';
  end if;

  update public.automations
     set trigger_config = v_cfg, status = v_status, paused_by_suspension = false, updated_at = now()
   where id = a.id;

  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'automation.changed', 'automation', a.id,
          jsonb_build_object('status', a.status, 'config', a.trigger_config),
          jsonb_build_object('status', v_status, 'config', v_cfg, 'type', a.trigger_type));

  return jsonb_build_object('id', a.id, 'status', v_status, 'config', v_cfg);
end $$;

-- Turn an integration off, back on, or remove it.
-- remove wipes the saved sign-in details; reconnecting afterwards is done by the Zella team.
create or replace function public.zella_set_integration(p_business_id uuid, p_integration_id uuid, p_action text) returns text
language plpgsql security definer set search_path = public as $$
declare i public.integrations%rowtype; v_new text;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_action not in ('off', 'on', 'remove') then raise exception 'BAD_FIELD:action'; end if;
  select * into i from public.integrations where id = p_integration_id and business_id = p_business_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_action = 'off' then
    if i.status = 'disconnected' then raise exception 'NEEDS_RECONNECT'; end if;
    v_new := 'inactive';
  elsif p_action = 'on' then
    if i.status = 'disconnected' then raise exception 'NEEDS_RECONNECT'; end if;
    v_new := 'active';
  else
    v_new := 'disconnected';
  end if;

  update public.integrations
     set status = v_new, updated_at = now(),
         credentials = case when p_action = 'remove' then '{}'::jsonb else credentials end,
         account_email = case when p_action = 'remove' then null else account_email end,
         external_account_id = case when p_action = 'remove' then null else external_account_id end,
         error_message = null, last_error = null, error_count = 0
   where id = i.id;

  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'integration.' || p_action, 'integration', i.id,
          jsonb_build_object('status', i.status, 'provider', i.provider),
          jsonb_build_object('status', v_new, 'provider', i.provider));
  return v_new;
end $$;

revoke all on function public.zella_clean_automation_config(text, jsonb) from public, anon, authenticated;
revoke all on function public.zella_set_automation(uuid, uuid, boolean, jsonb) from public, anon;
revoke all on function public.zella_set_integration(uuid, uuid, text) from public, anon;
grant execute on function public.zella_set_automation(uuid, uuid, boolean, jsonb) to authenticated;
grant execute on function public.zella_set_integration(uuid, uuid, text) to authenticated;
