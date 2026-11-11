-- Rollback for sql/zella_report_schedules.sql (hand-written).
-- Puts back the daily summary as it is in production on 5 Nov 2026 (sent at 8 AM business time to active businesses),
-- and removes the schedule functions. The schedules and run history are kept (renamed) so the owners' choices are not lost.
begin;
CREATE OR REPLACE FUNCTION public.zella_post_daily_summaries()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b record; v_tz text; v_rev jsonb; v_leads int; v_today int; v_overdue int; v_issues text; v_body text; v_day_start timestamptz; n integer := 0;
begin
  for b in select id, name, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_tz := b.tz;
    begin
      if extract(hour from (now() at time zone v_tz)) <> 8 then continue; end if;
    exception when others then continue; end;
    if exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'daily_summary' and created_at > now() - interval '20 hours') then continue; end if;

    v_rev := public.zella_performance_review(b.id, 1);
    select count(*) into v_leads from public.customers where business_id = b.id and created_at >= now() - interval '24 hours';
    v_day_start := date_trunc('day', now() at time zone v_tz) at time zone v_tz;
    select count(*) into v_today from public.appointments
     where business_id = b.id and start_time >= v_day_start and start_time < v_day_start + interval '1 day'
       and status in ('scheduled', 'confirmed') and coalesce(booking_state, 'confirmed') = 'confirmed';
    select count(*) into v_overdue from public.callbacks
     where business_id = b.id and status not in ('completed', 'cancelled', 'needs_review') and due_at < now();

    v_issues := (select string_agg(x, ' ') from jsonb_array_elements_text(v_rev -> 'issues') x);
    if v_overdue > 0 then v_issues := concat_ws(' ', v_issues, v_overdue || ' callback(s) are overdue.'); end if;

    if (v_rev ->> 'calls')::int = 0 and v_leads = 0 and v_today = 0 and (v_rev ->> 'appointments_booked')::int = 0 and v_issues is null then continue; end if;

    v_body := 'Yesterday: ' || (v_rev ->> 'calls') || ' call(s), ' || (v_rev ->> 'missed') || ' missed, '
           || (v_rev ->> 'appointments_booked') || ' booked, ' || v_leads || ' new customer(s) or lead(s). '
           || 'Today: ' || v_today || ' appointment(s). '
           || case when v_issues is not null then 'To look at: ' || v_issues else 'Nothing needs attention.' end;
    perform public.zella_notify_owners(b.id, 'daily_summary', 'Your day with Zella - ' || b.name, v_body,
      case when v_issues is not null then 'warning' else 'info' end, 'reports');
    n := n + 1;
  end loop;
  return n;
end $function$

;
revoke execute on function public.zella_post_daily_summaries() from public, anon, authenticated;
grant execute on function public.zella_post_daily_summaries() to service_role;
drop function if exists public.zella_set_report_schedule(uuid, text, jsonb);
drop function if exists public.zella_report_schedules(uuid);
drop function if exists public.zella_run_daily_reports(timestamptz);
drop function if exists public.zella_report_build(uuid, text, timestamptz);
drop function if exists public.zella_report_next_run(uuid, timestamptz);
do $$
declare t text; i record; v_stamp text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');
begin
  foreach t in array array['business_report_runs', 'business_report_schedules'] loop
    continue when to_regclass('public.' || t) is null;
    for i in select ix.relname, ix.oid from pg_index x join pg_class ix on ix.oid = x.indexrelid
      where x.indrelid = to_regclass('public.' || t) and not x.indisprimary loop
      execute format('alter index public.%I rename to %I', i.relname, left(i.relname, 20) || '_rb' || i.oid || '_' || v_stamp);
    end loop;
    if to_regclass('public.' || t || '_rolled_back') is not null then
      execute format('alter table public.%I rename to %I', t || '_rolled_back', t || '_rb_' || v_stamp);
    end if;
    execute format('alter table public.%I rename to %I', t, t || '_rolled_back');
    execute format('alter table public.%I enable row level security', t || '_rolled_back');
    execute format('revoke all on public.%I from public, anon, authenticated', t || '_rolled_back');
  end loop;
end $$;
commit;
