-- Zella Voice: "Missing routing", the businesses whose AI receptionist has no transfer number or no fallback number
-- (docs/ADMIN_AUDIT_2026-11-16.md UI-17). Call routing could only be checked one business at a time.
-- zella_admin_routing_missing(p_limit, p_offset): businesses.view, read only; businesses that aren't cancelled and have
-- a default AI receptionist, where transfers are on but no transfer number is set (escalation_rules.transfer_number or
-- transfer_to.phone, as zella_admin_routing_get reads them), or no fallback number is set (escalation_rules
-- .fallback_number; REQ-BIL-34, used by usage enforcement at 100%). Paged (1 to 100 rows), with the total.
-- A new function only; a different function of the same name stops the file (VERSION_MISMATCH).
-- Rollback: sql/rollback/zella_admin_routing_missing_rollback.sql
begin;

do $$ begin
  if to_regprocedure('public.zella_admin_require(text)') is null or to_regclass('public.ai_agent_configs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regprocedure('public.zella_admin_routing_missing(integer,integer)') is not null then
    if md5(pg_get_functiondef(to_regprocedure('public.zella_admin_routing_missing(integer,integer)'))) <> 'e3b06eca2cfa77abdcd6d998197e95f8' then
      raise exception 'VERSION_MISMATCH: a different zella_admin_routing_missing already exists';
    end if;
  end if;
end $$;

create or replace function public.zella_admin_routing_missing(p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100); v_offset integer := greatest(coalesce(p_offset, 0), 0); out jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  with routing as (
    select b.id, b.name, b.suspended_at is not null suspended,
           coalesce((cfg.escalation_rules ->> 'transfer_enabled')::boolean, true) transfer_enabled,
           coalesce(nullif(cfg.escalation_rules ->> 'transfer_number', ''), nullif(cfg.escalation_rules #>> '{transfer_to,phone}', '')) is not null has_transfer,
           nullif(cfg.escalation_rules ->> 'fallback_number', '') is not null has_fallback
      from public.businesses b
      join lateral (select ag.id from public.ai_agents ag where ag.business_id = b.id and ag.is_default limit 1) ag on true
      left join public.ai_agent_configs cfg on cfg.agent_id = ag.id
     where b.cancelled_at is null),
  missing as (
    select id, name, suspended, transfer_enabled, transfer_enabled and not has_transfer missing_transfer, not has_fallback missing_fallback
      from routing where (transfer_enabled and not has_transfer) or not has_fallback)
  select jsonb_build_object('total', (select count(*) from missing), 'limit', v_limit, 'offset', v_offset,
           'rows', coalesce((select jsonb_agg(jsonb_build_object('business_id', id, 'name', name, 'suspended', suspended, 'transfer_enabled', transfer_enabled,
                                                                 'missing_transfer', missing_transfer, 'missing_fallback', missing_fallback) order by lower(name), id)
                               from (select * from missing order by lower(name), id limit v_limit offset v_offset) p), '[]'::jsonb))
    into out;
  return out;
end $$;
revoke all on function public.zella_admin_routing_missing(integer, integer) from public, anon;
grant execute on function public.zella_admin_routing_missing(integer, integer) to authenticated, service_role;

commit;
