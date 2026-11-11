-- Puts seating data back after sql/rollback/zella_tables_rollback.sql followed by a re-apply of sql/zella_tables.sql.
-- Hand-written. Run it right after the re-apply; it is safe to run more than once and never deletes anything.
--
-- The rollback keeps everything: the seating tables are renamed "<table>_rolled_back" (with row level security and no
-- client access), and what it removes from other tables (the 'tables' capability, appointment table assignments,
-- waitlist party size / preferences / contact permission, and the needs-clearing states) is copied first into the
-- private archive table_data_rolled_back. This script copies all of that back into the active tables that the
-- re-apply created:
--   * tables, combinations, blocks and the event history, by their original ids (rows already there win);
--   * each table's needs-clearing state, from the newest archived copy, when that table is back;
--   * the 'tables' capability choice, unless the business has made a new choice since;
--   * appointment table assignments and waitlist details, only where the column is still empty. An assignment the
--     booking checks now refuse (for example a table taken again since) is left out and reported, never forced.
-- Only the latest rollback's explicit generation is used, including when it archived no data rows,
-- so an older generation can never put back a value that a later rollback no longer had.
-- Completed rows and seating categories are recorded so retries only load unresolved data.
-- Archive data is kept; the generation marker records a completed restore to allow another rollback.
begin;
set local lock_timeout = '10s';

do $restore$
declare
  t text; v_generation bigint; v_cols text; v_n bigint; v_total bigint := 0; r record; v_skipped int := 0; v_unmatched int := 0; v_appointment public.appointments%rowtype; v_seating_restored boolean := false;
