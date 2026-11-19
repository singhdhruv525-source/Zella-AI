-- Undoes sql/zella_weekly_platform_report.sql exactly. Safe to run twice.
--   * zella_run_scheduled_job and zella_run_schedule_group: the report's entry is taken out of each list (the exact
--     reverse of the file's patch). When nothing else changed either function since, the result is the archived original
--     byte for byte, and the archived original is put back. When another migration changed it later (for example
--     zella_cancellations_scheduled.sql applied after this file), only the report's entry is removed, so that later change
--     stays; a NOTICE says so.
--   * The three new functions are dropped. platform_report_runs and every report stored in it are kept (a rollback never
--     deletes data; the table stays server only), and applying the file again uses them.
--   * The open "weekly platform report is ready" alert is resolved, so the bell no longer points to a page that is gone.
begin;
do $$
declare s text; d text; v_new text; v_orig text; v_md5 text;
  entry constant text := $t$, 'zella_post_weekly_platform_report'$t$;
begin
  foreach s in array array['public.zella_run_scheduled_job(text)', 'public.zella_run_schedule_group(text)'] loop
    if to_regprocedure(s) is null then continue; end if;
    d := pg_get_functiondef(s::regprocedure);
    if position(entry in d) = 0 then continue; end if;                                   -- already rolled back
    if (length(d) - length(replace(d, entry, ''))) / length(entry) <> 1 then
      raise exception 'ROLLBACK_DRIFT: the weekly report entry is in % more than once', s;
    end if;
    v_new := replace(d, entry, '');
    v_orig := null; v_md5 := null;
    if to_regclass('public.zella_function_archive') is not null then
      execute 'select definition, definition_md5 from public.zella_function_archive where migration = $1 and signature = $2'
        into v_orig, v_md5 using 'zella_weekly_platform_report', s;
    end if;
    if v_md5 = md5(v_new) then
      execute v_orig;                                                                  -- the original, exactly
    else
      execute v_new;
      raise notice 'kept later changes to %: only the weekly report entry was removed', s;
    end if;
  end loop;
  if to_regclass('public.zella_function_archive') is not null then
    execute 'delete from public.zella_function_archive where migration = $1' using 'zella_weekly_platform_report';
  end if;
  if to_regclass('public.platform_alerts') is not null then
    update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'The weekly platform report was removed.'
     where kind = 'weekly_report' and status <> 'resolved';
  end if;
end $$;
drop function if exists public.zella_admin_weekly_reports(integer);
drop function if exists public.zella_post_weekly_platform_report(timestamptz);
drop function if exists public.zella_platform_weekly_summary(timestamptz, timestamptz);
commit;
