-- Holidays and special hours hold for bookings, not only for what callers are told. Safe to run twice.
-- Rollback: sql/rollback/zella_holiday_availability_rollback.sql (tests/setup/make_rollback.py holiday).
--
-- H1  Holidays (Settings > Hours & holidays, business_closures) reached the instructions ("Upcoming closures") and the
--     open-hours check, but not zella_available_slots. So check_availability offered times on a day the business is
--     closed, and book_appointment (which books through the same function) accepted them; so did the CRM's own
--     booking and the reschedule link. Now a closed day offers no times, and a day with special hours offers only
--     times inside them.

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_available_slots(uuid, timestamptz, timestamptz, integer, uuid, integer, integer, uuid)'::regprocedure);
  if position('zella_holiday_availability' in def) = 0 then
    def := replace(def, $a$     and not exists (
       select 1 from public.blocked_times bt$a$, $a$     and not exists (   /* zella_holiday_availability: closed days, and special hours on those days */
       select 1 from public.business_closures hc
        where hc.business_id = p_business_id and r.lstart::date between hc.starts_on and hc.ends_on
          and (hc.opens is null or hc.closes is null or r.lstart::time < hc.opens or r.lend::time > hc.closes)
     )
     and not exists (
       select 1 from public.blocked_times bt$a$);
    if position('zella_holiday_availability' in def) = 0 then raise exception 'zella_available_slots has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
