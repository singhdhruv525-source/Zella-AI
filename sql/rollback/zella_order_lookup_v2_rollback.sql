-- Undoes sql/zella_order_lookup_v2.sql (hand-written; tests/orders/run_v2.sh checks it restores the functions exactly).
-- The lookup records keep their found_<level> results and their order references are dropped with the column.
\set ON_ERROR_STOP on
begin;
drop function if exists public.zella_store_lookup_context(text, uuid, text);
drop function if exists public.zella_store_lookup_log(uuid, text, uuid, text, boolean, text);
drop index if exists public.ai_tool_calls_lookup_ref_idx;
alter table public.ai_tool_calls drop column if exists lookup_ref;
-- the report as sql/zella_order_lookup_assurance.sql has it
create or replace function public.zella_order_lookup_report(p_business_id uuid, p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' and not exists (select 1 from public.business_members m where m.business_id = p_business_id
       and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  return coalesce((select jsonb_agg(d order by d ->> 'day' desc) from (
    select jsonb_build_object('day', created_at::date,
      'given_caller_id', count(*) filter (where result_status = 'found_caller_id'),
      'given_email', count(*) filter (where result_status = 'found_email'),
      'given_before_levels', count(*) filter (where result_status = 'found'),   -- recorded before this change
      'not_matched', count(*) filter (where result_status in ('unverified', 'not_found')),
      'stopped_by_limit', count(*) filter (where result_status = 'limited'),
      'store_problem', count(*) filter (where result_status in ('store_error', 'store_unauthorized'))) d
      from public.ai_tool_calls where business_id = p_business_id and tool = 'lookup_order'
       and created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 366))
     group by created_at::date) x), '[]'::jsonb);
end $$;
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_brain_tool_defs()'::regprocedure);
  if position('zella_order_lookup_v2' in def) > 0 then
    def := replace(def, $a$'Look up the status of the caller''s order in the business''s store (zella_order_lookup_v2). Needs the order number; ask for the email address used for the order too, because more can be shared when both the phone and the email match. Say only what the tool returns. Never read out a tracking number; offer to have the team send tracking to the phone or email on the order.'$a$, $a$'Look up the status of the caller''s order in the business''s store. Needs the order number; if the caller is not calling from the number on the order, also ask for the email address used for the order. Only status and tracking can be shared.'$a$);
    if position('zella_order_lookup_v2' in def) > 0 then raise exception 'zella_brain_tool_defs: could not remove this patch'; end if;
    execute def;
  end if;
end $$;
commit;
