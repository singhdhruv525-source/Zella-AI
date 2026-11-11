-- Undo sql/zella_replace_business_hours.sql. The function is new (nothing existed before), so undoing it is
-- dropping it; owner-provision-business then falls back to delete-then-insert. No data is touched.
begin;
drop function if exists public.zella_replace_business_hours(uuid, jsonb);
commit;
