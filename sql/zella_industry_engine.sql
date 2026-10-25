-- Zella - industry automation engine (checklist 196-254, 235). Safe to run more than once.
-- Run AFTER zella_customer_touches.sql, zella_industry_crm.sql and zella_ops_automation.sql. Nothing here sends anything by itself:
-- messages are queued as follow-up tasks (sent only when sms_live / email_live are on and the person can be contacted).
-- A rule lives in `automations`. Rule types (trigger_type):
--   record_status_action  {type_key, rules:[{status, when_data?:{key,value}, message?, delay_minutes?, task?:{title,body?,priority?,due_hours?}, notify?:{title,body?,severity?}}]}
--                         fires when a record is created in, or moves to, that status
--   record_due_reminder   {type_key, before_hours?, after_hours?, statuses?:[..], rule:{...}}   relative to the record's due date
--   record_stale          {type_key, status, after_hours | after_days, rule:{...}}              record sat in a status too long
--   appointment_followup  {after_days, rule:{...}}                                              N days after a completed visit
--   seasonal_reminder     {months:[..], service, rule?}                                         once a season to past customers
--   service_due           {days, service}                                                       (already built)
-- In text, {title} and {status} are replaced by the record's title and status.
create table if not exists public.industry_automation_runs (
  automation_id uuid not null,
  record_id uuid not null,
  step text not null,
  ran_at timestamptz not null default now(),
  primary key (automation_id, record_id, step));
alter table public.industry_automation_runs enable row level security;
revoke all on public.industry_automation_runs from anon, authenticated;
create index if not exists industry_runs_old_idx on public.industry_automation_runs (ran_at);

create table if not exists public.industry_automation_presets (
  id uuid primary key default gen_random_uuid(),
  industry_key text not null,
  name text not null,
  checklist_no integer,
  description text,
  trigger_type text not null,
  trigger_config jsonb not null,
  unique (industry_key, name));
alter table public.industry_automation_presets enable row level security;
revoke all on public.industry_automation_presets from anon, authenticated;

