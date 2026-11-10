-- Call transcripts and recordings: least privilege (2026-11-04 industry work, batch 1).
--
-- What was wrong (reproduced on the isolated copy of the production schema): calls_view already blanked transcript and
-- recording_url below manager, but the calls table itself is readable by every member role (grant SELECT to
-- authenticated + "business members can view calls"). Any staff or view-only member could read every transcript and
-- recording link straight from the table. Business settings > Team tells owners only owners, admins and managers can.
--
-- After this:
--   * signed-in users can no longer read calls.transcript or calls.recording_url from the table (column grants);
--   * calls_view is the way to read calls. It runs with the view owner's rights, so it applies the same row rules as
--     the table itself (member of the business, calls module on, two-step sign-in satisfied) and shows transcript and
--     recording only to those allowed by zella_can_read_call_content();
--   * owners may let staff read transcripts (setup_data.privacy.staff_read_call_content = true), except in industries
--     whose calls routinely carry health, legal, financial, insurance or children's information.
-- Server code (service role) is unchanged. Safe to run twice. Needs the owner's approval before it is applied.

create or replace function public.zella_sensitive_industry(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select i.slug in ('dental', 'healthcare', 'pet-care-veterinary', 'legal', 'financial-services', 'insurance', 'childcare')
                     from public.businesses b join public.industries i on i.id = b.industry_id where b.id = p_business_id), false);
$$;

create or replace function public.zella_can_read_call_content(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_has_role(p_business_id, array['owner', 'admin', 'manager'])
      or (public.zella_has_role(p_business_id, array['staff'])
          and not public.zella_sensitive_industry(p_business_id)
          and coalesce((select (b.setup_data #>> '{privacy,staff_read_call_content}')::boolean from public.businesses b where b.id = p_business_id), false));
$$;
revoke execute on function public.zella_sensitive_industry(uuid), public.zella_can_read_call_content(uuid) from public, anon;
grant execute on function public.zella_sensitive_industry(uuid), public.zella_can_read_call_content(uuid) to authenticated, service_role;

-- Owners and admins choose whether staff may read transcripts (never in sensitive industries).
create or replace function public.zella_set_call_content_access(p_business_id uuid, p_staff boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_staff and public.zella_sensitive_industry(p_business_id) then raise exception 'NOT_FOR_THIS_INDUSTRY'; end if;
  update public.businesses set setup_data = jsonb_set(coalesce(setup_data, '{}'::jsonb), '{privacy}',
         coalesce(setup_data -> 'privacy', '{}'::jsonb) || jsonb_build_object('staff_read_call_content', p_staff)), updated_at = now()
   where id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'privacy_call_content_changed', 'business', p_business_id, jsonb_build_object('staff_read_call_content', p_staff));
  return p_staff;
end $$;
revoke execute on function public.zella_set_call_content_access(uuid, boolean) from public, anon;
grant execute on function public.zella_set_call_content_access(uuid, boolean) to authenticated, service_role;

-- The table: every column except the two sensitive ones.
do $$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'calls' and column_name not in ('transcript', 'recording_url');
  execute 'revoke select on public.calls from authenticated';
  execute format('grant select (%s) on public.calls to authenticated', cols);
end $$;

-- The view: same columns as before; rows filtered like the table's own policies.
create or replace view public.calls_view with (security_invoker = false) as
select c.id, c.business_id, c.customer_id, c.conversation_id, c.direction, c.status, c.from_number, c.to_number, c.started_at, c.answered_at,
       c.ended_at, c.duration_seconds, c.ai_handled, c.external_call_id, c.metadata, c.created_at, c.updated_at, c.needs_human,
       c.escalation_reason, c.escalated_at, c.escalation_resolved_at, c.escalation_resolved_by, c.summary, c.transfer_status, c.failure_reason,
       c.failure_context, c.assigned_to, c.outcome, c.outcome_note, c.outcome_at, c.escalation_acknowledged_at, c.escalation_acknowledged_by,
       c.escalation_reminded_at,
       case when public.zella_can_read_call_content(c.business_id) then c.recording_url end as recording_url,
       case when public.zella_can_read_call_content(c.business_id) then c.transcript end as transcript
  from public.calls c
 where public.is_business_member(c.business_id)
   and public.zella_module_on(c.business_id, 'calls')
   and public.zella_mfa_satisfied();
revoke all on public.calls_view from anon;
grant select on public.calls_view to authenticated, service_role;
