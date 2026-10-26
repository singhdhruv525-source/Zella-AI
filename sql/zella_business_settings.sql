-- Zella - business Settings in the business app (2026-10-26). Safe to re-run.
--
-- Purpose
--   Settings in the business app were read-only ("changes are made by the Zella team"). Opening hours and holidays
--   had a table each (zella_voice_rules.sql) but nothing could write them, so every business read as "hours not
--   set" to the phone assistant. These functions let a business keep its own details:
--     zella_business_settings(business)            everything the Settings page shows, in one read
--     zella_save_business_profile(business, json)  name, contact details, address, time zone (owner, admin)
--     zella_save_business_hours(business, json)    weekly opening hours, split shifts allowed (owner, admin, manager)
--     zella_add_business_closure(...)              a holiday or special hours (owner, admin, manager)
--     zella_delete_business_closure(id)            (owner, admin, manager)
--     zella_save_my_profile(first, last, phone)    the signed-in person's own name and mobile number
--
-- Only columns the existing code already writes are touched:
--   businesses: name, legal_name, email, phone, website, address_line_1, address_line_2, city, state, postal_code,
--               country, timezone, updated_at  (the same list owner-provision-business saves)
--   profiles:   first_name, last_name, phone   (read by zella_inbox.sql, zella_lead_pipeline.sql, zella_staff_sms.sql)
-- The industry, plan, modules and status stay with the Zella admin dashboard.
--
-- Needs: zella_voice_rules.sql (business_hours, business_closures), zella_ops_extras.sql (zella_has_role),
--   zella_staff_sms.sql (business_members.sms_alerts). The base tables businesses, profiles, business_members and
--   audit_logs come from the base schema (see docs/SCHEMA_STATUS.md).
--
-- Authorization
--   Every function checks the signed-in person's active membership and role in that business on the server. A
--   business id from the browser is only used to look that membership up. Each change is written to audit_logs.
--
-- Rollback: drop the six functions (signatures below). No table or column is changed.
--
-- Validation (rolled back), as an owner of <business id>:
--   do $$ declare r jsonb; begin
--     perform set_config('request.jwt.claims', json_build_object('sub', '<owner user id>', 'role', 'authenticated')::text, true);
--     perform set_config('role', 'authenticated', true);
--     perform public.zella_save_business_hours('<business id>', '[{"weekday":1,"opens":"09:00","closes":"17:00"}]');
--     r := public.zella_business_settings('<business id>');
--     raise exception 'RESULT %', r -> 'hours';
--   end $$;

create or replace function public.zella_business_settings(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_role text; b record; v_me jsonb;
begin
  select m.role into v_role from public.business_members m
   where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active';
  if v_role is null then raise exception 'NOT_ALLOWED'; end if;
  select * into b from public.businesses where id = p_business_id;
  select jsonb_build_object('first_name', p.first_name, 'last_name', p.last_name, 'phone', p.phone) into v_me
    from public.profiles p where p.id = auth.uid();
  return jsonb_build_object(
    'role', v_role,
    'can_edit_profile', v_role in ('owner', 'admin'),
    'can_edit_hours', v_role in ('owner', 'admin', 'manager'),
    'business', jsonb_build_object(
      'name', b.name, 'legal_name', b.legal_name, 'email', b.email, 'phone', b.phone, 'website', b.website,
      'address_line_1', b.address_line_1, 'address_line_2', b.address_line_2, 'city', b.city, 'state', b.state,
      'postal_code', b.postal_code, 'country', b.country, 'timezone', b.timezone),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('weekday', h.weekday, 'opens', to_char(h.opens, 'HH24:MI'), 'closes', to_char(h.closes, 'HH24:MI'))
                         order by h.weekday, h.opens) from public.business_hours h where h.business_id = p_business_id), '[]'::jsonb),
    'closures', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'starts_on', c.starts_on, 'ends_on', c.ends_on, 'label', c.label,
                            'opens', to_char(c.opens, 'HH24:MI'), 'closes', to_char(c.closes, 'HH24:MI')) order by c.starts_on)
                          from public.business_closures c where c.business_id = p_business_id and c.ends_on >= current_date - 1), '[]'::jsonb),
    'me', coalesce(v_me, '{}'::jsonb) || jsonb_build_object('sms_alerts',
            coalesce((select m.sms_alerts from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()), false))
  );
