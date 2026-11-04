-- Records that point at each other, sensitive fields kept apart, and capacity (2026-11-04 industry work, batch 3).
--
-- 1. Links. A field {"type": "record", "target": "<type key>"} holds the id of another record of this business
--    (a job's property, a vehicle's owner record, a class booking's class). The write path checks the target exists in
--    the same business, is of the target type and isn't archived; a link to another business's record is refused even
--    if its id is known. zella_record_related(id) lists records linking to and from one record.
-- 2. Sensitive fields. A field with "sensitive": true (gate codes, lockbox and alarm codes, key numbers) is never kept in
--    crm_records.data, which every member and every list reads. Its value lives in crm_record_secrets, which no signed-in
--    user can read directly. zella_record_secrets(id) returns the values to owners, admins and managers, and to staff
--    only while they're assigned to the record or to an open record linking to it that is due between yesterday and two
--    days from now. Every read and change is written to the record's history with the field names only, never values.
--    Writes: key present = set, empty = clear, absent = unchanged. The AI receptionist can't write or read them, and
--    staff below manager can't change them. Existing plain values are moved out by zella_move_sensitive_values().
-- 3. Capacity. A type with capacity {"parent_field", "capacity_field", "counted": [...], "waitlist_status"} (class
--    bookings against a class) locks the parent record while counting, so two bookings for the last place can't both get
--    it; the second goes to the waitlist status, or is refused with FULL when there's none.
-- 4. Record types can name the capability they belong to (crm_record_types.capability); new records of that type are
--    refused while it's off. Existing records stay readable.
-- Safe to run twice. Needs the owner's approval before it is applied.

alter table public.crm_record_types add column if not exists capability text;
alter table public.crm_record_types add column if not exists capacity jsonb;
alter table public.crm_record_types add column if not exists fields_seen text[] not null default '{}';

create table if not exists public.crm_record_secrets (
  record_id uuid not null references public.crm_records(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  field_key text not null,
  value text not null,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (record_id, field_key)
);
alter table public.crm_record_secrets enable row level security;
revoke all on public.crm_record_secrets from anon, authenticated;
grant select, insert, update, delete on public.crm_record_secrets to service_role;
-- same restrictive two-step sign-in rule as every other business table
do $$ begin
  if exists (select 1 from pg_proc where proname = 'zella_mfa_satisfied') and not exists (
    select 1 from pg_policies where tablename = 'crm_record_secrets' and policyname = 'zella_mfa_required') then
    execute 'create policy zella_mfa_required on public.crm_record_secrets as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
  end if;
end $$;

-- Links are looked up by value inside data.
create index if not exists crm_records_data_gin on public.crm_records using gin (data jsonb_path_ops);

-- Cleaning: record links must be ids; sensitive fields never reach data.
create or replace function public.zella_crm_clean_data(p_fields jsonb, p_data jsonb, out cleaned jsonb, out unique_key text)
language plpgsql set search_path = public as $$
declare f jsonb; k text; v text; lbl text; ty text; out_obj jsonb := '{}'::jsonb;
begin
  for f in select * from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) loop
    k := f ->> 'key'; lbl := f ->> 'label'; ty := f ->> 'type';
    if coalesce((f ->> 'sensitive')::boolean, false) then continue; end if;
    v := nullif(trim(coalesce(p_data ->> k, '')), '');
    if v is null then
      if coalesce((f ->> 'required')::boolean, false) and ty <> 'bool' then raise exception 'FIELD_REQUIRED:%', lbl; end if;
      continue;
    end if;
    if ty = 'number' then
      begin perform v::numeric; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v::numeric);
    elsif ty = 'bool' then
      out_obj := out_obj || jsonb_build_object(k, v in ('true', 't', '1', 'yes'));
    elsif ty = 'date' then
      begin perform v::date; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v::date::text);
    elsif ty = 'datetime' then
      begin perform v::timestamptz; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v);
    elsif ty = 'select' then
      if not (f -> 'options') ? v then raise exception 'BAD_FIELD:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, v);
    elsif ty = 'email' then
      if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_FIELD:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, lower(v));
    elsif ty = 'record' then
      if v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'BAD_LINK:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, lower(v));
    else
      out_obj := out_obj || jsonb_build_object(k, left(v, 4000));
    end if;
    if coalesce((f ->> 'unique')::boolean, false) then unique_key := lower(regexp_replace(v, '[^[:alnum:]]', '', 'g')); end if;
  end loop;
  cleaned := out_obj;
end $$;

