-- "Add lead" in the CRM goes through the lead pipeline (2026-11-04 industry journeys).
--
-- The CRM's Add lead form inserted straight into customers, so a lead typed in by the team skipped everything
-- zella_capture_lead does for leads from calls and the website: duplicate check, lead stage "new", a contact deadline,
-- lead rules (priority, assignment), a "Contact <name>" task, the new-lead callback when the business switched it on,
-- and the "New lead" notification. zella_capture_lead is server-only (it has no caller check), so this wrapper lets
-- owners, admins, managers and staff use it for their own business; view-only members can't.
-- Returns what zella_capture_lead returns: result created / matched (already in the list, notes added) / needs_review.
-- Safe to run twice. Needs the owner's approval before it is applied.
create or replace function public.zella_staff_add_lead(p_business_id uuid, p_first_name text default null, p_last_name text default null,
  p_phone text default null, p_email text default null, p_source text default 'manual', p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager', 'staff']) then raise exception 'NOT_ALLOWED'; end if;
  if nullif(trim(coalesce(p_first_name, '') || coalesce(p_last_name, '')), '') is null then raise exception 'NAME_REQUIRED'; end if;
  return public.zella_capture_lead(p_business_id, p_first_name, p_last_name, p_phone, p_email,
    coalesce(nullif(trim(p_source), ''), 'manual'), p_notes, null);
end $$;
revoke execute on function public.zella_staff_add_lead(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.zella_staff_add_lead(uuid, text, text, text, text, text, text) to authenticated, service_role;
