-- Industry capabilities (2026-11-04 industry work, batch 2).
--
-- Every business saw the same pages (Calendar, Check-ins, Waitlist, appointment booking) whatever it does. A
-- capability says whether a kind of work applies to a business:
--   scheduling   appointments / bookings / reservations on a calendar (and the AI receptionist booking them)
--   checkins     front-desk arrivals (needs scheduling)
--   waitlist     a waitlist for appointment slots (needs scheduling)
--   dispatch     jobs at the customer's address with arrival windows and technicians
--   classes      group classes with capacity, bookings and attendance
--   orders       order support for an online shop (order lookup needs a store connection)
--   money        estimates, invoices, deposits, fees and gift cards recorded by the team (no card processing)
--   access_vault access instructions, keys and alarm codes, shown only to managers and assigned staff
--
-- The industry decides what is supported and what is on by default (industry_configurations.features.capabilities =
-- {"on": [...], "optional": [...]}; anything else is unsupported). A business's own choices are kept apart in
-- business_capabilities and are never overwritten by industry defaults. Turning a capability off hides its pages and
-- refuses new work of that kind on the server; nothing already recorded is deleted.
-- States reported by zella_capabilities(): unsupported, off, needs_setup (on, but something it needs is missing), on.
-- Safe to run twice. Needs the owner's approval before it is applied.

create table if not exists public.business_capabilities (
  business_id uuid not null references public.businesses(id) on delete cascade,
  capability text not null,
  enabled boolean not null,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (business_id, capability)
);
alter table public.business_capabilities enable row level security;
revoke all on public.business_capabilities from anon, authenticated;
grant select, insert, update, delete on public.business_capabilities to service_role;
drop policy if exists business_capabilities_read on public.business_capabilities;
create policy business_capabilities_read on public.business_capabilities for select to authenticated using (public.zella_is_member(business_id));
grant select on public.business_capabilities to authenticated;

-- The catalogue: label, what it needs, and the capability it depends on.
create or replace function public.zella_capability_catalog() returns jsonb
language sql immutable as $$
  select '{
    "scheduling":   {"label": "Appointments and bookings", "order": 1},
    "checkins":     {"label": "Front-desk check-ins", "needs": "scheduling", "order": 2},
    "waitlist":     {"label": "Waitlist for openings", "needs": "scheduling", "order": 3},
    "dispatch":     {"label": "Jobs and dispatch", "order": 4},
    "classes":      {"label": "Classes and attendance", "order": 5},
    "orders":       {"label": "Order support", "order": 6},
    "money":        {"label": "Estimates, invoices and deposits", "order": 7},
    "access_vault": {"label": "Access codes and keys", "order": 8}
  }'::jsonb;
$$;

