-- Zella: fixes found in the industry audit.
-- Needs: zella_industry_engine.sql, zella_industry_presets.sql, zella_industry_presets_more.sql
--  1. Due-date reminders never fired: nothing ever filled crm_records.due_at. The reminders now read the
--     date from a field on the record (config "due_field"), and fall back to due_at if one is set.
--  2. Emergency rules never fired: plumbing looked for a field it does not have (urgency, not priority),
--     electrical compared "emergency" with "Emergency", and HVAC had no emergency rule at all.
--     Field values are now compared without caring about capital letters.
set lock_timeout = '15s';

-- A date field means noon that day in the business's time zone; a date-and-time field is used as is.
create or replace function public.zella_record_due(p_due timestamptz, p_data jsonb, p_cfg jsonb, p_tz text)
returns timestamptz language plpgsql stable set search_path = public as $$
declare v text;
begin
  if p_due is not null then return p_due; end if;
  v := nullif(p_data ->> (p_cfg ->> 'due_field'), '');
  if v is null then return null; end if;
  if v ~ '^\d{4}-\d{2}-\d{2}$' then
    return ((v || ' 12:00:00')::timestamp) at time zone coalesce(nullif(p_tz, ''), 'America/New_York');
  end if;
  return v::timestamptz;
exception when others then
  return null;
end $$;

-- Which field holds the date for each reminder.
update public.industry_automation_presets p set trigger_config = p.trigger_config || jsonb_build_object('due_field', d.f)
  from (values
    ('beauty_salon','Membership renewal reminder','renews'), ('fitness','Membership expiry reminder','renews'),
    ('childcare','Start date reminder','start_date'), ('financial_services','Renewal reminder','next_step'),
    ('home_services','Plan visit reminder','next_visit'), ('landscaping','Plan visit reminder','next_visit'),
    ('hospitality','Arrival reminder','arrival'), ('hospitality','Checkout reminder','departure'),
    ('hvac','Agreement renewal reminder','renews'), ('hvac','Equipment maintenance reminder','next_maintenance'),
    ('legal','Deadline reminder 1 day','key_date'), ('legal','Deadline reminder 3 days','key_date'), ('legal','Document due reminder','due'),
    ('photography_events','Shoot reminder','event_date'), ('professional_services','Milestone reminder','milestone_date'),
    ('property_management','Lease renewal reminder','ends'), ('real_estate','Viewing reminder','viewing_at'),
    ('restaurant','Event reminder','event_date'), ('spa_wellness','Package expiry reminder','expires'),
    ('travel','Pre-departure 1 day','depart'), ('travel','Pre-departure 3 days','depart')
  ) as d(k, n, f)
 where p.industry_key = d.k and p.name = d.n and p.trigger_type = 'record_due_reminder';

-- Two reminders target a status that counts as closed (enrolled, won); let them still run.
update public.industry_automation_presets set trigger_config = trigger_config || '{"include_closed": true}'::jsonb
 where (industry_key, name) in (('childcare','Start date reminder'), ('financial_services','Renewal reminder'));
update public.automations set trigger_config = trigger_config || '{"include_closed": true}'::jsonb
 where name in ('Start date reminder','Renewal reminder') and trigger_type = 'record_due_reminder';

-- Emergency rules.
update public.industry_automation_presets set trigger_config = replace(trigger_config::text, '"key": "priority"', '"key": "urgency"')::jsonb
 where industry_key = 'plumbing' and name = 'Emergency routing';
update public.industry_automation_presets set trigger_config = replace(trigger_config::text, '"value": "emergency"', '"value": "Emergency"')::jsonb
 where industry_key in ('plumbing', 'electrical') and trigger_config::text like '%"value": "emergency"%';
insert into public.industry_automation_presets (industry_key, name, checklist_no, description, trigger_type, trigger_config) values
('hvac', 'Emergency intake', 343, 'Alert the team at once for emergency jobs such as no heat.', 'record_status_action',
 '{"type_key":"jobs","rules":[{"status":"new","notify":{"title":"Emergency job: {title}","severity":"urgent","body":"Call the customer now."},"task":{"title":"Call emergency customer: {title}","priority":"urgent","due_hours":1},"when_data":{"key":"priority","value":"Emergency"}}]}'::jsonb)
on conflict (industry_key, name) do update set trigger_config = excluded.trigger_config, description = excluded.description;

-- Businesses that already have these rules get the corrected settings (their own notify choice is kept).
update public.automations a
   set trigger_config = p.trigger_config || case when a.trigger_config ? 'notify_via' then jsonb_build_object('notify_via', a.trigger_config ->> 'notify_via') else '{}'::jsonb end,
       updated_at = now()
  from public.industry_automation_presets p
 where a.name = p.name and a.trigger_type = p.trigger_type and p.trigger_config ? 'due_field' and not a.trigger_config ? 'due_field';
