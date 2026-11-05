-- AI caller saving (zella_ai_caller_fixes.sql) and one booking message / one after-visit check-in (zella_message_courtesy.sql).
\set ON_ERROR_STOP on
begin;
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values ('eb000000-0000-0000-0000-0000000000a1', 'Salon Q', 'UTC', true, 'active');
insert into public.automations (business_id, name, trigger_type, status, trigger_config, actions, conditions) values
 ('eb000000-0000-0000-0000-0000000000a1', 'Confirm', 'appointment_confirmation', 'active', '{}', '[]', '{}');
insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled) values
 ('eb000000-0000-0000-0000-0000000000a1', 'inbound', 'answered', '+15125550601', 'q-call-1', true),
 ('eb000000-0000-0000-0000-0000000000a1', 'inbound', 'answered', '+15125550602', 'q-call-2', true);
do $$ declare c record; r jsonb; begin
  -- new caller who wants texts: saved, used for messages, call linked
  r := public.zella_ai_tool('q-call-1', 'eb000000-0000-0000-0000-0000000000a1', 'update_caller', '{"first_name":"Ana","preferred_contact_method":"text"}');
  select * into c from public.customers where phone = '+15125550601';
  assert c.preferred_contact_method = 'sms' and c.preferred_channel = 'sms', 'text me saved for a new caller';
  assert (select customer_id from public.calls where external_call_id = 'q-call-1') = c.id, 'live call linked';
  -- existing caller who wants a call: no failure, saved as voice, channel unchanged
  r := public.zella_ai_tool('q-call-1', 'eb000000-0000-0000-0000-0000000000a1', 'update_caller', '{"preferred_contact_method":"call"}');
  assert r ->> 'status' = 'saved', 'call preference saved: ' || r::text;
  assert (select preferred_contact_method || '/' || preferred_channel from public.customers where id = c.id) = 'voice/sms', 'voice saved, text channel kept';
  r := public.zella_ai_tool('q-call-1', 'eb000000-0000-0000-0000-0000000000a1', 'update_caller', '{"preferred_contact_method":"email"}');
  assert (select preferred_channel from public.customers where id = c.id) = 'email', 'email me changes the message channel';

  -- one booking message: the confirmation, not a repeat follow-up; the welcome gives way
  update public.followup_tasks set status = 'pending' where customer_id = c.id and kind = 'welcome_new_customer';
  insert into public.appointments (business_id, customer_id, title, start_time, end_time) values ('eb000000-0000-0000-0000-0000000000a1', c.id, 'Cut', now() + interval '5 days', now() + interval '5 days 1 hour');
  assert not exists (select 1 from public.followup_tasks where customer_id = c.id and kind = 'booking_follow_up'), 'no repeat booking text';
  assert exists (select 1 from public.appointment_reminders where customer_id = c.id and kind = 'confirmation'), 'the booking scheduled its confirmation';
  assert (select status || ':' || outcome from public.followup_tasks where customer_id = c.id and kind = 'welcome_new_customer') = 'skipped:superseded', 'welcome withdrawn';

  -- one after-visit check-in within 36 hours; review-style notes on other subjects still go
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'feedback_request', '{}', interval '0', null, interval '0');
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'record_status_update', '{"record_title": "your visit", "status_line": "Thanks"}', interval '0', null, interval '0');
  assert (select count(*) from public.followup_tasks where customer_id = c.id and (kind = 'feedback_request' or vars ->> 'record_title' = 'your visit')) = 1, 'one check-in';
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'record_status_update', '{"record_title": "Your repair", "status_line": "Ready"}', interval '0', null, interval '0');
  assert exists (select 1 from public.followup_tasks where customer_id = c.id and vars ->> 'record_title' = 'Your repair'), 'status updates are never held back';
end $$;
select 'PASS caller saving (text/call/email, new and existing, live call linked) and one booking message / one after-visit check-in';
rollback;
