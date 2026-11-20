-- Zella Voice: the hourly job may run zella_check_business_moments. sql/zella_business_moments.sql (applied 15 Nov 2026)
-- put it in zella_run_schedule_group('hourly') but not in zella_run_scheduled_job's allowed list, so once
-- zella_jobs_hourly is switched on the job would answer not_allowed for it and the three business moments would never be
-- checked. This adds it to the allowed list right after zella_check_milestones. Nothing else changes.
-- Version guard: zella_run_scheduled_job must be production's version (md5 671ec3ca...) or production's after
-- sql/zella_weekly_platform_report.sql (36a6c80d...); it is archived first (zella_function_archive) for the exact
-- rollback. Already this file's version: nothing happens. Anything else: VERSION_MISMATCH. Safe to run twice.
-- Production md5s: computed on the isolated copy (zprod3, then zella_writing_cleanup.sql and the merged, unapplied
-- migrations in docs/SCHEMA_STATUS.md, which don't change this function); to be confirmed by the supervisor before
-- applying.
-- Order: apply after sql/zella_weekly_platform_report.sql, whose own guard accepts only production's version of
-- zella_run_scheduled_job.
-- Rollback: sql/rollback/zella_business_moments_job_rollback.sql
begin;

do $$
declare
  s constant text := 'public.zella_run_scheduled_job(text)'; d text;
  anchor constant text := $t$'zella_check_milestones', $t$;
  entry constant text := $t$'zella_check_milestones', 'zella_check_business_moments', $t$;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_check_business_moments(timestamptz)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) in ('f6d16a32855710c2c3cd75ede10a262e', '0b2182d27e25e8dbf49041120fafee29') then                         -- this file's version (already applied)
    return;
  end if;
  if md5(d) not in ('671ec3ca5b53cc2d660f054b837d67d1',                     -- production's version
                    '36a6c80d11d36e6d2f0c7a0f90af716b') then                -- the same with the weekly platform report
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'VERSION_MISMATCH: zella_check_milestones is not in % exactly once', s;
  end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_business_moments_job', s, d, md5(d)) on conflict (migration, signature) do nothing;
  execute replace(d, anchor, entry);
  if md5(pg_get_functiondef(s::regprocedure)) not in ('f6d16a32855710c2c3cd75ede10a262e', '0b2182d27e25e8dbf49041120fafee29') then
    raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', s;
  end if;
end $$;

commit;
