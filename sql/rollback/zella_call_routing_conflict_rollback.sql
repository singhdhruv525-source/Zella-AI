-- Undoes sql/zella_call_routing_conflict.sql exactly: zella_business_for_number goes back to production's version
-- (md5(pg_get_functiondef) 051170698159c7b440ebb7ca62a3a0eb, STABLE, the 4 Nov 2026 baseline text), with its grants.
-- After it, a call whose number and Vapi phone ID name two businesses is routed by the Vapi phone ID again.
-- Every call_routing_conflict platform alert already raised is kept (a rollback never deletes data); resolve them in
-- the admin alerts once the phone number records are corrected.
-- The function must be exactly the migration's version (5f066cb575f536698873724a6e4b65ef) or already production's,
-- otherwise ROLLBACK_DRIFT and nothing changes. Safe to run twice. Run with sql/rollback/run.sh, with the owner's
-- approval.
begin;
do $$
declare s constant text := 'public.zella_business_for_number(text,text,uuid)'; h text;
begin
  if to_regprocedure(s) is null then raise exception 'ROLLBACK_DRIFT: % is missing', s; end if;
  h := md5(pg_get_functiondef(s::regprocedure));
  if h = '051170698159c7b440ebb7ca62a3a0eb' then return; end if;   -- not applied, or already rolled back
  if h <> '5f066cb575f536698873724a6e4b65ef' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration (%)', s, h;
  end if;
  execute $def$CREATE OR REPLACE FUNCTION public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text DEFAULT NULL::text, p_fallback uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_biz uuid; v_e text := public.zella_normalize_e164(p_called_number);
begin
  select n.business_id into v_biz from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
   where n.status = 'active' and b.suspended_at is null and b.cancelled_at is null
     and ((nullif(p_vapi_phone_number_id, '') is not null and n.vapi_phone_number_id = p_vapi_phone_number_id) or (v_e is not null and n.e164 = v_e))
   order by (n.vapi_phone_number_id = p_vapi_phone_number_id) desc nulls last limit 1;
  if v_biz is not null then return v_biz; end if;
  if exists (select 1 from public.business_phone_numbers n where (v_e is not null and n.e164 = v_e) or (nullif(p_vapi_phone_number_id, '') is not null and n.vapi_phone_number_id = p_vapi_phone_number_id)) then return null; end if;
  if p_fallback is not null and exists (select 1 from public.businesses b where b.id = p_fallback and b.suspended_at is null and b.cancelled_at is null) then return p_fallback; end if;
  return null;
end $function$
$def$;
  if md5(pg_get_functiondef(s::regprocedure)) <> '051170698159c7b440ebb7ca62a3a0eb' then
    raise exception 'ROLLBACK_DRIFT: % was not restored exactly', s;
  end if;
  revoke execute on function public.zella_business_for_number(text, text, uuid) from public, anon, authenticated;
  grant execute on function public.zella_business_for_number(text, text, uuid) to service_role;
end $$;
commit;
