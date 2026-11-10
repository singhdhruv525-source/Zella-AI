-- Zella - customer messages: welcome, feedback request, cancellation confirmation, record-status updates,
-- service-due reminders and no-reply nudges. Safe to run more than once. Needs zella_followup_emails.sql first.
-- Nothing here sends anything. It queues follow-up tasks; the n8n Follow-up Texts / Emails workflows send them,
-- only when sms_live / email_live are true and the person can be contacted.

-- 1. A task can now carry its own details (a status line, a service name...).
alter table public.followup_tasks add column if not exists vars jsonb not null default '{}'::jsonb;

-- 2. The two claims return those details as 'vars'. The originals are kept under a new name and wrapped.
do $$
begin
  if to_regprocedure('public.zella_claim_followup_texts_base(integer,text[])') is null then
    alter function public.zella_claim_followup_texts(integer, text[]) rename to zella_claim_followup_texts_base;
  end if;
  if to_regprocedure('public.zella_claim_followup_emails_base(integer,text[])') is null then
    alter function public.zella_claim_followup_emails(integer, text[]) rename to zella_claim_followup_emails_base;
  end if;
end $$;

create or replace function public.zella_claim_followup_texts(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(e || jsonb_build_object('vars', coalesce((select f.vars from public.followup_tasks f where f.id = (e ->> 'task_id')::uuid), '{}'::jsonb))), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_followup_texts_base(p_limit, p_kinds)) e;
$$;
create or replace function public.zella_claim_followup_emails(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(e || jsonb_build_object('vars', coalesce((select f.vars from public.followup_tasks f where f.id = (e ->> 'task_id')::uuid), '{}'::jsonb))), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_followup_emails_base(p_limit, p_kinds)) e;
$$;

-- 3. Platform templates (text and email). A business or industry can override any of them.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, v.key, v.channel, v.purpose, 'en-US', v.subject, v.body, 1, 'active'
  from (values
    ('welcome_new_customer','sms','transactional',null,'Hi {{first_name}}, welcome to {{business}}. We have your details and will be in touch. Reply STOP to opt out.'),
    ('welcome_new_customer','email','transactional','Welcome to {{business}}',E'Hi {{first_name}},\n\nWelcome to {{business}}. We have your details and look forward to helping you.'),
    ('feedback_request','sms','transactional',null,'Hi {{first_name}}, how was your visit with {{business}}? Reply here with any feedback. Reply STOP to opt out.'),
    ('feedback_request','email','transactional','How was your visit to {{business}}?',E'Hi {{first_name}},\n\nThank you for visiting {{business}}. We would love to hear how it went. Just reply to this email with your feedback.'),
    ('cancellation_confirmation','sms','transactional',null,'Hi {{first_name}}, your appointment with {{business}} has been cancelled. Reply here if you would like to book a new time. Reply STOP to opt out.'),
    ('cancellation_confirmation','email','transactional','Your appointment with {{business}} is cancelled',E'Hi {{first_name}},\n\nYour appointment with {{business}} has been cancelled. If you would like to book a new time, please contact {{business}}.'),
    ('record_status_update','sms','transactional',null,'Hi {{first_name}}, an update from {{business}}: {{status_line}} Reply STOP to opt out.'),
    ('record_status_update','email','transactional','An update from {{business}}',E'Hi {{first_name}},\n\nAn update from {{business}}: {{status_line}}'),
    ('service_due','sms','transactional',null,'Hi {{first_name}}, it is time for your next {{service}} with {{business}}. Reply here to book. Reply STOP to opt out.'),
    ('service_due','email','transactional','Time for your next visit to {{business}}',E'Hi {{first_name}},\n\nIt is time for your next {{service}} with {{business}}. Please contact {{business}} to book a time.'),
    ('no_response_follow_up','sms','transactional',null,'Hi {{first_name}}, just checking in from {{business}}. Reply here if you still need help. Reply STOP to opt out.'),
    ('no_response_follow_up','email','transactional','Checking in from {{business}}',E'Hi {{first_name}},\n\nJust checking in from {{business}}. If you still need help, reply to this email and we will pick it up.')
  ) as v(key, channel, purpose, subject, body)
 where not exists (
   select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = v.channel and t.locale = 'en-US');

-- 4. One queue function for all of them. Picks text or email, never double-queues, never touches
--    people who opted out. Returns the new task id, or null when nothing was queued.
create or replace function public.zella_queue_customer_message(
  p_business_id uuid, p_customer_id uuid, p_kind text, p_vars jsonb default '{}'::jsonb,
  p_delay interval default interval '0', p_appointment_id uuid default null, p_dedupe interval default interval '30 days')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c record; v_channel text; v_id uuid;
begin
  if p_kind not in ('welcome_new_customer','feedback_request','cancellation_confirmation','record_status_update','service_due','no_response_follow_up') then
    raise exception 'BAD_KIND';
  end if;
  if coalesce(public.zella_setting('customer_touches', '{}'::jsonb) -> p_kind, 'true'::jsonb) = 'false'::jsonb then return null; end if;
  select x.id, x.phone, x.email, coalesce(x.do_not_contact,false) dnc, coalesce(x.do_not_sms,false) dns, coalesce(x.do_not_email,false) dne
    into c from public.customers x where x.id = p_customer_id and x.business_id = p_business_id;
  if c.id is null or c.dnc then return null; end if;
  if public.zella_digits(c.phone) is not null and not c.dns then v_channel := 'sms';
  elsif public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
  else return null; end if;
  if p_kind <> 'record_status_update' and exists (
       select 1 from public.followup_tasks f where f.customer_id = p_customer_id and f.kind = p_kind
          and (f.status in ('pending','in_progress') or f.created_at > now() - p_dedupe)
          and (p_appointment_id is null or f.appointment_id is not distinct from p_appointment_id)) then
    return null;
  end if;
  insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)
  values (p_business_id, p_customer_id, p_appointment_id, p_kind, v_channel, now() + p_delay, 2, coalesce(p_vars, '{}'::jsonb))
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $$;

