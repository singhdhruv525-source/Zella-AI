-- Zella - calendar: who made each booking (2026-10-26). Safe to re-run. Changes no existing rows or functions.
--
-- New bookings record where they came from in appointments.metadata.source, so the calendar can mark them:
--   'staff'  a signed-in team member booked it (also stores metadata.created_by)
--   'zella'  Zella booked it with no one signed in: the AI receptionist on a call, a waitlist offer, or the
--            customer's own reschedule link
-- A source already set by the code that books (for example 'ai_receptionist') is kept as it is.
-- Bookings made before this file is applied have no source and show without a marker.
-- Rollback: drop trigger zella_appointment_source_trg on public.appointments; drop function public.zella_appointment_source();

create or replace function public.zella_appointment_source()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(new.metadata ->> 'source', '') = '' then
    new.metadata := coalesce(new.metadata, '{}'::jsonb)
      || jsonb_build_object('source', case when auth.uid() is not null then 'staff' else 'zella' end)
      || case when auth.uid() is not null then jsonb_build_object('created_by', auth.uid()) else '{}'::jsonb end;
  end if;
  return new;
end $$;
revoke all on function public.zella_appointment_source() from public, anon, authenticated;

drop trigger if exists zella_appointment_source_trg on public.appointments;
create trigger zella_appointment_source_trg before insert on public.appointments
  for each row execute function public.zella_appointment_source();
