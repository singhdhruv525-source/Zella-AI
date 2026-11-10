-- Appointments and jobs linked to the record they are for (5 Nov 2026): the pet at the vet, the vehicle at the workshop,
-- the property a crew visits, the child at a tour, the matter of a consultation, the repair order of a drop-off.
--
--   * appointments.record_id: the confirmed record, of a type the business allows ("Can be booked for",
--     crm_record_types.appointment_link). Checked on every write, whoever writes (team, AI receptionist, integrations):
--     same business, not archived, a bookable type, and if the record belongs to a customer, the appointment's customer
--     is that customer (filled in when the booking has none).
--   * Zella never decides which pet, vehicle or property a booking is for. When a customer has exactly one, it is
--     offered as a suggestion (record_suggested_id) for the team to confirm with one click; the customer may have a new
--     one that isn't on file yet. With none, nothing is asked; with several, nothing is suggested.
--   * zella_appointments_needing_record lists upcoming bookings whose customer has pets / vehicles / properties ... on
--     file but no confirmed one, with the suggestion and the choices, so they are answered before the visit.
--   * The customer and the record must match when the change is committed (a deferred check), so merging duplicate
--     customers (which moves bookings and records separately) works, and a booking moved to another customer while it
--     still points at the old customer's pet is refused. Changing the customer drops any suggestion.
--   * Cancelling or rescheduling keeps the link. Archiving the record keeps existing links (history) but refuses new
--     ones. Deleting a record clears the link.
--   * Linking and confirming write a line in the record's history. Staff and above link, confirm or unlink; view-only
--     members can't.
-- Needs zella_viewer_read_only.sql (zella_can_edit). Safe to run twice. Needs the owner's approval before it is applied.

do $$
declare v_new boolean := not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'crm_record_types' and column_name = 'appointment_link');
begin
  alter table public.crm_record_types add column if not exists appointment_link boolean not null default false;
  -- first run only: switch it on for the types bookings are naturally for (never overrides an owner's choice later)
  if v_new then
    update public.crm_record_types set appointment_link = true
     where key in ('pets', 'vehicles', 'properties', 'sites', 'units', 'equipment', 'children', 'matters', 'trips', 'policies',
                   'jobs', 'repair_orders', 'visits', 'treatment_plans', 'claims', 'requests', 'enrolments', 'stays', 'bookings', 'projects');
  end if;
end $$;
alter table public.appointments add column if not exists record_id uuid references public.crm_records(id) on delete set null;
alter table public.appointments add column if not exists record_suggested_id uuid references public.crm_records(id) on delete set null;
create index if not exists appointments_record on public.appointments (record_id) where record_id is not null;

-- presets carry the flag so new businesses (and new types) get it too
update public.industry_crm_presets p set config = jsonb_set(p.config, '{types}', (
  select jsonb_agg(case when t ->> 'key' in ('pets', 'vehicles', 'properties', 'sites', 'units', 'equipment', 'children', 'matters', 'trips', 'policies',
                                              'jobs', 'repair_orders', 'visits', 'treatment_plans', 'claims', 'requests', 'enrolments', 'stays', 'bookings', 'projects')
                           and not t ? 'appointment_link' then t || '{"appointment_link": true}' else t end order by o)
    from jsonb_array_elements(p.config -> 'types') with ordinality e(t, o)))
 where exists (select 1 from jsonb_array_elements(p.config -> 'types') t where not t ? 'appointment_link');

-- a type copied from a preset takes the preset's choice
create or replace function public.zella_record_type_defaults_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.preset_key is not null and not new.appointment_link then
    new.appointment_link := coalesce((select (t ->> 'appointment_link')::boolean from public.industry_crm_presets p, jsonb_array_elements(p.config -> 'types') t
                                       where p.key = new.preset_key and t ->> 'key' = new.key limit 1), false);
  end if;
  return new;
end $$;
drop trigger if exists zella_record_type_defaults on public.crm_record_types;
create trigger zella_record_type_defaults before insert on public.crm_record_types for each row execute function public.zella_record_type_defaults_trg();

-- the asset types a suggestion can come from (things a customer owns, not jobs or matters)
create or replace function public.zella_asset_type_keys() returns text[] language sql immutable as $$
  select array['pets', 'vehicles', 'properties', 'sites', 'units', 'equipment', 'children'] $$;

-- checks on the confirmed record, and the suggestion (never the link)
create or replace function public.zella_appointment_record_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_only uuid; v_n int;
begin
  if tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id then new.record_suggested_id := null; end if;
  if new.record_id is not null and (tg_op = 'INSERT' or new.record_id is distinct from old.record_id) then
    select x.id, x.business_id, x.customer_id, x.archived_at, t.appointment_link into r
      from public.crm_records x join public.crm_record_types t on t.business_id = x.business_id and t.key = x.type_key where x.id = new.record_id;
    if not found or r.business_id <> new.business_id or r.archived_at is not null or not r.appointment_link then raise exception 'BAD_RECORD'; end if;
    if r.customer_id is not null then
      if new.customer_id is null then new.customer_id := r.customer_id;
      elsif new.customer_id <> r.customer_id then raise exception 'RECORD_OTHER_CUSTOMER'; end if;
    end if;
    new.record_suggested_id := null;
  end if;
  if tg_op = 'INSERT' and new.record_id is null and new.customer_id is not null then
    select count(*), min(x.id::text)::uuid into v_n, v_only
      from public.crm_records x join public.crm_record_types t on t.business_id = x.business_id and t.key = x.type_key
     where x.business_id = new.business_id and x.customer_id = new.customer_id and x.archived_at is null and x.closed_at is null
       and t.enabled and t.appointment_link and t.key = any (public.zella_asset_type_keys());
    new.record_suggested_id := case when v_n = 1 then v_only end;
  end if;
  return new;
end $$;
drop trigger if exists zella_appointment_record on public.appointments;
create trigger zella_appointment_record before insert or update of record_id, customer_id on public.appointments
  for each row execute function public.zella_appointment_record_trg();

-- customer and record must agree once the whole change is done (merges move bookings and records one table at a time)
create or replace function public.zella_appointment_record_match_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.appointments a join public.crm_records x on x.id = a.record_id
              where a.id = new.id and x.customer_id is not null and a.customer_id is distinct from x.customer_id) then
    raise exception 'RECORD_OTHER_CUSTOMER';
  end if;
  return null;
