-- Undoes sql/zella_scheduling.sql. One transaction: all or nothing.
-- Nothing recorded is lost: the five tables are kept, renamed (resources_rolled_back, resource_needs_rolled_back,
-- job_dispatch_rolled_back, recurring_plans_rolled_back, recurring_visits_rolled_back), and the new columns
-- (appointments.resource_ids, appointments.crew_staff_ids, blocked_times.resource_id) stay with their values. The
-- triggers and functions are removed, so bookings are checked exactly as before (staff and tables only).
-- Applying the migration again starts new, empty tables.
begin;
drop trigger if exists zella_resource_guard on public.appointments;
drop trigger if exists zella_resource_block_guard on public.blocked_times;
drop function if exists public.zella_recurring_generate(uuid, uuid, date);
drop function if exists public.zella_recurring_dates(public.recurring_plans, date, date);
drop function if exists public.zella_recurring_save(uuid, uuid, jsonb);
drop function if exists public.zella_dispatch_return_visit(uuid, timestamptz, integer, uuid, text);
drop function if exists public.zella_dispatch_checklist(uuid, jsonb);
drop function if exists public.zella_dispatch_status(uuid, text, text, text);
drop function if exists public.zella_dispatch_assign(uuid, uuid, uuid[]);
drop function if exists public.zella_dispatch_board(uuid, date);
drop function if exists public.zella_resource_day(uuid, date);
drop function if exists public.zella_resource_needs_save(uuid, jsonb);
drop function if exists public.zella_resource_save(uuid, uuid, text, text, integer, integer, text, integer, boolean);
drop function if exists public.zella_schedule_can_work(uuid);
drop function if exists public.zella_schedule_can_manage(uuid);
drop function if exists public.zella_schedule_audit(uuid, text, text, uuid, jsonb);
drop function if exists public.zella_resource_block_guard();
drop function if exists public.zella_resource_guard();
drop function if exists public.zella_resource_pick(uuid, text, timestamptz, timestamptz, integer, uuid);
drop function if exists public.zella_resource_free(uuid, timestamptz, timestamptz, integer, uuid);
drop function if exists public.zella_resource_used(uuid, timestamptz, timestamptz, uuid);
drop function if exists public.zella_resource_usage(integer, integer);
do $$
declare t text; i record; c record; v_stamp text := to_char(now(), 'YYYYMMDDHH24MISS');
begin
  -- blocks keep their resource_id values, without the link to the table that is set aside
  for c in select conname from pg_constraint where conrelid = 'public.blocked_times'::regclass and contype = 'f'
              and confrelid = coalesce(to_regclass('public.resources'), 0::regclass) loop
    execute format('alter table public.blocked_times drop constraint %I', c.conname);
  end loop;
  foreach t in array array['recurring_visits', 'recurring_plans', 'job_dispatch', 'resource_needs', 'resources'] loop
    continue when to_regclass('public.' || t) is null;
    -- free the index names, so applying the migration again creates its own
    for i in select ix.relname from pg_index x join pg_class ix on ix.oid = x.indexrelid
              where x.indrelid = to_regclass('public.' || t) and not x.indisprimary loop
      execute format('alter index public.%I rename to %I', i.relname, left(i.relname, 40) || '_rb' || v_stamp);
    end loop;
    if to_regclass('public.' || t || '_rolled_back') is not null then
      execute format('alter table public.%I rename to %I', t || '_rolled_back', t || '_rolled_back_' || v_stamp);
    end if;
    execute format('alter table public.%I rename to %I', t, t || '_rolled_back');
    execute format('revoke all on public.%I from authenticated', t || '_rolled_back');
  end loop;
end $$;
commit;