update public.automations a
   set trigger_config = p.trigger_config || case when a.trigger_config ? 'notify_via' then jsonb_build_object('notify_via', a.trigger_config ->> 'notify_via') else '{}'::jsonb end,
       updated_at = now()
  from public.industry_automation_presets p
 where a.name = p.name and a.trigger_type = 'record_status_action' and p.name in ('Emergency routing', 'Emergency intake')
   and a.trigger_config -> 'rules' <> p.trigger_config -> 'rules';

-- Field values match without regard to capital letters.
do $do$
declare d text;
begin
  select pg_get_functiondef('public.zella_industry_status_trg()'::regprocedure) into d;
  if d not like '%lower(new.data%' then
    d := replace(d, 'new.data ->> (r -> ''when_data'' ->> ''key'') = r -> ''when_data'' ->> ''value''',
                    'lower(new.data ->> (r -> ''when_data'' ->> ''key'')) = lower(r -> ''when_data'' ->> ''value'')');
    execute d;
  end if;
  select pg_get_functiondef('public.zella_run_industry_timers()'::regprocedure) into d;
  if d not like '%zella_record_due%' then
    d := replace(d, 'r.assigned_to, r.due_at from public.crm_records r',
      'r.assigned_to, public.zella_record_due(r.due_at, r.data, c, (select timezone from public.businesses where id = a.business_id)) as due_at from public.crm_records r');
    d := replace(d, 'r.due_at is not null', 'public.zella_record_due(r.due_at, r.data, c, (select timezone from public.businesses where id = a.business_id)) is not null');
    d := replace(d, 'and r.due_at - make_interval', 'and public.zella_record_due(r.due_at, r.data, c, (select timezone from public.businesses where id = a.business_id)) - make_interval');
    execute d;
  end if;
  select pg_get_functiondef('public.zella_run_industry_timers()'::regprocedure) into d;
  if d not like '%include_closed%' then
    d := replace(d, 'c, (select timezone from public.businesses where id = a.business_id)) is not null and r.archived_at is null and r.closed_at is null',
                    'c, (select timezone from public.businesses where id = a.business_id)) is not null and r.archived_at is null and (r.closed_at is null or coalesce((c ->> ''include_closed'')::boolean, false))');
    execute d;
  end if;
end $do$;

select public.zella_apply_industry_automations(id) from public.businesses;

-- Legal: a text message must not reveal that a firm has taken someone on as a client.
update public.industry_automation_presets set trigger_config = replace(trigger_config::text, 'We have accepted your matter. We will contact you about the next steps.', 'Thank you for contacting us. We will be in touch about the next steps.')::jsonb
 where industry_key = 'legal' and name = 'Matter accepted';
update public.automations set trigger_config = replace(trigger_config::text, 'We have accepted your matter. We will contact you about the next steps.', 'Thank you for contacting us. We will be in touch about the next steps.')::jsonb
 where name = 'Matter accepted';

-- AI safety wording for more industries (the same text lives in zella_brain.sql).
do $do$
declare d text; o text := E'         when v_key = ''pet_care'' then'; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'zella_brain_prompt' and p.pronamespace = 'public'::regnamespace;
  if d like '%allergen%' then return; end if;
  if position(o in d) = 0 then raise exception 'ANCHOR_NOT_FOUND'; end if;
  n := E'         when v_key in (''restaurant'', ''hospitality'') then E''- Never say a dish or drink is free of an allergen or safe for an allergy; say the team will confirm and offer a callback. Do not promise a table or room at a time unless a booking is confirmed.\\n''\n'
    || E'         when v_key = ''fitness'' then E''- Give no medical, injury or diet advice; suggest speaking with a doctor and offer a callback from the team.\\n''\n'
    || E'         when v_key = ''property_management'' then E''- Never promise repair times. For a gas smell, fire, flooding or no heat in freezing weather, tell the caller to get to safety and call 911 or the utility first, then use report_emergency. Give no legal advice about leases or evictions.\\n''\n'
    || E'         when v_key = ''travel'' then E''- Do not quote fares or promise availability, visas or refunds unless the knowledge says so; offer a consultation.\\n''\n'
    || E'         when v_key = ''education'' then E''- Do not promise admission, grades or fees unless the knowledge says so; offer to book a conversation with the team.\\n''\n'
    || E'         when v_key = ''photography_events'' then E''- Do not quote prices or promise dates; offer a consultation.\\n''\n' || o;
  execute replace(d, o, n);
end $do$;

-- Financial services: the renewal date lives on service requests, not on opportunities.
update public.industry_automation_presets set trigger_config = (trigger_config - 'include_closed') || '{"type_key":"requests","statuses":["open","waiting"],"due_field":"renewal"}'::jsonb
 where industry_key = 'financial_services' and name = 'Renewal reminder';
update public.automations a set trigger_config = p.trigger_config || case when a.trigger_config ? 'notify_via' then jsonb_build_object('notify_via', a.trigger_config ->> 'notify_via') else '{}'::jsonb end
  from public.industry_automation_presets p
 where p.industry_key = 'financial_services' and p.name = 'Renewal reminder' and a.name = p.name and a.trigger_type = 'record_due_reminder';
