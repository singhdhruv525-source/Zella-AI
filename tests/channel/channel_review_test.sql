-- Regression tests for sql/zella_channel_review.sql (tests/channel/run.sh). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role; set timezone = 'UTC';
select set_config('request.jwt.claims', '', false);

do $$ begin
  assert (select count(*) from automation_channel_reviews where status = 'needs_review') = 4, 'reviews: ' || (select count(*) from automation_channel_reviews)::text;
  assert not exists (select 1 from automation_channel_reviews where business_id = 'ec000000-0000-0000-0000-00000000000d'), 'a text-only business got a review';
  assert (select trigger_config ->> 'channel' from automations where business_id = 'ec000000-0000-0000-0000-00000000000b') = 'sms_and_call'
     and not (select trigger_config ? 'channel_requested' from automations where business_id = 'ec000000-0000-0000-0000-00000000000b'),
     'the automation M3 switched is not back to what the owner saved';
  assert (select requested_channel from automation_channel_reviews where business_id = 'ec000000-0000-0000-0000-00000000000b') = 'sms_and_call', 'requested channel lost';
  assert (select count(*) from staff_notifications where kind = 'automation_review' and business_id::text like 'ec000000-%') = 4, 'owners not told';
  raise notice 'PASS C1 every automation saved as AI call (including one M3 switched to text) is held for review, back on the owner''s own setting, and its owners are told; text-only businesses are untouched';
end $$;

do $$ declare n int; begin
  assert not exists (select 1 from appointment_reminders where business_id = 'ec000000-0000-0000-0000-00000000000a' and status = 'pending'),
    'a reminder still waits to be sent as a text for an AI-call automation';
  perform public.zella_replace_reminders('ec200000-0000-0000-0000-00000000000a', true, 'booked');
  assert not exists (select 1 from appointment_reminders where business_id = 'ec000000-0000-0000-0000-00000000000a' and status = 'pending'), 'new reminders queued while held';
  -- a leftover pending row is held by the sender, visibly
  insert into appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel, status)
  values ('ec000000-0000-0000-0000-00000000000a', 'ec200000-0000-0000-0000-00000000000a', 'ec100000-0000-0000-0000-00000000000a', 'reminder', 1, 'test', now() - interval '1 minute', 'sms', 'pending');
  perform public.zella_claim_reminders(50, 'sms');
  assert (select error from appointment_reminders where business_id = 'ec000000-0000-0000-0000-00000000000a' and hours_before = 1) = 'channel_needs_review', 'held reminder was claimed';
  -- the text-only business is unaffected
  insert into appointments (id, business_id, customer_id, title, start_time, end_time, timezone, status)
  values ('ec200000-0000-0000-0000-00000000000d', 'ec000000-0000-0000-0000-00000000000d', 'ec100000-0000-0000-0000-00000000000d', 'Cut', date_trunc('hour', now()) + interval '3 days', date_trunc('hour', now()) + interval '3 days 30 minutes', 'UTC', 'scheduled');
  perform public.zella_replace_reminders('ec200000-0000-0000-0000-00000000000d', false, 'booked');
  select count(*) into n from appointment_reminders where business_id = 'ec000000-0000-0000-0000-00000000000d' and status = 'pending' and channel = 'sms';
  assert n = 1, 'text business reminders: ' || n;
  -- waitlist: no offer at all, rather than a text
  assert public.zella_offer_slot('ec000000-0000-0000-0000-00000000000c', now() + interval '1 day', now() + interval '1 day 30 minutes', null, null) = 0, 'waitlist offer sent';
  assert not exists (select 1 from followup_tasks where business_id = 'ec000000-0000-0000-0000-00000000000c' and kind = 'waitlist_offer'), 'waitlist text queued';
  raise notice 'PASS C1 while held: no reminder, confirmation or waitlist offer is queued or sent, leftovers are held as channel_needs_review; other businesses unchanged';
end $$;

