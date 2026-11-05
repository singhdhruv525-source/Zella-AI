-- Regression tests for sql/zella_report_schedules.sql (tests/reports/run.sh). Test data only; moments are fixed so time
-- zones and daylight saving are checked exactly (America/New_York leaves daylight saving on 1 Nov 2026).
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role; set timezone = 'UTC';
select set_config('request.jwt.claims', '', false);
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.n, i.id, v.tz, true, 'active' from industries i join (values
  ('ed000000-0000-0000-0000-00000000000a', 'NY Salon', 'beauty-salon', 'America/New_York'),
  ('ed000000-0000-0000-0000-00000000000b', 'Tokyo Bistro', 'restaurant', 'Asia/Tokyo'),
  ('ed000000-0000-0000-0000-00000000000c', 'Web Shop', 'ecommerce', 'Europe/London'),
  ('ed000000-0000-0000-0000-00000000000d', 'No Report Plumbing', 'plumbing', 'America/Chicago')) v(id, n, slug, tz) on i.slug = v.slug;
insert into auth.users (id, email, email_confirmed_at) select ('ed1' || substr(x, 4))::uuid, x || '@reports.test', now()
  from unnest(array['ed000000-0000-0000-0000-0000000000a1', 'ed000000-0000-0000-0000-0000000000a2', 'ed000000-0000-0000-0000-0000000000a3']) x;
insert into business_members (business_id, user_id, role, status) values
  ('ed000000-0000-0000-0000-00000000000a', 'ed100000-0000-0000-0000-0000000000a1', 'owner', 'active'),
  ('ed000000-0000-0000-0000-00000000000a', 'ed100000-0000-0000-0000-0000000000a2', 'manager', 'active'),
  ('ed000000-0000-0000-0000-00000000000a', 'ed100000-0000-0000-0000-0000000000a3', 'staff', 'active');
insert into business_members (business_id, user_id, role, status) select b, 'ed100000-0000-0000-0000-0000000000a1', 'owner', 'active'
  from unnest(array['ed000000-0000-0000-0000-00000000000b', 'ed000000-0000-0000-0000-00000000000c', 'ed000000-0000-0000-0000-00000000000d']::uuid[]) b;
-- yesterday's activity (local 31 Oct in New York), and a lead for the shop
insert into calls (business_id, direction, status, from_number, external_call_id, ai_handled, created_at) values
  ('ed000000-0000-0000-0000-00000000000a', 'inbound', 'completed', '+15125550801', 'rep-1', true, '2026-10-31 15:00Z'),
  ('ed000000-0000-0000-0000-00000000000a', 'inbound', 'missed', '+15125550802', 'rep-2', true, '2026-10-31 16:00Z'),
  ('ed000000-0000-0000-0000-00000000000a', 'inbound', 'completed', '+15125550803', 'rep-6', true, '2026-11-01 18:00Z'),
  ('ed000000-0000-0000-0000-00000000000b', 'inbound', 'completed', '+81300000001', 'rep-3', true, '2026-10-31 03:00Z'),
  ('ed000000-0000-0000-0000-00000000000c', 'inbound', 'completed', '+442000000001', 'rep-4', true, '2026-10-31 12:00Z'),
  ('ed000000-0000-0000-0000-00000000000c', 'inbound', 'completed', '+442000000002', 'rep-5', true, '2026-11-01 12:00Z');
create function pg_temp.notes(b uuid) returns int language sql as $$ select count(*)::int from staff_notifications where business_id = b and kind = 'daily_summary' $$;

-- the owner chooses the time while setting up (as the wizard does through owner-provision-business: the service role)
do $$ begin
  begin perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000a', 'daily_summary', '{"enabled": true}'); raise exception 'created without a time';
  exception when raise_exception then if sqlerrm <> 'HOUR_REQUIRED' then raise; end if; end;
  perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000a', 'daily_summary', '{"local_hour": 8}');
  perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000b', 'daily_summary', '{"local_hour": 9, "period": "last_24_hours"}');
  perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000c', 'daily_summary', '{"local_hour": 5}');
  assert not exists (select 1 from business_report_schedules where business_id = 'ed000000-0000-0000-0000-00000000000d'), 'a schedule was assumed';
  raise notice 'PASS no time is assumed: a schedule needs the hour chosen at setup; a business that chose none has none';
end $$;

-- Tokyo at 9:00 local (00:00 UTC), last 24 hours; restaurant wording
do $$ declare b text; begin
  perform public.zella_run_daily_reports('2026-11-01 00:10Z');
  select body into b from staff_notifications where business_id = 'ed000000-0000-0000-0000-00000000000b' and kind = 'daily_summary';
  assert b like 'Last 24 hours: 1 call(s)%' and b ~* 'reservation|booking|guest', 'Tokyo report: ' || coalesce(b, '(none)');
  raise notice 'PASS Tokyo at 9:00 its own time, last 24 hours, in the restaurant''s own terms: %', b;
end $$;

