-- Reminder times of 15 and 30 minutes before an appointment.
-- Changes only the check on the reminder options (zella_clean_automation_config):
-- 'hours_before' for appointment reminders now accepts 0.25 (15 min) and 0.5 (30 min) as well,
-- and keeps fractions instead of rounding them to whole hours. Safe to run more than once.
-- Reminder times are stored in hours; the reminder creator already handles fractions.

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
        if exists (select 1 from jsonb_array_elements_text(v) e where e not in ('0.25','0.5','1','2','4','24','48')) then raise exception 'BAD_FIELD:hours_before'; end if;
        v_out := v_out || jsonb_build_object(k, (select jsonb_agg(distinct e::numeric order by e::numeric) from jsonb_array_elements_text(v) e));
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
