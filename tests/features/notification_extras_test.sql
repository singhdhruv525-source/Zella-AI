-- Notification extras (staging only). Needs on_call, reviews and scorecards applied first (run.sh order).
\i ../voice-reliability/fixture.sql
delete from public.staff_notifications; delete from public.zella_milestones; delete from public.on_call_reminders_sent; delete from public.on_call_shifts;
delete from public.on_call_settings; delete from public.business_members; delete from public.profiles; delete from public.reviews; delete from public.callbacks; delete from public.crm_tasks;
delete from public.platform_alerts; delete from public.platform_admins; delete from public.ai_tool_calls;
insert into profiles (id, first_name, last_name, phone) values ('0aaaaaaa-0000-4000-8000-000000000001', 'Olivia', 'Owner', null), ('0aaaaaaa-0000-4000-8000-000000000002', 'Sam', 'Rivera', '+1 (555) 020-0001');
insert into business_members (business_id, user_id, role, status, sms_alerts) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000001', 'owner', 'active', false),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', 'active', true);
insert into staff_members (id, business_id, name, phone, is_active) values ('5aaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Sam Rivera', '+15550200001', true);

do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; n int;
begin
  -- calls answered by the AI: 1st and 100th are celebrated once each
  insert into calls (business_id, direction, status, ai_handled, started_at) select A, 'inbound', 'completed', true, now() - g * interval '1 minute' from generate_series(1, 100) g;
  insert into ai_tool_calls (business_id, tool, status, verified) values (A, 'book_appointment', 'done', true), (A, 'book_appointment', 'done', false);
  perform zella_check_milestones();
  perform zella_check_milestones();
  assert (select count(*) from staff_notifications where business_id = A and kind = 'milestone') = 3, (select string_agg(title, ' | ') from staff_notifications);
  assert exists (select 1 from staff_notifications where title = 'Your AI receptionist has answered 100 calls');
  assert exists (select 1 from staff_notifications where title = 'Your AI receptionist booked its first appointment');
  raise notice 'PASS milestones (first call, 100 calls, first verified AI booking) are celebrated once each, even when checked twice';

  insert into reviews (business_id, provider, external_id, author_name, rating, body) values (A, 'manual', 'x1', 'Ana Lopez', 5, 'Wonderful!');
  assert (select title from staff_notifications where kind = 'five_star_review') = '5-star review from Ana';
  raise notice 'PASS a 5-star review is celebrated with the reviewer''s first name';

  -- on call: a cover shift starting in 30 minutes
  insert into on_call_settings (business_id, enabled) values (A, true);
  insert into on_call_shifts (business_id, staff_id, kind, starts_at, ends_at) values (A, '5aaaaaaa-0000-4000-8000-000000000001', 'cover', now() + interval '30 minutes', now() + interval '10 hours');
  perform zella_on_call_reminders(); perform zella_on_call_reminders();
  assert (select count(*) from staff_notifications where kind = 'on_call_starting' and user_id is null) = 1;
  assert (select sms_status from staff_notifications where kind = 'on_call_starting' and user_id = '0aaaaaaa-0000-4000-8000-000000000002') = 'pending';
  raise notice 'PASS the team is told once who is on call; Sam (matched by phone) gets their own reminder, marked for a text because Sam opted in';
  update business_members set sms_alerts = false where user_id = '0aaaaaaa-0000-4000-8000-000000000002';
  delete from staff_notifications where kind = 'on_call_starting'; delete from on_call_reminders_sent;
  perform zella_on_call_reminders();
  assert (select sms_status from staff_notifications where kind = 'on_call_starting' and user_id = '0aaaaaaa-0000-4000-8000-000000000002') is null;
  assert (select sms_status from staff_notifications where kind = 'on_call_starting' and user_id is null) is null;
  raise notice 'PASS without text alerts switched on, nobody is texted; the team copy is never texted';
  update on_call_settings set enabled = false; delete from staff_notifications where kind = 'on_call_starting'; delete from on_call_reminders_sent;
  perform zella_on_call_reminders();
  assert (select count(*) from staff_notifications where kind = 'on_call_starting') = 0;
  raise notice 'PASS no reminders while the rota is switched off';

  -- an urgent alert is still texted as before
  update business_members set sms_alerts = true where user_id = '0aaaaaaa-0000-4000-8000-000000000002';
  perform zella_notify(A, 'emergency_call', 'Emergency', null, 'urgent', 'calls', null, '0aaaaaaa-0000-4000-8000-000000000002');
  assert (select sms_status from staff_notifications where kind = 'emergency_call') = 'pending';
  raise notice 'PASS urgent alerts are still marked for a text exactly as before';
end $$;

-- the Monday nudge: 9:15 am on Monday 2 November 2026 in New York
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
begin
  insert into callbacks (business_id, reason, priority, status, contact_number, assigned_to, due_at, created_by)
    values (A, 'requested', 'normal', 'due', '+15551230001', '0aaaaaaa-0000-4000-8000-000000000002', now() - interval '1 day', 'system');
  perform zella_team_scorecard_nudge('2026-11-03 09:15 America/New_York');
  assert (select count(*) from staff_notifications where kind = 'team_scorecard') = 0, 'tuesday';
  perform zella_team_scorecard_nudge('2026-11-02 09:15 America/New_York'); perform zella_team_scorecard_nudge('2026-11-02 09:45 America/New_York');
  assert (select count(*) from staff_notifications where kind = 'team_scorecard') = 1;
  assert (select body from staff_notifications where kind = 'team_scorecard') = 'Overdue right now: Sam Rivera (1 callback).', (select body from staff_notifications where kind = 'team_scorecard');
  raise notice 'PASS Monday 9 am: one line to the owners about who is behind (Sam: 1 callback), only once, and not on other days';
end $$;

-- admin bell
do $$
declare v uuid; v_err text;
begin
  insert into platform_admins (user_id, role, is_active) values ('0dddddd0-0000-4000-8000-000000000001', 'super_admin', true);
  v := zella_platform_alert('queue_backlog', 'Follow-ups are waiting', '3 items', 'warning', null, 'followups');
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_admin_acknowledge_alert(v); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  perform set_config('request.jwt.claim.sub', '0dddddd0-0000-4000-8000-000000000001', true);
  assert zella_admin_acknowledge_alert(v);
  assert (select status from platform_alerts where id = v) = 'acknowledged';
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS a Zella admin can acknowledge an alert from the bell; a business owner cannot';
end $$;
