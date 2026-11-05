-- AI caller saving (zella_ai_caller_fixes.sql) and the per-industry message policy (zella_message_courtesy.sql).
\set ON_ERROR_STOP on
begin;
-- the industry lookup (reference data in production; the bare schema here has only some of it)
insert into public.industry_crm_presets (key, match, config) values ('beauty_salon', '{beautysalon}', '{"types":[]}'), ('dental', '{dental}', '{"types":[]}'), ('plumbing', '{plumbing}', '{"types":[]}')
on conflict (key) do nothing;
insert into public.industries (id, name, slug) values ('eb000000-0000-0000-0000-000000000001', 'Beauty Salon', 'beauty-salon'),
 ('eb000000-0000-0000-0000-000000000002', 'Dental', 'dental'), ('eb000000-0000-0000-0000-000000000003', 'Plumbing', 'plumbing') on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('eb000000-0000-0000-0000-0000000000a1', 'Salon Q', 'UTC', true, 'active', (select id from public.industries where slug = 'beauty-salon')),
 ('eb000000-0000-0000-0000-0000000000a2', 'Dental Q', 'UTC', true, 'active', (select id from public.industries where slug = 'dental')),
 ('eb000000-0000-0000-0000-0000000000a3', 'Plumbing Q', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing'));
insert into auth.users (id, email, email_confirmed_at) values ('eb000000-0000-0000-0000-00000000000a', 'own@q.test', now()), ('eb000000-0000-0000-0000-00000000000b', 'staff@q.test', now());
insert into public.business_members (business_id, user_id, role, status) values
 ('eb000000-0000-0000-0000-0000000000a2', 'eb000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('eb000000-0000-0000-0000-0000000000a2', 'eb000000-0000-0000-0000-00000000000b', 'staff', 'active');
insert into public.customers (id, business_id, first_name, phone, source) values
 ('eb000000-0000-0000-0000-0000000000c2', 'eb000000-0000-0000-0000-0000000000a2', 'Pat', '+15125550701', 'manual'),
 ('eb000000-0000-0000-0000-0000000000c3', 'eb000000-0000-0000-0000-0000000000a3', 'Lee', '+15125550702', 'manual');
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
  assert (select status || ':' || outcome_notes from public.followup_tasks where customer_id = c.id and kind = 'booking_follow_up') = 'skipped:The booking confirmation already says this.', 'no repeat booking text (kept as skipped, with the reason)';
  assert exists (select 1 from public.appointment_reminders where customer_id = c.id and kind = 'confirmation'), 'the booking scheduled its confirmation';
  assert (select status || ':' || outcome from public.followup_tasks where customer_id = c.id and kind = 'welcome_new_customer') = 'skipped:superseded', 'welcome withdrawn';

  -- salon: one after-visit check-in within 36 hours (the second is kept as skipped, with the reason); the review request still goes
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'feedback_request', '{}', interval '0', null, interval '0');
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'record_status_update', '{"record_title": "your visit", "status_line": "Thanks"}', interval '0', null, interval '0');
  assert (select count(*) from public.followup_tasks where customer_id = c.id and status = 'pending' and (kind = 'feedback_request' or vars ->> 'record_title' = 'your visit')) = 1, 'one check-in';
  assert (select outcome_notes from public.followup_tasks where customer_id = c.id and status = 'skipped' and vars ->> 'record_title' = 'your visit') = 'They already had an after-visit check-in.', 'held back, visible with its reason';
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'record_status_update', '{"record_title": "your visit", "status_line": "Review us", "review": true}', interval '0', null, interval '0');
  assert exists (select 1 from public.followup_tasks where customer_id = c.id and status = 'pending' and (vars ->> 'review')::boolean), 'salon review request goes';
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a1', c.id, 'record_status_update', '{"record_title": "Your repair", "status_line": "Ready"}', interval '0', null, interval '0');
  assert exists (select 1 from public.followup_tasks where customer_id = c.id and status = 'pending' and vars ->> 'record_title' = 'Your repair'), 'status updates are never held back';
end $$;

