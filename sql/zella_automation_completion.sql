-- Automation completion: shared automations that really reach every business, missing per-industry defaults,
-- new industry presets, staff-approved message drafts, live notices ("full tonight"), review link,
-- and the restaurant walk-in waitlist and tables. Safe to run more than once.
-- Needs zella_industry_engine.sql, zella_industry_presets.sql, zella_industry_presets_more.sql and zella_security_sweep.sql first.

------------------------------------------------------------------ 1. Shared ("general") presets now reach every business
-- Before this, the 'general' presets were never copied because the lookup only used the business's own key.
create or replace function public.zella_apply_industry_automations(p_business_id uuid)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text; v_key text; n integer := 0; v_rows integer; p record;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  if not found then return 0; end if;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  if v_key is null then v_key := 'other'; end if;
  for p in select * from public.industry_automation_presets
            where industry_key = v_key
               or (industry_key = 'general' and v_key not in ('healthcare', 'dental', 'legal', 'financial_services', 'childcare')) loop
    insert into public.automations (business_id, name, description, trigger_type, status, trigger_config, actions, conditions)
    select p_business_id, p.name, p.description, p.trigger_type, 'active', p.trigger_config, '[]'::jsonb, '{}'::jsonb
     where not exists (select 1 from public.automations x where x.business_id = p_business_id and x.name = p.name);
    get diagnostics v_rows = row_count;
    n := n + v_rows;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_apply_industry_automations(uuid) from public, anon, authenticated;
grant execute on function public.zella_apply_industry_automations(uuid) to service_role;

-- zella_set_industry_rules looks presets up by name for the business's key or 'general'. Sensitive industries must not get them either.
-- The seasonal general preset is dropped: a blanket twice-a-year text is too close to marketing.
delete from public.industry_automation_presets where industry_key = 'general' and name = 'Spring and autumn check-in';

------------------------------------------------------------------ 2. Lead reactivation read the wrong setting name
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'zella_queue_lead_reactivation';
  if v_def is not null and v_def like '%''inactive_days''%' and v_def not like '%''days_inactive''%' then
    v_def := replace(v_def, '(v_auto.trigger_config ->> ''inactive_days'')::integer',
                     'coalesce((v_auto.trigger_config ->> ''days_inactive'')::integer, (v_auto.trigger_config ->> ''inactive_days'')::integer)');
    execute v_def;
  end if;
end $$;

------------------------------------------------------------------ 3. Industry defaults that were missing
with cfg(trig, c) as (values
  ('appointment_confirmation', '{"channel":"sms","hours_before":24}'::jsonb),
  ('appointment_reminder',      '{"channel":"sms","hours_before":[24,2]}'::jsonb),
  ('missed_call_follow_up',     '{"fallback_sms":true,"max_attempts":2,"minutes_after":5}'::jsonb),
  ('new_lead_callback',         '{"fallback_sms":true,"max_attempts":2,"minutes_after":5}'::jsonb),
  ('no_show_follow_up',         '{"channel":"sms","minutes_after":15}'::jsonb),
  ('post_appointment_follow_up','{"channel":"sms","hours_after":24}'::jsonb),
  ('quote_follow_up',           '{"channel":"sms","hours_after":48,"max_attempts":2}'::jsonb),
  ('lead_reactivation',         '{"channel":"sms","days_inactive":60}'::jsonb),
  ('waitlist_offer',            '{"offers":3,"channel":"sms","offer_minutes":30}'::jsonb),
  ('staff_unavailable',         '{"channel":"sms"}'::jsonb)),
