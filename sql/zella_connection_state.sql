-- Zella Voice: one definition of connected, answering and live (docs/ADMIN_AUDIT_2026-11-16.md COM-01, OPS-07, UI-02,
-- COM-06). Overview, AI agents, Integrations and the operations health counts each worked "connected" out on their
-- own, mostly from the integrations table, which only the store connection writes. So the four pages disagreed about
-- the same business. The definition now lives here, once (docs/PRODUCT.md "Connected, answering and live"):
--   phone        an active business_phone_numbers row
--   vapi_linked  an active number that has its Vapi number id
--   answering    a served assistant_deliveries row in the last 7 days (ANSWERING_DAYS). Shown on its own, never
--                folded into live: deliveries only arrive once the numbers send assistant-request to voice-rules
--   calendar     an active calendar_connections row
--   leads        an enabled website form, a connected Meta account or an enabled Google lead key
--   email        not tracked: there is no mailbox connection table
--   problems     connections that need attention: integrations in error or disconnected, calendars in error or
--                disconnected, Meta accounts that need reconnecting, in error or disconnected
--   live         the business is active (setup finished, switched on, not suspended or cancelled), its receptionist
--                is active, and it has an active number linked to Vapi
-- Functions (all new; nothing is replaced):
--   zella_connection_state(uuid[])        the definition; no grants (called by the two below only)
--   zella_business_connections(uuid[])    one row per business, at most 1000 ids per call; admins with
--                                         businesses.view and server code. Shared with the Business detail job.
--   zella_connection_counts()             the same definition counted over every business, as jsonb
-- The readiness ladder (zella_business_readiness, held by the Business detail job) is not changed here; that job can
-- read zella_business_connections for its phone, voice and live checks.
-- Rerunning needs this file's exact versions, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_connection_state_rollback.sql
begin;

do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_connection_state(uuid[])', 'f03b127e562815f7cf5c7897e283f46d'),
      ('public.zella_business_connections(uuid[])', 'adcf308f2984282e34b03ee2d72d125b'),
      ('public.zella_connection_counts()', '0124fe13da3e43dd57ff6c1b37742fc6')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists and is not this file''s version', f.sig;
    end if;
  end loop;
  if to_regprocedure('public.zella_admin_can(text)') is null then
    raise exception 'VERSION_MISMATCH: zella_admin_can(text) is missing';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_connection_state(p_business_ids uuid[])
 RETURNS TABLE(business_id uuid, business_state text, receptionist text, phone boolean, phone_numbers integer,
   vapi_linked boolean, answering boolean, last_served_at timestamp with time zone, calendar boolean, leads boolean,
   lead_sources text[], email text, problems integer, live boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with knobs as (select interval '7 days' as answering_window),   -- ANSWERING_DAYS: a default the owner can change
  base as (
    select b.id,
           case when b.cancelled_at is not null then 'cancelled'
                when b.suspended_at is not null then 'suspended'
                when b.onboarding_status = 'active' and b.is_active then 'active'
                else 'setup' end as state,
           coalesce((select a.status from public.ai_agents a where a.business_id = b.id and a.agent_type = 'receptionist'
                      order by a.is_default desc, a.created_at limit 1), 'none') as receptionist,
           (select count(*) from public.business_phone_numbers n where n.business_id = b.id and n.status = 'active')::int as numbers,
           exists (select 1 from public.business_phone_numbers n where n.business_id = b.id and n.status = 'active'
                    and nullif(trim(n.vapi_phone_number_id), '') is not null) as linked,
           (select max(d.created_at) from public.assistant_deliveries d where d.business_id = b.id and d.outcome = 'served') as served_at,
           exists (select 1 from public.calendar_connections c where c.business_id = b.id and c.status = 'active') as cal,
           array_remove(array[
             case when exists (select 1 from public.website_forms w where w.business_id = b.id and w.enabled) then 'website' end,
             case when exists (select 1 from public.meta_connections m where m.business_id = b.id and m.status = 'connected') then 'meta' end,
             case when exists (select 1 from public.google_lead_keys g where g.business_id = b.id and g.enabled) then 'google' end
           ], null) as sources,
           ((select count(*) from public.integrations i where i.business_id = b.id and i.status in ('error', 'disconnected'))
            + (select count(*) from public.calendar_connections c where c.business_id = b.id and c.status in ('error', 'disconnected'))
            + (select count(*) from public.meta_connections m where m.business_id = b.id and m.status in ('needs_reconnect', 'error', 'disconnected')))::int as broken
      from public.businesses b
     where p_business_ids is null or b.id = any (p_business_ids)
  )
  select base.id, base.state, base.receptionist, base.numbers > 0, base.numbers, base.linked,
         coalesce(base.served_at > now() - knobs.answering_window, false), base.served_at, base.cal,
         cardinality(base.sources) > 0, base.sources, 'not_tracked'::text, base.broken,
         base.state = 'active' and base.receptionist = 'active' and base.numbers > 0 and base.linked
    from base, knobs;
$function$;
revoke all on function public.zella_connection_state(uuid[]) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.zella_business_connections(p_business_ids uuid[])
 RETURNS TABLE(business_id uuid, business_state text, receptionist text, phone boolean, phone_numbers integer,
   vapi_linked boolean, answering boolean, last_served_at timestamp with time zone, calendar boolean, leads boolean,
   lead_sources text[], email text, problems integer, live boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.zella_admin_can('businesses.view') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if p_business_ids is null then raise exception 'BUSINESS_IDS_REQUIRED' using errcode = '22023'; end if;
  if cardinality(p_business_ids) > 1000 then raise exception 'TOO_MANY_BUSINESSES' using errcode = '22023'; end if;
  return query select * from public.zella_connection_state(p_business_ids);
end $function$;
revoke all on function public.zella_business_connections(uuid[]) from public, anon;
grant execute on function public.zella_business_connections(uuid[]) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.zella_connection_counts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.zella_admin_can('businesses.view') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  select jsonb_build_object(
           'businesses', count(*),
           'active', count(*) filter (where s.business_state = 'active'),
           'receptionists_active', count(*) filter (where s.receptionist = 'active' and s.business_state not in ('suspended', 'cancelled')),
           'phone', count(*) filter (where s.phone),
           'vapi_linked', count(*) filter (where s.vapi_linked),
           'answering', count(*) filter (where s.answering),
           'calendar', count(*) filter (where s.calendar),
           'leads', count(*) filter (where s.leads),
           'live', count(*) filter (where s.live),
           'problems', coalesce(sum(s.problems), 0),
           'email', 'not_tracked')
    into v from public.zella_connection_state(null) s;
  return v;
end $function$;
revoke all on function public.zella_connection_counts() from public, anon;
grant execute on function public.zella_connection_counts() to authenticated, service_role;

commit;
