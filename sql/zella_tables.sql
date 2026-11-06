-- Tables and live seating for restaurants (and any business that seats guests). Safe to run twice.
-- Needs sql/zella_arrival_windows.sql. Rollback: sql/rollback/zella_tables_rollback.sql (make_rollback.py tables).
--
-- BM2  A restaurant was one calendar: after one 7 PM reservation no other 7 PM reservation could be made, by the AI or
--      the team, however many tables were empty. Party size was stored but never checked, and the AI never asked it.
--
-- One availability engine, used by the AI, the CRM, the reschedule link and the seating board:
--   * Tables (restaurant_tables): name, section (main dining room, patio, private room...), smallest and largest
--     party, attributes (accessible, window, booth, high top...), and a combine group: tables in the same group and
--     section; and the combinations the owner allows (table_combinations: these tables together, with the party
--     range they really seat, e.g. T04+T05 seats 5 to 6, not 8).
--   * Every reservation that holds time needs a party size and is seated at the smallest free table, or the
--     smallest valid combination, that seats it and meets its requirements (section, attributes). A table is never
--     in two reservations or combinations at once (gap between bookings included), nor while it is blocked
--     (table_blocks), switched off, or still waiting to be cleared. This is enforced on every write under the
--     booking lock, so two callers can't take the same capacity: the second is refused, and is offered other times.
--   * A reservation must end by closing time; opening hours, holidays and blocked times still decide when the
--     restaurant is open. Parties above the AI's limit (appointment_rules.max_party_ai, at most the largest table or
--     combination) are passed to the team as a request, never booked by the AI.
--   * The seating board (zella_table_board) shows each table's state now and what comes next; staff actions
--     (zella_table_action: seat, walk-in, move, depart, clear, block, unblock, waitlist) are recorded in table_events
--     with who did them. A move that would take a table already committed elsewhere is refused, never silent.
--   * Waitlist entries carry party size, preferences and contact permission; when a table is cleared the board lists
--     the waiting parties it would now seat. No wait time is promised.
-- Without tables, nothing changes.

