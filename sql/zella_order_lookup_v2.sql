-- Zella - order lookup, revised assurance (5 Nov 2026). Safe to run twice. Not applied. Needs
-- sql/zella_order_lookup_assurance.sql (applied to production on 5 Nov). Policy: docs/ORDER_LOOKUP_ASSURANCE_2026-11-05.md.
-- Class V. Deploy order: this file, then the voice-rules function of the same date (its lookup passes p_order_ref, which
-- only the new overloads below take; the deployed function keeps using the old ones and keeps working).
--
-- O4  Levels: none / recipient (shipping phone only) / one_factor (buyer phone or order email) / two_factor (both).
--     Recorded as found_recipient / found_one_factor / found_two_factor; the report counts each.
-- O5  Two more limits on lookups that didn't match: 5 a day against one order number (emails guessed from many phones)
--     and 30 an hour for the business (many phones, many order numbers). The order number is counted as a 32-character
--     SHA-256 prefix of business id + number, never stored as given (short sequential numbers can still be guessed from
--     it, so it is a counter key, not a secret).
-- O6  The assistant's tool description says what a caller needs and that tracking numbers are never read out.

alter table public.ai_tool_calls add column if not exists lookup_ref text;
create index if not exists ai_tool_calls_lookup_ref_idx on public.ai_tool_calls (business_id, lookup_ref, created_at) where tool = 'lookup_order';

create or replace function public.zella_store_lookup_context(p_provider_call_id text, p_business_id uuid, p_order_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb := public.zella_store_lookup_context(p_provider_call_id, p_business_id);
begin
  if coalesce((c ->> 'ok')::boolean, false) is not true then return c; end if;
  return c || jsonb_build_object(
    'failed_this_order_day', (select count(*) from public.ai_tool_calls t where t.business_id = p_business_id and t.tool = 'lookup_order'
                               and t.lookup_ref = left(p_order_ref, 64) and t.created_at > now() - interval '1 day' and t.result_status in ('unverified', 'not_found')),
    'failed_business_hour', (select count(*) from public.ai_tool_calls t where t.business_id = p_business_id and t.tool = 'lookup_order'
                               and t.created_at > now() - interval '1 hour' and t.result_status in ('unverified', 'not_found')));
end $$;

create or replace function public.zella_store_lookup_log(p_business_id uuid, p_provider_call_id text, p_integration_id uuid, p_result text, p_verified boolean, p_order_ref text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.ai_tool_calls (business_id, provider_call_id, tool, arg_keys, status, result_status, verified, finished_at, lookup_ref)
  values (p_business_id, left(p_provider_call_id, 200), 'lookup_order', array['order_number'], 'done', left(p_result, 40), p_verified, now(), left(p_order_ref, 64));
  if p_integration_id is not null and p_result <> 'limited' then
    if p_result in ('store_unauthorized', 'store_error') then
      update public.integrations set error_count = error_count + 1, last_error = p_result, last_checked_at = now(),
             status = case when p_result = 'store_unauthorized' then 'error' else status end where id = p_integration_id;
    else
      update public.integrations set error_count = 0, last_error = null, last_checked_at = now(), last_synced_at = now() where id = p_integration_id;
    end if;
  end if;
end $$;

revoke execute on function public.zella_store_lookup_context(text, uuid, text), public.zella_store_lookup_log(uuid, text, uuid, text, boolean, text) from public, anon, authenticated;
grant execute on function public.zella_store_lookup_context(text, uuid, text), public.zella_store_lookup_log(uuid, text, uuid, text, boolean, text) to service_role;

create or replace function public.zella_order_lookup_report(p_business_id uuid, p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' and not exists (select 1 from public.business_members m where m.business_id = p_business_id
       and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  return coalesce((select jsonb_agg(d order by d ->> 'day' desc) from (
    select jsonb_build_object('day', created_at::date,
      'given_two_factor', count(*) filter (where result_status = 'found_two_factor'),
      'given_one_factor', count(*) filter (where result_status in ('found_one_factor', 'found_caller_id', 'found_email')),
      'given_recipient', count(*) filter (where result_status = 'found_recipient'),
      'given_before_levels', count(*) filter (where result_status = 'found'),
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
  if position('zella_order_lookup_v2' in def) = 0 then
    def := replace(def, $a$'Look up the status of the caller''s order in the business''s store. Needs the order number; if the caller is not calling from the number on the order, also ask for the email address used for the order. Only status and tracking can be shared.'$a$,
      $a$'Look up the status of the caller''s order in the business''s store (zella_order_lookup_v2). Needs the order number; ask for the email address used for the order too, because more can be shared when both the phone and the email match. Say only what the tool returns. Never read out a tracking number; offer to have the team send tracking to the phone or email on the order.'$a$);
    if position('zella_order_lookup_v2' in def) = 0 then raise exception 'zella_brain_tool_defs has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
