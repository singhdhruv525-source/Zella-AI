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
