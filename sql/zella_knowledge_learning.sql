-- Learning from calls: who may turn a caller's unanswered question into an answer the receptionist uses.
-- Safe to run twice. Rollback: sql/rollback/zella_knowledge_learning_rollback.sql.
--
-- K4  zella_answer_knowledge_gap and zella_dismiss_knowledge_gap run with the definer's rights and only checked that the
--     caller is an active member. A viewer (read-only; refused by the knowledge_items policies) could publish an answer
--     the receptionist then gives to callers, or dismiss the question, and both skipped the MFA rule every other
--     knowledge write is held to. Now they follow the same rule as editing Knowledge directly: an active member who is
--     not a viewer, with MFA satisfied. The answer goes through the same save-time check (sql/zella_knowledge_live.sql)
--     and is recorded as approved by that person.
--     Suggestions written by the knowledge workflow (zella_set_gap_suggestion, server only) stay on the question; they
--     never reach callers until a person answers with them.

create or replace function public.zella_knowledge_gap_editor(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active')
     and not public.zella_has_role(p_business_id, array['viewer'])
     and public.zella_mfa_satisfied()
$$;
revoke execute on function public.zella_knowledge_gap_editor(uuid) from public, anon;
grant execute on function public.zella_knowledge_gap_editor(uuid) to authenticated, service_role;

create or replace function public.zella_answer_knowledge_gap(p_gap_id uuid, p_answer text, p_kind text default 'faq', p_title text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_gap record; v_item uuid;
begin
  select * into v_gap from public.knowledge_gaps where id = p_gap_id for update;
  if not found or not public.zella_knowledge_gap_editor(v_gap.business_id) then   -- zella_gap_editor_check
    raise exception 'NOT_ALLOWED';
  end if;
  if v_gap.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  if nullif(trim(coalesce(p_answer, '')), '') is null then raise exception 'EMPTY_ANSWER'; end if;
  insert into public.knowledge_items (business_id, kind, title, question, answer, status, gap_id, created_by, approved_by, approved_at)
  values (v_gap.business_id, case when p_kind in ('faq','service','policy','hours','other','product','price') then p_kind else 'faq' end,
          coalesce(nullif(trim(p_title), ''), left(v_gap.question, 80)), v_gap.question, trim(p_answer), 'processing', p_gap_id, auth.uid(), auth.uid(), now())
  returning id into v_item;
  update public.knowledge_gaps set status = 'answered', knowledge_item_id = v_item, resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id;
  return v_item;
end $$;

create or replace function public.zella_dismiss_knowledge_gap(p_gap_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_business uuid;
begin
  select business_id into v_business from public.knowledge_gaps where id = p_gap_id;
  if v_business is null or not public.zella_knowledge_gap_editor(v_business) then   -- zella_gap_editor_check
    raise exception 'NOT_ALLOWED';
  end if;
  update public.knowledge_gaps set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id and status = 'open';
  return found;
end $$;
