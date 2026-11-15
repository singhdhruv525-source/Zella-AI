-- Zella Voice: three new business moments for the notification bell (docs/DESIGN_SYSTEM.md, Notifications).
--   best_day     (celebration) yesterday the AI receptionist booked more appointments than on any day in the 90 days
--                before (at least 10)
--   call_surge   (information) today's calls so far are at least 2.5 times a usual day (at least 20, after 11:00)
--   on_call_gap  (heads up)    on Thursday or Friday: on call is switched on but nobody is on call for part, or all,
--                of the coming weekend
-- Each is raised at most once per business per day (or weekend), through zella_milestone_once, and only for live
-- businesses. Wording follows the writing rule (no dashes); the CRM words each one for the business's industry.
-- Runs hourly: zella_run_schedule_group('hourly') gets zella_check_business_moments after zella_check_milestones
-- (zella_patch_function: changed only if the anchor is there exactly once; safe to run twice).
-- Rollback: sql/rollback/zella_business_moments_rollback.sql
begin;

do $$ begin
  if to_regprocedure('public.zella_milestone_once(uuid,text)') is null or to_regprocedure('public.zella_notify(uuid,text,text,text,text,text,uuid,uuid)') is null
     or to_regprocedure('public.zella_on_call_now(uuid,timestamptz)') is null or to_regprocedure('public.zella_patch_function(text,text,text,text)') is null
     or to_regprocedure('public.zella_run_schedule_group(text)') is null then
    raise exception 'VERSION_MISMATCH: a function this file needs is missing';
  end if;
end $$;

create or replace function public.zella_check_business_moments(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public as $$
declare b record; n integer := 0; v_local timestamp; v_day date; v_count integer; v_best integer; v_since date; v_avg numeric;
        v_sat date; v_t timestamptz; v_points integer; v_gaps integer; v_first_gap timestamptz;
begin
  for b in select id, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    begin
      v_local := p_now at time zone b.tz;
      v_day := v_local::date;

      -- record day: yesterday's bookings made by the AI receptionist beat every day of the 90 before
      select count(*) into v_count from public.appointments a
       where a.business_id = b.id and coalesce(a.metadata ->> 'source', '') in ('ai', 'phone', 'ai_call')
         and coalesce(a.status, '') not in ('cancelled', 'canceled') and (a.created_at at time zone b.tz)::date = v_day - 1;
      if v_count >= 10 then
        select coalesce(max(c), 0) into v_best from (
          select count(*) c from public.appointments a
           where a.business_id = b.id and coalesce(a.metadata ->> 'source', '') in ('ai', 'phone', 'ai_call')
             and coalesce(a.status, '') not in ('cancelled', 'canceled')
             and (a.created_at at time zone b.tz)::date between v_day - 91 and v_day - 2
           group by (a.created_at at time zone b.tz)::date) d;
        if v_count > v_best and public.zella_milestone_once(b.id, 'best_day_' || (v_day - 1)::text) then
          v_since := v_day - 91;
          perform public.zella_notify(b.id, 'best_day', 'A record day for bookings',
            'Your AI receptionist booked ' || v_count || ' appointments yesterday, more than on any day since ' || to_char(v_since, 'FMDD FMMonth') || '.',
            'info', 'calendar');
          n := n + 1;
        end if;
      end if;

      -- call surge: today so far is at least 2.5 times a usual day (the average of the 28 days before)
      if extract(hour from v_local) >= 11 then
        select count(*) into v_count from public.calls c
         where c.business_id = b.id and coalesce(c.direction, 'inbound') = 'inbound' and (c.created_at at time zone b.tz)::date = v_day;
        if v_count >= 20 then
          select count(*)::numeric / 28 into v_avg from public.calls c
           where c.business_id = b.id and coalesce(c.direction, 'inbound') = 'inbound'
             and (c.created_at at time zone b.tz)::date between v_day - 28 and v_day - 1;
          if v_avg > 0 and v_count >= 2.5 * v_avg and public.zella_milestone_once(b.id, 'call_surge_' || v_day::text) then
            perform public.zella_notify(b.id, 'call_surge', 'Calls are pouring in today',
              v_count || ' calls so far today, about ' || to_char(round(v_count / v_avg, 1), 'FM999.0') || ' times a usual day. '
                || 'Your AI receptionist is answering them. Keep an eye on your minutes if it stays this busy.',
              'info', 'calls');
            n := n + 1;
          end if;
        end if;
      end if;

      -- on call gap: Thursday or Friday from 9:00, on call switched on, and part of the weekend has nobody on call
      if extract(isodow from v_local) in (4, 5) and extract(hour from v_local) >= 9
         and exists (select 1 from public.on_call_settings s where s.business_id = b.id and s.enabled) then
        v_sat := v_day + (6 - extract(isodow from v_local)::int);
        v_points := 0; v_gaps := 0; v_first_gap := null;
        -- every two hours from Saturday 00:00 to Sunday 22:00, in the business's time zone
        for i in 0..23 loop
          v_t := ((v_sat::timestamp + make_interval(hours => i * 2)) at time zone b.tz);
          v_points := v_points + 1;
          if coalesce(public.zella_on_call_now(b.id, v_t) ->> 'staff_id', '') = '' then   -- '{}' means nobody
            v_gaps := v_gaps + 1;
            v_first_gap := coalesce(v_first_gap, v_t);
          end if;
        end loop;
        if v_gaps > 0 and public.zella_milestone_once(b.id, 'on_call_gap_' || v_sat::text) then
          if v_gaps = v_points then
            perform public.zella_notify(b.id, 'on_call_gap', 'No one is on call this weekend',
              'Calls that need a person on Saturday and Sunday will go to voicemail until someone is added to the rota.', 'warning', 'on_call');
          else
            perform public.zella_notify(b.id, 'on_call_gap', 'Gaps in this weekend''s on call cover',
              'Nobody is on call from ' || to_char(v_first_gap at time zone b.tz, 'FMDay HH24:MI') || '. Calls that need a person will go to voicemail then.',
              'warning', 'on_call');
          end if;
          n := n + 1;
        end if;
      end if;
    exception when others then null;   -- one business never stops the others; it is tried again next hour
    end;
  end loop;
  return n;
end $$;
revoke all on function public.zella_check_business_moments(timestamptz) from public, anon, authenticated;
grant execute on function public.zella_check_business_moments(timestamptz) to service_role;

-- run it every hour with the other celebrations
do $$ declare r text; begin
  r := public.zella_patch_function('public.zella_run_schedule_group(text)', 'zella_check_business_moments',
         '''zella_check_milestones''', '''zella_check_milestones'', ''zella_check_business_moments''');
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_run_schedule_group (%)', r; end if;
end $$;

commit;