create table if not exists public.restaurant_tables (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 40),
  section text not null default 'Main dining room' check (length(trim(section)) between 1 and 40),
  min_party integer not null default 1 check (min_party between 1 and 100),
  max_party integer not null check (max_party between 1 and 100),
  attributes text[] not null default '{}' check (cardinality(attributes) <= 10),
  active boolean not null default true,
  position integer not null default 0,
  notes text check (notes is null or length(notes) <= 200),
  updated_at timestamptz not null default now(),
  check (min_party <= max_party),
  unique (business_id, name)
);
-- where each table sits on the floor plan (percent of the section's width and height) and its shape; drawn, never
-- used for availability
alter table public.restaurant_tables add column if not exists pos_x numeric(5,2) check (pos_x is null or pos_x between 0 and 100);
alter table public.restaurant_tables add column if not exists pos_y numeric(5,2) check (pos_y is null or pos_y between 0 and 100);
alter table public.restaurant_tables add column if not exists shape text not null default 'square' check (shape in ('square', 'round', 'rect'));

create table if not exists public.table_combinations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  table_ids uuid[] not null check (cardinality(table_ids) between 2 and 4),
  min_party integer not null default 1 check (min_party between 1 and 100),
  max_party integer not null check (max_party between 1 and 100),
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  check (min_party <= max_party)
);
create table if not exists public.table_blocks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  table_id uuid not null references public.restaurant_tables(id) on delete cascade,
  starts_at timestamptz not null, ends_at timestamptz not null check (ends_at > starts_at),
  reason text check (reason is null or length(reason) <= 200),
  created_by uuid, created_at timestamptz not null default now()
);
create index if not exists table_blocks_table_idx on public.table_blocks (table_id, starts_at);
create table if not exists public.table_states (
  table_id uuid primary key references public.restaurant_tables(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  state text not null check (state in ('needs_clearing')),
  appointment_id uuid, since timestamptz not null default now(), by_user uuid
);
create table if not exists public.table_events (
  id bigint generated always as identity primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  table_id uuid, appointment_id uuid, action text not null, by_user uuid, detail jsonb not null default '{}', at timestamptz not null default now()
);
create index if not exists table_events_table_idx on public.table_events (table_id, at desc);
do $$ declare t text; begin
  foreach t in array array['restaurant_tables', 'table_combinations', 'table_blocks', 'table_states', 'table_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (exists (select 1 from public.business_members m where m.business_id = %I.business_id and m.user_id = (select auth.uid()) and m.status = ''active''))',
                   t || '_member_select', t, t);
  end loop;
end $$;

alter table public.appointments add column if not exists table_ids uuid[];
create index if not exists appointments_table_ids_idx on public.appointments using gin (table_ids) where table_ids is not null;
alter table public.waitlist_entries add column if not exists party_size integer check (party_size is null or party_size between 1 and 100);
alter table public.waitlist_entries add column if not exists preferences text check (preferences is null or length(preferences) <= 300);
alter table public.waitlist_entries add column if not exists contact_ok boolean;

-- seating applies when the business has the "Tables and seating" capability on and at least one active table
create or replace function public.zella_table_mode(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_capability_on(p_business_id, 'tables') and exists (select 1 from public.restaurant_tables t where t.business_id = p_business_id and t.active)
$$;

-- are all these tables free for this time: not in another reservation that holds time (a seated party until it has
-- left), not blocked, switched on, and (for a time starting now) not waiting to be cleared
create or replace function public.zella_tables_free(p_table_ids uuid[], p_start timestamptz, p_end timestamptz, p_ignore uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(cardinality(p_table_ids), 0) > 0
     and (select count(*) from public.restaurant_tables t where t.id = any (p_table_ids) and t.active) = cardinality(p_table_ids)
     and not exists (
       select 1 from public.appointments a, public.restaurant_tables t
        where t.id = p_table_ids[1] and a.table_ids && p_table_ids and (p_ignore is null or a.id <> p_ignore)
          and public.zella_appointment_holds_time(a.status, a.booking_state, a.hold_expires_at)
          and a.start_time < p_end + make_interval(mins => public.zella_booking_buffer(t.business_id))
          and (case when a.in_service_at is not null then greatest(a.end_time, now()) else a.end_time end) + make_interval(mins => public.zella_booking_buffer(t.business_id)) > p_start)
     and not exists (select 1 from public.table_blocks b where b.table_id = any (p_table_ids) and b.starts_at < p_end and b.ends_at > p_start)
     and not (p_start < now() + interval '15 minutes' and exists (select 1 from public.table_states s where s.table_id = any (p_table_ids)))
$$;

-- does a set of tables suit a party: one table in its range, or exactly an allowed combination in its range; every
-- table switched on, in the section asked for and with the attributes asked for
create or replace function public.zella_tables_fit(p_business_id uuid, p_table_ids uuid[], p_party integer, p_section text default null, p_needs text[] default '{}') returns boolean
language sql stable security definer set search_path = public as $$
  with t as (select * from public.restaurant_tables x where x.business_id = p_business_id and x.id = any (p_table_ids) and x.active)
  select (select count(*) from t) = coalesce(cardinality(p_table_ids), 0) and coalesce(cardinality(p_table_ids), 0) between 1 and 4
     and (p_section is null or not exists (select 1 from t where lower(t.section) <> lower(p_section)))
     and not exists (select 1 from t where not (coalesce(p_needs, '{}') <@ t.attributes))
     and case when cardinality(p_table_ids) = 1 then exists (select 1 from t where p_party between t.min_party and t.max_party)
              else exists (select 1 from public.table_combinations c where c.business_id = p_business_id and c.active and c.table_ids @> p_table_ids and c.table_ids <@ p_table_ids
                             and p_party between c.min_party and c.max_party) end
$$;

-- the best free tables for a party: a single table with the fewest spare seats, else the allowed combination with the
-- fewest spare seats (then the fewest tables); null if nothing fits
create or replace function public.zella_pick_tables(p_business_id uuid, p_party integer, p_start timestamptz, p_end timestamptz, p_ignore uuid default null,
                                                    p_section text default null, p_needs text[] default '{}') returns uuid[]
language sql stable security definer set search_path = public as $$
  with options as (
    select array[t.id] ids, t.max_party - p_party spare, 1 n, t.position pos from public.restaurant_tables t
     where t.business_id = p_business_id and t.active and p_party between t.min_party and t.max_party
    union all
    select c.table_ids, c.max_party - p_party, cardinality(c.table_ids), 0 from public.table_combinations c
     where c.business_id = p_business_id and c.active and p_party between c.min_party and c.max_party)
  select o.ids from options o
   where public.zella_tables_fit(p_business_id, o.ids, p_party, p_section, p_needs) and public.zella_tables_free(o.ids, p_start, p_end, p_ignore)
   order by o.n = 1 desc, o.spare, o.n, o.pos limit 1
$$;

-- a caller's seating preference: a section name, or a table attribute (accessible, window...)
create or replace function public.zella_seating_pref(p_business_id uuid, p_pref text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'section', (select t.section from public.restaurant_tables t where t.business_id = p_business_id and t.active and nullif(trim(p_pref), '') is not null
                  and lower(t.section) = lower(trim(p_pref)) limit 1),
    'needs', coalesce((select to_jsonb(array_agg(distinct a)) from public.restaurant_tables t, unnest(t.attributes) a
                        where t.business_id = p_business_id and t.active and nullif(trim(p_pref), '') is not null and lower(a) = lower(trim(p_pref))), '[]'::jsonb))
$$;

-- times to offer a party: when the restaurant is open and tables for them are free
create or replace function public.zella_table_times(p_business_id uuid, p_from timestamptz, p_to timestamptz, p_party integer, p_duration integer, p_limit integer default 5,
                                                    p_section text default null, p_needs text[] default '{}')
returns table (slot_start timestamptz)
language sql stable security definer set search_path = public as $$
  select s.slot_start from public.zella_available_slots(p_business_id, p_from, p_to, p_duration, null, 30, 50, null) s
   where p_party is not null and public.zella_pick_tables(p_business_id, p_party, s.slot_start, s.slot_start + make_interval(mins => p_duration), null, p_section, p_needs) is not null
   order by s.slot_start limit least(coalesce(p_limit, 5), 10)
$$;

create or replace function public.zella_offer_times(p_tables boolean, p_party integer, p_business_id uuid, p_from timestamptz, p_to timestamptz, p_duration integer, p_window integer,
                                                    p_pref text default null)
returns table (slot_start timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_pref jsonb;
begin
  if p_tables then
    v_pref := public.zella_seating_pref(p_business_id, p_pref);
    return query select t.slot_start from public.zella_table_times(p_business_id, p_from, p_to, p_party, p_duration, 5, v_pref ->> 'section',
                                                                     array(select jsonb_array_elements_text(v_pref -> 'needs'))) t;
  else return query select c.slot_start from public.zella_booking_choices(p_business_id, p_from, p_to, p_duration, p_window) c; end if;
end $$;

-- the largest party the AI books itself (the owner's limit, never more than the largest table or combination)
create or replace function public.zella_max_party_ai(p_business_id uuid) returns integer
language sql stable security definer set search_path = public as $$
  select least(coalesce(case when (public.zella_booking_rules(p_business_id) ->> 'max_party_ai') ~ '^\d{1,3}$' then (public.zella_booking_rules(p_business_id) ->> 'max_party_ai')::int end, 100),
               greatest(coalesce((select max(t.max_party) from public.restaurant_tables t where t.business_id = p_business_id and t.active), 0),
                        coalesce((select max(c.max_party) from public.table_combinations c where c.business_id = p_business_id and c.active
                                   and not exists (select 1 from unnest(c.table_ids) i join public.restaurant_tables t on t.id = i where not t.active)), 0)))
$$;

create or replace function public.zella_table_event(p_business_id uuid, p_table_id uuid, p_appointment_id uuid, p_action text, p_detail jsonb default '{}') returns void
language sql security definer set search_path = public as $$
  insert into public.table_events (business_id, table_id, appointment_id, action, by_user, detail) values (p_business_id, p_table_id, p_appointment_id, p_action, auth.uid(), coalesce(p_detail, '{}'))
$$;

-- the CRM: list and save tables (owners, admins, managers)
create or replace function public.zella_tables(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active') then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object('tables', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'section', t.section, 'min_party', t.min_party, 'max_party', t.max_party,
           'attributes', to_jsonb(t.attributes), 'active', t.active, 'position', t.position, 'notes', t.notes, 'x', t.pos_x, 'y', t.pos_y, 'shape', t.shape) order by t.position, t.name)
           from restaurant_tables t where t.business_id = p_business_id), '[]'::jsonb),
         'combinations', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'table_ids', to_jsonb(c.table_ids), 'min_party', c.min_party, 'max_party', c.max_party, 'active', c.active,
           'name', (select string_agg(x.name, ' + ' order by x.position, x.name) from restaurant_tables x where x.id = any (c.table_ids))) order by c.max_party, c.id)
           from table_combinations c where c.business_id = p_business_id), '[]'::jsonb),
         'max_party_ai', public.zella_max_party_ai(p_business_id),
         'duration_minutes', coalesce(nullif(public.zella_booking_rules(p_business_id) ->> 'default_minutes', '')::int, 90),
         'buffer_minutes', public.zella_booking_buffer(p_business_id));
