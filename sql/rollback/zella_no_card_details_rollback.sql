-- Undoes sql/zella_no_card_details.sql exactly: zella_brain_prompt(uuid) goes back to production's version
-- (md5(pg_get_functiondef) 87466ed3ae42a7f4767fbcae7de238c0, sql/zella_automation_completion.sql), with its grants.
-- After it, the receptionist's instructions no longer end with the PAYMENT DETAILS section. No rows change.
-- The function must be exactly the migration's version (291dd344249d98c486c88edde1327297) or already production's,
-- otherwise ROLLBACK_DRIFT and nothing changes. Safe to run twice. Run with sql/rollback/run.sh, with the owner's
-- approval (it changes the live receptionist's instructions).
begin;
do $$
declare s constant text := 'public.zella_brain_prompt(uuid)'; h text;
begin
  if to_regprocedure(s) is null then raise exception 'ROLLBACK_DRIFT: % is missing', s; end if;
  h := md5(pg_get_functiondef(s::regprocedure));
  if h = '87466ed3ae42a7f4767fbcae7de238c0' then return; end if;   -- not applied, or already rolled back
  if h <> '291dd344249d98c486c88edde1327297' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration (%)', s, h;
  end if;
  execute $def$CREATE OR REPLACE FUNCTION public.zella_brain_prompt(p_business_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t text; n text;
begin
  t := public.zella_brain_prompt_base(p_business_id);
  select string_agg('- ' || message, E'\n' order by created_at) into n
    from public.live_notices where business_id = p_business_id and cleared_at is null and ends_at > now();
  if n is not null then
    t := t || E'\nRIGHT NOW (this overrides anything above about availability; tell callers when it matters)\n' || n
           || E'\nDo not offer or confirm a booking or table that conflicts with this. Offer another day, a callback, or take a message.\n';
  end if;
  return t;
end $function$
$def$;
  if md5(pg_get_functiondef(s::regprocedure)) <> '87466ed3ae42a7f4767fbcae7de238c0' then
    raise exception 'ROLLBACK_DRIFT: % was not restored exactly', s;
  end if;
  revoke execute on function public.zella_brain_prompt(uuid) from public, anon, authenticated;
  grant execute on function public.zella_brain_prompt(uuid) to service_role;
end $$;
commit;