end $$;

create or replace function public.zella_save_business_profile(p_business_id uuid, p_fields jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  old jsonb;
  v_name text := left(trim(coalesce(p_fields ->> 'name', '')), 200);
  v_email text := lower(nullif(left(trim(coalesce(p_fields ->> 'email', '')), 254), ''));
  v_phone text := nullif(regexp_replace(coalesce(p_fields ->> 'phone', ''), '[\s()-]', '', 'g'), '');
  v_web text := nullif(left(trim(coalesce(p_fields ->> 'website', '')), 300), '');
  v_country text := upper(nullif(left(trim(coalesce(p_fields ->> 'country', '')), 2), ''));
  v_tz text := nullif(trim(coalesce(p_fields ->> 'timezone', '')), '');
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_fields) is distinct from 'object' then raise exception 'BAD_INPUT'; end if;
  if v_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'BAD_PHONE'; end if;
  if v_web is not null and v_web !~* '^https?://[^\s/]+\.[^\s]+' then raise exception 'BAD_WEBSITE'; end if;
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then raise exception 'BAD_COUNTRY'; end if;
  if v_tz is null or not exists (select 1 from pg_timezone_names where name = v_tz) then raise exception 'BAD_TIMEZONE'; end if;

  select to_jsonb(b) - 'terminology_overrides' into old from public.businesses b where id = p_business_id for update;
  if old is null then raise exception 'NOT_FOUND'; end if;
  update public.businesses set
    name = v_name,
    legal_name = nullif(left(trim(coalesce(p_fields ->> 'legal_name', '')), 200), ''),
    email = v_email,
    phone = v_phone,
    website = v_web,
    address_line_1 = nullif(left(trim(coalesce(p_fields ->> 'address_line_1', '')), 200), ''),
    address_line_2 = nullif(left(trim(coalesce(p_fields ->> 'address_line_2', '')), 200), ''),
    city = nullif(left(trim(coalesce(p_fields ->> 'city', '')), 120), ''),
    state = nullif(left(trim(coalesce(p_fields ->> 'state', '')), 120), ''),
    postal_code = nullif(left(trim(coalesce(p_fields ->> 'postal_code', '')), 20), ''),
    country = coalesce(v_country, country),
    timezone = v_tz,
    updated_at = now()
  where id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'business.profile_updated', 'business', p_business_id,
          jsonb_build_object('name', old ->> 'name', 'email', old ->> 'email', 'phone', old ->> 'phone', 'timezone', old ->> 'timezone'),
          jsonb_build_object('name', v_name, 'email', v_email, 'phone', v_phone, 'timezone', v_tz));
  return public.zella_business_settings(p_business_id) -> 'business';
end $$;

-- p_hours: [{"weekday": 0-6 (0 = Sunday), "opens": "09:00", "closes": "17:00"}, ...]. Replaces the whole week.
-- An empty list means "hours not set" (the assistant never says closed), as zella_voice_rules.sql defines.
create or replace function public.zella_save_business_hours(p_business_id uuid, p_hours jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare r jsonb; n integer := 0; v_day int; v_open time; v_close time;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_hours) is distinct from 'array' or jsonb_array_length(p_hours) > 42 then raise exception 'BAD_INPUT'; end if;
  -- Check everything before changing anything.
  for r in select * from jsonb_array_elements(p_hours) loop
    begin
      v_day := (r ->> 'weekday')::int; v_open := (r ->> 'opens')::time; v_close := (r ->> 'closes')::time;
    exception when others then raise exception 'BAD_HOURS';
    end;
    if v_day is null or v_day not between 0 and 6 or v_open is null or v_close is null then raise exception 'BAD_HOURS'; end if;
    if v_close <= v_open then raise exception 'CLOSES_BEFORE_OPENS'; end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(p_hours) with ordinality a(v, i), jsonb_array_elements(p_hours) with ordinality b(v, i)
              where a.i < b.i and (a.v ->> 'weekday') = (b.v ->> 'weekday')
                and (a.v ->> 'opens')::time < (b.v ->> 'closes')::time and (b.v ->> 'opens')::time < (a.v ->> 'closes')::time) then
    raise exception 'HOURS_OVERLAP';
  end if;

  perform 1 from public.businesses where id = p_business_id for update;   -- one save at a time per business
  delete from public.business_hours where business_id = p_business_id;
  insert into public.business_hours (business_id, weekday, opens, closes)
  select p_business_id, (e ->> 'weekday')::smallint, (e ->> 'opens')::time, (e ->> 'closes')::time from jsonb_array_elements(p_hours) e;
  get diagnostics n = row_count;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'business.hours_updated', 'business', p_business_id, jsonb_build_object('hours', p_hours));
  return n;