end $$;

create or replace function public.zella_save_tables(p_business_id uuid, p_tables jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t jsonb; v_old jsonb; v_keep uuid[] := '{}'; v_id uuid; i integer := 0; v_attrs text[];
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_tables) <> 'array' or jsonb_array_length(p_tables) > 200 then raise exception 'BAD_INPUT'; end if;
  v_old := (public.zella_tables(p_business_id)) -> 'tables';
  perform public.zella_booking_lock(p_business_id);
  for t in select * from jsonb_array_elements(p_tables) loop
    i := i + 1;
    if nullif(trim(coalesce(t ->> 'name', '')), '') is null then raise exception 'TABLE_NAME_REQUIRED'; end if;
    if not ((t ->> 'max_party') ~ '^\d{1,3}$') or (t ->> 'max_party')::int not between 1 and 100
       or (t ? 'min_party' and not ((t ->> 'min_party') ~ '^\d{1,3}$' and (t ->> 'min_party')::int between 1 and (t ->> 'max_party')::int)) then raise exception 'BAD_TABLE_SIZE'; end if;
    v_attrs := array(select distinct lower(left(trim(x), 30)) from jsonb_array_elements_text(case when jsonb_typeof(t -> 'attributes') = 'array' then t -> 'attributes' else '[]' end) x where trim(x) <> '' limit 10);
    v_id := case when (t ->> 'id') ~ '^[0-9a-f-]{36}$' then (t ->> 'id')::uuid end;
    if v_id is not null and exists (select 1 from restaurant_tables where id = v_id and business_id = p_business_id) then
      update restaurant_tables set name = left(trim(t ->> 'name'), 40), section = coalesce(nullif(left(trim(coalesce(t ->> 'section', '')), 40), ''), 'Main dining room'),
             min_party = coalesce((t ->> 'min_party')::int, 1), max_party = (t ->> 'max_party')::int, attributes = v_attrs,
             active = coalesce((t ->> 'active')::boolean, true), position = i,
             pos_x = case when (t ->> 'x') ~ '^\d{1,3}(\.\d+)?$' then least(100, greatest(0, (t ->> 'x')::numeric)) when t ? 'x' then null else pos_x end,
             pos_y = case when (t ->> 'y') ~ '^\d{1,3}(\.\d+)?$' then least(100, greatest(0, (t ->> 'y')::numeric)) when t ? 'y' then null else pos_y end,
             shape = case when t ->> 'shape' in ('square', 'round', 'rect') then t ->> 'shape' else shape end,
             notes = nullif(left(trim(coalesce(t ->> 'notes', '')), 200), ''), updated_at = now()
       where id = v_id;
    else
      insert into restaurant_tables (business_id, name, section, min_party, max_party, attributes, active, position, notes, pos_x, pos_y, shape)
      values (p_business_id, left(trim(t ->> 'name'), 40), coalesce(nullif(left(trim(coalesce(t ->> 'section', '')), 40), ''), 'Main dining room'), coalesce((t ->> 'min_party')::int, 1),
              (t ->> 'max_party')::int, v_attrs, coalesce((t ->> 'active')::boolean, true), i,
              nullif(left(trim(coalesce(t ->> 'notes', '')), 200), ''),
              case when (t ->> 'x') ~ '^\d{1,3}(\.\d+)?$' then least(100, greatest(0, (t ->> 'x')::numeric)) end,
              case when (t ->> 'y') ~ '^\d{1,3}(\.\d+)?$' then least(100, greatest(0, (t ->> 'y')::numeric)) end,
              case when t ->> 'shape' in ('square', 'round', 'rect') then t ->> 'shape' else 'square' end)
      returning id into v_id;
    end if;
    v_keep := v_keep || v_id;
  end loop;
  -- tables left out are switched off, never deleted: past reservations keep their table
  update restaurant_tables set active = false, updated_at = now() where business_id = p_business_id and not (id = any (v_keep)) and active;
  perform public.zella_tables_check_bookings(p_business_id);   -- refuses (and undoes) a change that would unseat a booking
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'tables_changed', 'business', p_business_id, jsonb_build_object('tables', v_old), jsonb_build_object('tables', p_tables));
  return public.zella_tables(p_business_id);
end $$;

-- future reservations a configuration change would leave without valid tables: the change is refused with the list,
-- so the team moves or cancels them first (nothing is changed silently)
create or replace function public.zella_tables_affected(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('appointment_id', a.id, 'at', a.start_time, 'party', a.party_size,
           'tables', (select jsonb_agg(x.name order by x.name) from public.restaurant_tables x where x.id = any (a.table_ids))) order by a.start_time), '[]'::jsonb)
    from public.appointments a
   where a.business_id = p_business_id and a.table_ids is not null and a.end_time > now() and a.in_service_at is null
     and public.zella_appointment_holds_time(a.status, a.booking_state, a.hold_expires_at)
     and not public.zella_tables_fit(p_business_id, a.table_ids, a.party_size)
$$;
create or replace function public.zella_tables_check_bookings(p_business_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare v jsonb := public.zella_tables_affected(p_business_id);
begin
  if jsonb_array_length(v) > 0 then
    raise exception 'AFFECTS_RESERVATIONS' using detail = v::text, hint = 'These reservations would no longer fit. Move or cancel them first, then save again.';
  end if;
end $$;

create or replace function public.zella_save_combinations(p_business_id uuid, p_combinations jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb; v_ids uuid[]; v_old jsonb; v_keep uuid[] := '{}'; v_id uuid;
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_combinations) <> 'array' or jsonb_array_length(p_combinations) > 200 then raise exception 'BAD_INPUT'; end if;
  v_old := (public.zella_tables(p_business_id)) -> 'combinations';
  perform public.zella_booking_lock(p_business_id);
  for c in select * from jsonb_array_elements(p_combinations) loop
    v_ids := array(select distinct (x)::uuid from jsonb_array_elements_text(case when jsonb_typeof(c -> 'table_ids') = 'array' then c -> 'table_ids' else '[]' end) x order by 1);
    if cardinality(v_ids) not between 2 and 4 then raise exception 'COMBINATION_NEEDS_2_TO_4_TABLES'; end if;
    if (select count(*) from restaurant_tables t where t.id = any (v_ids) and t.business_id = p_business_id) <> cardinality(v_ids) then raise exception 'NOT_ALLOWED'; end if;
    if not ((c ->> 'max_party') ~ '^\d{1,3}$') or (c ->> 'max_party')::int not between 1 and 100
       or (c ? 'min_party' and not ((c ->> 'min_party') ~ '^\d{1,3}$' and (c ->> 'min_party')::int between 1 and (c ->> 'max_party')::int)) then raise exception 'BAD_TABLE_SIZE'; end if;
    select id into v_id from table_combinations where business_id = p_business_id and table_ids @> v_ids and table_ids <@ v_ids limit 1;
    if v_id is null then
      insert into table_combinations (business_id, table_ids, min_party, max_party, active) values (p_business_id, v_ids, coalesce((c ->> 'min_party')::int, 1), (c ->> 'max_party')::int,
             coalesce((c ->> 'active')::boolean, true)) returning id into v_id;
    else
      update table_combinations set min_party = coalesce((c ->> 'min_party')::int, 1), max_party = (c ->> 'max_party')::int, active = coalesce((c ->> 'active')::boolean, true), updated_at = now()
       where id = v_id;
    end if;
    v_keep := v_keep || v_id;
  end loop;
  update table_combinations set active = false, updated_at = now() where business_id = p_business_id and not (id = any (v_keep)) and active;
  perform public.zella_tables_check_bookings(p_business_id);
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'table_combinations_changed', 'business', p_business_id, jsonb_build_object('combinations', v_old), jsonb_build_object('combinations', p_combinations));
  return public.zella_tables(p_business_id);
