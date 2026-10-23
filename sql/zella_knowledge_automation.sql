-- Zella - knowledge automation. Safe to run more than once.
-- Needs zella_knowledge.sql first.
-- Two jobs, both started by the dispatcher only when something is waiting:
--   1. Publish: knowledge an owner added or changed (status 'processing') is checked and marked 'ready'.
--      The assistant only ever uses 'ready' items, read from zella_ready_knowledge() at call time.
--   2. Suggest: for a question the assistant could not answer, an AI drafts an answer from the business's own
--      approved knowledge. It is only a DRAFT: the owner must check and submit it before anything is used.
-- The AI drafting is off until knowledge_ai_live is true and an Anthropic key is added by hand in n8n.

insert into public.platform_settings (key, value) values ('knowledge_ai_live', 'false'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('knowledge_ai_model', '"claude-haiku-5-5"'::jsonb) on conflict (key) do nothing;

-- Open questions that still need a draft, with what the business already told us. Claims nothing unless live.
create or replace function public.zella_claim_gap_drafts(p_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce(public.zella_setting('knowledge_ai_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_model text := coalesce(nullif(trim(public.zella_setting('knowledge_ai_model', '"claude-haiku-5-5"'::jsonb) #>> '{}'), ''), 'claude-haiku-5-5');
  v_res jsonb := '[]'::jsonb; g record; v_biz record;
begin
  if not v_live then return v_res; end if;
  for g in select * from public.zella_claim_gaps_for_suggestion(greatest(1, least(coalesce(p_limit, 5), 20))) loop
    select b.id, b.name, b.suspended_at, b.cancelled_at into v_biz from public.businesses b where b.id = g.business_id;
    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null then
      update public.knowledge_gaps set suggested_at = now(), suggestion_confidence = 'none' where id = g.id;
      continue;
    end if;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'gap_id', g.id, 'question', g.question, 'times_asked', g.times_asked, 'model', v_model,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name),
      'knowledge', coalesce((select jsonb_agg(jsonb_build_object('kind', k.kind, 'title', k.title, 'answer', left(k.answer, 800)))
                               from (select * from public.knowledge_items where business_id = g.business_id and status = 'ready' order by updated_at desc limit 40) k), '[]'::jsonb)));
  end loop;
  return v_res;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_claim_gap_drafts(integer)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- 3. The phone assistant reports a question it could not answer (called through the Vapi tool workflow, during a call).
--    The business comes from the call itself when we know it, otherwise from the business id the call was started with.
--    At most 5 questions per call are kept, and the same question is only ever one review item (it just counts up).
create or replace function public.zella_report_unanswered(p_provider_call_id text, p_business_id uuid, p_question text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_call_id uuid; v_call_biz uuid; v_cust uuid; v_biz uuid; v_q text := left(regexp_replace(trim(coalesce(p_question, '')), '\s+', ' ', 'g'), 500);
begin
  if length(v_q) < 3 then raise exception 'EMPTY_QUESTION'; end if;
  if nullif(p_provider_call_id, '') is not null then
    select c.id, c.business_id, c.customer_id into v_call_id, v_call_biz, v_cust from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call_biz, p_business_id);
  if v_biz is null or not exists (select 1 from public.businesses b where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true)) then
    raise exception 'UNKNOWN_BUSINESS';
  end if;
  if v_call_id is not null and (select count(*) from public.knowledge_gaps g where g.call_id = v_call_id) >= 5 then return null; end if;
  return public.zella_log_knowledge_gap(v_biz, v_q, v_call_id, v_cust);
end $$;
revoke execute on function public.zella_report_unanswered(text, uuid, text) from public, anon, authenticated;
grant execute on function public.zella_report_unanswered(text, uuid, text) to service_role;