-- New York, 1 Nov 2026 (EST from 06:00 UTC): 8:00 local = 13:00 UTC
do $$ declare r int; begin
  perform public.zella_run_daily_reports('2026-11-01 12:59Z');   -- 07:59 local
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000a') = 0, 'sent before 8:00 local';
  perform public.zella_run_daily_reports('2026-11-01 13:05Z');   -- 08:05 local
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000a') = 1, 'not sent at 8:00 local';
  assert (select user_id from staff_notifications where business_id = 'ed000000-0000-0000-0000-00000000000a' and kind = 'daily_summary') = 'ed100000-0000-0000-0000-0000000000a1', 'went to someone other than the owner';
  assert (select body from staff_notifications where business_id = 'ed000000-0000-0000-0000-00000000000a' and kind = 'daily_summary') like 'Yesterday: 2 call(s), 1 missed%', 'wrong period contents';
  perform public.zella_run_daily_reports('2026-11-01 13:35Z'); perform public.zella_run_daily_reports('2026-11-01 14:00Z');
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000a') = 1, 'sent twice on the same local day';
  assert (select status from business_report_runs r join business_report_schedules s on s.id = r.schedule_id where s.business_id = 'ed000000-0000-0000-0000-00000000000a' and r.local_date = '2026-11-01') = 'sent';
  raise notice 'PASS New York at 8:00 local on the day daylight saving ends (13:00 UTC): not before, once only, to the owner only, with yesterday''s real figures';
end $$;
do $$ begin
  -- the day before, daylight saving still on: 8:00 local was 12:00 UTC
  assert public.zella_report_next_run((select id from business_report_schedules where business_id = 'ed000000-0000-0000-0000-00000000000a'), '2026-10-30 11:00Z') = '2026-10-30 12:00Z', 'EDT next run wrong';
  assert public.zella_report_next_run((select id from business_report_schedules where business_id = 'ed000000-0000-0000-0000-00000000000a'), '2026-11-01 14:00Z') = '2026-11-02 13:00Z', 'next run after today''s wrong';
  raise notice 'PASS next run follows daylight saving: 12:00 UTC while EDT, 13:00 UTC after; after today''s run it is tomorrow';
end $$;

-- a shop takes no bookings: no booking line; a missed hour is recorded, not sent late
do $$ declare b text; begin
  -- the earlier runs reached London at 12:59 and 13:05 (GMT), 8 hours after its 5:00 report time
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000c') = 0, 'sent far too late';
  assert (select status from business_report_runs r join business_report_schedules s on s.id = r.schedule_id where s.business_id = 'ed000000-0000-0000-0000-00000000000c' and r.local_date = '2026-11-01') = 'missed', 'missed run not recorded';
  perform public.zella_run_daily_reports('2026-11-02 05:30Z');   -- next day, on time
  select body into b from staff_notifications where business_id = 'ed000000-0000-0000-0000-00000000000c' and kind = 'daily_summary';
  assert b is not null and b !~* 'booked', 'shop report: ' || coalesce(b, '(none)');
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000d') = 0, 'business with no schedule got a report';
  raise notice 'PASS a run the scheduler missed by over 6 hours is recorded as missed (not sent late); a shop''s report has no booking line; no schedule, no report';
end $$;

-- CRM change: managers added and the hour moved; staff can't change it; bad values refused
select set_config('request.jwt.claims', '{"sub":"ed100000-0000-0000-0000-0000000000a3","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ begin
  begin perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000a', 'daily_summary', '{"local_hour": 9}'); raise exception 'staff changed it';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"ed100000-0000-0000-0000-0000000000a1","role":"authenticated","aal":"aal1"}', false);
set role authenticated;
do $$ declare r jsonb; begin
  begin perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000a', 'daily_summary', '{"local_hour": 24}'); raise exception '24 accepted';
  exception when raise_exception then if sqlerrm <> 'BAD_HOUR' then raise; end if; end;
  begin perform public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000a', 'daily_summary', '{"recipient_roles": ["staff"]}'); raise exception 'staff recipients accepted';
  exception when raise_exception then if sqlerrm <> 'BAD_RECIPIENTS' then raise; end if; end;
  r := public.zella_set_report_schedule('ed000000-0000-0000-0000-00000000000a', 'daily_summary', '{"local_hour": 9, "recipient_roles": ["owner", "manager"]}');
  assert r -> 0 ->> 'local_hour' = '9' and r -> 0 -> 'last_run' ->> 'status' = 'sent' and r -> 0 ->> 'next_run_at' is not null, 'schedule view: ' || r::text;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
do $$ begin
  perform public.zella_run_daily_reports('2026-11-02 13:30Z');   -- 08:30 New York: before the new 9:00
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000a') = 1, 'old hour still used';
  perform public.zella_run_daily_reports('2026-11-02 14:05Z');   -- 09:05
  assert pg_temp.notes('ed000000-0000-0000-0000-00000000000a') = 3, 'owner and manager not both sent: ' || pg_temp.notes('ed000000-0000-0000-0000-00000000000a');
  assert not exists (select 1 from staff_notifications where business_id = 'ed000000-0000-0000-0000-00000000000a' and kind = 'daily_summary' and user_id = 'ed100000-0000-0000-0000-0000000000a3'), 'staff got the report';
  assert exists (select 1 from audit_logs where action = 'report_schedule_changed' and business_id = 'ed000000-0000-0000-0000-00000000000a'), 'change not audited';
  raise notice 'PASS a CRM change (9:00, owner and manager) applies from the next day; staff can''t change it or receive it; bad hours and roles refused; changes audited';
end $$;
