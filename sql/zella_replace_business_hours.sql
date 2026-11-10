-- Replace a business's opening hours in one transaction (from CodeRabbit's full review of the edge functions).
-- owner-provision-business (setup wizard, "Hours & services") calls it so a failed insert can't leave the
-- business with no hours. Until this is applied the function falls back to the old delete-then-insert.
-- Safe to run twice. Undo: sql/rollback/zella_replace_business_hours_rollback.sql
begin;

create or replace function public.zella_replace_business_hours(p_business_id uuid, p_hours jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if p_hours is null or jsonb_typeof(p_hours) <> 'array' then
    raise exception 'Invalid hours';
  end if;
  -- Serialize replacements for the same business. Any insert failure rolls back the delete.
  perform 1 from public.businesses where id = p_business_id for update;
  if not found then raise exception 'Business not found'; end if;
  delete from public.business_hours where business_id = p_business_id;
  insert into public.business_hours (business_id, weekday, opens, closes)
    select p_business_id, h.weekday, h.opens, h.closes
    from jsonb_to_recordset(p_hours) as h(weekday smallint, opens time, closes time);
end;
$$;

-- Only the server (the edge function, with the service role) may call it.
revoke all on function public.zella_replace_business_hours(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.zella_replace_business_hours(uuid, jsonb) to service_role;

commit;
