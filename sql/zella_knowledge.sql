-- =========================================================
-- Zella: approved knowledge + knowledge-gap review queue.
-- Run AFTER zella_crm_details.sql. Safe to run again.
--
--  * The AI only ever uses knowledge with status 'ready'.
--  * Any change to an FAQ, service or policy puts it back to
--    'processing' (new version) until n8n has pushed it to the
--    business's assistant and confirmed it - nothing goes live unchecked.
--  * When the AI can't answer, the question lands in "review"; the
--    owner approves an answer and it becomes new knowledge.
-- =========================================================

create table if not exists public.knowledge_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null default 'faq' check (kind in ('faq', 'service', 'policy', 'hours', 'other')),
  title text not null,
  question text,
  answer text not null,
  status text not null default 'processing'
    check (status in ('draft', 'processing', 'ready', 'failed', 'archived')),
  version integer not null default 1,
  error text,
  gap_id uuid,
  created_by uuid,
  approved_by uuid,
  approved_at timestamptz,
  ready_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists knowledge_items_business_idx on public.knowledge_items (business_id, status, updated_at desc);

create table if not exists public.knowledge_gaps (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  call_id uuid,
  customer_id uuid,
  question text not null,
  question_key text not null,
  times_asked integer not null default 1,
  status text not null default 'open' check (status in ('open', 'answered', 'dismissed')),
  knowledge_item_id uuid,
  notified_at timestamptz,
  resolved_by uuid,
  resolved_at timestamptz,
  first_asked_at timestamptz not null default now(),
  last_asked_at timestamptz not null default now()
);
-- one open review item per distinct question
create unique index if not exists knowledge_gaps_open_question_idx
  on public.knowledge_gaps (business_id, question_key) where status = 'open';
create index if not exists knowledge_gaps_business_idx on public.knowledge_gaps (business_id, status, last_asked_at desc);

alter table public.knowledge_items enable row level security;
alter table public.knowledge_gaps enable row level security;

drop policy if exists knowledge_items_member_select on public.knowledge_items;
create policy knowledge_items_member_select on public.knowledge_items for select to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = knowledge_items.business_id and m.user_id = auth.uid() and m.status = 'active'));
drop policy if exists knowledge_items_member_insert on public.knowledge_items;
create policy knowledge_items_member_insert on public.knowledge_items for insert to authenticated
  with check (exists (select 1 from public.business_members m where m.business_id = knowledge_items.business_id and m.user_id = auth.uid() and m.status = 'active'));
drop policy if exists knowledge_items_member_update on public.knowledge_items;
create policy knowledge_items_member_update on public.knowledge_items for update to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = knowledge_items.business_id and m.user_id = auth.uid() and m.status = 'active'))
  with check (exists (select 1 from public.business_members m where m.business_id = knowledge_items.business_id and m.user_id = auth.uid() and m.status = 'active'));

drop policy if exists knowledge_gaps_member_select on public.knowledge_gaps;
create policy knowledge_gaps_member_select on public.knowledge_gaps for select to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = knowledge_gaps.business_id and m.user_id = auth.uid() and m.status = 'active'));

-- The browser can read gaps and edit knowledge text, but status/readiness
-- columns are controlled by the trigger and the functions below.
revoke all on public.knowledge_items, public.knowledge_gaps from anon;
revoke insert, update, delete on public.knowledge_gaps from authenticated;
revoke delete on public.knowledge_items from authenticated;
grant select on public.knowledge_gaps to authenticated;
grant select, insert, update on public.knowledge_items to authenticated;

