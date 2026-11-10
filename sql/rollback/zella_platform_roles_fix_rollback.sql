-- Undoes sql/zella_platform_roles_fix.sql: the trigger as production has it on 5 Nov 2026 (read from production; only
-- super_admin and zella_owner accepted). Hand-written; tests/deploy/run_all.sh checks it restores the function exactly.
-- Existing rows with other roles will reject UPDATEs under the restored trigger.
begin;
do $$ declare n bigint; begin
  select count(*) into n from public.platform_admins where role not in ('super_admin', 'zella_owner');
  if n > 0 then raise notice '% platform_admins rows have unsupported roles; inspect them before updating', n; end if;
end $$;
create or replace function public.zella_platform_admin_trigger() returns trigger
 language plpgsql security definer set search_path to 'public'
as $function$
    begin
      if tg_op in ('INSERT', 'UPDATE') then
        if new.role not in ('super_admin', 'zella_owner') then raise exception 'INVALID_ADMIN_ROLE'; end if;
      end if;
      return new;
    end $function$;
commit;