-- dental: no welcome, feedback or review request by default; reminders-type messages unaffected
do $$ declare c uuid := 'eb000000-0000-0000-0000-0000000000c2'; begin
  assert public.zella_message_policy_for('eb000000-0000-0000-0000-0000000000a2') ->> 'feedback_request' = 'off', 'dental default';
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a2', c, 'feedback_request', '{}', interval '0', null, interval '0');
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a2', c, 'welcome_new_customer', '{}', interval '0', null, interval '0');
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a2', c, 'record_status_update', '{"record_title": "your visit", "status_line": "Review us", "review": true}', interval '0', null, interval '0');
  assert not exists (select 1 from public.followup_tasks where customer_id = c and status = 'pending'), 'dental: nothing after a visit';
  assert (select count(*) from public.followup_tasks where customer_id = c and status = 'skipped' and outcome = 'policy') = 3, 'all three visible as held back';
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a2', c, 'cancellation_confirmation', '{}', interval '0', null, interval '0');
  assert exists (select 1 from public.followup_tasks where customer_id = c and kind = 'cancellation_confirmation' and status = 'pending'), 'dental: cancellation confirmation still goes';
end $$;

-- plumbing: the job-completed note is the check-in; a feedback request after it is held back
do $$ declare c uuid := 'eb000000-0000-0000-0000-0000000000c3'; begin
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a3', c, 'service_completed', '{"record_title": "Leak"}', interval '0', null, interval '0');
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a3', c, 'feedback_request', '{}', interval '0', null, interval '0');
  assert (select string_agg(kind || ':' || status, ',' order by kind) from public.followup_tasks where customer_id = c) = 'feedback_request:skipped,service_completed:pending', 'one plumbing check-in';
end $$;

-- cancellation and rescheduling withdraw the booking's own pending messages
do $$ declare c uuid := 'eb000000-0000-0000-0000-0000000000c3'; a uuid; b uuid; begin
  insert into public.appointments (business_id, customer_id, title, start_time, end_time) values ('eb000000-0000-0000-0000-0000000000a3', c, 'Boiler', now() + interval '5 days', now() + interval '5 days 1 hour') returning id into a;
  assert exists (select 1 from public.followup_tasks where appointment_id = a and kind = 'booking_follow_up' and status = 'pending'), 'plumbing without confirmations: booking follow-up queued';
  update public.appointments set start_time = start_time + interval '1 day', end_time = end_time + interval '1 day' where id = a;
  assert (select status || ':' || outcome from public.followup_tasks where appointment_id = a and kind = 'booking_follow_up') = 'cancelled:appointment_moved', 'moved: stale follow-up withdrawn';
  insert into public.appointments (business_id, customer_id, title, start_time, end_time) values ('eb000000-0000-0000-0000-0000000000a3', c, 'Tap', now() + interval '6 days', now() + interval '6 days 1 hour') returning id into b;
  update public.appointments set status = 'cancelled' where id = b;
  assert (select status from public.followup_tasks where appointment_id = b and kind = 'booking_follow_up') = 'cancelled', 'cancelled: follow-up withdrawn';
  assert exists (select 1 from public.followup_tasks where appointment_id = b and kind = 'cancellation_confirmation' and status = 'pending'), 'cancellation confirmation still queued';
end $$;

-- the owner can turn feedback on for their practice (audited); staff and other businesses can't
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"eb000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_message_policy('eb000000-0000-0000-0000-0000000000a2', '{"feedback_request":"on"}'); raise exception 'staff changed the policy';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_message_policy('eb000000-0000-0000-0000-0000000000a3'); raise exception 'read another business''s policy';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_message_policy_for('eb000000-0000-0000-0000-0000000000a3'); raise exception 'internal lookup callable';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"eb000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_set_message_policy('eb000000-0000-0000-0000-0000000000a2', '{"feedback_request":"loud"}'); raise exception 'bad value accepted';
  exception when others then if sqlerrm not like 'BAD_POLICY%' then raise; end if; end;
  assert public.zella_set_message_policy('eb000000-0000-0000-0000-0000000000a2', '{"feedback_request":"on"}') ->> 'feedback_request' = 'on', 'owner turned it on';
  assert public.zella_message_policy('eb000000-0000-0000-0000-0000000000a2') ->> 'review_request' = 'off', 'other defaults kept';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_logs where action = 'message_policy_changed' and business_id = 'eb000000-0000-0000-0000-0000000000a2'), 'change audited';
  perform public.zella_queue_customer_message('eb000000-0000-0000-0000-0000000000a2', 'eb000000-0000-0000-0000-0000000000c2', 'feedback_request', '{}', interval '0', null, interval '0');
  assert exists (select 1 from public.followup_tasks where customer_id = 'eb000000-0000-0000-0000-0000000000c2' and kind = 'feedback_request' and status = 'pending'), 'now queued';
end $$;
select 'PASS caller saving (text/call/email, new and existing, live call linked); message policy by industry: salon one check-in + review, dental nothing after a visit, plumbing job note as check-in, held-back messages visible, cancel/move withdraw booking messages, owner-only audited changes';
rollback;
