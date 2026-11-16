-- Zella Voice: scheduled cancellations take full effect on schedule (docs/ADMIN_AUDIT_2026-11-16.md BIZ-03).
-- Two paths cancelled a business once its cancel_at passed:
--   * zella_process_cancellations(): switches the AI receptionist and every automation off, cancels the subscription,
--     marks the business cancelled and inactive, and writes an audit row. It only ran when an admin opened Overview
--     or Businesses.
--   * zella_apply_scheduled_cancellations() in the daily job: only marked the business cancelled and inactive (the
--     lifecycle trigger then paused its automations), leaving the AI receptionist on and the subscription active,
--     with no audit row.
-- Now the scheduled one does the full cancellation (it calls zella_process_cancellations, then sends the "cancellation
-- coming" reminders as before), and it also runs every hour, so a business stops within the hour after its cancel_at,
-- not up to a day later. Both scheduled jobs (zella_jobs_hourly, zella_jobs_daily) are off in production until the
-- owner switches them on; until then the page-open path in owner-provision-business stays as the fallback.
-- Both functions are archived first and must match production exactly (16 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_cancellations_scheduled_rollback.sql
begin;

do $$
declare s1 constant text := 'public.zella_apply_scheduled_cancellations()'; s2 constant text := 'public.zella_run_schedule_group(text)'; d text;
begin
  if to_regprocedure(s1) is null or to_regprocedure(s2) is null or to_regprocedure('public.zella_process_cancellations()') is null
     or to_regclass('public.zella_function_archive') is null or to_regprocedure('public.zella_patch_function(text,text,text,text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s1::regprocedure);
  if position('public.zella_process_cancellations()' in d) = 0 then
    if md5(d) <> 'fe70824e03e62fec77930e6055a674fb' then raise exception 'VERSION_MISMATCH: % is not the version this file was written for', s1; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_cancellations_scheduled', s1, d, md5(d)) on conflict (migration, signature) do nothing;
  end if;
  d := pg_get_functiondef(s2::regprocedure);
  if position($t$'zella_team_scorecard_nudge', 'zella_apply_scheduled_cancellations'$t$ in d) = 0 then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_cancellations_scheduled', s2, d, md5(d)) on conflict (migration, signature) do nothing;
  end if;
end $$;

create or replace function public.zella_apply_scheduled_cancellations() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer;
begin
  -- the full cancellation: receptionist and automations off, subscription cancelled, business inactive, audited
  n := public.zella_process_cancellations();
  for r in select id, cancel_at from public.businesses
            where cancelled_at is null and cancel_at is not null and cancel_at > now() and cancel_at <= now() + interval '3 days'
              and not exists (select 1 from public.staff_notifications s where s.business_id = businesses.id and s.kind = 'cancellation_coming' and s.created_at > now() - interval '3 days') loop
    perform public.zella_notify_owners(r.id, 'cancellation_coming', 'Your account will be cancelled on ' || to_char(r.cancel_at, 'Mon DD'),
      'Changed your mind? Open Settings and keep your plan before then.', 'warning', 'settings');
  end loop;
  return n;
end $$;

-- also every hour (the reminders already skip a business told in the last 3 days, so running twice a day is harmless)
do $$ declare r text; begin
  r := public.zella_patch_function('public.zella_run_schedule_group(text)',
         $t$'zella_team_scorecard_nudge', 'zella_apply_scheduled_cancellations'$t$,
         $t$'zella_team_scorecard_nudge']$t$, $t$'zella_team_scorecard_nudge', 'zella_apply_scheduled_cancellations']$t$);
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_run_schedule_group (%)', r; end if;
end $$;

commit;
