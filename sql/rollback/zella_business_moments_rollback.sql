-- Undoes sql/zella_business_moments.sql: takes zella_check_business_moments out of the hourly group and drops it.
-- Notifications already raised and the once-only marks (zella_milestones) are kept. Safe to run twice.
begin;
do $$ declare d text; begin
  if to_regprocedure('public.zella_run_schedule_group(text)') is not null then
    d := pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure);
    if position('''zella_check_milestones'', ''zella_check_business_moments''' in d) > 0 then
      execute replace(d, '''zella_check_milestones'', ''zella_check_business_moments''', '''zella_check_milestones''');
    elsif position('zella_check_business_moments' in d) > 0 then
      raise exception 'VERSION_MISMATCH: zella_run_schedule_group was changed after the migration; review it by hand';
    end if;
  end if;
end $$;
drop function if exists public.zella_check_business_moments(timestamptz);
commit;
