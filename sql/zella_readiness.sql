-- Setup readiness, one ladder for the wizard and the business (2026-11-04 industry work, batch 5).
--
-- Each rung needs the one before it, and each is read from real records, never from a flag someone ticked:
--   saved                  the business exists (a draft)
--   setup_complete         owner invited or active, past the setup steps (testing or later), opening hours where it takes
--                          bookings, and at least one industry record type switched on
--   integrations_verified  a phone number assigned, the voice agent connected, and no capability that is on still
--                          needs setup (for example order support with no store connected)
--   ready                  the AI receptionist exists and is switched on
--   live                   the business is active and its receptionist is answering calls
-- Every check says what is missing, so "Ready" is never shown while something still blocks it.
-- Members of the business and Zella admins can read it. Safe to run twice. Needs the owner's approval to apply.

create or replace function public.zella_business_readiness(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b record; caps jsonb; checks jsonb := '[]'; v_state text := 'saved'; v_owner boolean; v_hours boolean; v_types boolean;
  v_phone boolean; v_voice boolean; v_pending text; v_agent text;
begin
  if auth.uid() is not null and not (public.zella_is_member(p_business_id) or public.is_platform_admin()) then raise exception 'NOT_ALLOWED'; end if;
  select * into b from public.businesses where id = p_business_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  caps := public.zella_capabilities(p_business_id);

  v_owner := exists (select 1 from public.business_members where business_id = p_business_id and role = 'owner' and status = 'active')
          or exists (select 1 from public.business_invitations where business_id = p_business_id and status not in ('revoked', 'expired', 'cancelled', 'failed'));
  v_hours := not coalesce((caps #>> '{scheduling,enabled}')::boolean, false) or exists (select 1 from public.business_hours where business_id = p_business_id);
  v_types := exists (select 1 from public.crm_record_types where business_id = p_business_id and enabled);
  v_phone := exists (select 1 from public.business_phone_numbers where business_id = p_business_id and status = 'active');
  v_voice := exists (select 1 from public.integrations where business_id = p_business_id and lower(provider) = 'telnyx' and status = 'active');
  select string_agg(v ->> 'label', ', ') into v_pending from jsonb_each(caps) e(k, v) where v ->> 'state' = 'needs_setup';
  select status into v_agent from public.ai_agents where business_id = p_business_id and agent_type = 'receptionist' order by is_default desc, created_at limit 1;

  checks := jsonb_build_array(
    jsonb_build_object('key', 'owner', 'rung', 'setup_complete', 'ok', v_owner, 'detail', case when v_owner then 'Owner active or invited' else 'Invite the owner' end),
    jsonb_build_object('key', 'steps', 'rung', 'setup_complete', 'ok', b.onboarding_status in ('testing', 'ready', 'active', 'paused'),
                       'detail', case when b.onboarding_status in ('testing', 'ready', 'active', 'paused') then 'Setup steps saved' else 'Setup steps not finished (' || coalesce(b.onboarding_status, 'not started') || ')' end),
    jsonb_build_object('key', 'hours', 'rung', 'setup_complete', 'ok', v_hours, 'detail', case when v_hours then 'Opening hours set, or no bookings taken' else 'Add opening hours so times can be offered' end),
    jsonb_build_object('key', 'records', 'rung', 'setup_complete', 'ok', v_types, 'detail', case when v_types then 'Industry records switched on' else 'No industry records switched on yet' end),
    jsonb_build_object('key', 'phone', 'rung', 'integrations_verified', 'ok', v_phone, 'detail', case when v_phone then 'Phone number assigned' else 'No phone number assigned' end),
    jsonb_build_object('key', 'voice', 'rung', 'integrations_verified', 'ok', v_voice, 'detail', case when v_voice then 'Voice connection active' else 'Voice connection not active' end),
    jsonb_build_object('key', 'capabilities', 'rung', 'integrations_verified', 'ok', v_pending is null, 'detail', coalesce('Still needs setup: ' || v_pending, 'Everything switched on is set up')),
    jsonb_build_object('key', 'receptionist', 'rung', 'ready', 'ok', coalesce(v_agent = 'active', false), 'detail', case when v_agent is null then 'No AI receptionist yet' when v_agent = 'active' then 'AI receptionist switched on' else 'AI receptionist is ' || v_agent end),
    jsonb_build_object('key', 'live', 'rung', 'live', 'ok', coalesce(b.onboarding_status = 'active' and b.is_active and v_agent = 'active' and v_phone and v_voice, false),
                       'detail', case when b.onboarding_status = 'active' and b.is_active and v_agent = 'active' and v_phone and v_voice then 'Live and answering calls'
                                      when b.onboarding_status = 'active' and b.is_active then 'Business active, but calls aren''t answered yet' else 'Not live yet' end));

  -- the highest rung whose checks, and every rung below it, all pass
  if not exists (select 1 from jsonb_array_elements(checks) c where c ->> 'rung' = 'setup_complete' and not (c ->> 'ok')::boolean) then
    v_state := 'setup_complete';
    if not exists (select 1 from jsonb_array_elements(checks) c where c ->> 'rung' = 'integrations_verified' and not (c ->> 'ok')::boolean) then
      v_state := 'integrations_verified';
      if not exists (select 1 from jsonb_array_elements(checks) c where c ->> 'rung' = 'ready' and not (c ->> 'ok')::boolean) then
        v_state := 'ready';
        if not exists (select 1 from jsonb_array_elements(checks) c where c ->> 'rung' = 'live' and not (c ->> 'ok')::boolean) then v_state := 'live'; end if;
      end if;
    end if;
  end if;
  return jsonb_build_object('state', v_state, 'checks', checks);
end $$;
revoke execute on function public.zella_business_readiness(uuid) from public, anon;
grant execute on function public.zella_business_readiness(uuid) to authenticated, service_role;
