-- Zella: make an automation's "notify via" choice (sms / email / both) real.
-- Needs: zella_staff_sms.sql, zella_industry_automations.sql
-- The industry engine sets a transaction-local setting, zella.notify_via, before it
-- raises an alert. The staff_notifications insert trigger reads it:
--   sms   -> text message only (email lane marked 'skipped'); sent even if not urgent
--   email -> email only (no text message)
--   both / unset -> unchanged: email always, text message only for urgent alerts
set lock_timeout = '15s';

create or replace function public.zella_mark_staff_sms() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_via text := coalesce(nullif(current_setting('zella.notify_via', true), ''), 'both'); v_ok boolean;
begin
  select exists (select 1 from public.business_members m where m.business_id = new.business_id and m.status = 'active' and m.sms_alerts
                  and (new.user_id is null and m.role in ('owner', 'admin') or m.user_id = new.user_id)) into v_ok;
  if v_via = 'sms' then
    if v_ok then new.sms_status := 'pending'; new.delivery_status := 'skipped'; end if;
  elsif v_via = 'email' then
    new.sms_status := null;
  elsif new.severity = 'urgent' and v_ok then
    new.sms_status := 'pending';
  end if;
  return new;
end $$;

create or replace function public.zella_industry_status_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare a record; r jsonb;
begin
  if TG_OP = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  if exists (select 1 from public.businesses b where b.id = new.business_id and (b.suspended_at is not null or b.cancelled_at is not null)) then return new; end if;
  for a in select * from public.automations x where x.business_id = new.business_id and x.trigger_type = 'record_status_action' and x.status = 'active'
              and x.trigger_config ->> 'type_key' = new.type_key loop
    perform set_config('zella.notify_via', coalesce(nullif(a.trigger_config ->> 'notify_via', ''), 'both'), true);
    for r in select * from jsonb_array_elements(coalesce(a.trigger_config -> 'rules', '[]'::jsonb)) loop
      if r ->> 'status' = new.status
         and (not (r ? 'when_data') or new.data ->> (r -> 'when_data' ->> 'key') = r -> 'when_data' ->> 'value') then
        perform public.zella_industry_act(new.business_id, r, new.customer_id, new.id, new.title, new.status, new.assigned_to);
      end if;
    end loop;
  end loop;
  perform set_config('zella.notify_via', '', true);
  return new;
exception when others then
  perform set_config('zella.notify_via', '', true);
  return new;
end $$;

-- The hourly timers: set the same setting for each automation they run.
do $do$
declare d text;
begin
  select pg_get_functiondef('public.zella_run_industry_timers()'::regprocedure) into d;
  if d not like '%zella.notify_via%' then
    d := replace(d, E'    c := a.trigger_config;\n', E'    c := a.trigger_config;\n    perform set_config(''zella.notify_via'', coalesce(nullif(c ->> ''notify_via'', ''''), ''both''), true);\n');
    d := replace(d, E'  return n;\nend', E'  perform set_config(''zella.notify_via'', '''', true);\n  return n;\nend');
    execute d;
  end if;
end $do$;
