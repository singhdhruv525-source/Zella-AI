-- Zella Voice: event based n8n dispatch (the missing section 5 of sql/zella_dispatcher.sql).
--
-- WHY: production has the dispatcher (zella_dispatch_n8n) but not the trigger function zella_kick_dispatch() or its
-- zella_kick_dispatch AFTER INSERT triggers (read only check, 26 Nov 2026). sql/zella_dispatcher.sql section 5 defines
-- them, but that file is applied and is never edited or re-run (DB-7: re-running it would also put an old
-- zella_dispatch_n8n back and schedule the timed jobs). So urgent work waits for the once a minute safety net, and that
-- job (zella_dispatch) is switched off in production. This file adds only section 5, as a new migration.
--
-- WHAT (docs/ARCHITECTURE.md §8.3):
--   1. zella_kick_dispatch(): saving a row in one of the eight queue tables below calls zella_dispatch_n8n() at once
--      (REQ-AUT-10 "on insert of due work"; PRN-4, ARC-5). The dispatcher is unchanged: it still calls a workflow only
--      when that queue has due work, and honours n8n_dispatch_enabled, the base address and the Vault secret
--      (REQ-AUT-12). Same rules as section 5:
--        - a follow up task due more than 5 seconds from now doesn't kick (the safety net wakes it when it is due);
--        - at most one kick every 2 seconds across all tables, kept in n8n_dispatch_state row '_kick'
--          (zella_admin_dispatch_responses, zella_admin_scheduler_health and zella_check_uptime leave that row out;
--          zella_automation_readiness lists it, with its time);
--        - a dispatch problem never blocks saving the row: any error is caught, a warning with the SQLSTATE only.
--      Three changes from section 5's text. The first is a fix: section 5 tests
--        "tg_table_name = 'followup_tasks' and new.due_at > ..." in one expression, and PL/pgSQL resolves new.due_at on
--        every table, so on the six tables without due_at every kick failed with 42703 and was swallowed: they would
--        never have kicked. The due_at test is now nested inside the followup_tasks test. The other two make sure a
--        kick can never hold up a save (rulebook first, DB-9):
--        - the '_kick' row is taken with FOR UPDATE SKIP LOCKED: while another open transaction is kicking, this save
--          skips the kick instead of waiting for that transaction to end (section 5's plain UPDATE would wait);
--        - lock_timeout 2s inside the function: if the dispatcher has to wait for a lock longer than that, the kick is
--          abandoned (caught) and the row is saved.
--      The function and the dispatcher run inside the saving transaction; pg_net sends only after it commits, so a save
--      that rolls back calls nothing. The call carries no business data (body {}), n8n claims the work itself
--      (§6.9 REQ-AUT-ISO-04).
--   2. AFTER INSERT ... FOR EACH ROW triggers named zella_kick_dispatch on automation_events, followup_tasks,
--      staff_notifications, appointment_reminders, meta_events, meta_outbox, website_pages, website_sources.
--      They are CREATED SWITCHED OFF (ALTER TABLE ... DISABLE TRIGGER), like zella_kick_platform_emails
--      (§14.4, ARC-8, NN-3): in production n8n_dispatch_enabled is true and the base address and secret are set, so an
--      enabled trigger would start calling n8n on the next save. Switching them on is a live switch for the owner;
--      n8n/GO-LIVE.md has the statement. Section 5 created them enabled; this is the fourth difference.
--   Nothing else: no cron job is scheduled or activated, no setting, secret or live switch changes, no rows change.
--
-- VERSION GUARD (DB-3): zella_dispatch_n8n() must be production's version, md5 48ebbf41429852c7f5a04a35bd09ff4f
-- (sql/zella_dispatch_response.sql, read from production 26 Nov 2026); n8n_dispatch_state must have workflow (text,
-- primary key) and last_triggered_at; the eight tables and followup_tasks.due_at must exist. A zella_kick_dispatch()
-- or a zella_kick_dispatch trigger that already exists must be exactly this file's. Otherwise VERSION_MISMATCH and
-- nothing changes.
-- SAFE TO RUN TWICE (DB-2): the function is replaced with the same body; an existing trigger is left exactly as it is,
-- so a second run never switches back on or off what the owner set.
-- WHO CAN DO WHAT AFTER: nobody calls zella_kick_dispatch() directly (execute revoked from public, anon,
-- authenticated); it runs only as a trigger, as the function owner.
-- VERIFY: select tgrelid::regclass, tgenabled from pg_trigger where tgname = 'zella_kick_dispatch';  -- 8 rows, 'D' (off)
--         select md5(pg_get_functiondef('public.zella_kick_dispatch()'::regprocedure));               -- a1ac376f047ba05dee027c34d05f6aa1
-- TESTS: tests/event_dispatch/run.sh (isolated test database only).
-- ROLLBACK (DB-4, NN-10): sql/rollback/zella_event_dispatch_rollback.sql
-- Needs: sql/zella_dispatch_response.sql (applied in production).
-- Rules and requirements: REQ-AUT-10 (wake on insert of due work), REQ-AUT-12 (master switch honoured), REQ-AUT-11 (not
-- changed: the dispatcher's back off still holds back a newly due item, a known gap, docs/ARCHITECTURE.md §8.3),
-- REQ-AUT-ISO-04, PRN-4, PRN-6, PRN-10, ARC-5, ARC-8, ARC-9 (pg_net, 5 second timeout, never waited for), NN-3, NN-4,
-- NN-10, DB-1, DB-2, DB-3, DB-4, DB-7, DB-9, DB-14, QA-1.
begin;
-- give up after 5 seconds instead of queueing behind (and in front of) saves on the eight tables; nothing changes then
set local lock_timeout = '5s';

do $$
declare
  s constant text := 'public.zella_dispatch_n8n()';
  k constant text := 'public.zella_kick_dispatch()';
  t text; tg record;
begin
  if to_regprocedure(s) is null or md5(pg_get_functiondef(s::regprocedure)) <> '48ebbf41429852c7f5a04a35bd09ff4f' then
    raise exception 'VERSION_MISMATCH: % is not the version this file was written for', s;
  end if;
  if to_regclass('public.n8n_dispatch_state') is null
     or not exists (select 1 from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
                     where c.conrelid = 'public.n8n_dispatch_state'::regclass and c.contype = 'p' and array_length(c.conkey, 1) = 1
                       and a.attname = 'workflow' and a.atttypid = 'text'::regtype)
     or not exists (select 1 from pg_attribute where attrelid = 'public.n8n_dispatch_state'::regclass and attname = 'last_triggered_at'
                       and atttypid = 'timestamptz'::regtype and not attisdropped) then
    raise exception 'VERSION_MISMATCH: n8n_dispatch_state is not the shape this file was written for';
  end if;
  foreach t in array array['automation_events', 'followup_tasks', 'staff_notifications', 'appointment_reminders', 'meta_events',
                           'meta_outbox', 'website_pages', 'website_sources'] loop
    if to_regclass(format('public.%I', t)) is null then
      raise exception 'VERSION_MISMATCH: table public.% is missing', t;
    end if;
  end loop;
  if not exists (select 1 from pg_attribute where attrelid = 'public.followup_tasks'::regclass and attname = 'due_at'
                   and atttypid = 'timestamptz'::regtype and not attisdropped) then
    raise exception 'VERSION_MISMATCH: followup_tasks.due_at is missing';
  end if;
  -- already applied: only exactly this file's function and triggers
  if to_regprocedure(k) is not null and md5(pg_get_functiondef(k::regprocedure)) <> 'a1ac376f047ba05dee027c34d05f6aa1' then
    raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', k;
  end if;
  for tg in select tgrelid::regclass::text rel, tgfoid, tgtype from pg_trigger where tgname = 'zella_kick_dispatch' and not tgisinternal loop
    if to_regprocedure(k) is null or tg.tgfoid <> to_regprocedure(k)::oid or tg.tgtype <> 5   -- 5 = AFTER INSERT FOR EACH ROW
       or tg.rel not in ('automation_events', 'followup_tasks', 'staff_notifications', 'appointment_reminders', 'meta_events',
                         'meta_outbox', 'website_pages', 'website_sources') then
      raise exception 'VERSION_MISMATCH: trigger zella_kick_dispatch on % is not this file''s', tg.rel;
    end if;
  end loop;
end $$;

-- 1. Act at once: when something is saved, call the dispatcher right away instead of waiting for the safety net.
--    At most one kick every 2 seconds. Never blocks or fails the save.
create or replace function public.zella_kick_dispatch()
returns trigger language plpgsql security definer set search_path = public set lock_timeout = '2s' as $$
begin
  -- a follow up due later is woken by the safety net when it falls due (nested: new.due_at exists only on followup_tasks)
  if tg_table_name = 'followup_tasks' then
    if new.due_at > now() + interval '5 seconds' then return new; end if;
  end if;
  insert into public.n8n_dispatch_state (workflow) values ('_kick') on conflict do nothing;
  -- one kick every 2 seconds; while another transaction holds the kick, skip it instead of waiting
  perform 1 from public.n8n_dispatch_state
   where workflow = '_kick' and (last_triggered_at is null or last_triggered_at < now() - interval '2 seconds')
     for update skip locked;
  if found then
    update public.n8n_dispatch_state set last_triggered_at = now() where workflow = '_kick';
    perform public.zella_dispatch_n8n();
  end if;
  return new;
exception when others then
  raise warning 'zella_kick_dispatch: %', sqlstate;   -- a dispatch problem must never block saving the row
  return new;
end $$;
revoke all on function public.zella_kick_dispatch() from public, anon, authenticated;

-- 2. The triggers, created switched off. Switching them on is the owner's live switch (n8n/GO-LIVE.md).
do $$
declare t text;
begin
  foreach t in array array['automation_events', 'followup_tasks', 'staff_notifications', 'appointment_reminders', 'meta_events',
                           'meta_outbox', 'website_pages', 'website_sources'] loop
    if not exists (select 1 from pg_trigger where tgname = 'zella_kick_dispatch' and tgrelid = format('public.%I', t)::regclass) then
      execute format('create trigger zella_kick_dispatch after insert on public.%I for each row execute function public.zella_kick_dispatch()', t);
      execute format('alter table public.%I disable trigger zella_kick_dispatch', t);
    end if;
  end loop;
end $$;

commit;