want(ind, trig) as (values
  -- trade-style businesses with no defaults at all
  ('Landscaping & Lawn Care','appointment_reminder'),('Landscaping & Lawn Care','missed_call_follow_up'),('Landscaping & Lawn Care','new_lead_callback'),('Landscaping & Lawn Care','post_appointment_follow_up'),('Landscaping & Lawn Care','quote_follow_up'),('Landscaping & Lawn Care','staff_unavailable'),
  ('Pest Control','appointment_reminder'),('Pest Control','missed_call_follow_up'),('Pest Control','new_lead_callback'),('Pest Control','post_appointment_follow_up'),('Pest Control','quote_follow_up'),('Pest Control','staff_unavailable'),
  ('Cleaning Services','appointment_reminder'),('Cleaning Services','missed_call_follow_up'),('Cleaning Services','new_lead_callback'),('Cleaning Services','post_appointment_follow_up'),('Cleaning Services','quote_follow_up'),('Cleaning Services','staff_unavailable'),
  ('Property Management','appointment_reminder'),('Property Management','missed_call_follow_up'),('Property Management','new_lead_callback'),('Property Management','post_appointment_follow_up'),('Property Management','staff_unavailable'),
  -- appointment businesses with no defaults at all
  ('Spa & Wellness','appointment_confirmation'),('Spa & Wellness','appointment_reminder'),('Spa & Wellness','missed_call_follow_up'),('Spa & Wellness','no_show_follow_up'),('Spa & Wellness','post_appointment_follow_up'),('Spa & Wellness','waitlist_offer'),('Spa & Wellness','staff_unavailable'),
  ('Pet Care & Veterinary','appointment_confirmation'),('Pet Care & Veterinary','appointment_reminder'),('Pet Care & Veterinary','missed_call_follow_up'),('Pet Care & Veterinary','no_show_follow_up'),('Pet Care & Veterinary','post_appointment_follow_up'),('Pet Care & Veterinary','waitlist_offer'),('Pet Care & Veterinary','staff_unavailable'),
  ('Photography & Events','appointment_confirmation'),('Photography & Events','appointment_reminder'),('Photography & Events','missed_call_follow_up'),('Photography & Events','new_lead_callback'),('Photography & Events','post_appointment_follow_up'),('Photography & Events','quote_follow_up'),('Photography & Events','staff_unavailable'),
  ('Childcare','appointment_reminder'),('Childcare','missed_call_follow_up'),('Childcare','new_lead_callback'),('Childcare','staff_unavailable'),
  ('Insurance','appointment_reminder'),('Insurance','missed_call_follow_up'),('Insurance','new_lead_callback'),('Insurance','post_appointment_follow_up'),('Insurance','quote_follow_up'),('Insurance','staff_unavailable'),
  -- gaps in industries that already have some
  ('Legal','appointment_confirmation'),('Legal','no_show_follow_up'),('Legal','post_appointment_follow_up'),('Legal','staff_unavailable'),
  ('Financial Services','appointment_confirmation'),('Financial Services','post_appointment_follow_up'),('Financial Services','staff_unavailable'),
  ('Real Estate','post_appointment_follow_up'),('Real Estate','staff_unavailable'),
  ('Education','post_appointment_follow_up'),('Education','staff_unavailable'),
  ('Professional Services','post_appointment_follow_up'),('Professional Services','staff_unavailable'),
  ('Fitness','post_appointment_follow_up'),('Fitness','staff_unavailable'),
  ('Healthcare','post_appointment_follow_up'),('Healthcare','staff_unavailable'),
  ('Dental','staff_unavailable'),('Beauty & Salon','staff_unavailable'),('Beauty & Salon','new_lead_callback'),
  ('Automotive','no_show_follow_up'),('Automotive','staff_unavailable'),
  ('Restaurant','no_show_follow_up'),
  ('Hospitality','no_show_follow_up'),('Travel','appointment_confirmation'))
insert into public.industry_automation_defaults (industry_id, trigger_type, enabled, config)
select i.id, w.trig, true, c.c
  from want w join public.industries i on i.name = w.ind join cfg c on c.trig = w.trig
on conflict (industry_id, trigger_type) do nothing;

-- Lead reactivation only for industries that sell to leads (never healthcare, dental, legal or childcare).
insert into public.industry_automation_defaults (industry_id, trigger_type, enabled, config)
select i.id, 'lead_reactivation', true, '{"channel":"sms","days_inactive":60}'::jsonb
  from public.industries i
 where i.name in ('Landscaping & Lawn Care','Pest Control','Cleaning Services','Spa & Wellness','Pet Care & Veterinary','Photography & Events','Insurance',
                  'Automotive','HVAC','Plumbing','Electrical','Home Services','Financial Services','Property Management')
on conflict (industry_id, trigger_type) do nothing;