-- Industry defaults (keyed by industry slug). Only the "capabilities" key of features is written; other feature keys
-- are kept. Returns how many industries were updated so the backfill can be reported.
create or replace function public.zella_seed_capability_defaults() returns integer
language plpgsql security definer set search_path = public as $f$
declare n integer;
begin
  with d(slug, caps) as (values
    ('automotive',            '{"on": ["scheduling","checkins","money"], "optional": ["waitlist","dispatch"]}'),
    ('beauty-salon',          '{"on": ["scheduling","checkins","waitlist","money"], "optional": ["classes"]}'),
    ('childcare',             '{"on": ["scheduling","money"], "optional": ["classes"]}'),
    ('cleaning-services',     '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('dental',                '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'),
    ('ecommerce',             '{"on": ["orders","money"], "optional": ["scheduling"]}'),
    ('education',             '{"on": ["scheduling","classes","money"], "optional": ["checkins","waitlist"]}'),
    ('electrical',            '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('financial-services',    '{"on": ["scheduling","money"], "optional": ["checkins"]}'),
    ('fitness',               '{"on": ["scheduling","classes","checkins","money"], "optional": ["waitlist"]}'),
    ('healthcare',            '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'),
    ('home-services',         '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('hospitality',           '{"on": ["scheduling","checkins","money"], "optional": ["waitlist"]}'),
    ('hvac',                  '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('insurance',             '{"on": ["scheduling","money"], "optional": ["checkins"]}'),
    ('landscaping-lawn-care', '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('legal',                 '{"on": ["scheduling","money"], "optional": ["checkins"]}'),
    ('other',                 '{"on": ["scheduling","checkins","waitlist","money"], "optional": ["dispatch","classes","orders","access_vault"]}'),
    ('pest-control',          '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('pet-care-veterinary',   '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'),
    ('photography-events',    '{"on": ["scheduling","money"], "optional": []}'),
    ('plumbing',              '{"on": ["scheduling","dispatch","money","access_vault"], "optional": []}'),
    ('professional-services', '{"on": ["scheduling","money"], "optional": ["checkins"]}'),
    ('property-management',   '{"on": ["scheduling","dispatch","money","access_vault"], "optional": ["checkins"]}'),
    ('real-estate',           '{"on": ["scheduling","money"], "optional": ["checkins","access_vault"]}'),
    ('restaurant',            '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'),
    ('spa-wellness',          '{"on": ["scheduling","checkins","waitlist","money"], "optional": ["classes"]}'),
    ('travel',                '{"on": ["scheduling","money"], "optional": []}')
  )
  insert into public.industry_configurations (industry_id, features)
  select i.id, jsonb_build_object('capabilities', d.caps::jsonb) from d join public.industries i on i.slug = d.slug
  on conflict (industry_id) do update set features = coalesce(public.industry_configurations.features, '{}'::jsonb) || excluded.features, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $f$;
revoke execute on function public.zella_seed_capability_defaults() from public, anon, authenticated;
grant execute on function public.zella_seed_capability_defaults() to service_role;
do $$ begin raise notice 'capability defaults written for % industries', public.zella_seed_capability_defaults(); end $$;

-- Every capability for one business: supported, enabled, configured, state, and why.
create or replace function public.zella_capabilities(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_def jsonb; v_on jsonb; v_opt jsonb; k text; meta jsonb; out_obj jsonb := '{}'::jsonb;
  v_supported boolean; v_enabled boolean; v_configured boolean; v_why text; v_over boolean;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) and not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(ic.features -> 'capabilities', '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'::jsonb) into v_def
    from public.businesses b left join public.industry_configurations ic on ic.industry_id = b.industry_id where b.id = p_business_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_def := coalesce(v_def, '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'::jsonb);
  v_on := coalesce(v_def -> 'on', '[]'); v_opt := coalesce(v_def -> 'optional', '[]');
  -- pass 1: enabled (dependencies need their parent on)
  for k, meta in select * from jsonb_each(public.zella_capability_catalog()) loop
    v_supported := v_on ? k or v_opt ? k;
    select enabled into v_over from public.business_capabilities where business_id = p_business_id and capability = k;
    v_enabled := v_supported and coalesce(v_over, v_on ? k);
    out_obj := out_obj || jsonb_build_object(k, jsonb_build_object('supported', v_supported, 'default', v_on ? k, 'enabled', v_enabled,
      'chosen', v_over is not null, 'label', meta ->> 'label', 'needs', meta ->> 'needs', 'order', (meta ->> 'order')::int));
  end loop;
  for k, meta in select * from jsonb_each(out_obj) loop
    if meta ->> 'needs' is not null and not coalesce((out_obj #>> array[meta ->> 'needs', 'enabled'])::boolean, false) then
      out_obj := jsonb_set(out_obj, array[k, 'enabled'], 'false');
    end if;
  end loop;
  -- pass 2: configured and state
  for k, meta in select * from jsonb_each(out_obj) loop
    v_configured := true; v_why := null;
    if k in ('scheduling', 'checkins', 'waitlist') and not exists (select 1 from public.business_hours h where h.business_id = p_business_id) then
      v_configured := false; v_why := 'Add opening hours so times can be offered.';
    elsif k = 'dispatch' and not exists (select 1 from public.staff_members s where s.business_id = p_business_id and s.is_active) then
      v_configured := false; v_why := 'Add the technicians or crews jobs are assigned to.';
    elsif k = 'classes' and not exists (select 1 from public.crm_records r where r.business_id = p_business_id and r.type_key = 'classes' and r.archived_at is null) then
      v_configured := false; v_why := 'Add the classes you run.';
    elsif k = 'orders' and not exists (select 1 from public.integrations g where g.business_id = p_business_id
                                         and lower(coalesce(g.provider, '')) in ('shopify', 'woocommerce', 'bigcommerce') and g.status in ('active', 'connected')) then
      v_configured := false; v_why := 'No store is connected, so order status can''t be looked up. Cases are recorded for the team.';
    end if;
    out_obj := jsonb_set(out_obj, array[k], meta || jsonb_build_object('configured', v_configured, 'why', v_why,
      'state', case when not (meta ->> 'supported')::boolean then 'unsupported' when not (out_obj #>> array[k, 'enabled'])::boolean then 'off'
                    when not v_configured then 'needs_setup' else 'on' end));
  end loop;
  return out_obj;
end $$;

create or replace function public.zella_capability_on(p_business_id uuid, p_key text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_def jsonb; v_over boolean; v_needs text;
begin
  select coalesce(ic.features -> 'capabilities', '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'::jsonb) into v_def
    from public.businesses b left join public.industry_configurations ic on ic.industry_id = b.industry_id where b.id = p_business_id;
  v_def := coalesce(v_def, '{"on": ["scheduling","checkins","waitlist","money"], "optional": []}'::jsonb);
  if not (coalesce(v_def -> 'on', '[]') ? p_key or coalesce(v_def -> 'optional', '[]') ? p_key) then return false; end if;
  select enabled into v_over from public.business_capabilities where business_id = p_business_id and capability = p_key;
  if not coalesce(v_over, coalesce(v_def -> 'on', '[]') ? p_key) then return false; end if;
  v_needs := public.zella_capability_catalog() #>> array[p_key, 'needs'];
  return v_needs is null or public.zella_capability_on(p_business_id, v_needs);
end $$;

create or replace function public.zella_require_capability(p_business_id uuid, p_key text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_capability_on(p_business_id, p_key) then
    raise exception 'CAPABILITY_OFF:%', p_key using hint = 'This business doesn''t use ' || coalesce(public.zella_capability_catalog() #>> array[p_key, 'label'], p_key) || '.';
  end if;
end $$;

-- Owners and admins (or a Zella admin during setup) turn a supported capability on or off. Nothing recorded is deleted.
create or replace function public.zella_set_capability(p_business_id uuid, p_key text, p_enabled boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_caps jsonb;
begin
  if not (public.zella_has_role(p_business_id, array['owner', 'admin']) or public.is_platform_admin()) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_capability_catalog() ? p_key then raise exception 'UNKNOWN_CAPABILITY'; end if;
  v_caps := public.zella_capabilities(p_business_id);
  if not (v_caps #>> array[p_key, 'supported'])::boolean then raise exception 'NOT_FOR_THIS_INDUSTRY'; end if;
  if p_enabled and (v_caps #>> array[p_key, 'needs']) is not null and not (v_caps #>> array[v_caps #>> array[p_key, 'needs'], 'enabled'])::boolean then
    raise exception 'NEEDS:%', v_caps #>> array[p_key, 'needs'];
  end if;
  insert into public.business_capabilities (business_id, capability, enabled, updated_by) values (p_business_id, p_key, p_enabled, auth.uid())
  on conflict (business_id, capability) do update set enabled = excluded.enabled, updated_by = excluded.updated_by, updated_at = now();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'capability_changed', 'business', p_business_id,
          jsonb_build_object(p_key, v_caps #>> array[p_key, 'enabled']), jsonb_build_object(p_key, p_enabled));
  return public.zella_capabilities(p_business_id);
end $$;

revoke execute on function public.zella_capabilities(uuid), public.zella_capability_on(uuid, text), public.zella_require_capability(uuid, text),
  public.zella_set_capability(uuid, text, boolean) from public, anon;
grant execute on function public.zella_capabilities(uuid), public.zella_capability_on(uuid, text), public.zella_set_capability(uuid, text, boolean) to authenticated, service_role;
grant execute on function public.zella_require_capability(uuid, text) to service_role;

-- Server enforcement: new appointments need scheduling (staff, the AI receptionist and every other path insert here).
create or replace function public.zella_capability_appointment_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform public.zella_require_capability(new.business_id, 'scheduling'); end if;
  return new;
end $$;
drop trigger if exists zella_capability_appointment on public.appointments;
create trigger zella_capability_appointment before insert on public.appointments for each row execute function public.zella_capability_appointment_trg();

-- Check-ins and the waitlist: the functions behind those pages ask first.
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_set_attendance(uuid, text, text, uuid)'::regprocedure);
  if position('zella_capability_checkins' in def) = 0 then
    def := replace(def, $a$if p_action not in ('arrived', 'checked_in', 'in_service', 'completed', 'no_show', 'cancelled', 'undo', 'assign') then raise exception 'BAD_ACTION'; end if;$a$,
      $a$if p_action not in ('arrived', 'checked_in', 'in_service', 'completed', 'no_show', 'cancelled', 'undo', 'assign') then raise exception 'BAD_ACTION'; end if;
  /* zella_capability_checkins */ if p_action in ('arrived', 'checked_in', 'in_service') then perform public.zella_require_capability(a.business_id, 'checkins'); end if;$a$);
    if position('zella_capability_checkins' in def) = 0 then raise exception 'zella_set_attendance has changed; review this patch'; end if;
    execute def;
  end if;
  for def in select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'zella_join_waitlist' loop
    if position('zella_capability_waitlist' in def) = 0 then
      def := regexp_replace(def, E'\\nbegin\\n', E'\nbegin\n  /* zella_capability_waitlist */ perform public.zella_require_capability(p_business_id, ''waitlist'');\n');
      if position('zella_capability_waitlist' in def) = 0 then raise exception 'zella_join_waitlist has changed; review this patch'; end if;
      execute def;
    end if;
  end loop;
end $$;

-- The CRM menu receives the capabilities with the rest of the navigation.
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_workspace_navigation(uuid)'::regprocedure);
  if position('''capabilities''' in def) = 0 then
    def := replace(def, $a$'location', nullif($a$, $a$'capabilities', public.zella_capabilities(b.id),
    'location', nullif($a$);
    if position('''capabilities''' in def) = 0 then raise exception 'zella_workspace_navigation has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

-- Today: open work for every enabled record type, counted in the business's own time zone (not only the first two
-- types, and not only bookings). Archived records are never counted; closed statuses come from the type itself.
create or replace function public.zella_today_operations(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_start timestamptz; v_end timestamptz;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.businesses where id = p_business_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_start := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_end := v_start + interval '1 day';
  return coalesce((
    select jsonb_agg(jsonb_build_object('key', t.key, 'plural', t.plural, 'icon', t.icon, 'open', coalesce(c.open, 0),
             'overdue', coalesce(c.overdue, 0), 'due_today', coalesce(c.due_today, 0), 'unassigned', coalesce(c.unassigned, 0)) order by t.position, t.key)
      from public.crm_record_types t
      left join lateral (
        select count(*) as open,
               count(*) filter (where r.due_at < now()) as overdue,
               count(*) filter (where r.due_at >= v_start and r.due_at < v_end) as due_today,
               count(*) filter (where r.assigned_to is null) as unassigned
          from public.crm_records r
         where r.business_id = p_business_id and r.type_key = t.key and r.archived_at is null and r.closed_at is null
           and not (r.status = any (coalesce(t.closed_statuses, '{}'::text[])))
      ) c on true
     where t.business_id = p_business_id and t.enabled), '[]'::jsonb);
end $$;
revoke execute on function public.zella_today_operations(uuid) from public, anon;
grant execute on function public.zella_today_operations(uuid) to authenticated, service_role;