-- The one write path for records (staff, the AI receptionist, integrations).
create or replace function public.zella_crm_write_record(p_actor uuid, p_source text, p_business_id uuid, p_type_key text, p_id uuid, p_title text,
  p_status text, p_customer_id uuid, p_assigned_to uuid, p_due_at timestamptz, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ty record; v_status text; v_clean jsonb; v_ukey text; v_dup uuid; v_id uuid; v_old_status text; f jsonb; v_link text;
  v_parent uuid; v_cap numeric; v_taken int; v_waitlisted boolean := false; v_secret_keys text[] := '{}'; v_val text;
begin
  select * into ty from public.crm_record_types where business_id = p_business_id and key = p_type_key and enabled;
  if not found then raise exception 'NOT_VALID'; end if;
  if p_id is null and ty.capability is not null then perform public.zella_require_capability(p_business_id, ty.capability); end if;
  if nullif(trim(coalesce(p_title, '')), '') is null then raise exception 'EMPTY_TITLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_assigned_to is not null and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_assigned_to and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  if ty.link_person = false then p_customer_id := null; end if;
  select c.cleaned, c.unique_key into v_clean, v_ukey from public.zella_crm_clean_data(ty.fields, p_data) c;

  -- links: same business, right type, not archived, not itself
  for f in select * from jsonb_array_elements(coalesce(ty.fields, '[]'::jsonb)) where value ->> 'type' = 'record' loop
    v_link := v_clean ->> (f ->> 'key');
    continue when v_link is null;
    if v_link::uuid = p_id or not exists (select 1 from public.crm_records r where r.id = v_link::uuid and r.business_id = p_business_id
        and r.archived_at is null and (f ->> 'target' is null or r.type_key = f ->> 'target')) then
      raise exception 'BAD_LINK:%', f ->> 'label';
    end if;
  end loop;

  if p_id is not null then
    select status into v_old_status from public.crm_records
      where id = p_id and business_id = p_business_id and type_key = p_type_key and archived_at is null for update;
    if not found then raise exception 'NOT_ALLOWED'; end if;
  end if;
  v_status := coalesce(nullif(p_status, ''), v_old_status, ty.statuses -> 0 ->> 'key');
  if not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = v_status) then raise exception 'NOT_VALID'; end if;

  -- capacity: lock the parent (the class) so concurrent bookings are counted one at a time
  if ty.capacity is not null and v_status = any (array(select jsonb_array_elements_text(coalesce(ty.capacity -> 'counted', '[]'))))
     and (p_id is null or v_old_status is distinct from v_status or true) then
    v_parent := (v_clean ->> (ty.capacity ->> 'parent_field'))::uuid;
    if v_parent is not null then
      select nullif(data ->> (ty.capacity ->> 'capacity_field'), '')::numeric into v_cap
        from public.crm_records where id = v_parent and business_id = p_business_id for update;
      if v_cap is not null then
        select count(*) into v_taken from public.crm_records r
         where r.business_id = p_business_id and r.type_key = p_type_key and r.archived_at is null and r.id is distinct from p_id
           and r.data ->> (ty.capacity ->> 'parent_field') = v_parent::text
           and r.status = any (array(select jsonb_array_elements_text(ty.capacity -> 'counted')));
        if v_taken >= v_cap then
          if ty.capacity ->> 'waitlist_status' is null then raise exception 'FULL'; end if;
          v_status := ty.capacity ->> 'waitlist_status'; v_waitlisted := true;
        end if;
      end if;
    end if;
  end if;

  if v_ukey is not null then
    select id into v_dup from public.crm_records
      where business_id = p_business_id and type_key = p_type_key and unique_key = v_ukey and archived_at is null and id is distinct from p_id limit 1;
    if v_dup is not null then raise exception 'DUPLICATE:%', v_dup; end if;
  end if;

  -- sensitive values: only managers and above (or server code) may change them; the AI never
  for f in select * from jsonb_array_elements(coalesce(ty.fields, '[]'::jsonb)) where coalesce((value ->> 'sensitive')::boolean, false) loop
    if p_data ? (f ->> 'key') and coalesce(p_source, '') <> 'ai' then
      if p_actor is not null and not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED:%', f ->> 'label'; end if;
      v_secret_keys := v_secret_keys || (f ->> 'key');
    end if;
  end loop;

  if p_id is null then
    insert into public.crm_records (business_id, type_key, title, status, customer_id, assigned_to, due_at, data, unique_key, source, created_by, closed_at)
    values (p_business_id, p_type_key, trim(p_title), v_status, p_customer_id, p_assigned_to, p_due_at, v_clean, v_ukey, p_source, p_actor,
            case when v_status = any (ty.closed_statuses) then now() end)
    returning id into v_id;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'created', null, p_actor);
  else
    update public.crm_records set title = trim(p_title), status = v_status, customer_id = p_customer_id, assigned_to = p_assigned_to, due_at = p_due_at,
      data = v_clean, unique_key = v_ukey, updated_at = now(),
      closed_at = case when v_status = any (ty.closed_statuses) then coalesce(closed_at, now()) else null end
      where id = p_id;
    v_id := p_id;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'edited', null, p_actor);
    if v_old_status <> v_status then
      insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'status', v_old_status || ' → ' || v_status, p_actor);
    end if;
  end if;

  if array_length(v_secret_keys, 1) > 0 then
    foreach v_link in array v_secret_keys loop
      v_val := nullif(trim(coalesce(p_data ->> v_link, '')), '');
      if v_val is null then
        delete from public.crm_record_secrets where record_id = v_id and field_key = v_link;
      else
        insert into public.crm_record_secrets (record_id, business_id, field_key, value, updated_by) values (v_id, p_business_id, v_link, left(v_val, 2000), p_actor)
        on conflict (record_id, field_key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
      end if;
    end loop;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor)
    values (p_business_id, v_id, 'secret_changed', array_to_string(v_secret_keys, ', '), p_actor);
  end if;
  return jsonb_build_object('id', v_id, 'status', v_status, 'waitlisted', v_waitlisted);
