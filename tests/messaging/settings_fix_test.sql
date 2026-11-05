-- Regression tests for sql/zella_message_settings_fix.sql (tests/messaging/run.sh, isolated copy). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select 'e5000000-0000-0000-0000-000000000001', 'Msg Salon', i.id, 'UTC', true, 'active' from industries i where i.slug = 'beauty-salon';
insert into customers (id, business_id, first_name, phone, email) values
  ('e6000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000001', 'Ana', '+15125550111', 'ana@example.test'),
  ('e6000000-0000-0000-0000-000000000002', 'e5000000-0000-0000-0000-000000000001', 'Ben', '+15125550112', null);
insert into automations (business_id, name, trigger_type, status, trigger_config) values
  ('e5000000-0000-0000-0000-000000000001', 'Reminders', 'appointment_reminder', 'active', '{"hours_before": [24], "channel": "sms_and_call"}'),
  ('e5000000-0000-0000-0000-000000000001', 'Confirm', 'appointment_confirmation', 'active', '{"channel": "call"}'),
  ('e5000000-0000-0000-0000-000000000001', 'Quotes', 'quote_follow_up', 'active', '{"hours_after": 48, "max_attempts": 1, "channel": "email"}'),
  ('e5000000-0000-0000-0000-000000000001', 'After visit', 'post_appointment_follow_up', 'active', '{"hours_after": 2, "channel": "email"}');

do $$ declare v_appt uuid; r record; begin
  insert into appointments (id, business_id, customer_id, title, start_time, end_time, status)
  values ('e7000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000001', 'e6000000-0000-0000-0000-000000000001', 'Cut', now() + interval '3 days', now() + interval '3 days 1 hour', 'scheduled');
  perform public.zella_replace_reminders('e7000000-0000-0000-0000-000000000001', true, 'booked');
  assert not exists (select 1 from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001' and channel not in ('sms', 'email')), 'a call reminder was queued';
  assert (select count(*) from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001' and kind = 'reminder' and status = 'pending') = 1, 'reminder not queued';
  raise notice 'PASS M3 reminders and confirmations saved as "by AI call" are queued as texts, so they are sent';
end $$;

-- M4: changing the reminder automation re-plans waiting reminders; off withdraws them; the sender skips if off
do $$ declare v_due timestamptz; r jsonb; begin
  update automations set trigger_config = trigger_config || '{"hours_before": [48, 2]}' where business_id = 'e5000000-0000-0000-0000-000000000001' and trigger_type = 'appointment_reminder';
  assert (select array_agg(hours_before order by hours_before) from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001' and kind = 'reminder' and status = 'pending') = '{2,48}',
    'timing change not followed: ' || (select string_agg(hours_before::text || ':' || status, ',') from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001');
  assert exists (select 1 from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001' and kind = 'confirmation' and status = 'pending'), 'the waiting booking confirmation was lost';
  update automations set status = 'paused' where business_id = 'e5000000-0000-0000-0000-000000000001' and trigger_type = 'appointment_reminder';
  assert not exists (select 1 from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001' and kind = 'reminder' and status = 'pending'), 'paused reminders still waiting';
  -- safety net: a reminder that slipped through is skipped by the sender while the automation is off
  insert into appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
  values ('e5000000-0000-0000-0000-000000000001', 'e7000000-0000-0000-0000-000000000001', 'e6000000-0000-0000-0000-000000000001', 'reminder', 1, 'test', now() - interval '1 minute', 'sms');
  r := public.zella_claim_reminders(25, 'sms');
  assert (select error from appointment_reminders where reason = 'test') = 'automation_off', 'sender sent a reminder of a paused automation: ' || r;
  update automations set status = 'paused' where business_id = 'e5000000-0000-0000-0000-000000000001' and trigger_type = 'appointment_confirmation';
  assert not exists (select 1 from appointment_reminders where appointment_id = 'e7000000-0000-0000-0000-000000000001' and kind = 'confirmation' and status = 'pending'), 'confirmations off: still waiting';
  raise notice 'PASS M4 a reminder timing change re-plans waiting reminders (confirmation kept); switching off withdraws them; the sender skips reminders whose automation is off';
end $$;

-- M1 + M2: quote follow-up timing, attempts and email
do $$ declare q record; t record; begin
  insert into quotes (business_id, customer_id, title, expires_at, max_follow_ups, follow_up_every_days, next_follow_up_at)
  select 'e5000000-0000-0000-0000-000000000001', 'e6000000-0000-0000-0000-000000000001', 'Q', now() + interval '30 days', 3, 3, null;
  update quotes set next_follow_up_at = now() - interval '1 minute' where title = 'Q';
  perform public.zella_queue_quote_followups();
  select * into t from followup_tasks where kind = 'quote_follow_up' and customer_id = 'e6000000-0000-0000-0000-000000000001';
  assert t.channel = 'email', 'quote follow-up chose Email but went as ' || coalesce(t.channel, 'nothing');
  raise notice 'PASS M2 quote follow-ups set to Email are queued as email when the customer has an address';
end $$;

do $$ declare n_email int; n_sms int; begin
  insert into appointments (id, business_id, customer_id, title, start_time, end_time, status) values
    ('e7000000-0000-0000-0000-000000000002', 'e5000000-0000-0000-0000-000000000001', 'e6000000-0000-0000-0000-000000000001', 'V1', now() - interval '2 hours', now() - interval '1 hour', 'scheduled'),
    ('e7000000-0000-0000-0000-000000000003', 'e5000000-0000-0000-0000-000000000001', 'e6000000-0000-0000-0000-000000000002', 'V2', now() - interval '2 hours', now() - interval '1 hour', 'scheduled');
  update appointments set status = 'completed' where id in ('e7000000-0000-0000-0000-000000000002', 'e7000000-0000-0000-0000-000000000003');
  select count(*) filter (where channel = 'email'), count(*) filter (where channel = 'sms') into n_email, n_sms
    from followup_tasks where kind = 'post_appointment_follow_up' and appointment_id in ('e7000000-0000-0000-0000-000000000002', 'e7000000-0000-0000-0000-000000000003');
  assert n_email = 1 and n_sms = 1, format('post-visit: email %s sms %s (Ana has an email, Ben does not)', n_email, n_sms);
  raise notice 'PASS M2 post-visit follow-ups set to Email go by email, or by text when the customer has no email';
end $$;

-- M1: a quote issued by the owner follows the saved timing and attempts (48 hours, 1 try)
reset role;
insert into auth.users (id, email, email_confirmed_at) values ('e8000000-0000-0000-0000-000000000001', 'owner@msg.test', now());
insert into business_members (business_id, user_id, role, status) values ('e5000000-0000-0000-0000-000000000001', 'e8000000-0000-0000-0000-000000000001', 'owner', 'active');
select set_config('request.jwt.claims', '{"sub":"e8000000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
select public.zella_issue_quote('e6000000-0000-0000-0000-000000000002', 'Fence', 30);
reset role;
do $$ declare q record; begin
  select * into q from quotes where title = 'Fence';
  assert q.max_follow_ups = 1 and q.follow_up_every_days = 2, format('quote used %s follow-ups every %s days (saved: 1 try, 48 hours)', q.max_follow_ups, q.follow_up_every_days);
  assert q.next_follow_up_at between now() + interval '47 hours' and now() + interval '49 hours', 'first follow-up not 2 days out: ' || q.next_follow_up_at;
  raise notice 'PASS M1 a quote follows the saved "follow up after 2 days, 1 try" (was always 3 follow-ups every 3 days)';
end $$;