------------------------------------------------------------------ 4. Message drafts that staff approve before anything is sent
create table if not exists public.message_drafts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  body text not null check (length(body) between 1 and 300),
  reason text,
  entity_id uuid,
  status text not null default 'pending' check (status in ('pending', 'sent', 'dismissed')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists message_drafts_pending_idx on public.message_drafts (business_id, created_at desc) where status = 'pending';
create index if not exists message_drafts_customer_idx on public.message_drafts (customer_id);
alter table public.message_drafts enable row level security;
drop policy if exists message_drafts_read on public.message_drafts;
create policy message_drafts_read on public.message_drafts for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.message_drafts from anon, authenticated;
grant select on public.message_drafts to authenticated;

create or replace function public.zella_list_drafts(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'body', d.body, 'reason', d.reason, 'customer_id', d.customer_id,
            'customer', nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), 'created_at', d.created_at) order by d.created_at)
          from public.message_drafts d join public.customers c on c.id = d.customer_id
         where d.business_id = p_business_id and d.status = 'pending'), '[]'::jsonb);
end $$;

create or replace function public.zella_decide_draft(p_draft_id uuid, p_send boolean, p_body text default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.message_drafts; v_body text; v_id uuid;
begin
  select * into d from public.message_drafts where id = p_draft_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(d.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if p_send then
    v_body := left(coalesce(nullif(trim(p_body), ''), d.body), 300);
    if v_body ~ '[$€£]' or v_body ~* '\m(sale|discount|% off|offer ends|promo)\M' then raise exception 'NO_MARKETING_OR_PRICES'; end if;
    v_id := public.zella_queue_customer_message(d.business_id, d.customer_id, 'record_status_update',
              jsonb_build_object('status_line', v_body, 'status', 'draft', 'record_title', ''), interval '0', null, interval '0');
    if v_id is null then raise exception 'CANNOT_REACH'; end if;
    update public.message_drafts set status = 'sent', decided_by = auth.uid(), decided_at = now() where id = d.id;
  else
    update public.message_drafts set status = 'dismissed', decided_by = auth.uid(), decided_at = now() where id = d.id;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (d.business_id, auth.uid(), case when p_send then 'draft_sent' else 'draft_dismissed' end, 'message_draft', d.id, jsonb_build_object('customer_id', d.customer_id));
  return case when p_send then 'queued' else 'dismissed' end;
end $$;

------------------------------------------------------------------ 5. Review link
create or replace function public.zella_set_review_link(p_business_id uuid, p_url text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v text := nullif(trim(coalesce(p_url, '')), '');
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if v is not null and (v !~* '^https://[^\s]+$' or length(v) > 200) then raise exception 'BAD_URL'; end if;
  update public.businesses set setup_data = case when v is null then coalesce(setup_data, '{}'::jsonb) - 'review_link'
                                                  else jsonb_set(coalesce(setup_data, '{}'::jsonb), '{review_link}', to_jsonb(v)) end,
         updated_at = now()
   where id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'review_link_changed', 'business', p_business_id, jsonb_build_object('set', v is not null));
end $$;

create or replace function public.zella_get_review_link(p_business_id uuid)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return (select setup_data ->> 'review_link' from public.businesses where id = p_business_id);
end $$;

------------------------------------------------------------------ 6. Industry actions: drafts and {review_link}
create or replace function public.zella_industry_act(p_biz uuid, p_rule jsonb, p_cust uuid, p_entity uuid, p_title text, p_status text, p_assigned uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_line text; v_raw text; v_link text; t jsonb; nt jsonb;
begin
  if p_rule ? 'message' and p_cust is not null then
    v_raw := p_rule ->> 'message';
    v_link := null;
    if v_raw like '%{review_link}%' then
      select nullif(b.setup_data ->> 'review_link', '') into v_link from public.businesses b where b.id = p_biz;
      if v_link is null then v_raw := null; end if;   -- no review link saved: send nothing rather than a broken message
    end if;
    if v_raw is not null then
      v_line := left(replace(replace(replace(v_raw, '{title}', coalesce(p_title, '')), '{status}', coalesce(p_status, '')), '{review_link}', coalesce(v_link, '')), 300);
      if coalesce(p_rule ->> 'mode', '') = 'draft' then
        if not exists (select 1 from public.message_drafts where business_id = p_biz and customer_id = p_cust and status = 'pending' and entity_id is not distinct from p_entity and body = v_line) then
          insert into public.message_drafts (business_id, customer_id, body, reason, entity_id)
          values (p_biz, p_cust, v_line, left(coalesce(nullif(p_title, ''), 'Follow-up'), 120), p_entity);
          perform public.zella_notify_owners(p_biz, 'draft_ready', 'A message is ready to review', 'Check it and send it, or dismiss it.', 'info', 'drafts');
        end if;
      else
        perform public.zella_queue_customer_message(p_biz, p_cust, 'record_status_update',
          jsonb_build_object('status_line', v_line, 'status', p_status, 'record_title', p_title),
          make_interval(mins => greatest(1, coalesce((p_rule ->> 'delay_minutes')::int, 1))), null, interval '0');
      end if;
    end if;
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
revoke execute on function public.zella_industry_act(uuid, jsonb, uuid, uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_industry_act(uuid, jsonb, uuid, uuid, text, text, uuid) to service_role;

------------------------------------------------------------------ 7. Live notices ("full tonight", "closing early")
create table if not exists public.live_notices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null check (kind in ('full', 'closing_early', 'closed', 'custom')),
  message text not null check (length(message) between 3 and 200),
  ends_at timestamptz not null,
  created_by uuid,
  cleared_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists live_notices_active_idx on public.live_notices (business_id, ends_at) where cleared_at is null;
alter table public.live_notices enable row level security;
drop policy if exists live_notices_read on public.live_notices;
create policy live_notices_read on public.live_notices for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.live_notices from anon, authenticated;
grant select on public.live_notices to authenticated;

create or replace function public.zella_set_live_notice(p_business_id uuid, p_kind text, p_message text default null, p_hours integer default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tz text; v_msg text; v_end timestamptz; v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_kind not in ('full', 'closing_early', 'closed', 'custom') then raise exception 'BAD_KIND'; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = p_business_id;
  v_msg := regexp_replace(trim(coalesce(nullif(trim(p_message), ''), case p_kind
      when 'full' then 'We are fully booked for the rest of today.'
      when 'closing_early' then 'We are closing earlier than usual today.'
      when 'closed' then 'We are closed for the rest of today.'
      else null end)), '\s+', ' ', 'g');
  if v_msg is null or length(v_msg) < 3 then raise exception 'MESSAGE_REQUIRED'; end if;
  v_msg := left(v_msg, 200);
  v_end := case when p_hours is null then (date_trunc('day', now() at time zone v_tz) + interval '1 day') at time zone v_tz
                else now() + make_interval(hours => least(greatest(p_hours, 1), 72)) end;
  update public.live_notices set cleared_at = now() where business_id = p_business_id and kind = p_kind and cleared_at is null;
  insert into public.live_notices (business_id, kind, message, ends_at, created_by) values (p_business_id, p_kind, v_msg, v_end, auth.uid()) returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'live_notice_set', 'live_notice', v_id, jsonb_build_object('kind', p_kind));
  return v_id;
end $$;

create or replace function public.zella_clear_live_notice(p_business_id uuid, p_notice_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.live_notices set cleared_at = now() where id = p_notice_id and business_id = p_business_id and cleared_at is null;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'live_notice_cleared', 'live_notice', p_notice_id);
end $$;

create or replace function public.zella_active_notices(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'message', message, 'ends_at', ends_at) order by created_at)
                     from public.live_notices where business_id = p_business_id and cleared_at is null and ends_at > now()), '[]'::jsonb);
end $$;

-- The AI receptionist reads the notice through its prompt. The original prompt builder is kept as zella_brain_prompt_base.
do $$ begin
  if not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'zella_brain_prompt_base') then
    alter function public.zella_brain_prompt(uuid) rename to zella_brain_prompt_base;
  end if;
end $$;
create or replace function public.zella_brain_prompt(p_business_id uuid)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare t text; n text;
begin
  t := public.zella_brain_prompt_base(p_business_id);
  select string_agg('- ' || message, E'\n' order by created_at) into n
    from public.live_notices where business_id = p_business_id and cleared_at is null and ends_at > now();
  if n is not null then
    t := t || E'\nRIGHT NOW (this overrides anything above about availability; tell callers when it matters)\n' || n
           || E'\nDo not offer or confirm a booking or table that conflicts with this. Offer another day, a callback, or take a message.\n';
  end if;
  return t;
end $$;

------------------------------------------------------------------ 8. Grants for the new functions
do $$
declare f text;
begin
  foreach f in array array['zella_brain_prompt(uuid)', 'zella_brain_prompt_base(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_list_drafts(uuid)', 'zella_decide_draft(uuid,boolean,text)', 'zella_set_review_link(uuid,text)', 'zella_get_review_link(uuid)',
                           'zella_set_live_notice(uuid,text,text,integer)', 'zella_clear_live_notice(uuid,uuid)', 'zella_active_notices(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