end $$;

-- Can this person read this record's sensitive values now?
create or replace function public.zella_can_read_record_secrets(p_record_id uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select id, business_id, assigned_to, archived_at into r from public.crm_records where id = p_record_id;
  if not found or r.archived_at is not null then return false; end if;
  if public.zella_has_role(r.business_id, array['owner', 'admin', 'manager']) then return true; end if;
  if not public.zella_has_role(r.business_id, array['staff']) then return false; end if;
  if r.assigned_to = auth.uid() then return true; end if;
  -- assigned to an open record (a job, a visit) that links to this one and is due around now
  return exists (
    select 1 from public.crm_records j join public.crm_record_types t on t.business_id = j.business_id and t.key = j.type_key
     where j.business_id = r.business_id and j.assigned_to = auth.uid() and j.archived_at is null and j.closed_at is null
       and (j.due_at is null or j.due_at between now() - interval '1 day' and now() + interval '2 days')
       and exists (select 1 from jsonb_array_elements(t.fields) f where f ->> 'type' = 'record' and j.data ->> (f ->> 'key') = r.id::text));
end $$;

create or replace function public.zella_record_secrets(p_record_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_out jsonb;
begin
  select business_id into v_biz from public.crm_records where id = p_record_id;
  if v_biz is null or not public.zella_is_member(v_biz) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_mfa_satisfied() then raise exception 'MFA_REQUIRED'; end if;
  if not public.zella_can_read_record_secrets(p_record_id) then
    return jsonb_build_object('allowed', false, 'keys', (select coalesce(jsonb_agg(field_key), '[]') from public.crm_record_secrets where record_id = p_record_id));
  end if;
  select coalesce(jsonb_object_agg(field_key, value), '{}'::jsonb) into v_out from public.crm_record_secrets where record_id = p_record_id;
  if v_out <> '{}'::jsonb then
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor)
    values (v_biz, p_record_id, 'secret_viewed', (select string_agg(k, ', ') from jsonb_object_keys(v_out) k), auth.uid());
  end if;
  return jsonb_build_object('allowed', true, 'values', v_out);
end $$;

-- Records linking to this one and records this one links to (same business only).
create or replace function public.zella_record_related(p_record_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; v_out jsonb := '[]'::jsonb;
begin
  select * into r from public.crm_records where id = p_record_id;
  if not found or not public.zella_is_member(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(jsonb_agg(x order by x ->> 'direction', x ->> 'updated_at' desc), '[]') into v_out from (
    -- this record points at
    select jsonb_build_object('direction', 'to', 'field', f ->> 'label', 'id', o.id, 'type_key', o.type_key, 'title', o.title, 'status', o.status, 'updated_at', o.updated_at) x
      from public.crm_record_types t cross join lateral jsonb_array_elements(t.fields) f
      join public.crm_records o on o.id::text = r.data ->> (f ->> 'key') and o.business_id = r.business_id and o.archived_at is null
     where t.business_id = r.business_id and t.key = r.type_key and f ->> 'type' = 'record'
    union all
    -- records pointing at this one
    select jsonb_build_object('direction', 'from', 'field', f ->> 'label', 'id', o.id, 'type_key', o.type_key, 'title', o.title, 'status', o.status, 'updated_at', o.updated_at)
      from public.crm_record_types t cross join lateral jsonb_array_elements(t.fields) f
      join public.crm_records o on o.business_id = t.business_id and o.type_key = t.key and o.archived_at is null
                                and o.data @> jsonb_build_object(f ->> 'key', r.id::text)
     where t.business_id = r.business_id and f ->> 'type' = 'record' and (f ->> 'target' is null or f ->> 'target' = r.type_key)
     limit 200) s;
  return v_out;
end $$;

-- Moves plain values of fields now marked sensitive out of data. Returns how many values moved (for the report).
drop function if exists public.zella_move_sensitive_values();
create or replace function public.zella_move_sensitive_values(p_business_id uuid default null) returns integer
language plpgsql security definer set search_path = public as $$
declare t record; f jsonb; n integer := 0; c integer;
begin
  for t in select * from public.crm_record_types where p_business_id is null or business_id = p_business_id loop
    for f in select * from jsonb_array_elements(coalesce(t.fields, '[]')) where coalesce((value ->> 'sensitive')::boolean, false) loop
      insert into public.crm_record_secrets (record_id, business_id, field_key, value)
      select r.id, r.business_id, f ->> 'key', left(r.data ->> (f ->> 'key'), 2000) from public.crm_records r
       where r.business_id = t.business_id and r.type_key = t.key and nullif(trim(coalesce(r.data ->> (f ->> 'key'), '')), '') is not null
      on conflict (record_id, field_key) do nothing;
      get diagnostics c = row_count; n := n + c;
      update public.crm_records set data = data - (f ->> 'key') where business_id = t.business_id and type_key = t.key and data ? (f ->> 'key');
    end loop;
  end loop;
  return n;
end $$;

revoke execute on function public.zella_crm_clean_data(jsonb, jsonb), public.zella_can_read_record_secrets(uuid), public.zella_record_secrets(uuid),
  public.zella_record_related(uuid), public.zella_move_sensitive_values(uuid) from public, anon;
revoke execute on function public.zella_crm_write_record(uuid, text, uuid, text, uuid, text, text, uuid, uuid, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.zella_crm_write_record(uuid, text, uuid, text, uuid, text, text, uuid, uuid, timestamptz, jsonb) to service_role;
grant execute on function public.zella_record_secrets(uuid), public.zella_record_related(uuid), public.zella_can_read_record_secrets(uuid) to authenticated, service_role;
revoke execute on function public.zella_move_sensitive_values(uuid) from authenticated;
grant execute on function public.zella_move_sensitive_values(uuid) to service_role;
do $$ begin raise notice 'sensitive values moved out of record data: %', public.zella_move_sensitive_values(); end $$;

-- Customize records: record links are a field type (to one of this business's own types); a sensitive field stays
-- sensitive; newly marked sensitive fields have their values moved out of record data straight away.
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_save_record_type(uuid, text, jsonb)'::regprocedure);
  if position('zella_links_patch' in def) = 0 then
    def := replace(def, $a$not in ('text', 'longtext', 'select', 'date', 'datetime', 'number', 'phone', 'email', 'bool') then raise exception 'NOT_VALID'; end if;$a$,
      $a$not in ('text', 'longtext', 'select', 'date', 'datetime', 'number', 'phone', 'email', 'bool', 'record') then raise exception 'NOT_VALID'; end if;
    /* zella_links_patch */
    if (f ->> 'type') = 'record' and not ((f ->> 'target') = p_key or exists (select 1 from public.crm_record_types t where t.business_id = p_business_id and t.key = f ->> 'target')) then
      raise exception 'BAD_LINK:%', f ->> 'label';
    end if;$a$);
    def := replace(def, $a$then raise exception 'FIELD_LOCKED:%', o ->> 'label'; end if;
    end loop;$a$, $a$then raise exception 'FIELD_LOCKED:%', o ->> 'label'; end if;
      if coalesce((o ->> 'sensitive')::boolean, false)
         and not coalesce((select (x ->> 'sensitive')::boolean from jsonb_array_elements(v_fields) x where x ->> 'key' = o ->> 'key'), false) then
        raise exception 'FIELD_LOCKED:%', o ->> 'label';
      end if;
    end loop;$a$);
    def := replace(def, $a$  return jsonb_build_object('key', p_key);
end$a$, $a$  perform public.zella_move_sensitive_values(p_business_id);
  return jsonb_build_object('key', p_key);
end$a$);
    if position('zella_links_patch' in def) = 0 or position('zella_move_sensitive_values(p_business_id)' in def) = 0 then raise exception 'zella_save_record_type patch did not apply'; end if;
    execute def;
  end if;
end $$;
