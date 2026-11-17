-- Rollback baseline is captured on first apply of this version, never on reruns.
-- An older deployment needs its original backup; this cannot reconstruct already-overwritten state.
create table if not exists public.zella_attendance_undo (seq bigint generated always as identity, command text not null);
revoke all on public.zella_attendance_undo from public, anon, authenticated, service_role;
do $capture$
declare f text; p oid; r record; g record; ddl text; cols text[];
begin
 if not exists (select 1 from public.zella_attendance_undo) then
  insert into public.zella_attendance_undo(command) values ('select 1');
  foreach f in array array['public.zella_set_attendance(uuid,text,text,uuid)'] loop
    p := to_regprocedure(f);
    if p is null then
      insert into public.zella_attendance_undo(command) values ('drop function if exists ' || f);
    else
      insert into public.zella_attendance_undo(command) values (pg_get_functiondef(p));
      -- Only these roles' permissions are modified by the migrations.
      insert into public.zella_attendance_undo(command) values ('revoke all on function ' || f || ' from public, anon, authenticated, service_role');
      for g in select a.* from pg_proc x, lateral aclexplode(coalesce(x.proacl, acldefault('f',x.proowner))) a
        where x.oid=p and (a.grantee=0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role'))) loop
        insert into public.zella_attendance_undo(command) values ('grant execute on function ' || f || ' to ' ||
          case when g.grantee=0 then 'public' else quote_ident(pg_get_userbyid(g.grantee)) end ||
          case when g.is_grantable then ' with grant option' else '' end);
      end loop;
    end if;
  end loop;
  if not exists (select 1 from pg_attribute where attrelid='public.appointments'::regclass and attname='arrived_at' and not attisdropped) then
    insert into public.zella_attendance_undo(command) values ('alter table public.appointments drop column if exists arrived_at');
  end if;
  if not exists (select 1 from pg_attribute where attrelid='public.appointments'::regclass and attname='in_service_at' and not attisdropped) then
    insert into public.zella_attendance_undo(command) values ('alter table public.appointments drop column if exists in_service_at');
  end if;
  if not exists (select 1 from pg_attribute where attrelid='public.appointments'::regclass and attname='attendance_source' and not attisdropped) then
    insert into public.zella_attendance_undo(command) values ('alter table public.appointments drop column if exists attendance_source');
  end if;
  if not exists (select 1 from pg_attribute where attrelid='public.appointments'::regclass and attname='attendance_by' and not attisdropped) then
    insert into public.zella_attendance_undo(command) values ('alter table public.appointments drop column if exists attendance_by');
  end if;
  if not exists (select 1 from pg_attribute where attrelid='public.appointments'::regclass and attname='attendance_note' and not attisdropped) then
    insert into public.zella_attendance_undo(command) values ('alter table public.appointments drop column if exists attendance_note');
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.appointments'::regclass and conname='appointments_attendance_source_chk') then
    insert into public.zella_attendance_undo(command) values ('alter table public.appointments drop constraint if exists appointments_attendance_source_chk');
  end if;
 end if;
end $capture$;

-- Attendance tracking: arrived, checked in, in service, completed, no-show,
-- cancelled. Only staff (signed in) or a trusted integration (service role)
-- can record attendance, and each change is logged. Nothing is assumed
-- because an appointment time has passed.

alter table public.appointments add column if not exists arrived_at timestamptz;
alter table public.appointments add column if not exists in_service_at timestamptz;
alter table public.appointments add column if not exists attendance_source text;
alter table public.appointments add column if not exists attendance_by uuid;
alter table public.appointments add column if not exists attendance_note text;
do $$ begin
  alter table public.appointments add constraint appointments_attendance_source_chk check (attendance_source is null or attendance_source in ('staff', 'integration'));
exception when duplicate_object then null; end $$;

create or replace function public.zella_set_attendance(
  p_appointment_id uuid, p_action text, p_reason text default null, p_staff_id uuid default null
) returns text
language plpgsql security definer set search_path = public as $$
declare a public.appointments; v_uid uuid := auth.uid(); v_src text; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_uid is not null and not public.zella_has_role(a.business_id, array['owner', 'admin', 'manager', 'staff']) then raise exception 'NOT_ALLOWED'; end if;
  v_src := case when v_uid is null then 'integration' else 'staff' end;
  if p_action not in ('arrived', 'checked_in', 'in_service', 'completed', 'no_show', 'cancelled', 'undo', 'assign') then raise exception 'BAD_ACTION'; end if;
  /* zella_capability_checkins */ if p_action in ('arrived', 'checked_in', 'in_service')
    and to_regprocedure('public.zella_require_capability(uuid,text)') is not null then
    perform public.zella_require_capability(a.business_id, 'checkins');
  end if;
  if p_staff_id is not null and not exists (select 1 from public.staff_members where id = p_staff_id and business_id = a.business_id and is_active) then
    raise exception 'BAD_STAFF';
  end if;
  if p_action <> 'undo' and a.status in ('cancelled', 'no_show', 'completed') and p_action <> 'assign' then raise exception 'ALREADY_CLOSED'; end if;

  if p_action = 'arrived' then
    update public.appointments set arrived_at = coalesce(arrived_at, now()) where id = a.id;
  elsif p_action = 'checked_in' then
    update public.appointments set arrived_at = coalesce(arrived_at, now()), checked_in_at = coalesce(checked_in_at, now()) where id = a.id;
  elsif p_action = 'in_service' then
    update public.appointments set arrived_at = coalesce(arrived_at, now()), checked_in_at = coalesce(checked_in_at, now()), in_service_at = coalesce(in_service_at, now()),
           staff_id = coalesce(p_staff_id, staff_id) where id = a.id;
  elsif p_action = 'completed' then
    update public.appointments set status = 'completed', arrived_at = coalesce(arrived_at, now()), checked_in_at = coalesce(checked_in_at, now()), in_service_at = coalesce(in_service_at, now()) where id = a.id;
  elsif p_action = 'no_show' then
    if a.start_time > now() then raise exception 'TOO_EARLY'; end if;
    if v_reason is null then raise exception 'REASON_REQUIRED'; end if;
    update public.appointments set status = 'no_show', checked_in_at = null, arrived_at = null, in_service_at = null where id = a.id;
  elsif p_action = 'cancelled' then
    if v_reason is null then raise exception 'REASON_REQUIRED'; end if;
    update public.appointments set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason where id = a.id;
  elsif p_action = 'assign' then
    if p_staff_id is null then raise exception 'BAD_STAFF'; end if;
    update public.appointments set staff_id = p_staff_id where id = a.id;
  elsif p_action = 'undo' then
    update public.appointments set status = case when status in ('completed', 'no_show') then 'scheduled' else status end,
           arrived_at = null, checked_in_at = null, in_service_at = null where id = a.id;
  end if;

  if p_action <> 'assign' then
    update public.appointments set attendance_source = v_src, attendance_by = v_uid, attendance_note = coalesce(v_reason, case when p_action = 'undo' then null else attendance_note end),
           updated_at = now() where id = a.id;
  else
    update public.appointments set updated_at = now() where id = a.id;
  end if;

  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (a.business_id, v_uid, 'attendance.' || p_action, 'appointment', a.id,
          jsonb_build_object('status', a.status, 'staff_id', a.staff_id),
          jsonb_build_object('source', v_src, 'reason', v_reason, 'staff_id', p_staff_id));
  return p_action;
end $$;

revoke all on function public.zella_set_attendance(uuid, text, text, uuid) from public, anon;
grant execute on function public.zella_set_attendance(uuid, text, text, uuid) to authenticated, service_role;