end $$;
drop trigger if exists zella_appointment_record_match on public.appointments;
create constraint trigger zella_appointment_record_match after update of customer_id on public.appointments
  deferrable initially deferred for each row execute function public.zella_appointment_record_match_trg();

-- the record's history says when something was booked for it
create or replace function public.zella_appointment_record_event_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.record_id is not null and (tg_op = 'INSERT' or new.record_id is distinct from old.record_id) then
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor)
    values (new.business_id, new.record_id, 'appointment', coalesce(new.title, 'Appointment') || ' · ' ||
            to_char(new.start_time at time zone coalesce((select timezone from public.businesses where id = new.business_id), 'UTC'), 'Mon DD, HH12:MI AM'), auth.uid());
  end if;
  return null;
end $$;
drop trigger if exists zella_appointment_record_event on public.appointments;
create trigger zella_appointment_record_event after insert or update of record_id on public.appointments
  for each row execute function public.zella_appointment_record_event_trg();

-- staff and above link or unlink (pass null to unlink)
create or replace function public.zella_set_appointment_record(p_appointment_id uuid, p_record_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz uuid;
begin
  select business_id into v_biz from public.appointments where id = p_appointment_id;
  if v_biz is null or not public.zella_can_edit(v_biz) then raise exception 'NOT_ALLOWED'; end if;
  update public.appointments set record_id = p_record_id, updated_at = now() where id = p_appointment_id;
  return jsonb_build_object('id', p_appointment_id, 'record_id', p_record_id);
end $$;
-- staff and above confirm the suggestion
create or replace function public.zella_confirm_appointment_record(p_appointment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_sug uuid;
begin
  select business_id, record_suggested_id into v_biz, v_sug from public.appointments where id = p_appointment_id;
  if v_biz is null or not public.zella_can_edit(v_biz) then raise exception 'NOT_ALLOWED'; end if;
  if v_sug is null then raise exception 'NO_SUGGESTION'; end if;
  update public.appointments set record_id = v_sug, updated_at = now() where id = p_appointment_id;
  return jsonb_build_object('id', p_appointment_id, 'record_id', v_sug);
end $$;

-- upcoming bookings that still need to say which pet / vehicle / property ... they are for
create or replace function public.zella_appointments_needing_record(p_business_id uuid, p_days integer default 14) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('appointment_id', a.id, 'title', a.title, 'start_time', a.start_time, 'customer_id', a.customer_id,
             'suggested', (select jsonb_build_object('id', x.id, 'title', x.title) from public.crm_records x where x.id = a.record_suggested_id),
             'choices', c.choices) order by a.start_time)
      from public.appointments a
      cross join lateral (
        select jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'type', t.singular) order by x.title) as choices, count(*) as n
          from public.crm_records x join public.crm_record_types t on t.business_id = x.business_id and t.key = x.type_key
         where x.business_id = a.business_id and x.customer_id = a.customer_id and x.archived_at is null and x.closed_at is null
           and t.enabled and t.appointment_link and t.key = any (public.zella_asset_type_keys())) c
     where a.business_id = p_business_id and a.record_id is null and a.customer_id is not null and c.n > 0
       and a.status in ('scheduled', 'confirmed') and a.start_time between now() - interval '1 day' and now() + make_interval(days => greatest(1, least(p_days, 90)))), '[]'::jsonb);
end $$;

revoke execute on function public.zella_confirm_appointment_record(uuid), public.zella_appointments_needing_record(uuid, integer),
  public.zella_appointment_record_match_trg(), public.zella_asset_type_keys() from public, anon;
grant execute on function public.zella_confirm_appointment_record(uuid), public.zella_appointments_needing_record(uuid, integer) to authenticated, service_role;
revoke execute on function public.zella_set_appointment_record(uuid, uuid), public.zella_appointment_record_trg(), public.zella_appointment_record_event_trg(),
  public.zella_record_type_defaults_trg() from public, anon;
grant execute on function public.zella_set_appointment_record(uuid, uuid) to authenticated, service_role;

-- Customize records can switch "Can be booked for" (owners, admins, managers, like the rest of a type)
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_save_record_type(uuid, text, jsonb)'::regprocedure);
  if position('appointment_link' in def) = 0 then
    def := replace(def, $a$fields = v_fields, columns = v_cols, title_label = coalesce(nullif(trim(p_patch ->> 'title_label'), ''), title_label), updated_at = now()$a$,
                        $a$fields = v_fields, columns = v_cols, title_label = coalesce(nullif(trim(p_patch ->> 'title_label'), ''), title_label),
      appointment_link = coalesce((p_patch ->> 'appointment_link')::boolean, appointment_link), updated_at = now()$a$);
    if position('appointment_link' in def) = 0 then raise exception 'zella_save_record_type has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
