-- A block on a resource (a room, chair, bay or van out for maintenance or cleaning) no longer closes the whole
-- business in slot search. Safe to run twice. Needs sql/zella_scheduling.sql first (blocked_times.resource_id).
-- Rollback: sql/rollback/zella_slots_resource_blocks_rollback.sql (tests/setup/make_rollback.py slotblocks).
--
-- S1  zella_available_slots treats a blocked time with no person as business-wide (holidays, "closed for training").
--     Release 2 added blocked_times.resource_id, and a block on one resource has no person either, so slot search
--     (the AI receptionist's check_availability and book_appointment, the CRM's booking and the reschedule link)
--     offered no times for anyone while it lasted. Now only a block with neither a person nor a resource closes the
--     business; a person's own block still closes only that person. The resource itself is still protected when a
--     booking is written: zella_resource_guard refuses a booking that uses a blocked resource.
--     Nothing else in the function changes.

\set ON_ERROR_STOP on
begin;
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'blocked_times' and column_name = 'resource_id') then
    raise exception 'blocked_times.resource_id is missing: apply sql/zella_scheduling.sql first';
  end if;
end $$;

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer, uuid)'::regprocedure);
  if position('zella_slots_resource_blocks' in def) = 0 then
    def := replace(def, $a$          and (bt.staff_id is null or bt.staff_id = r.sid)$a$, $a$          and ((bt.staff_id is null and bt.resource_id is null) or bt.staff_id = r.sid)   /* zella_slots_resource_blocks: a block on a resource doesn't close the business */$a$);
    if position('zella_slots_resource_blocks' in def) = 0 then raise exception 'zella_available_slots has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
commit;