do $$ begin
  begin perform public.zella_clean_automation_config('appointment_reminder', '{"channel":"call"}'); raise exception 'call accepted for reminders';
  exception when raise_exception then if sqlerrm <> 'BAD_FIELD:channel' then raise; end if; end;
  begin perform public.zella_clean_automation_config('waitlist_offer', '{"channel":"call"}'); raise exception 'call accepted for waitlist';
  exception when raise_exception then if sqlerrm <> 'BAD_FIELD:channel' then raise; end if; end;
  begin perform public.zella_clean_automation_config('appointment_confirmation', '{"channel":"sms_and_call"}'); raise exception 'sms_and_call accepted';
  exception when raise_exception then if sqlerrm <> 'BAD_FIELD:channel' then raise; end if; end;
  assert public.zella_clean_automation_config('no_show_follow_up', '{"channel":"call"}') ->> 'channel' = 'call', 'no-show AI callbacks (built) refused';
  assert public.zella_clean_automation_config('appointment_reminder', '{"channel":"email"}') ->> 'channel' = 'email', 'email reminders refused';
  raise notice 'PASS C1 saving AI call for reminders, confirmations or waitlist offers is refused (BAD_FIELD:channel); built channels still save';
end $$;

-- the owner decides
insert into auth.users (id, email, email_confirmed_at) values ('ec300000-0000-0000-0000-000000000001', 'owner@calls.test', now()), ('ec300000-0000-0000-0000-000000000002', 'mgr@calls.test', now());
insert into business_members (business_id, user_id, role, status) select b.id, 'ec300000-0000-0000-0000-000000000001', 'owner', 'active' from businesses b where b.id::text like 'ec000000-%';
insert into business_members (business_id, user_id, role, status) values ('ec000000-0000-0000-0000-00000000000a', 'ec300000-0000-0000-0000-000000000002', 'manager', 'active');
select set_config('request.jwt.claims', '{"sub":"ec300000-0000-0000-0000-000000000002","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare rem uuid := (select automation_id from automation_channel_reviews where business_id = 'ec000000-0000-0000-0000-00000000000a' and trigger_type = 'appointment_reminder'); begin
  assert jsonb_array_length(public.zella_channel_reviews('ec000000-0000-0000-0000-00000000000a')) = 2, 'manager cannot see the reviews';
  begin perform public.zella_resolve_channel_review(rem, 'sms', true); raise exception 'manager resolved';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"ec300000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare rem uuid := (select automation_id from automation_channel_reviews where business_id = 'ec000000-0000-0000-0000-00000000000a' and trigger_type = 'appointment_reminder');
             wl uuid := (select automation_id from automation_channel_reviews where business_id = 'ec000000-0000-0000-0000-00000000000c'); begin
  begin perform public.zella_resolve_channel_review(rem, 'sms', false); raise exception 'resolved without confirming consent';
  exception when raise_exception then if sqlerrm <> 'CONSENT_NOT_CONFIRMED' then raise; end if; end;
  begin perform public.zella_resolve_channel_review(wl, 'email', true); raise exception 'email accepted for waitlist';
  exception when raise_exception then if sqlerrm <> 'BAD_CHOICE' then raise; end if; end;
  perform public.zella_resolve_channel_review(rem, 'sms', true);
  perform public.zella_resolve_channel_review(wl, 'off', false);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
do $$ begin
  assert (select trigger_config ->> 'channel' from automations where business_id = 'ec000000-0000-0000-0000-00000000000a' and trigger_type = 'appointment_reminder') = 'sms', 'choice not saved';
  assert exists (select 1 from appointment_reminders where business_id = 'ec000000-0000-0000-0000-00000000000a' and kind = 'reminder' and status = 'pending' and channel = 'sms'),
    'reminders for the waiting booking were not planned after the owner chose text';
  assert (select new_data ->> 'customers_agreed_to_channel' from audit_logs where action = 'automation_channel_resolved' and business_id = 'ec000000-0000-0000-0000-00000000000a') = 'true', 'consent not recorded';
  assert (select status from automations where business_id = 'ec000000-0000-0000-0000-00000000000c') = 'disabled', 'waitlist not switched off';
  assert (select count(*) from automation_channel_reviews where status = 'needs_review') = 2, 'other reviews closed';
  raise notice 'PASS C1 only owners and admins decide; text or email needs consent confirmed (recorded in the audit log); after choosing text the waiting booking gets its reminders; off switches the automation off; managers can see but not decide';
end $$;
