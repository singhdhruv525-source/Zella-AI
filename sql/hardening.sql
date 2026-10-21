do $$ declare f text; begin
  foreach f in array array['zella_appointment_after()', 'zella_block_trigger()', 'zella_platform_admin_audit()', 'zella_platform_admin_trigger()',
                           'zella_queue_no_show_followup()', 'zella_staff_deactivated()', 'zella_subscription_trigger()'] loop
    if to_regprocedure('public.' || f) is not null then
      execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
    end if;
  end loop;
  if to_regprocedure('public.zella_digits(text)') is not null then
    alter function public.zella_digits(text) set search_path = public;
  end if;
end $$;