end $$;

create or replace function public.zella_add_business_closure(p_business_id uuid, p_starts_on date, p_ends_on date, p_label text default 'Closed',
  p_opens time default null, p_closes time default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then raise exception 'BAD_DATES'; end if;
  if p_ends_on < current_date - 1 then raise exception 'IN_THE_PAST'; end if;
  if p_ends_on - p_starts_on > 366 then raise exception 'BAD_DATES'; end if;
  if (p_opens is null) <> (p_closes is null) or (p_opens is not null and p_closes <= p_opens) then raise exception 'BAD_HOURS'; end if;
  insert into public.business_closures (business_id, starts_on, ends_on, label, opens, closes)
  values (p_business_id, p_starts_on, p_ends_on, coalesce(nullif(left(trim(coalesce(p_label, '')), 80), ''), 'Closed'), p_opens, p_closes)
  returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'business.closure_added', 'business_closure', v_id,
          jsonb_build_object('starts_on', p_starts_on, 'ends_on', p_ends_on, 'label', p_label));
  return v_id;
end $$;

create or replace function public.zella_delete_business_closure(p_closure_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare c public.business_closures;
begin
  select * into c from public.business_closures where id = p_closure_id for update;
  if not found then return false; end if;
  if not public.zella_has_role(c.business_id, array['owner', 'admin', 'manager']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  delete from public.business_closures where id = p_closure_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data)
  values (c.business_id, auth.uid(), 'business.closure_removed', 'business_closure', p_closure_id,
          jsonb_build_object('starts_on', c.starts_on, 'ends_on', c.ends_on, 'label', c.label));
  return true;
end $$;

-- The signed-in person's own details. The mobile number is where urgent text alerts go (zella_set_my_sms_alerts).
create or replace function public.zella_save_my_profile(p_first_name text, p_last_name text, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_first text := nullif(left(trim(coalesce(p_first_name, '')), 100), '');
  v_last text := nullif(left(trim(coalesce(p_last_name, '')), 100), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '[\s()-]', '', 'g'), '');
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'BAD_PHONE'; end if;
  update public.profiles set first_name = v_first, last_name = v_last, phone = v_phone where id = auth.uid();
  if not found then
    insert into public.profiles (id, first_name, last_name, phone) values (auth.uid(), v_first, v_last, v_phone);
  end if;
  -- Text alerts need a number; switch them off everywhere if it was removed.
  if v_phone is null then update public.business_members set sms_alerts = false where user_id = auth.uid() and sms_alerts; end if;
  return jsonb_build_object('first_name', v_first, 'last_name', v_last, 'phone', v_phone);
end $$;

revoke all on function public.zella_business_settings(uuid) from public, anon;
revoke all on function public.zella_save_business_profile(uuid, jsonb) from public, anon;
revoke all on function public.zella_save_business_hours(uuid, jsonb) from public, anon;
revoke all on function public.zella_add_business_closure(uuid, date, date, text, time, time) from public, anon;
revoke all on function public.zella_delete_business_closure(uuid) from public, anon;
revoke all on function public.zella_save_my_profile(text, text, text) from public, anon;
grant execute on function public.zella_business_settings(uuid) to authenticated, service_role;
grant execute on function public.zella_save_business_profile(uuid, jsonb) to authenticated, service_role;
grant execute on function public.zella_save_business_hours(uuid, jsonb) to authenticated, service_role;
grant execute on function public.zella_add_business_closure(uuid, date, date, text, time, time) to authenticated, service_role;
grant execute on function public.zella_delete_business_closure(uuid) to authenticated, service_role;
grant execute on function public.zella_save_my_profile(text, text, text) to authenticated, service_role;
