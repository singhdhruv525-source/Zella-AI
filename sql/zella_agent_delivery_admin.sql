-- Zella Voice: platform admins see whether each receptionist is really being served to calls (docs/ADMIN_AUDIT_2026-11-16.md
-- COM-03, list part). assistant_deliveries records what every call got (served, not_ready, unknown_number,
-- forwarded_usage, with the problems), but the only reader, zella_assistant_delivery_status, is for a business's own
-- owners, admins and managers, so the AI agents page couldn't show it. Two new admin readers, aggregated in SQL so no
-- raw delivery rows are read into the function (PostgREST returns at most 1000 rows):
--   zella_admin_agent_deliveries_summary(uuid[])   per business: last outcome and time, served, not_ready,
--                                                  unknown_number and forwarded_usage counts over the last 7 days,
--                                                  the last problems, the version served last and the published
--                                                  version with its sync state. At most 1000 ids per call.
--   zella_admin_agent_deliveries(uuid, integer)    one business's recent deliveries for the drawer, newest first
--                                                  (1 to 100, default 25); the call id is shortened.
-- Both need businesses.view (zella_admin_can) or server code. Shared with the Business detail job (COM-03 on the detail
-- page). Nothing is replaced. Rerunning needs this file's exact versions, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_agent_delivery_admin_rollback.sql
begin;

do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_agent_deliveries_summary(uuid[])', '39670a0a9cf1cc2c70d8002f30bd5e98'),
      ('public.zella_admin_agent_deliveries(uuid,integer)', '48bd7fce72f915cc351b705ed218a0bf')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists and is not this file''s version', f.sig;
    end if;
  end loop;
  if to_regprocedure('public.zella_admin_can(text)') is null or to_regclass('public.assistant_deliveries') is null then
    raise exception 'VERSION_MISMATCH: zella_admin_can(text) or assistant_deliveries is missing';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_admin_agent_deliveries_summary(p_business_ids uuid[])
 RETURNS TABLE(business_id uuid, last_outcome text, last_at timestamp with time zone, served_7d integer,
   not_ready_7d integer, unknown_number_7d integer, forwarded_usage_7d integer, last_problems jsonb,
   last_problem_at timestamp with time zone, served_version integer, published_version integer,
   published_sync_status text, published_sync_error text)
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
  return query
  select b.id,
         last_d.outcome, last_d.created_at,
         coalesce(w.served, 0)::int, coalesce(w.not_ready, 0)::int, coalesce(w.unknown_number, 0)::int, coalesce(w.forwarded_usage, 0)::int,
         prob.problems, prob.created_at,
         (select v.version from public.assistant_deliveries d join public.agent_config_versions v on v.id = d.version_id
           where d.business_id = b.id and d.outcome = 'served' order by d.created_at desc, d.id desc limit 1),
         pub.version, pub.sync_status, pub.sync_error
    from public.businesses b
    left join lateral (select d.outcome, d.created_at from public.assistant_deliveries d
                        where d.business_id = b.id order by d.created_at desc, d.id desc limit 1) last_d on true
    left join lateral (select count(*) filter (where d.outcome = 'served') served,
                              count(*) filter (where d.outcome = 'not_ready') not_ready,
                              count(*) filter (where d.outcome = 'unknown_number') unknown_number,
                              count(*) filter (where d.outcome = 'forwarded_usage') forwarded_usage
                         from public.assistant_deliveries d
                        where d.business_id = b.id and d.created_at > now() - interval '7 days') w on true
    left join lateral (select d.problems, d.created_at from public.assistant_deliveries d
                        where d.business_id = b.id and d.outcome = 'not_ready' order by d.created_at desc, d.id desc limit 1) prob on true
    left join lateral (select v.version, v.sync_status, v.sync_error from public.agent_config_versions v
                        where v.business_id = b.id and v.status = 'published' order by v.published_at desc nulls last, v.version desc limit 1) pub on true
   where b.id = any (p_business_ids);
end $function$;
revoke all on function public.zella_admin_agent_deliveries_summary(uuid[]) from public, anon;
grant execute on function public.zella_admin_agent_deliveries_summary(uuid[]) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.zella_admin_agent_deliveries(p_business_id uuid, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.zella_admin_can('businesses.view') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then
    raise exception 'BUSINESS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'business_id', p_business_id,
    'deliveries', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'at', x.created_at, 'outcome', x.outcome, 'problems', x.problems,
               'version', x.version, 'call', case when x.provider_call_id is null then null else '…' || right(x.provider_call_id, 6) end)
               order by x.created_at desc, x.id desc)
        from (select d.id, d.created_at, d.outcome, d.problems, d.provider_call_id, v.version
                from public.assistant_deliveries d left join public.agent_config_versions v on v.id = d.version_id
               where d.business_id = p_business_id order by d.created_at desc, d.id desc limit v_limit) x), '[]'::jsonb),
    'limit', v_limit);
end $function$;
revoke all on function public.zella_admin_agent_deliveries(uuid, integer) from public, anon;
grant execute on function public.zella_admin_agent_deliveries(uuid, integer) to authenticated, service_role;

commit;