-- Members cannot mark things ready or forge approval: the trigger decides.
create or replace function public.zella_knowledge_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_service boolean := coalesce(auth.role(), 'service_role') = 'service_role' and auth.uid() is null;
begin
  if tg_op = 'INSERT' then
    if not v_service then
      new.status := case when new.status = 'draft' then 'draft' else 'processing' end;
      new.version := 1; new.error := null; new.ready_at := null;
      new.created_by := auth.uid();
      if new.status = 'processing' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    end if;
    return new;
  end if;

  if not v_service then
    -- members may change content, archive, or send a draft for processing; nothing else
    if new.status not in ('draft', 'processing', 'archived') then
      new.status := old.status;
    end if;
    if new.status = 'ready' or (old.status = 'ready' and new.status = 'ready') then new.status := old.status; end if;
    new.ready_at := old.ready_at; new.error := old.error; new.version := old.version;
    new.business_id := old.business_id; new.created_by := old.created_by; new.gap_id := old.gap_id;
    if (new.title, new.question, new.answer, new.kind) is distinct from (old.title, old.question, old.answer, old.kind)
       and new.status <> 'archived' then
      -- changed content is never live until it has been processed again
      new.status := case when old.status = 'draft' and new.status = 'draft' then 'draft' else 'processing' end;
      new.version := old.version + 1; new.error := null; new.ready_at := null;
      if new.status = 'processing' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    elsif old.status = 'draft' and new.status = 'processing' then
      new.approved_by := auth.uid(); new.approved_at := now(); new.version := old.version + 1;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists zella_knowledge_guard_trg on public.knowledge_items;
create trigger zella_knowledge_guard_trg before insert or update on public.knowledge_items
  for each row execute function public.zella_knowledge_guard();

