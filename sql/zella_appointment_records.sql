-- Appointments and jobs linked to the record they are for (5 Nov 2026): the pet at the vet, the vehicle at the workshop,
-- the property a crew visits, the child at a tour, the matter of a consultation, the repair order of a drop-off.
--
--   * appointments.record_id: one record per appointment, of a type the business allows ("Can be booked for",
--     crm_record_types.appointment_link). Checked on every write, whoever writes (team, AI receptionist, integrations):
--     same business, not archived, a bookable type, and if the record belongs to a customer, the appointment's customer
--     is that customer (it is filled in when the appointment has none).
--   * When a booking has a customer and no record, and that customer has exactly one bookable "thing" (pet, vehicle,
--     property, site, unit, piece of equipment, child), the booking is linked to it. With two or more nothing is
--     guessed; the team picks. This covers bookings the AI receptionist makes without asking it anything new.
--   * Linking writes a line in the record's history. Deleting an appointment or archiving the record never deletes the
--     other: the link is cleared (appointment) or kept for history (archived record stays linked, can't be newly linked).
--   * zella_set_appointment_record: staff and above change the link (view-only members can't).
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

-- the checks and the automatic link
create or replace function public.zella_appointment_record_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_only uuid; v_n int;
begin
  if new.record_id is not null and (tg_op = 'INSERT' or new.record_id is distinct from old.record_id or new.customer_id is distinct from old.customer_id) then
    select x.id, x.business_id, x.customer_id, x.archived_at, x.title, t.appointment_link into r
      from public.crm_records x join public.crm_record_types t on t.business_id = x.business_id and t.key = x.type_key where x.id = new.record_id;
    if not found or r.business_id <> new.business_id then raise exception 'BAD_RECORD'; end if;
    if new.record_id is distinct from (case when tg_op = 'UPDATE' then old.record_id end) and (r.archived_at is not null or not r.appointment_link) then
      raise exception 'BAD_RECORD';
    end if;
    if r.customer_id is not null then
      if new.customer_id is null then new.customer_id := r.customer_id;
      elsif new.customer_id <> r.customer_id then raise exception 'RECORD_OTHER_CUSTOMER'; end if;
    end if;
  elsif tg_op = 'INSERT' and new.record_id is null and new.customer_id is not null then
    select count(*), min(x.id::text)::uuid into v_n, v_only
      from public.crm_records x join public.crm_record_types t on t.business_id = x.business_id and t.key = x.type_key
     where x.business_id = new.business_id and x.customer_id = new.customer_id and x.archived_at is null and x.closed_at is null
       and t.enabled and t.appointment_link and t.key in ('pets', 'vehicles', 'properties', 'sites', 'units', 'equipment', 'children');
    if v_n = 1 then new.record_id := v_only; end if;
  end if;
  return new;
end $$;
drop trigger if exists zella_appointment_record on public.appointments;
create trigger zella_appointment_record before insert or update of record_id, customer_id on public.appointments
  for each row execute function public.zella_appointment_record_trg();

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
