-- Rollback for sql/zella_knowledge_learning.sql (hand-written): the two functions as in production on 5 Nov 2026.
begin;
CREATE OR REPLACE FUNCTION public.zella_answer_knowledge_gap(p_gap_id uuid, p_answer text, p_kind text DEFAULT 'faq'::text, p_title text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_gap record; v_item uuid;
begin
  select * into v_gap from public.knowledge_gaps where id = p_gap_id for update;
  if not found or not exists (select 1 from public.business_members m where m.business_id = v_gap.business_id and m.user_id = auth.uid() and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_gap.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  if nullif(trim(coalesce(p_answer, '')), '') is null then raise exception 'EMPTY_ANSWER'; end if;
  insert into public.knowledge_items (business_id, kind, title, question, answer, status, gap_id, created_by, approved_by, approved_at)
  values (v_gap.business_id, case when p_kind in ('faq','service','policy','hours','other') then p_kind else 'faq' end,
          coalesce(nullif(trim(p_title), ''), left(v_gap.question, 80)), v_gap.question, trim(p_answer), 'processing', p_gap_id, auth.uid(), auth.uid(), now())
  returning id into v_item;
  update public.knowledge_gaps set status = 'answered', knowledge_item_id = v_item, resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id;
  return v_item;
end $function$

;
CREATE OR REPLACE FUNCTION public.zella_dismiss_knowledge_gap(p_gap_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_business uuid;
begin
  select business_id into v_business from public.knowledge_gaps where id = p_gap_id;
  if v_business is null or not exists (select 1 from public.business_members m where m.business_id = v_business and m.user_id = auth.uid() and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  update public.knowledge_gaps set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id and status = 'open';
  return found;
end $function$

;
drop function if exists public.zella_knowledge_gap_editor(uuid);
commit;