end $$;

-- the seating board: every table's state now and what comes next, today's reservations and the waitlist
create or replace function public.zella_table_board(p_business_id uuid, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_day_start timestamptz; v_day_end timestamptz; v_tables jsonb; v_res jsonb; v_wait jsonb;
begin
  if not exists (select 1 from business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active') then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(nullif(timezone, ''), 'America/New_York') into v_tz from businesses where id = p_business_id;
  v_day_start := ((p_at at time zone v_tz)::date)::timestamp at time zone v_tz;
  v_day_end := v_day_start + interval '1 day';
  with res as (
    select a.*, nullif(trim(concat_ws(' ', c.first_name, c.last_name)), '') guest, c.phone guest_phone
      from appointments a left join customers c on c.id = a.customer_id
     where a.business_id = p_business_id and a.start_time < v_day_end and a.end_time > v_day_start and a.status in ('scheduled', 'confirmed', 'completed', 'no_show')
  ),
  t as (
    select x.*,
      (select jsonb_build_object('reason', bl.reason, 'until', bl.ends_at) from table_blocks bl where bl.table_id = x.id and bl.starts_at <= p_at and bl.ends_at > p_at limit 1) block,
      (select jsonb_build_object('since', s.since) from table_states s where s.table_id = x.id) clearing,
      se.id se_id, se.guest se_guest, se.party_size se_party, se.in_service_at se_since, se.end_time se_end,
      he.id he_id,
      nx.id nx_id, nx.guest nx_guest, nx.party_size nx_party, nx.start_time nx_at, nx.arrived_at nx_arrived
    from restaurant_tables x
    left join lateral (select r.* from res r where x.id = any (r.table_ids) and r.in_service_at is not null and r.status not in ('completed', 'no_show', 'cancelled') order by r.in_service_at desc limit 1) se on true
    left join lateral (select r.id from res r where x.id = any (r.table_ids) and r.booking_state = 'tentative' and r.hold_expires_at > p_at and r.start_time <= p_at + interval '30 minutes' order by r.start_time limit 1) he on true
    left join lateral (select r.* from res r where x.id = any (r.table_ids) and r.in_service_at is null and r.status in ('scheduled', 'confirmed') and coalesce(r.booking_state, 'confirmed') = 'confirmed'
                         and r.end_time > p_at order by r.start_time limit 1) nx on true
    where x.business_id = p_business_id and x.active
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'section', t.section, 'seats', t.max_party, 'min_party', t.min_party, 'attributes', to_jsonb(t.attributes),
           'x', t.pos_x, 'y', t.pos_y, 'shape', t.shape, 'position', t.position,
           'state', case when t.block is not null then 'unavailable' when t.clearing is not null then 'needs_clearing' when t.se_id is not null then 'seated'
                         when t.he_id is not null then 'held' when t.nx_id is not null and t.nx_at <= p_at + interval '30 minutes' then 'reserved' else 'available' end,
           'block', t.block, 'clearing_since', t.clearing -> 'since',
           'current', case when t.se_id is not null then jsonb_build_object('appointment_id', t.se_id, 'guest', t.se_guest, 'party', t.se_party, 'since', t.se_since, 'expected_end', t.se_end) end,
           'next', case when t.nx_id is not null then jsonb_build_object('appointment_id', t.nx_id, 'guest', t.nx_guest, 'party', t.nx_party, 'at', t.nx_at, 'arrived', t.nx_arrived is not null) end,
           'available_until', case when t.block is null and t.clearing is null and t.se_id is null then t.nx_at end)
         order by t.section, t.position, t.name), '[]'::jsonb) into v_tables from t;
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'at', r.start_time, 'until', r.end_time, 'guest', r.guest, 'phone', r.guest_phone, 'party', r.party_size,
           'tables', (select coalesce(jsonb_agg(x.name order by x.name), '[]'::jsonb) from restaurant_tables x where x.id = any (r.table_ids)),
           'status', case when r.status in ('completed', 'no_show') then r.status when r.in_service_at is not null then 'seated' when r.arrived_at is not null then 'arrived'
                          when r.booking_state = 'requested' then 'requested' when r.booking_state = 'tentative' then 'held' else 'confirmed' end,
           'source', coalesce(r.metadata ->> 'source', case when r.attendance_source is not null then 'staff' end, 'staff'),
           'preferences', r.metadata ->> 'seating', 'notes', r.internal_notes, 'requests', r.description) order by r.start_time), '[]'::jsonb)
    into v_res from (select a.*, nullif(trim(concat_ws(' ', c.first_name, c.last_name)), '') guest, c.phone guest_phone
                       from appointments a left join customers c on c.id = a.customer_id
                      where a.business_id = p_business_id and a.start_time < v_day_end and a.end_time > v_day_start
                        and a.status in ('scheduled', 'confirmed', 'completed', 'no_show')) r;
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'guest', nullif(trim(concat_ws(' ', c.first_name, c.last_name)), ''), 'party', w.party_size, 'joined', w.created_at,
           'preferences', w.preferences, 'contact_ok', w.contact_ok, 'status', w.status, 'offer_expires_at', w.offer_expires_at,
           'fits_now', case when w.party_size is not null then (select coalesce(jsonb_agg(x.name order by x.name), '[]'::jsonb) from restaurant_tables x
                             where x.id = any (public.zella_pick_tables(p_business_id, w.party_size, p_at, p_at + make_interval(mins => coalesce(w.duration_minutes, 90))))) end)
         order by w.created_at), '[]'::jsonb)
    into v_wait from waitlist_entries w join customers c on c.id = w.customer_id
   where w.business_id = p_business_id and w.status in ('waiting', 'offered') and w.created_at > v_day_start - interval '1 day';
  return jsonb_build_object('at', p_at, 'timezone', v_tz,
    'summary', (select jsonb_object_agg(s, (select count(*) from jsonb_array_elements(v_tables) e where e ->> 'state' = s))
                  from unnest(array['available', 'held', 'reserved', 'seated', 'needs_clearing', 'unavailable']) s),
    'sections', (select coalesce(jsonb_agg(distinct e ->> 'section'), '[]'::jsonb) from jsonb_array_elements(v_tables) e),
    'tables', v_tables, 'reservations', v_res, 'waitlist', v_wait);