-- 5. Welcome: a new person who came in by phone, chat or website (not bulk imports) gets one hello.
create or replace function public.zella_welcome_new_customer_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(lower(new.source), '') in ('import','csv','migration','booking','manual') then return new; end if;
  perform public.zella_queue_customer_message(new.business_id, new.id, 'welcome_new_customer', '{}'::jsonb, interval '10 minutes', null, interval '3650 days');
  return new;
exception when others then
  return new;   -- a messaging problem must never block saving the customer
end $$;
drop trigger if exists zella_welcome_new_customer on public.customers;
create trigger zella_welcome_new_customer after insert on public.customers
  for each row execute function public.zella_welcome_new_customer_trg();

-- 6. Appointment finished -> ask for feedback a few hours later. Appointment cancelled -> confirm it.
create or replace function public.zella_appointment_touches_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status and new.customer_id is not null then
    if new.status = 'completed' then
      perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'feedback_request', '{}'::jsonb, interval '3 hours', new.id, interval '30 days');
    elsif new.status = 'cancelled' and new.start_time > now() - interval '1 hour' then
      perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'cancellation_confirmation', '{}'::jsonb, interval '1 minute', new.id, interval '1 day');
    end if;
  end if;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_appointment_touches on public.appointments;
create trigger zella_appointment_touches after update of status on public.appointments
  for each row execute function public.zella_appointment_touches_trg();

-- 7. Record status updates (order ready, job scheduled...). Off unless the business adds an automation:
--    trigger_type 'record_status_update', trigger_config {"type_key":"repair","messages":{"ready":"Your repair is ready for pickup."}}
create or replace function public.zella_record_status_touches_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare a record; v_line text;
begin
  if new.status is distinct from old.status and new.customer_id is not null then
    for a in select * from public.automations x
              where x.business_id = new.business_id and x.trigger_type = 'record_status_update' and x.status = 'active'
                and (x.trigger_config ->> 'type_key' is null or x.trigger_config ->> 'type_key' = new.type_key) loop
      v_line := left(nullif(trim(a.trigger_config -> 'messages' ->> new.status), ''), 300);
      if v_line is not null then
        perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'record_status_update',
          jsonb_build_object('status_line', v_line, 'status', new.status, 'record_title', new.title), interval '1 minute', null, interval '0');
      end if;
    end loop;
  end if;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_record_status_touches on public.crm_records;
create trigger zella_record_status_touches after update of status on public.crm_records
  for each row execute function public.zella_record_status_touches_trg();

-- 8. Timed checks (daily): service due, and a nudge when a lead never answered.
--    Service due is off unless the business adds an automation: trigger_type 'service_due',
--    trigger_config {"days":180,"service":"cleaning"}.  No-reply nudge: a lead acknowledged 3+ days ago, still 'new'.
create or replace function public.zella_queue_customer_touches(p_limit integer default 50)
returns integer language plpgsql security definer set search_path = public as $$
declare a record; c record; n integer := 0; v_days integer;
begin
  for a in select * from public.automations x where x.trigger_type = 'service_due' and x.status = 'active' loop
    v_days := greatest(7, coalesce((a.trigger_config ->> 'days')::integer, 180));
    for c in select x.id from public.customers x
              where x.business_id = a.business_id and not coalesce(x.do_not_contact, false)
                and exists (select 1 from public.appointments p where p.customer_id = x.id and p.status = 'completed' and p.start_time < now() - make_interval(days => v_days))
                and not exists (select 1 from public.appointments p where p.customer_id = x.id and p.status not in ('cancelled','no_show') and p.start_time > now() - make_interval(days => v_days))
              limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
      if public.zella_queue_customer_message(a.business_id, c.id, 'service_due',
           jsonb_build_object('service', coalesce(nullif(a.trigger_config ->> 'service', ''), 'visit')), interval '0', null, make_interval(days => v_days)) is not null then
        n := n + 1;
      end if;
    end loop;
  end loop;
  for c in select x.id, x.business_id from public.customers x
            where x.lead_stage = 'new' and coalesce(x.last_contacted_at, x.created_at) < now() - interval '3 days'
              and coalesce(x.last_contacted_at, x.created_at) > now() - interval '14 days'
              and not coalesce(x.do_not_contact, false)
              and exists (select 1 from public.followup_tasks f where f.customer_id = x.id and f.status = 'done' and f.created_at > now() - interval '14 days')
            limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
    if public.zella_queue_customer_message(c.business_id, c.id, 'no_response_follow_up', '{}'::jsonb, interval '0', null, interval '14 days') is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_queue_customer_message(uuid,uuid,text,jsonb,interval,uuid,interval)', 'zella_queue_customer_touches(integer)',
    'zella_claim_followup_texts(integer,text[])', 'zella_claim_followup_emails(integer,text[])',
    'zella_claim_followup_texts_base(integer,text[])', 'zella_claim_followup_emails_base(integer,text[])'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- 9. Fix: the text claim read an offer record that was never filled for non-waitlist tasks, which made every
--    other kind fail. The record is now emptied at the start of each task.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_claim_followup_texts_base(integer,text[])'::regprocedure);
  if d not like '%where false;%' then
    d := replace(d, E'  loop\n', E'  loop\n    select e.id, e.title, e.status, e.offered_start, e.offered_end, e.offer_expires_at into v_offer from public.waitlist_entries e where false;\n');
    execute d;
  end if;
end $$;
