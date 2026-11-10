-- Staff scorecards (staging only). 30-day window ending now.
\i ../voice-reliability/fixture.sql
delete from public.business_members; delete from public.profiles; delete from public.callbacks; delete from public.callback_attempts; delete from public.crm_tasks;
insert into profiles (id, first_name, last_name) values ('0aaaaaaa-0000-4000-8000-000000000001', 'Olivia', 'Owner'), ('0aaaaaaa-0000-4000-8000-000000000002', 'Sam', 'Staff');
insert into business_members (business_id, user_id, role, status) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000001', 'owner', 'active'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', 'active'),
  ('bbbbbbbb-0000-4000-8000-000000000002', '0bbbbbbb-0000-4000-8000-000000000001', 'owner', 'active');
-- Sam: 3 callbacks this month (first attempts after 10, 20 and 30 minutes; 2 completed), 1 overdue now, 1 from last year
insert into callbacks (id, business_id, reason, priority, status, contact_number, assigned_to, created_at, due_at, completed_at, created_by) values
  ('cb000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'missed_call', 'normal', 'completed', '+15551230001', '0aaaaaaa-0000-4000-8000-000000000002', now() - interval '5 days', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', 'system'),
  ('cb000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'missed_call', 'normal', 'completed', '+15551230002', '0aaaaaaa-0000-4000-8000-000000000002', now() - interval '4 days', now() - interval '4 days', now() - interval '4 days' + interval '1 hour', 'system'),
  ('cb000000-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'requested', 'normal', 'due', '+15551230003', '0aaaaaaa-0000-4000-8000-000000000002', now() - interval '3 days', now() - interval '1 day', null, 'system'),
  ('cb000000-0000-4000-8000-000000000004', 'aaaaaaaa-0000-4000-8000-000000000001', 'requested', 'normal', 'completed', '+15551230004', '0aaaaaaa-0000-4000-8000-000000000002', now() - interval '400 days', now() - interval '400 days', now() - interval '400 days', 'system');
insert into callback_attempts (callback_id, business_id, attempt_no, attempted_at, outcome) values
  ('cb000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 1, now() - interval '5 days' + interval '10 minutes', 'connected'),
  ('cb000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 1, now() - interval '4 days' + interval '20 minutes', 'no_answer'),
  ('cb000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 2, now() - interval '4 days' + interval '50 minutes', 'connected'),
  ('cb000000-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 1, now() - interval '3 days' + interval '30 minutes', 'no_answer');
update customers set lead_stage = 'won', assigned_to = '0aaaaaaa-0000-4000-8000-000000000002', created_at = now() - interval '10 days', converted_at = now() - interval '2 days',
  last_contacted_at = now() - interval '10 days' + interval '2 hours' where id = 'cccccccc-0000-4000-8000-000000000001';
update customers set lead_stage = 'new', assigned_to = '0aaaaaaa-0000-4000-8000-000000000002', created_at = now() - interval '1 day' where id = 'cccccccc-0000-4000-8000-000000000002';
insert into crm_tasks (business_id, kind, title, priority, status, due_at, assigned_to, source, completed_at) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'follow_up', 'Call back', 'normal', 'done', now() - interval '2 days', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', now() - interval '2 days'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'follow_up', 'Send quote', 'normal', 'open', now() - interval '1 day', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', null);
insert into staff_members (id, business_id, name, phone, is_active, sort_order) values
  ('5aaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Dr Kim', null, true, 1),
  ('5aaaaaaa-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'Dr Lee', null, true, 2);
insert into appointments (business_id, staff_id, title, status, start_time, end_time) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '5aaaaaaa-0000-4000-8000-000000000001', 'A', 'completed', now() - interval '3 days', now() - interval '3 days' + interval '30 minutes'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '5aaaaaaa-0000-4000-8000-000000000001', 'B', 'no_show', now() - interval '2 days', now() - interval '2 days' + interval '30 minutes'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '5aaaaaaa-0000-4000-8000-000000000001', 'C', 'cancelled', now() - interval '1 day', now() - interval '1 day' + interval '30 minutes');

do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; r jsonb; sam jsonb; v_err text; kim jsonb;
begin
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  r := zella_staff_scorecards(A, now() - interval '30 days', now());
  assert (r ->> 'everyone')::boolean and jsonb_array_length(r -> 'people') = 2, r::text;
  select p into sam from jsonb_array_elements(r -> 'people') p where p ->> 'name' = 'Sam Staff';
  assert sam #>> '{callbacks,assigned}' = '3' and sam #>> '{callbacks,completed}' = '2' and sam #>> '{callbacks,median_minutes_to_first_call}' = '20'
     and sam #>> '{callbacks,overdue_now}' = '1', 'callbacks ' || sam::text;
  assert sam #>> '{leads,assigned}' = '2' and sam #>> '{leads,won}' = '1' and sam #>> '{leads,median_hours_to_contact}' = '2.0', 'leads ' || sam::text;
  assert sam #>> '{tasks,completed}' = '1' and sam #>> '{tasks,overdue_now}' = '1', 'tasks ' || sam::text;
  raise notice 'PASS Sam''s month: 3 callbacks (2 done, first call after a median 20 minutes, 1 overdue), 2 leads (1 won, contacted in 2 hours), 1 task done and 1 overdue; last year''s callback not counted';
  select b into kim from jsonb_array_elements(r -> 'bookable') b where b ->> 'name' = 'Dr Kim';
  assert kim ->> 'booked' = '3' and kim ->> 'completed' = '1' and kim ->> 'no_shows' = '1' and kim ->> 'cancelled' = '1', kim::text;
  assert exists (select 1 from jsonb_array_elements(r -> 'bookable') b where b ->> 'name' = 'Dr Lee' and b ->> 'booked' = '0');
  raise notice 'PASS bookable team: Dr Kim 3 booked (1 done, 1 no-show, 1 cancelled), Dr Lee none';

  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000002', true);
  r := zella_staff_scorecards(A, now() - interval '30 days', now());
  assert not (r ->> 'everyone')::boolean and jsonb_array_length(r -> 'people') = 1 and r #>> '{people,0,name}' = 'Sam Staff'
     and jsonb_array_length(r -> 'bookable') = 0, r::text;
  raise notice 'PASS a staff member sees only their own scorecard';
  perform set_config('request.jwt.claim.sub', '0bbbbbbb-0000-4000-8000-000000000001', true);
  begin perform zella_staff_scorecards(A, now() - interval '30 days', now()); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_staff_scorecards(A, now(), now() - interval '1 day'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_PERIOD';
  begin perform zella_staff_scorecards(A, now() - interval '2 years', now()); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_PERIOD';
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS other businesses can''t see it; backwards or longer-than-a-year periods are refused';
end $$;
