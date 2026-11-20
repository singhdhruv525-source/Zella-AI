-- Undoes sql/zella_business_moments_job.sql exactly: zella_run_scheduled_job goes back to the archived original, byte
-- for byte, and zella_check_business_moments is no longer allowed as a scheduled job. Safe to run twice.
-- Refuses (ROLLBACK_DRIFT) when the function is neither this file's version nor the original, for example when another
-- migration changed it since; that migration must be rolled back first.
begin;

do $$
declare s constant text := 'public.zella_run_scheduled_job(text)'; d text; v_orig text; v_md5 text;
begin
  if to_regprocedure(s) is null then return; end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) in ('671ec3ca5b53cc2d660f054b837d67d1', '36a6c80d11d36e6d2f0c7a0f90af716b') then   -- already the original
    if to_regclass('public.zella_function_archive') is not null then
      delete from public.zella_function_archive where migration = 'zella_business_moments_job';
    end if;
    return;
  end if;
  if md5(d) not in ('f6d16a32855710c2c3cd75ede10a262e', '0b2182d27e25e8dbf49041120fafee29') then
    raise exception 'ROLLBACK_DRIFT: % is not the version sql/zella_business_moments_job.sql left', s;
  end if;
  select definition, definition_md5 into v_orig, v_md5 from public.zella_function_archive
   where migration = 'zella_business_moments_job' and signature = s;
  if v_orig is null or md5(replace(d, $t$'zella_check_business_moments', $t$, '')) <> v_md5 then
    raise exception 'ROLLBACK_DRIFT: the archived original of % is missing or does not match', s;
  end if;
  execute v_orig;
  if md5(pg_get_functiondef(s::regprocedure)) <> v_md5 then
    raise exception 'ROLLBACK_DRIFT: % did not come back exactly', s;
  end if;
  delete from public.zella_function_archive where migration = 'zella_business_moments_job';
end $$;

commit;
