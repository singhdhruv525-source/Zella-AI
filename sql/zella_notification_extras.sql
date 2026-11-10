-- Zella - notification extras (2026-10-28). Safe to re-run.
-- Needs sql/zella_workflows.sql (zella_notify), sql/zella_staff_sms.sql, sql/zella_on_call.sql, sql/zella_reviews.sql and
-- sql/zella_scorecards.sql. Only in-app notifications are created here; email and texts follow the existing rules
-- (email_live / sms_live, each person's preferences, urgent-only texts).
--
-- 1. Celebrations (kind 'milestone', 'five_star_review', 'best_week'): the AI receptionist's 1st / 100th / 500th /
--    1,000th / 5,000th answered call, its 1st / 50th / 250th booking, every 5-star review, and a record week.
--    Each milestone is celebrated once per business (zella_milestones).
-- 2. On call (kind 'on_call_starting'): an hour before an on-call period starts, the owners and managers are told who is
--    on call, and the on-call person too when they sign in to Zella (matched by phone number). Their copy is marked for
--    a text when they switched on text alerts for themselves.
-- 3. Team scorecard nudge (kind 'team_scorecard'): on Monday mornings the owners and managers get one line about who has
--    overdue callbacks or tasks, linking to Scorecards. Nothing when nobody is behind.
-- 4. Admin bell: a Zella admin can acknowledge a platform alert from the dashboard (zella_admin_acknowledge_alert).
-- 5. Urgent text alerts on by default for every team member (turned off per person in My profile).
-- Rollback: drop table public.zella_milestones, public.on_call_reminders_sent; drop the functions below; re-run
--   sql/zella_notify_via.sql (zella_mark_staff_sms).

create table if not exists public.zella_milestones (
  business_id uuid not null references public.businesses (id) on delete cascade,
  key text not null,
  reached_at timestamptz not null default now(),
  primary key (business_id, key)
);
alter table public.zella_milestones enable row level security;
revoke all on public.zella_milestones from anon, authenticated;

create table if not exists public.on_call_reminders_sent (
  shift_id uuid not null,
  starts_at timestamptz not null,
  sent_at timestamptz not null default now(),
  primary key (shift_id, starts_at)
);
alter table public.on_call_reminders_sent enable row level security;
revoke all on public.on_call_reminders_sent from anon, authenticated;

-- Mark a milestone once; true only the first time.
create or replace function public.zella_milestone_once(p_business_id uuid, p_key text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into public.zella_milestones (business_id, key) values (p_business_id, p_key) on conflict do nothing;
  return found;
end $$;
revoke all on function public.zella_milestone_once(uuid, text) from public, anon, authenticated;

-- 1. Celebrations (hourly; best week on Mondays)
create or replace function public.zella_check_milestones() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_calls integer; v_books integer; m integer; n integer := 0; v_tz text; v_week_start date; v_last integer; v_best integer;
begin
  for b in select id, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    select count(*) into v_calls from public.calls where business_id = b.id and ai_handled;
    foreach m in array array[1, 100, 500, 1000, 5000] loop
      if v_calls >= m and public.zella_milestone_once(b.id, 'calls_' || m) then
        perform public.zella_notify(b.id, 'milestone',
          case when m = 1 then 'Your AI receptionist answered its first call' else 'Your AI receptionist has answered ' || to_char(m, 'FM9,999') || ' calls' end,
          case when m = 1 then 'Zella is on the line for you. Have a look at how it went in Calls.' else 'That''s ' || to_char(m, 'FM9,999') || ' callers who got an answer straight away.' end,
          'info', 'calls');
        n := n + 1;
      end if;
    end loop;
    select count(*) into v_books from public.ai_tool_calls where business_id = b.id and tool = 'book_appointment' and status = 'done' and verified is true;
    foreach m in array array[1, 50, 250] loop
      if v_books >= m and public.zella_milestone_once(b.id, 'ai_bookings_' || m) then
        perform public.zella_notify(b.id, 'milestone',
          case when m = 1 then 'Your AI receptionist booked its first appointment' else 'Your AI receptionist has booked ' || m || ' appointments' end,
          'Booked straight into your calendar while you got on with your day.', 'info', 'calendar');
        n := n + 1;
      end if;
    end loop;
    -- a record week: last week's completed appointments beat each of the 12 weeks before (and at least 5)
    v_week_start := date_trunc('week', (now() at time zone b.tz))::date;
    if extract(isodow from (now() at time zone b.tz)) = 1 then
      select count(*) into v_last from public.appointments a where a.business_id = b.id and a.status = 'completed'
         and (a.start_time at time zone b.tz)::date >= v_week_start - 7 and (a.start_time at time zone b.tz)::date < v_week_start;
      select coalesce(max(c), 0) into v_best from (
        select count(*) c from public.appointments a where a.business_id = b.id and a.status = 'completed'
           and (a.start_time at time zone b.tz)::date >= v_week_start - 7 * 13 and (a.start_time at time zone b.tz)::date < v_week_start - 7
         group by date_trunc('week', a.start_time at time zone b.tz)) w;
      if v_last >= 5 and v_last > v_best and public.zella_milestone_once(b.id, 'best_week_' || (v_week_start - 7)::text) then
        perform public.zella_notify(b.id, 'best_week', 'Your best week in three months',
          v_last || ' completed appointments last week, more than any week since ' || to_char(v_week_start - 7 * 13, 'FMMonth FMDD') || '.', 'info', 'reports');
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.zella_check_milestones() from public, anon, authenticated;

-- 2. On call starting within the hour (every 15 minutes)
create or replace function public.zella_on_call_reminders() returns integer
language plpgsql security definer set search_path = public as $$
declare s record; v_start timestamptz; v_local timestamp; v_user uuid; n integer := 0; v_name text; v_until text;
begin
  for s in select sh.*, sm.name, sm.phone, coalesce(b.timezone, 'America/New_York') as tz
             from public.on_call_shifts sh
             join public.on_call_settings st on st.business_id = sh.business_id and st.enabled
             join public.staff_members sm on sm.id = sh.staff_id and sm.is_active
             join public.businesses b on b.id = sh.business_id and b.suspended_at is null and b.cancelled_at is null loop
    v_start := null;
    if s.kind = 'cover' then
      v_start := s.starts_at;
    else
      -- the next weekly start in the business's time zone
      v_local := (now() at time zone s.tz);
      v_start := ((v_local::date + ((s.weekday - extract(dow from v_local)::int + 7) % 7)) + s.starts) at time zone s.tz;
      if v_start < now() then v_start := v_start + interval '7 days'; end if;
    end if;
    continue when v_start is null or v_start < now() or v_start > now() + interval '60 minutes';
    insert into public.on_call_reminders_sent (shift_id, starts_at) values (s.id, v_start) on conflict do nothing;
    continue when not found;
    v_name := s.name;
    v_until := case when s.kind = 'cover' then to_char(s.ends_at at time zone s.tz, 'FMDy FMHH12:MI AM') else to_char(s.ends, 'FMHH12:MI AM') end;
    perform public.zella_notify(s.business_id, 'on_call_starting', v_name || ' is on call from ' || to_char(v_start at time zone s.tz, 'FMHH12:MI AM'),
      'After-hours calls go to ' || v_name || ' until ' || v_until || '.', 'info', 'team');
    -- the on-call person themselves, when they sign in to Zella with the same phone number
    select bm.user_id into v_user from public.business_members bm join public.profiles p on p.id = bm.user_id
     where bm.business_id = s.business_id and bm.status = 'active' and public.zella_digits(p.phone) is not null
       and public.zella_digits(p.phone) = public.zella_digits(s.phone) limit 1;
    if v_user is not null then
      perform public.zella_notify(s.business_id, 'on_call_starting', 'You''re on call from ' || to_char(v_start at time zone s.tz, 'FMHH12:MI AM'),
        'After-hours calls for this business will ring your phone until ' || v_until || '.', 'warning', 'team', s.id, v_user);
    end if;
    n := n + 1;
  end loop;
  -- keep the log small
  delete from public.on_call_reminders_sent where starts_at < now() - interval '14 days';
  return n;
end $$;
revoke all on function public.zella_on_call_reminders() from public, anon, authenticated;

-- urgent alerts are texted to people who opted in; so is their own "you're on call" reminder. One exact piece of the
-- live trigger body (sql/zella_notify_via.sql), so the notify_via choice keeps working as before.
select public.zella_patch_function('public.zella_mark_staff_sms()', 'zella_on_call_text',
  E'  elsif new.severity = ''urgent'' and v_ok then\n',
  E'  elsif (new.severity = ''urgent'' or (new.kind = ''on_call_starting'' and new.user_id is not null)) and v_ok then -- zella_on_call_text\n');

-- 3. Monday morning team nudge (runs hourly; acts once per business per week, between 8 and 10 am local time)
create or replace function public.zella_team_scorecard_nudge(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_lines text; n integer := 0; v_local timestamp;
begin
  for b in select id, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    v_local := p_now at time zone b.tz;
    continue when extract(isodow from v_local) <> 1 or extract(hour from v_local) not between 8 and 9;
    continue when exists (select 1 from public.zella_milestones where business_id = b.id and key = 'scorecard_' || v_local::date);
    select string_agg(who, ', ' order by total desc) into v_lines from (
      select coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), 'A team member')
               || ' (' || concat_ws(', ', case when cb > 0 then cb || ' callback' || case when cb > 1 then 's' else '' end end,
                                          case when tk > 0 then tk || ' task' || case when tk > 1 then 's' else '' end end) || ')' as who,
             cb + tk as total
        from (select m.user_id,
                     (select count(*) from public.callbacks c where c.business_id = b.id and c.assigned_to = m.user_id
                         and c.status not in ('completed', 'cancelled', 'needs_review') and c.due_at < now()) as cb,
                     (select count(*) from public.crm_tasks t where t.business_id = b.id and t.assigned_to = m.user_id and t.status = 'open' and t.due_at < now()) as tk
                from public.business_members m where m.business_id = b.id and m.status = 'active') x
        left join public.profiles p on p.id = x.user_id
       where cb + tk > 0 limit 5) y;
    perform public.zella_milestone_once(b.id, 'scorecard_' || v_local::date);
    continue when v_lines is null;
    perform public.zella_notify(b.id, 'team_scorecard', 'A few things are waiting from last week', left('Overdue right now: ' || v_lines || '.', 300), 'info', 'scorecards');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_team_scorecard_nudge(timestamptz) from public, anon, authenticated;

-- 4. Admin bell: acknowledge one platform alert
create or replace function public.zella_admin_acknowledge_alert(p_alert_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  update public.platform_alerts set status = 'acknowledged', acknowledged_by = auth.uid(), acknowledged_at = now()
   where id = p_alert_id and status = 'open';
  return found;
end $$;
revoke all on function public.zella_admin_acknowledge_alert(uuid) from public, anon;
grant execute on function public.zella_admin_acknowledge_alert(uuid) to authenticated;

grant execute on function public.zella_check_milestones(), public.zella_on_call_reminders(), public.zella_team_scorecard_nudge(timestamptz) to service_role;

-- 5. Urgent text alerts are on by default (2026-10-28 decision): every team member gets them, owners and admins for
--    business-wide alerts, anyone for alerts meant for them. A person turns them off in My profile
--    (zella_set_my_sms_alerts). Texts still only go out once sms_live is on, to people with a mobile number on their
--    profile, at most 5 per business per hour.
alter table public.business_members alter column sms_alerts set default true;
-- one time: switch them on for existing members (texting has never been live, so nobody turned them off on purpose)
do $$
begin
  if not exists (select 1 from public.platform_settings where key = 'sms_alerts_default_on') then
    update public.business_members set sms_alerts = true where not sms_alerts;
    insert into public.platform_settings (key, value) values ('sms_alerts_default_on', 'true'::jsonb);
  end if;
end $$;
-- removing a phone number no longer switches alerts off for good: without a number nothing can be sent anyway, and
-- adding one back resumes them (zella_save_my_profile, sql/zella_business_settings.sql)
select public.zella_patch_function('public.zella_save_my_profile(text,text,text)', 'zella_sms_stays_on',
  E'  -- Text alerts need a number; switch them off everywhere if it was removed.\n  if v_phone is null then update public.business_members set sms_alerts = false where user_id = auth.uid() and sms_alerts; end if;\n',
  E'  -- zella_sms_stays_on: text alerts stay as the person chose; without a number nothing is sent\n');
