-- Undoes sql/zella_batch1_security.sql: zella_appointment_holds_time back to IMMUTABLE with no fixed search path.
begin;
alter function public.zella_appointment_holds_time(text, text, timestamptz) immutable;
alter function public.zella_appointment_holds_time(text, text, timestamptz) reset search_path;
commit;