end $$;

-- staff actions on the board (anyone who can edit; every one recorded in table_events)
create or replace function public.zella_table_action(p_business_id uuid, p_action text, p_args jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public as $$
declare a record; v_ids uuid[]; v_id uuid; v_cust uuid; v_party int; v_dur int; v_now timestamptz := date_trunc('minute', now()); v_tid uuid; v_fits jsonb;
begin
  if auth.uid() is null or not public.zella_can_edit(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_args) <> 'object' then raise exception 'BAD_INPUT'; end if;
  v_ids := case when jsonb_typeof(p_args -> 'table_ids') = 'array' then array(select (x)::uuid from jsonb_array_elements_text(p_args -> 'table_ids') x) end;
  if v_ids is not null and exists (select 1 from unnest(v_ids) i where not exists (select 1 from restaurant_tables t where t.id = i and t.business_id = p_business_id)) then raise exception 'NOT_ALLOWED'; end if;
  if (p_args ->> 'appointment_id') is not null then
    select * into a from appointments where id = (p_args ->> 'appointment_id')::uuid and business_id = p_business_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;
  perform public.zella_booking_lock(p_business_id);
  v_dur := coalesce(nullif(public.zella_booking_rules(p_business_id) ->> 'default_minutes', '')::int, 90);

  if p_action = 'seat' then   -- a reservation arrives and sits down (at its tables, or ones the host picks)
    if a.id is null then raise exception 'BAD_INPUT'; end if;
    update appointments set table_ids = coalesce(v_ids, table_ids), arrived_at = coalesce(arrived_at, now()), in_service_at = now(), attendance_source = 'staff', attendance_by = auth.uid(), updated_at = now()
     where id = a.id;
    foreach v_tid in array (select table_ids from appointments where id = a.id) loop perform public.zella_table_event(p_business_id, v_tid, a.id, 'seated', jsonb_build_object('party', a.party_size)); end loop;
  elsif p_action = 'walk_in' then
    v_party := case when (p_args ->> 'party_size') ~ '^\d{1,3}$' then (p_args ->> 'party_size')::int end;
    if v_party is null or v_party < 1 then raise exception 'PARTY_SIZE_REQUIRED'; end if;
    if nullif(trim(coalesce(p_args ->> 'name', '')), '') is not null or nullif(trim(coalesce(p_args ->> 'phone', '')), '') is not null then
      insert into customers (business_id, first_name, phone, source, status) values (p_business_id, nullif(left(trim(coalesce(p_args ->> 'name', '')), 80), ''),
             nullif(left(trim(coalesce(p_args ->> 'phone', '')), 30), ''), 'walk_in', 'active') returning id into v_cust;
    end if;
    insert into appointments (business_id, customer_id, title, start_time, end_time, timezone, status, party_size, booking_state, table_ids, arrived_at, in_service_at,
                              attendance_source, attendance_by, metadata, internal_notes)
    values (p_business_id, v_cust, 'Walk-in', v_now, v_now + make_interval(mins => coalesce(nullif(p_args ->> 'minutes', '')::int, v_dur)),
            (select coalesce(timezone, 'America/New_York') from businesses where id = p_business_id), 'scheduled', v_party, 'confirmed', v_ids, now(), now(), 'staff', auth.uid(),
            jsonb_build_object('source', 'walk_in'), nullif(left(coalesce(p_args ->> 'notes', ''), 500), ''))
    returning id into v_id;
    foreach v_tid in array (select table_ids from appointments where id = v_id) loop perform public.zella_table_event(p_business_id, v_tid, v_id, 'walk_in_seated', jsonb_build_object('party', v_party)); end loop;
    if (p_args ->> 'waitlist_id') is not null then
      update waitlist_entries set status = 'booked', appointment_id = v_id where id = (p_args ->> 'waitlist_id')::uuid and business_id = p_business_id;
    end if;
    return jsonb_build_object('ok', true, 'appointment_id', v_id, 'tables', (select table_ids from appointments where id = v_id));
  elsif p_action = 'move' then   -- assign, move or combine: refused if any table is committed elsewhere
    if a.id is null or v_ids is null then raise exception 'BAD_INPUT'; end if;
    if not public.zella_tables_fit(p_business_id, v_ids, a.party_size) then raise exception 'TABLES_DO_NOT_FIT' using hint = 'Those tables don''t seat the party, or can''t be combined.'; end if;
    update appointments set table_ids = v_ids, updated_at = now() where id = a.id;   -- the guard refuses tables in use (SLOT_TAKEN)
    perform public.zella_table_event(p_business_id, x, a.id, 'moved', jsonb_build_object('from', to_jsonb(a.table_ids), 'to', to_jsonb(v_ids))) from unnest(v_ids) x;
  elsif p_action = 'depart' then   -- guests left: the reservation ends now and its tables wait to be cleared
    if a.id is null then raise exception 'BAD_INPUT'; end if;
    update appointments set status = 'completed', end_time = greatest(start_time + interval '5 minutes', least(end_time, now())), updated_at = now() where id = a.id;
    insert into table_states (table_id, business_id, state, appointment_id, by_user) select x, p_business_id, 'needs_clearing', a.id, auth.uid() from unnest(coalesce(a.table_ids, '{}')) x
    on conflict (table_id) do update set state = excluded.state, appointment_id = excluded.appointment_id, since = now(), by_user = excluded.by_user;
    perform public.zella_table_event(p_business_id, x, a.id, 'departed') from unnest(coalesce(a.table_ids, '{}')) x;
  elsif p_action = 'clear' then
    v_tid := (p_args ->> 'table_id')::uuid;
    if not exists (select 1 from restaurant_tables where id = v_tid and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
    delete from table_states where table_id = v_tid;
    perform public.zella_table_event(p_business_id, v_tid, null, 'cleared');
    select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'party', w.party_size)), '[]'::jsonb) into v_fits from waitlist_entries w
     where w.business_id = p_business_id and w.status = 'waiting' and w.party_size is not null
       and exists (select 1 from restaurant_tables t where t.id = v_tid and w.party_size between t.min_party and t.max_party)   -- the table just cleared seats them
       and public.zella_tables_free(array[v_tid], now(), now() + make_interval(mins => coalesce(w.duration_minutes, v_dur)));
    return jsonb_build_object('ok', true, 'waitlist_fits', v_fits);
  elsif p_action = 'block' then
    v_tid := (p_args ->> 'table_id')::uuid;
    if not exists (select 1 from restaurant_tables where id = v_tid and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
    if exists (select 1 from appointments x where x.table_ids @> array[v_tid] and public.zella_appointment_holds_time(x.status, x.booking_state, x.hold_expires_at)
                and x.start_time < (p_args ->> 'ends_at')::timestamptz and x.end_time > coalesce((p_args ->> 'starts_at')::timestamptz, now())) then
      raise exception 'TABLE_HAS_RESERVATIONS' using hint = 'Move those reservations first; blocking never displaces a booking.';
    end if;
    insert into table_blocks (business_id, table_id, starts_at, ends_at, reason, created_by)
    values (p_business_id, v_tid, coalesce((p_args ->> 'starts_at')::timestamptz, now()), (p_args ->> 'ends_at')::timestamptz, nullif(left(coalesce(p_args ->> 'reason', ''), 200), ''), auth.uid())
    returning id into v_id;
    perform public.zella_table_event(p_business_id, v_tid, null, 'blocked', jsonb_build_object('until', p_args ->> 'ends_at', 'reason', p_args ->> 'reason'));
  elsif p_action = 'unblock' then
    delete from table_blocks where id = (p_args ->> 'block_id')::uuid and business_id = p_business_id returning table_id into v_tid;
    if v_tid is null then raise exception 'NOT_FOUND'; end if;
    perform public.zella_table_event(p_business_id, v_tid, null, 'unblocked');
  elsif p_action = 'waitlist_add' then
    v_party := case when (p_args ->> 'party_size') ~ '^\d{1,3}$' then (p_args ->> 'party_size')::int end;
    if v_party is null or v_party < 1 then raise exception 'PARTY_SIZE_REQUIRED'; end if;
    if nullif(trim(coalesce(p_args ->> 'name', '')), '') is null then raise exception 'NAME_REQUIRED'; end if;
    insert into customers (business_id, first_name, phone, source, status) values (p_business_id, left(trim(p_args ->> 'name'), 80), nullif(left(trim(coalesce(p_args ->> 'phone', '')), 30), ''), 'walk_in', 'active')
    returning id into v_cust;
    insert into waitlist_entries (business_id, customer_id, title, duration_minutes, earliest_at, latest_at, status, party_size, preferences, contact_ok)
    values (p_business_id, v_cust, 'Table', v_dur, now(), now() + interval '6 hours', 'waiting', v_party, nullif(left(coalesce(p_args ->> 'preferences', ''), 300), ''),
            coalesce((p_args ->> 'contact_ok')::boolean, false))
    returning id into v_id;
    return jsonb_build_object('ok', true, 'waitlist_id', v_id);
  elsif p_action = 'history' then
    v_tid := (p_args ->> 'table_id')::uuid;
    return jsonb_build_object('ok', true, 'events', (select coalesce(jsonb_agg(jsonb_build_object('at', e.at, 'action', e.action, 'appointment_id', e.appointment_id, 'detail', e.detail,
             'by', (select nullif(trim(concat_ws(' ', p.first_name, p.last_name)), '') from profiles p where p.id = e.by_user)) order by e.at desc), '[]'::jsonb)
             from (select * from table_events where business_id = p_business_id and table_id = v_tid order by at desc limit 100) e));
  else raise exception 'BAD_ACTION';
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.zella_table_mode(uuid), public.zella_tables_free(uuid[], timestamptz, timestamptz, uuid),
  public.zella_tables_fit(uuid, uuid[], integer, text, text[]), public.zella_pick_tables(uuid, integer, timestamptz, timestamptz, uuid, text, text[]),
  public.zella_seating_pref(uuid, text), public.zella_table_times(uuid, timestamptz, timestamptz, integer, integer, integer, text, text[]),
  public.zella_offer_times(boolean, integer, uuid, timestamptz, timestamptz, integer, integer, text), public.zella_max_party_ai(uuid),
  public.zella_table_event(uuid, uuid, uuid, text, jsonb), public.zella_tables_affected(uuid), public.zella_tables_check_bookings(uuid) from public, anon, authenticated;
grant execute on function public.zella_table_mode(uuid), public.zella_tables_free(uuid[], timestamptz, timestamptz, uuid),
  public.zella_tables_fit(uuid, uuid[], integer, text, text[]), public.zella_pick_tables(uuid, integer, timestamptz, timestamptz, uuid, text, text[]),
  public.zella_seating_pref(uuid, text), public.zella_table_times(uuid, timestamptz, timestamptz, integer, integer, integer, text, text[]),
  public.zella_offer_times(boolean, integer, uuid, timestamptz, timestamptz, integer, integer, text), public.zella_max_party_ai(uuid),
  public.zella_table_event(uuid, uuid, uuid, text, jsonb), public.zella_tables_affected(uuid), public.zella_tables_check_bookings(uuid) to service_role;
revoke execute on function public.zella_tables(uuid), public.zella_save_tables(uuid, jsonb), public.zella_save_combinations(uuid, jsonb), public.zella_table_board(uuid, timestamptz),
  public.zella_table_action(uuid, text, jsonb) from public, anon;
grant execute on function public.zella_tables(uuid), public.zella_save_tables(uuid, jsonb), public.zella_save_combinations(uuid, jsonb), public.zella_table_board(uuid, timestamptz),
  public.zella_table_action(uuid, text, jsonb) to authenticated, service_role;

do $$
declare def text;
begin
  -- the capability: "Tables and seating", on for restaurants, optional for hospitality
  def := pg_get_functiondef('public.zella_capability_catalog()'::regprocedure);
  if position('zella_tables_capability' in def) = 0 then
    def := replace(def, $a$  select '{$a$, $a$  select /* zella_tables_capability */ '{$a$);
    def := replace(def, $a$"access_vault": {"label": "Access codes and keys", "order": 8}$a$,
                        $a$"access_vault": {"label": "Access codes and keys", "order": 8},
    "tables":       {"label": "Tables and seating", "needs": "scheduling", "order": 9}$a$);
    if position('zella_tables_capability' in def) = 0 or position('"tables"' in def) = 0 then raise exception 'zella_capability_catalog has changed; review this patch'; end if;
    execute def;
  end if;
  def := pg_get_functiondef('public.zella_seed_capability_defaults()'::regprocedure);
  if position('zella_tables_capability' in def) = 0 then
    def := replace(def, $a$  with d(slug, caps) as (values$a$, $a$  with d(slug, caps) as (values   /* zella_tables_capability */$a$);
    def := replace(def, $a$('hospitality',           '{"on": ["scheduling","checkins","money"], "optional": ["waitlist"]}'),$a$,
                        $a$('hospitality',           '{"on": ["scheduling","checkins","money"], "optional": ["waitlist","tables"]}'),$a$);
    def := replace(def, $a$('restaurant',            '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'),$a$,
                        $a$('restaurant',            '{"on": ["scheduling","checkins","waitlist","money","tables"], "optional": []}'),$a$);
    if position('zella_tables_capability' in def) = 0 or position('"waitlist","money","tables"' in def) = 0 then raise exception 'zella_seed_capability_defaults has changed; review this patch'; end if;
    execute def;
  end if;

  if to_regprocedure('public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer)') is null then
    raise exception 'apply sql/zella_arrival_windows.sql first';
  end if;

  -- availability: with tables, a time is open when the restaurant is; which tables are free is decided per party
  def := pg_get_functiondef('public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer, uuid)'::regprocedure);
  if position('zella_tables' in def) = 0 then
    def := replace(def, $a$  v_has_hours boolean;$a$, $a$  v_has_hours boolean;
  v_tables boolean := public.zella_table_mode(p_business_id);   /* zella_tables */$a$);
    def := replace(def, $a$     and not exists (
       select 1 from public.appointments a$a$, $a$     and (v_tables or not exists (
       select 1 from public.appointments a$a$);
    def := replace(def, $a$          and a.start_time < r.t + v_duration + v_buffer and a.end_time + v_buffer > r.t
     )
   order by$a$, $a$          and a.start_time < r.t + v_duration + v_buffer and a.end_time + v_buffer > r.t
     ))
   order by$a$);
    if position('zella_tables' in def) = 0 or position('and (v_tables or not exists' in def) = 0 or position(E'> r.t\n     ))\n   order by' in def) = 0 then
      raise exception 'zella_available_slots has changed; review this patch';
    end if;
    execute def;
  end if;

  -- the guard: with tables, every reservation that holds time is seated at free tables that fit
  def := pg_get_functiondef('public.zella_appointment_conflict_guard()'::regprocedure);
  if position('zella_tables' in def) = 0 then
    def := replace(def, $a$and new.staff_id is not distinct from old.staff_id$a$,
                        $a$and new.staff_id is not distinct from old.staff_id and new.table_ids is not distinct from old.table_ids and new.party_size is not distinct from old.party_size$a$);
    def := replace(def, $a$  v_has_staff := exists (select 1 from public.staff_members s where s.business_id = new.business_id and s.is_active);$a$, $a$  if public.zella_table_mode(new.business_id) then   /* zella_tables */
    if new.party_size is null or new.party_size < 1 then
      raise exception 'PARTY_SIZE_REQUIRED' using hint = 'Enter how many people the reservation is for.';
    end if;
    if new.table_ids is not null and cardinality(new.table_ids) > 0 then
      if public.zella_tables_fit(new.business_id, new.table_ids, new.party_size) and public.zella_tables_free(new.table_ids, new.start_time, new.end_time, new.id) then
        return new;   -- the chosen (or current) tables are free and seat the party
      end if;
      if tg_op = 'UPDATE' and new.table_ids is not distinct from old.table_ids then new.table_ids := null;   -- moved or resized: seat it again
      else raise exception 'SLOT_TAKEN' using detail = 'those tables are taken then, or do not seat the party', hint = 'Pick other tables or another time, or book anyway on purpose.';
      end if;
    end if;
    new.table_ids := public.zella_pick_tables(new.business_id, new.party_size, new.start_time, new.end_time, new.id, new.metadata ->> 'section',
                                              array(select jsonb_array_elements_text(case when jsonb_typeof(new.metadata -> 'needs') = 'array' then new.metadata -> 'needs' else '[]' end)));
    if new.table_ids is null then
      raise exception 'SLOT_TAKEN' using detail = 'no table for ' || new.party_size || ' is free then', hint = 'Pick another time, or book anyway on purpose.';
    end if;
    return new;
  end if;
  v_has_staff := exists (select 1 from public.staff_members s where s.business_id = new.business_id and s.is_active);$a$);
    if position('zella_tables' in def) = 0 or position('new.table_ids is not distinct from old.table_ids' in def) = 0 then
      raise exception 'zella_appointment_conflict_guard has changed; review this patch';
    end if;
    execute def;
  end if;

  -- the AI: ask the party size, offer times with free tables, pass large parties to the team
  def := pg_get_functiondef('public.zella_ai_booking(text, uuid, text, jsonb)'::regprocedure);
  if position('zella_tables' in def) = 0 then
    def := replace(def, $a$v_notice integer; v_ahead integer; v_window integer;$a$, $a$v_notice integer; v_ahead integer; v_window integer; v_tables boolean; v_party integer; v_pref jsonb;$a$);
    def := replace(def, $a$  if v_window is not null then v_dur := v_window; end if;$a$, $a$  if v_window is not null then v_dur := v_window; end if;
  v_tables := public.zella_table_mode(v_biz);   /* zella_tables */
  v_party := case when (v_args ->> 'party_size') ~ '^\d{1,3}$' then (v_args ->> 'party_size')::int end;
  if v_tables and p_action in ('availability', 'book') then
    if v_party is null or v_party < 1 then
      return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask how many people the reservation is for, then try again with party_size.');
    end if;
    if p_action = 'availability' and v_party > public.zella_max_party_ai(v_biz) then
      return jsonb_build_object('ok', true, 'status', 'large_party', 'slots', '[]'::jsonb, 'say',
        'Parties of more than ' || public.zella_max_party_ai(v_biz) || ' are arranged by the team. Ask for the preferred day and time, the name and a phone number, then call book_appointment with that time: it is passed to the team to confirm. Do not say it is booked.');
    end if;
    v_pref := public.zella_seating_pref(v_biz, v_args ->> 'seating');
  end if;$a$);
    def := replace(def, $a$from public.zella_booking_choices(v_biz, v_from, v_to, v_dur, v_window) s;$a$,
                        $a$from public.zella_offer_times(v_tables, v_party, v_biz, v_from, v_to, v_dur, v_window, v_args ->> 'seating') s;$a$);
    def := replace(def, $a$from public.zella_booking_choices(v_biz, greatest(now(), v_start - interval '1 day'), v_start + interval '3 days', v_dur, v_window) s;$a$,
                        $a$from public.zella_offer_times(v_tables, v_party, v_biz, greatest(now(), v_start - interval '1 day'), v_start + interval '3 days', v_dur, v_window, v_args ->> 'seating') s;$a$);
    def := replace(def, $a$  if v_first is null then return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for their name.'); end if;$a$,
                        $a$  if v_first is null then return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for their name.'); end if;
  if v_tables and v_party > public.zella_max_party_ai(v_biz) then   -- zella_tables: a large party is the team's to arrange
    v_appt := public.zella_request_appointment(v_biz, null, coalesce(v_phone, v_call_phone), 'Reservation - party of ' || v_party, v_start,
                left(coalesce(v_notes || ' ', '') || 'Party of ' || v_party || '. Name: ' || v_first || coalesce(' ' || v_last, '') || '.', 500));
    update appointments set party_size = v_party, metadata = coalesce(metadata, '{}') || jsonb_build_object('source', 'ai_call') where id = v_appt;
    return jsonb_build_object('ok', true, 'status', 'requested', 'appointment_id', v_appt, 'say',
      'The request for a party of ' || v_party || ' was passed to the team, who will call to confirm. Do not say it is booked.');
  end if;$a$);
    def := replace(def, $a$    v_appt := public.zella_book_appointment(v_biz, v_cust, v_title, v_start, v_dur, null, null, v_notes);$a$,
                        $a$    v_appt := public.zella_book_appointment(v_biz, v_cust, v_title, v_start, v_dur, null, v_party, v_notes, coalesce(v_pref, '{}') || jsonb_build_object('source', 'ai_call', 'seating', v_args ->> 'seating'));$a$);
    if position('zella_tables' in def) = 0 or position('zella_offer_times(v_tables, v_party, v_biz, v_from' in def) = 0 or position('v_party, v_notes, coalesce(v_pref' in def) = 0
       or position('a large party is the team''s to arrange' in def) = 0 then
      raise exception 'zella_ai_booking has changed; review this patch';
    end if;
    execute def;
  end if;

  -- the tools: party_size and seating on check_availability and book_appointment
  def := pg_get_functiondef('public.zella_brain_tool_defs()'::regprocedure);
  if position('party_size' in def) = 0 then
    def := replace(def, $a$'days', jsonb_build_object('type', 'integer'), 'duration_minutes', jsonb_build_object('type', 'integer')))),$a$,
                        $a$'days', jsonb_build_object('type', 'integer'), 'duration_minutes', jsonb_build_object('type', 'integer'),
      'party_size', jsonb_build_object('type', 'integer', 'description', 'Number of people. Restaurants and anyone who seats guests: always ask first.'),
      'seating', jsonb_build_object('type', 'string', 'description', 'Optional seating preference the caller asked for, e.g. patio, accessible, window')))),$a$);
    def := replace(def, $a$'title', jsonb_build_object('type', 'string'), 'notes', jsonb_build_object('type', 'string'), 'duration_minutes', jsonb_build_object('type', 'integer'),$a$,
                        $a$'title', jsonb_build_object('type', 'string'), 'notes', jsonb_build_object('type', 'string'), 'duration_minutes', jsonb_build_object('type', 'integer'),
      'party_size', jsonb_build_object('type', 'integer', 'description', 'Number of people, as used for check_availability'),
      'seating', jsonb_build_object('type', 'string', 'description', 'The seating preference used for check_availability, if any'),$a$);
    if (length(def) - length(replace(def, 'party_size', ''))) / length('party_size') <> 2 then raise exception 'zella_brain_tool_defs has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

