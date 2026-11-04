-- View-only members can't change business data (2026-11-04 review).
--
-- Business settings > Team tells owners that "View only" members can see customers, calendar and calls but not
-- "add and edit customers and appointments". Table writes already refuse viewers (zella_viewer_no_* policies), but
-- these SECURITY DEFINER functions only asked zella_is_member() / is_business_member(), which viewers pass. Found by
-- the industry journeys: a viewer could change an industry record's status, add notes, create and edit records, add
-- customers and book. Production has the same function bodies (checked read-only 2026-11-04; 0 viewers live today).
--
-- Fix: zella_can_edit(business) = an active owner, admin, manager or staff member; each function below asks it
-- instead of plain membership. Nothing else in the functions changes: the definitions are taken from the database and
-- only the membership call is swapped, so it applies to whatever version is deployed. Personal actions stay open to
-- every member: marking one's own notifications read, one's own notification settings, setting oneself away.
-- Safe to run twice. Needs the owner's approval before it is applied.

create or replace function public.zella_can_edit(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_has_role(p_business_id, array['owner', 'admin', 'manager', 'staff']);
$$;
revoke execute on function public.zella_can_edit(uuid) from public, anon;
grant execute on function public.zella_can_edit(uuid) to authenticated, service_role;

do $$
declare
  fn text; f record; def text; changed int := 0;
  writers text[] := array[
    'create_appointment', 'create_customer', 'update_customer', 'zella_acknowledge_escalation', 'zella_add_lead_note',
    'zella_add_record_note', 'zella_assign_lead', 'zella_book_appointment', 'zella_call_create_lead', 'zella_call_mark_followed_up',
    'zella_call_set_escalation', 'zella_call_update', 'zella_complete_task', 'zella_confirm_hold', 'zella_confirm_requested_appointment',
    'zella_create_handover', 'zella_issue_quote', 'zella_join_waitlist', 'zella_record_callback_attempt', 'zella_record_consent',
    'zella_remove_waitlist_entry', 'zella_request_time_off', 'zella_reschedule_appointment', 'zella_resolve_duplicate',
    'zella_review_call_insight', 'zella_save_qualification', 'zella_set_attendance', 'zella_set_lead_plan', 'zella_set_lead_stage',
    'zella_set_quote_status', 'zella_set_record_status', 'zella_staff_create_task', 'zella_update_callback',
    'zella_update_customer_request', 'zella_save_record'];
begin
  foreach fn in array writers loop
    for f in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = fn loop
      def := pg_get_functiondef(f.oid);
      if def ~ '(zella_is_member|is_business_member)\(' then
        def := regexp_replace(def, '(public\.)?(zella_is_member|is_business_member)\(', 'public.zella_can_edit(', 'g');
        execute def;
        changed := changed + 1;
      end if;
    end loop;
  end loop;
  raise notice 'zella_viewer_read_only: % functions now need staff or above', changed;
end $$;