-- one action list: message, staff task, owner alert
create or replace function public.zella_industry_act(p_biz uuid, p_rule jsonb, p_cust uuid, p_entity uuid, p_title text, p_status text, p_assigned uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_line text; t jsonb; nt jsonb;
begin
  if p_rule ? 'message' and p_cust is not null then
    v_line := left(replace(replace(p_rule ->> 'message', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 300);
    perform public.zella_queue_customer_message(p_biz, p_cust, 'record_status_update',
      jsonb_build_object('status_line', v_line, 'status', p_status, 'record_title', p_title),
      make_interval(mins => greatest(1, coalesce((p_rule ->> 'delay_minutes')::int, 1))), null, interval '0');
  end if;
  if p_rule ? 'task' then
    t := p_rule -> 'task';
    perform public.zella_create_task(p_biz, p_cust, 'industry', left(replace(replace(t ->> 'title', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 200),
      left(replace(replace(t ->> 'body', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 500),
      coalesce(nullif(t ->> 'priority', ''), 'normal'), now() + make_interval(hours => greatest(0, coalesce((t ->> 'due_hours')::int, 24))), p_assigned, 'automation', p_entity);
  end if;
  if p_rule ? 'notify' then
    nt := p_rule -> 'notify';
    perform public.zella_notify_owners(p_biz, 'industry_alert', left(replace(replace(nt ->> 'title', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 150),
      left(replace(replace(nt ->> 'body', '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), 300), coalesce(nullif(nt ->> 'severity', ''), 'warning'), 'records');
  end if;
end $$;
revoke all on function public.zella_industry_act(uuid, jsonb, uuid, uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_industry_act(uuid, jsonb, uuid, uuid, text, text, uuid) to service_role;

-- status trigger
create or replace function public.zella_industry_status_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare a record; r jsonb;
begin
  if TG_OP = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  if exists (select 1 from public.businesses b where b.id = new.business_id and (b.suspended_at is not null or b.cancelled_at is not null)) then return new; end if;
  for a in select * from public.automations x where x.business_id = new.business_id and x.trigger_type = 'record_status_action' and x.status = 'active'
              and x.trigger_config ->> 'type_key' = new.type_key loop
    for r in select * from jsonb_array_elements(coalesce(a.trigger_config -> 'rules', '[]'::jsonb)) loop
      if r ->> 'status' = new.status
         and (not (r ? 'when_data') or new.data ->> (r -> 'when_data' ->> 'key') = r -> 'when_data' ->> 'value') then
        perform public.zella_industry_act(new.business_id, r, new.customer_id, new.id, new.title, new.status, new.assigned_to);
      end if;
    end loop;
  end loop;
  return new;
exception when others then
  return new;   -- an automation problem must never block saving the record
end $$;
drop trigger if exists zella_industry_status on public.crm_records;
create trigger zella_industry_status after insert or update of status on public.crm_records
  for each row execute function public.zella_industry_status_trg();

-- timers (hourly)
create or replace function public.zella_run_industry_timers() returns integer
language plpgsql security definer set search_path = public as $$
declare a record; x record; n integer := 0; v_at interval; v_step text; v_rows integer; c jsonb; v_months int[];
begin
  delete from public.industry_automation_runs where ran_at < now() - interval '120 days';
  for a in select au.* from public.automations au join public.businesses b on b.id = au.business_id
            where au.status = 'active' and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true)
              and au.trigger_type in ('record_due_reminder', 'record_stale', 'appointment_followup', 'seasonal_reminder') loop
    c := a.trigger_config;
    begin
      if a.trigger_type = 'record_due_reminder' then
        for x in select r.id, r.title, r.status, r.customer_id, r.assigned_to, r.due_at from public.crm_records r
                  where r.business_id = a.business_id and r.type_key = c ->> 'type_key' and r.due_at is not null and r.archived_at is null and r.closed_at is null
                    and (not (c ? 'statuses') or r.status in (select jsonb_array_elements_text(c -> 'statuses')))
                    and r.due_at - make_interval(hours => coalesce((c ->> 'before_hours')::int, 0)) + make_interval(hours => coalesce((c ->> 'after_hours')::int, 0)) <= now()
                    and r.due_at - make_interval(hours => coalesce((c ->> 'before_hours')::int, 0)) + make_interval(hours => coalesce((c ->> 'after_hours')::int, 0)) > now() - interval '3 days'
                  limit 200 loop
          v_step := 'due:' || coalesce(c ->> 'before_hours', '0') || ':' || coalesce(c ->> 'after_hours', '0') || ':' || x.due_at::text;
          insert into public.industry_automation_runs (automation_id, record_id, step) values (a.id, x.id, v_step) on conflict do nothing;
          get diagnostics v_rows = row_count;
          if v_rows = 1 then perform public.zella_industry_act(a.business_id, c -> 'rule', x.customer_id, x.id, x.title, x.status, x.assigned_to); n := n + 1; end if;
        end loop;
      elsif a.trigger_type = 'record_stale' then
        v_at := coalesce(make_interval(hours => (c ->> 'after_hours')::int), make_interval(days => coalesce((c ->> 'after_days')::int, 3)));
        for x in select r.id, r.title, r.status, r.customer_id, r.assigned_to, r.updated_at from public.crm_records r
                  where r.business_id = a.business_id and r.type_key = c ->> 'type_key' and r.status = c ->> 'status' and r.archived_at is null and r.closed_at is null
                    and r.updated_at <= now() - v_at and r.updated_at > now() - v_at - interval '30 days'
                  limit 200 loop
          insert into public.industry_automation_runs (automation_id, record_id, step) values (a.id, x.id, 'stale:' || x.updated_at::text) on conflict do nothing;
          get diagnostics v_rows = row_count;
          if v_rows = 1 then perform public.zella_industry_act(a.business_id, c -> 'rule', x.customer_id, x.id, x.title, x.status, x.assigned_to); n := n + 1; end if;
        end loop;
      elsif a.trigger_type = 'appointment_followup' then
        for x in select p.id, p.customer_id, p.assigned_to from public.appointments p
                  where p.business_id = a.business_id and p.status = 'completed' and p.customer_id is not null
                    and p.start_time <= now() - make_interval(days => greatest(0, coalesce((c ->> 'after_days')::int, 1)))
                    and p.start_time > now() - make_interval(days => greatest(0, coalesce((c ->> 'after_days')::int, 1)) + 2)
                  limit 200 loop
          insert into public.industry_automation_runs (automation_id, record_id, step) values (a.id, x.id, 'appt') on conflict do nothing;
          get diagnostics v_rows = row_count;
          if v_rows = 1 then perform public.zella_industry_act(a.business_id, c -> 'rule', x.customer_id, x.id, 'your visit', 'completed', x.assigned_to); n := n + 1; end if;
        end loop;
      elsif a.trigger_type = 'seasonal_reminder' then
        select array_agg(m::int) into v_months from jsonb_array_elements_text(c -> 'months') m;
        if extract(month from now() at time zone coalesce((select timezone from public.businesses where id = a.business_id), 'America/New_York'))::int = any (v_months)
           and extract(day from now() at time zone coalesce((select timezone from public.businesses where id = a.business_id), 'America/New_York')) <= 7 then
          for x in select cu.id from public.customers cu
                    where cu.business_id = a.business_id and not coalesce(cu.do_not_contact, false)
                      and exists (select 1 from public.appointments p where p.customer_id = cu.id and p.status = 'completed' and p.start_time > now() - interval '24 months')
                      and not exists (select 1 from public.appointments p where p.customer_id = cu.id and p.status not in ('cancelled', 'no_show') and p.start_time > now())
                    limit 100 loop
            if public.zella_queue_customer_message(a.business_id, x.id, 'service_due', jsonb_build_object('service', coalesce(nullif(c ->> 'service', ''), 'visit')), interval '0', null, interval '200 days') is not null then
              n := n + 1;
            end if;
          end loop;
        end if;
      end if;
    exception when others then
      continue;   -- one broken rule must not stop the others
    end;
  end loop;
  return n;
end $$;
revoke all on function public.zella_run_industry_timers() from public, anon, authenticated;
grant execute on function public.zella_run_industry_timers() to service_role;

-- copy a business's industry rules into its automations (never overwrites a rule the business already has)
create or replace function public.zella_apply_industry_automations(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v_name text; v_key text; n integer := 0; v_rows integer; p record;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  if not found then return 0; end if;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  if v_key is null then v_key := 'other'; end if;
  for p in select * from public.industry_automation_presets where industry_key = v_key loop
    insert into public.automations (business_id, name, description, trigger_type, status, trigger_config, actions, conditions)
    select p_business_id, p.name, p.description, p.trigger_type, 'active', p.trigger_config, '[]'::jsonb, '{}'::jsonb
     where not exists (select 1 from public.automations x where x.business_id = p_business_id and x.name = p.name);
    get diagnostics v_rows = row_count;
    n := n + v_rows;
  end loop;
  return n;
end $$;
revoke all on function public.zella_apply_industry_automations(uuid) from public, anon, authenticated;
grant execute on function public.zella_apply_industry_automations(uuid) to service_role;

create or replace function public.zella_industry_apply_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.zella_apply_industry_automations(new.id);
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_industry_apply on public.businesses;
create trigger zella_industry_apply after insert or update of industry_id on public.businesses
  for each row execute function public.zella_industry_apply_trg();

-- 235: owners and admins write their own rules
create or replace function public.zella_save_industry_rule(p_business_id uuid, p_name text, p_trigger_type text, p_config jsonb, p_enabled boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_text text;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_trigger_type not in ('record_status_action', 'record_due_reminder', 'record_stale', 'appointment_followup', 'seasonal_reminder', 'service_due') then raise exception 'BAD_TRIGGER'; end if;
  if length(trim(coalesce(p_name, ''))) < 3 then raise exception 'NAME_REQUIRED'; end if;
  if p_config is null or jsonb_typeof(p_config) <> 'object' then raise exception 'BAD_CONFIG'; end if;
  if p_trigger_type <> 'seasonal_reminder' and p_trigger_type <> 'service_due' and not (p_config ? 'rule' or p_config ? 'rules') then raise exception 'RULE_REQUIRED'; end if;
  -- no prices or marketing in customer messages
  for v_text in select (jsonb_path_query(p_config, '$.**.message')) #>> '{}' loop
    if v_text ~ '[$€£]' or v_text ~* '\m(sale|discount|% off|offer ends|promo)\M' then raise exception 'NO_MARKETING_OR_PRICES'; end if;
    if length(v_text) > 300 then raise exception 'MESSAGE_TOO_LONG'; end if;
  end loop;
  insert into public.automations (business_id, name, trigger_type, status, trigger_config, actions, conditions, created_by)
  values (p_business_id, left(trim(p_name), 100), p_trigger_type, case when p_enabled then 'active' else 'paused' end, p_config, '[]'::jsonb, '{}'::jsonb, auth.uid())
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.zella_save_industry_rule(uuid, text, text, jsonb, boolean) from public, anon;
grant execute on function public.zella_save_industry_rule(uuid, text, text, jsonb, boolean) to authenticated, service_role;