-- zella_book_appointment with booking details (the seating preference and source) for the guard: a new overload,
-- so existing callers are unchanged
create or replace function public.zella_book_appointment(p_business_id uuid, p_customer_id uuid, p_title text, p_start timestamptz, p_duration_minutes integer,
                                                          p_staff_id uuid, p_party_size integer, p_notes text, p_metadata jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_slot record; v_tz text; v_id uuid;
begin
  if auth.uid() is not null and not public.zella_can_edit(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  perform public.zella_booking_lock(p_business_id);
  select * into v_slot from public.zella_available_slots(p_business_id, p_start, p_start, p_duration_minutes, p_staff_id, 5, 1, null) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, staff_id, party_size, description, booking_state, metadata)
  values (p_business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Appointment'), v_slot.slot_start, v_slot.slot_end, v_tz, 'scheduled', v_slot.staff_id, p_party_size, p_notes, 'confirmed',
          coalesce(p_metadata, '{}'))
  returning id into v_id;
  if p_customer_id is not null then perform public.zella_stop_callbacks_for(p_business_id, p_customer_id, null, 'booked'); end if;
  return v_id;
end $$;
revoke execute on function public.zella_book_appointment(uuid, uuid, text, timestamptz, integer, uuid, integer, text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_book_appointment(uuid, uuid, text, timestamptz, integer, uuid, integer, text, jsonb) to service_role;

-- the guard also runs when only the tables or the party size change (a move or a resize), so a move can never take a
-- table committed to someone else
drop trigger if exists zella_appointment_conflict_guard on public.appointments;
create trigger zella_appointment_conflict_guard before insert or update of start_time, end_time, staff_id, status, booking_state, table_ids, party_size
  on public.appointments for each row execute function public.zella_appointment_conflict_guard();

-- the industries' current defaults (what zella_seed_capability_defaults now writes for them)
update public.industry_configurations ic set features = jsonb_set(ic.features, '{capabilities,on}', (ic.features #> '{capabilities,on}') || '["tables"]'), updated_at = now()
  from public.industries i where i.id = ic.industry_id and i.slug = 'restaurant' and not (ic.features #> '{capabilities,on}') ? 'tables';
update public.industry_configurations ic set features = jsonb_set(ic.features, '{capabilities,optional}', (ic.features #> '{capabilities,optional}') || '["tables"]'), updated_at = now()
  from public.industries i where i.id = ic.industry_id and i.slug = 'hospitality' and not (ic.features #> '{capabilities,optional}') ? 'tables';

-- a party marked done anywhere (the seating board, Check-ins, an integration) leaves its tables waiting to be cleared
create or replace function public.zella_table_clearing_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' and new.table_ids is not null and public.zella_table_mode(new.business_id) then
    insert into public.table_states (table_id, business_id, state, appointment_id, by_user)
    select x, new.business_id, 'needs_clearing', new.id, auth.uid() from unnest(new.table_ids) x
    on conflict (table_id) do update set state = excluded.state, appointment_id = excluded.appointment_id, since = now(), by_user = excluded.by_user;
  end if;
  return new;
end $$;
revoke execute on function public.zella_table_clearing_trg() from public, anon, authenticated;
drop trigger if exists zella_table_clearing_trg on public.appointments;
create trigger zella_table_clearing_trg after update of status on public.appointments for each row execute function public.zella_table_clearing_trg();
