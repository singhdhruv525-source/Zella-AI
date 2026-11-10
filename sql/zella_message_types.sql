-- Zella - more customer message types (checklist 52, 53, 56, 58, 65, 70, 91). Safe to run more than once.
-- Needs zella_customer_touches.sql. Adds, for email and text:
--   reschedule_confirmation  (56) sent a minute after an appointment is moved
--   booking_follow_up        (52) sent an hour after a booking made for 2+ days ahead
--   service_completed        (58) sent when a job record is marked completed (if the owner has not set their own wording)
--   lead_follow_up           (53, 70, 91) day 1 of the lead sequence; no_response_follow_up is day 3; lead_final_follow_up is day 7
-- Each uses the same consent, quiet-hours, template and unsubscribe rules as every other message. Owners can edit wording
-- per business like any template, and turn any kind off in platform_settings customer_touches {"kind": false}.

-- 1. Wording (platform defaults; a business can override).
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, v.key, v.channel, 'transactional', 'en-US', v.subject, v.body, 1, 'active'
  from (values
    ('reschedule_confirmation', 'email', 'Your appointment with {{business}} has moved',
      E'Hi {{first_name}},\n\nYour appointment with {{business}} is now {{when}}. If that does not work, please reply to this email.'),
    ('reschedule_confirmation', 'sms', null,
      'Hi {{first_name}}, your appointment with {{business}} is now {{when}}. Reply here if that does not work. Reply STOP to opt out.'),
    ('booking_follow_up', 'email', 'Your booking with {{business}}',
      E'Hi {{first_name}},\n\nJust a note that you are booked with {{business}} for {{when}}. If you need to change it, reply to this email and we will help.'),
    ('booking_follow_up', 'sms', null,
      'Hi {{first_name}}, you are booked with {{business}} for {{when}}. Reply here if you need to change it. Reply STOP to opt out.'),
    ('service_completed', 'email', 'Your job with {{business}} is complete',
      E'Hi {{first_name}},\n\nYour job with {{business}} is complete. If anything does not look right, reply to this email and we will make it right.'),
    ('service_completed', 'sms', null,
      'Hi {{first_name}}, your job with {{business}} is complete. Reply here if anything does not look right. Reply STOP to opt out.'),
    ('lead_follow_up', 'email', 'Following up from {{business}}',
      E'Hi {{first_name}},\n\nThanks for your interest in {{business}}. Is there anything we can help with, or a time that suits you? Just reply to this email.'),
    ('lead_follow_up', 'sms', null,
      'Hi {{first_name}}, thanks for your interest in {{business}}. Can we help with anything, or find you a time? Reply STOP to opt out.'),
    ('lead_final_follow_up', 'email', 'One last note from {{business}}',
      E'Hi {{first_name}},\n\nWe do not want to bother you, so this is our last note. If you would still like help from {{business}}, reply to this email any time.'),
    ('lead_final_follow_up', 'sms', null,
      'Hi {{first_name}}, last note from {{business}}: if you would still like help, reply here any time. Reply STOP to opt out.')
  ) as v(key, channel, subject, body)
 where not exists (select 1 from public.message_templates t where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = v.channel and t.locale = 'en-US');

-- 2. Allow the new kinds.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_queue_customer_message(uuid,uuid,text,jsonb,interval,uuid,interval)'::regprocedure);
  if d not like '%lead_final_follow_up%' then
    d := replace(d, '''no_response_follow_up'')', '''no_response_follow_up'',''reschedule_confirmation'',''booking_follow_up'',''service_completed'',''lead_follow_up'',''lead_final_follow_up'')');
    if d not like '%lead_final_follow_up%' then raise exception 'PATCH_FAILED'; end if;
    execute d;
  end if;
end $$;

-- 3. Moved or newly booked appointments.
create or replace function public.zella_appointment_message_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tz text; v_when text;
begin
  if new.customer_id is null or new.status not in ('scheduled', 'confirmed') or new.start_time <= now() then return new; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = new.business_id;
  v_when := to_char(new.start_time at time zone v_tz, 'Dy Mon FMDD "at" FMHH12:MI AM');
  if tg_op = 'UPDATE' then
    if new.start_time is distinct from old.start_time and old.start_time > now() - interval '1 day' then
      perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'reschedule_confirmation', jsonb_build_object('when', v_when), interval '1 minute', new.id, interval '1 hour');
    end if;
  elsif coalesce(new.booking_state, 'confirmed') = 'confirmed' and new.start_time > now() + interval '2 days' then
    perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'booking_follow_up', jsonb_build_object('when', v_when), interval '1 hour', new.id, interval '1 day');
  end if;
  return new;
exception when others then
  return new;   -- a messaging problem must never block saving an appointment
end $$;
drop trigger if exists zella_appointment_message on public.appointments;
create trigger zella_appointment_message after insert or update of start_time on public.appointments
  for each row execute function public.zella_appointment_message_trg();

-- 4. A job record marked completed (when the owner has not set their own wording for that status).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_record_status_touches_trg()'::regprocedure);
  if d not like '%service_completed%' then
    d := replace(d, E'  end if;\n  return new;\nexception', E'    if new.status = ''completed'' and new.type_key in (''jobs'', ''work_orders'') and not exists (\n         select 1 from public.automations x where x.business_id = new.business_id and x.trigger_type = ''record_status_update'' and x.status = ''active''\n            and nullif(trim(x.trigger_config -> ''messages'' ->> ''completed''), '''') is not null) then\n      perform public.zella_queue_customer_message(new.business_id, new.customer_id, ''service_completed'', jsonb_build_object(''record_title'', new.title), interval ''5 minutes'', null, interval ''1 day'');\n    end if;\n  end if;\n  return new;\nexception');
    if d not like '%service_completed%' then raise exception 'PATCH_FAILED_RECORD'; end if;
    execute d;
  end if;
end $$;

-- 5. The lead sequence (daily): day 1, day 3 (no_response_follow_up, already there), day 7.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_queue_customer_touches(integer)'::regprocedure);
  if d not like '%lead_follow_up%' then
    d := replace(d, E'  return n;\nend', E'  -- lead sequence: day 1 for a lead nobody has reached, day 7 as the last note\n  for c in select x.id, x.business_id, case when x.created_at < now() - interval ''7 days'' then ''lead_final_follow_up'' else ''lead_follow_up'' end as kind\n             from public.customers x\n            where x.lead_stage in (''new'', ''contacted'') and not coalesce(x.do_not_contact, false)\n              and x.created_at < now() - interval ''1 day'' and x.created_at > now() - interval ''14 days''\n              and coalesce(x.last_contacted_at, x.created_at) < now() - interval ''1 day''\n              and coalesce(lower(x.source), '''') not in (''import'', ''csv'', ''migration'')\n              and not exists (select 1 from public.appointments p where p.customer_id = x.id and p.status <> ''cancelled'')\n            limit greatest(1, least(coalesce(p_limit, 50), 200)) loop\n    if public.zella_queue_customer_message(c.business_id, c.id, c.kind, ''{}''::jsonb, interval ''0'', null, interval ''14 days'') is not null then\n      n := n + 1;\n    end if;\n  end loop;\n  return n;\nend');
    if d not like '%lead_follow_up%' then raise exception 'PATCH_FAILED_TOUCHES'; end if;
    execute d;
  end if;
end $$;