begin
  if to_regclass('public.restaurant_tables') is null then
    raise exception 'TABLES_NOT_APPLIED: re-apply sql/zella_tables.sql before restoring its data';
  end if;

  -- Serialize with rollback before locking active tables or reading archive names.
  if to_regclass('public.table_data_rolled_back') is not null then
    lock table public.table_data_rolled_back in share row exclusive mode;
    select max(id) into v_generation from public.table_data_rolled_back
     where source_table = 'rollback_generation';
    alter table public.table_data_rolled_back add column if not exists restore_completed boolean not null default false;
    select coalesce(row_data ->> 'seating_restored' = 'true', false) into v_seating_restored
      from public.table_data_rolled_back where id = v_generation;
    if exists (select 1 from public.table_data_rolled_back where id = v_generation and row_data ->> 'restored' = 'true') then
      raise notice 'latest seating generation is already restored';
      return;
    end if;
  end if;

  -- Seating archives are committed as a category; retries must not replay deleted rows.
  if not coalesce(v_seating_restored, false) then
    -- 1. the seating tables, parents first, by their original ids
    foreach t in array array['restaurant_tables', 'table_combinations', 'table_blocks', 'table_events'] loop
      continue when to_regclass('public.' || t || '_rolled_back') is null;
      execute format('lock table public.%I in share row exclusive mode', t);
      select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into v_cols
        from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = t
         and exists (select 1 from information_schema.columns a where a.table_schema = 'public'
                       and a.table_name = t || '_rolled_back' and a.column_name = c.column_name);
      execute format('insert into public.%I (%s) %s select %s from public.%I on conflict do nothing',
                     t, v_cols, case when t = 'table_events' then 'overriding system value' else '' end, v_cols, t || '_rolled_back');
      get diagnostics v_n = row_count; v_total := v_total + v_n;
      raise notice 'restored % rows into %', v_n, t;
    end loop;
    if to_regclass('public.table_events_rolled_back') is not null then
      -- keep new events numbered after the restored ones
      perform setval(pg_get_serial_sequence('public.table_events', 'id'), greatest((select coalesce(max(id), 0) from public.table_events), 1));
    end if;
  end if;

  if to_regclass('public.table_data_rolled_back') is null then
    raise notice 'no archived seating details to restore';
    return;
  end if;
  update public.table_data_rolled_back set row_data = row_data || '{"seating_restored": true}'::jsonb
   where id = v_generation;
  create temp table zella_tables_batch on commit drop as
    select * from public.table_data_rolled_back
     where generation_id = v_generation and not restore_completed;

  -- 2. needs-clearing states: the newest archived copy of each table that is back
  insert into public.table_states (table_id, business_id, state, appointment_id, since, by_user)
  select s.table_id, s.business_id, s.state, s.appointment_id, s.since, s.by_user
    from (select distinct on (x.table_id) x.*
            from pg_temp.zella_tables_batch a,
                 jsonb_populate_record(null::public.table_states, a.row_data) x
           where a.source_table = 'table_states'
           order by x.table_id, a.archived_at desc) s
   where exists (select 1 from public.restaurant_tables rt where rt.id = s.table_id and rt.business_id = s.business_id)
  on conflict (table_id) do nothing;
  get diagnostics v_n = row_count; raise notice 'restored % table states', v_n;

  -- 3. the 'tables' capability choice, unless a new choice was made since
  if to_regclass('public.business_capabilities') is not null then
    insert into public.business_capabilities (business_id, capability, enabled, updated_by, updated_at)
    select c.business_id, c.capability, c.enabled, c.updated_by, c.updated_at
      from (select distinct on (x.business_id) x.*
              from pg_temp.zella_tables_batch a,
                   jsonb_populate_record(null::public.business_capabilities, a.row_data) x
             where a.source_table = 'business_capabilities' and x.capability = 'tables'
             order by x.business_id, a.archived_at desc) c
     where exists (select 1 from public.businesses b where b.id = c.business_id)
    on conflict (business_id, capability) do nothing;
    get diagnostics v_n = row_count; raise notice 'restored % capability choices', v_n;
  end if;

  -- 4. waitlist details, only where still empty
  update public.waitlist_entries w
     set party_size = coalesce(w.party_size, (a.row_data ->> 'party_size')::integer),
         preferences = coalesce(w.preferences, a.row_data ->> 'preferences'),
         contact_ok = coalesce(w.contact_ok, (a.row_data ->> 'contact_ok')::boolean)
    from (select distinct on (row_data ->> 'id') row_data from pg_temp.zella_tables_batch
           where source_table = 'waitlist_entries' order by row_data ->> 'id', archived_at desc) a
   where w.id = (a.row_data ->> 'id')::uuid and w.business_id = (a.row_data ->> 'business_id')::uuid
     and (w.party_size is null or w.preferences is null or w.contact_ok is null);
  get diagnostics v_n = row_count; raise notice 'restored details on % waitlist entries', v_n;

  -- 5. appointment table assignments, one at a time through the booking checks; refused ones are reported
  v_n := 0;
  for r in select distinct on (a.row_data ->> 'id') (a.row_data ->> 'id')::uuid id,
                  array(select jsonb_array_elements_text(a.row_data -> 'table_ids'))::uuid[] table_ids
             from pg_temp.zella_tables_batch a
            where a.source_table = 'appointments' and jsonb_typeof(a.row_data -> 'table_ids') = 'array'
            order by a.row_data ->> 'id', a.archived_at desc loop
    begin
      select * into v_appointment from public.appointments where id = r.id for update;
      -- Deleted appointments and assignments replaced by users are handled permanently.
      if found and v_appointment.table_ids is null then
        if exists (select 1 from unnest(r.table_ids) u(id)
                    where not exists (select 1 from public.restaurant_tables rt
                      where rt.id = u.id and rt.business_id = v_appointment.business_id)) then
          v_unmatched := v_unmatched + 1;
          raise notice 'appointment % has unresolved archived table IDs', r.id;
          continue;
        end if;
        update public.appointments p set table_ids = r.table_ids
         where p.id = r.id and p.table_ids is null
           and not exists (select 1 from unnest(r.table_ids) u(id)
                            where not exists (select 1 from public.restaurant_tables rt where rt.id = u.id and rt.business_id = p.business_id));
        if found then
          v_n := v_n + 1;
        else
          -- A table may have disappeared since the matching check above.
          v_unmatched := v_unmatched + 1;
          raise notice 'appointment % has unresolved archived table IDs', r.id;
          continue;
        end if;
      end if;
      update public.table_data_rolled_back set restore_completed = true
       where generation_id = v_generation and source_table = 'appointments' and row_data ->> 'id' = r.id::text;
    exception
      when lock_not_available or query_canceled then raise; -- a lock wait is not a refusal: stop and run it again
      when others then
        v_skipped := v_skipped + 1;
        raise notice 'appointment % keeps no table assignment (%): %', r.id, sqlstate, sqlerrm;
    end;
  end loop;
  raise notice 'restored table assignments on % appointments (% refused by the booking checks)', v_n, v_skipped;
  raise notice '% assignments unresolved because archived table IDs could not be matched', v_unmatched;
  -- Other categories committed in this transaction must never be replayed on assignment retries.
  update public.table_data_rolled_back set restore_completed = true
   where generation_id = v_generation and source_table <> 'appointments';
  -- Both booking refusals and unmatched IDs keep the generation pending for retry.
  if v_skipped = 0 and v_unmatched = 0 then
    update public.table_data_rolled_back set row_data = row_data || '{"restored": true}'::jsonb
     where id = v_generation;
  end if;
end $restore$;

commit;