-- n8n (service role): the assistant calls this when it cannot answer.
create or replace function public.zella_log_knowledge_gap(
  p_business_id uuid, p_question text, p_call_id uuid default null, p_customer_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_key text := trim(lower(regexp_replace(coalesce(p_question, ''), '[^a-zA-Z0-9]+', ' ', 'g'))); v_id uuid;
begin
  if v_key = '' then raise exception 'EMPTY_QUESTION'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'BUSINESS_NOT_FOUND'; end if;
  insert into public.knowledge_gaps (business_id, call_id, customer_id, question, question_key)
  values (p_business_id, p_call_id, p_customer_id, left(trim(p_question), 500), left(v_key, 300))
  on conflict (business_id, question_key) where status = 'open'
  do update set times_asked = knowledge_gaps.times_asked + 1, last_asked_at = now(),
                call_id = coalesce(excluded.call_id, knowledge_gaps.call_id)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------
-- Zella drafts an answer for each gap; the owner only checks and submits.
-- A draft is never used by the AI until the owner submits it.
-- ---------------------------------------------------------
alter table public.knowledge_gaps
  add column if not exists suggested_title text,
  add column if not exists suggested_answer text,
  add column if not exists suggested_kind text,
  add column if not exists suggestion_source text,
  add column if not exists suggestion_confidence text check (suggestion_confidence in ('high', 'low', 'none')),
  add column if not exists suggestion_attempts integer not null default 0,
  add column if not exists suggested_at timestamptz;

-- n8n (service role): open questions that still need a draft (max 3 tries each).
create or replace function public.zella_claim_gaps_for_suggestion(p_limit integer default 10)
returns table (id uuid, business_id uuid, question text, times_asked integer)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with picked as (
    select g.id from public.knowledge_gaps g
     where g.status = 'open' and g.suggested_at is null and g.suggestion_attempts < 3
     order by g.times_asked desc, g.first_asked_at
     limit greatest(1, least(coalesce(p_limit, 10), 50))
     for update skip locked
  )
  update public.knowledge_gaps g set suggestion_attempts = g.suggestion_attempts + 1
    from picked where g.id = picked.id
  returning g.id, g.business_id, g.question, g.times_asked;
end $$;

-- n8n (service role): save the draft. 'none' = not enough information to
-- suggest anything (the owner then writes it themselves).
create or replace function public.zella_set_gap_suggestion(
  p_gap_id uuid, p_answer text, p_title text default null, p_kind text default 'faq',
  p_source text default null, p_confidence text default 'low'
) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_confidence not in ('high', 'low', 'none') then raise exception 'BAD_CONFIDENCE'; end if;
  update public.knowledge_gaps
     set suggested_answer = case when p_confidence = 'none' then null else nullif(trim(coalesce(p_answer, '')), '') end,
         suggested_title = left(nullif(trim(coalesce(p_title, '')), ''), 120),
         suggested_kind = case when p_kind in ('faq','service','policy','hours','other') then p_kind else 'faq' end,
         suggestion_source = left(p_source, 300),
         suggestion_confidence = case when nullif(trim(coalesce(p_answer, '')), '') is null then 'none' else p_confidence end,
         suggested_at = now()
   where id = p_gap_id and status = 'open';
  return found;
end $$;

-- Owner approves an answer for a gap: it becomes new knowledge (processing).
create or replace function public.zella_answer_knowledge_gap(
  p_gap_id uuid, p_answer text, p_kind text default 'faq', p_title text default null
) returns uuid language plpgsql security definer set search_path = public as $$
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
end $$;

create or replace function public.zella_dismiss_knowledge_gap(p_gap_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_business uuid;
begin
  select business_id into v_business from public.knowledge_gaps where id = p_gap_id;
  if v_business is null or not exists (select 1 from public.business_members m where m.business_id = v_business and m.user_id = auth.uid() and m.status = 'active') then
    raise exception 'NOT_ALLOWED';
  end if;
  update public.knowledge_gaps set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id and status = 'open';
  return found;
end $$;

-- n8n (service role): take knowledge waiting to be pushed to the assistant.
create or replace function public.zella_claim_knowledge_updates(p_limit integer default 20)
returns setof public.knowledge_items language plpgsql security definer set search_path = public as $$
begin
  return query
  select k.* from public.knowledge_items k
   where k.status = 'processing'
   order by k.updated_at limit greatest(1, least(coalesce(p_limit, 20), 100))
   for update skip locked;
end $$;

-- n8n (service role): confirm the assistant has the new version. A
-- stale result (the text changed again meanwhile) is ignored, so old
-- text can never be marked ready.
create or replace function public.zella_complete_knowledge_update(
  p_item_id uuid, p_version integer, p_ok boolean, p_error text default null
) returns text language plpgsql security definer set search_path = public as $$
declare v_item record;
begin
  select * into v_item from public.knowledge_items where id = p_item_id for update;
  if not found then raise exception 'ITEM_NOT_FOUND'; end if;
  if v_item.version <> p_version or v_item.status <> 'processing' then return 'stale'; end if;
  if p_ok then
    update public.knowledge_items set status = 'ready', ready_at = now(), error = null where id = p_item_id;
    return 'ready';
  end if;
  update public.knowledge_items set status = 'failed', error = left(coalesce(p_error, 'Could not be processed'), 500) where id = p_item_id;
  return 'failed';
end $$;

-- What the assistant may use: ready items only.
create or replace function public.zella_ready_knowledge(p_business_id uuid)
returns table (id uuid, kind text, title text, question text, answer text, version integer)
language sql stable security definer set search_path = public as $$
  select k.id, k.kind, k.title, k.question, k.answer, k.version
    from public.knowledge_items k
   where k.business_id = p_business_id and k.status = 'ready'
     and (auth.uid() is null or exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active'))
   order by k.kind, k.title;
$$;

revoke all on function public.zella_knowledge_guard() from public, anon, authenticated;
revoke all on function public.zella_log_knowledge_gap(uuid, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.zella_claim_knowledge_updates(integer) from public, anon, authenticated;
revoke all on function public.zella_complete_knowledge_update(uuid, integer, boolean, text) from public, anon, authenticated;
revoke all on function public.zella_answer_knowledge_gap(uuid, text, text, text) from public, anon;
revoke all on function public.zella_dismiss_knowledge_gap(uuid) from public, anon;
revoke all on function public.zella_ready_knowledge(uuid) from public, anon;
grant execute on function public.zella_log_knowledge_gap(uuid, text, uuid, uuid) to service_role;
grant execute on function public.zella_claim_knowledge_updates(integer) to service_role;
grant execute on function public.zella_complete_knowledge_update(uuid, integer, boolean, text) to service_role;
grant execute on function public.zella_answer_knowledge_gap(uuid, text, text, text) to authenticated, service_role;
grant execute on function public.zella_dismiss_knowledge_gap(uuid) to authenticated, service_role;
grant execute on function public.zella_ready_knowledge(uuid) to authenticated, service_role;
revoke all on function public.zella_claim_gaps_for_suggestion(integer) from public, anon, authenticated;
revoke all on function public.zella_set_gap_suggestion(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_claim_gaps_for_suggestion(integer) to service_role;
grant execute on function public.zella_set_gap_suggestion(uuid, text, text, text, text, text) to service_role;
