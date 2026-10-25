-- Zella - knowledge extras (checklist 150, 151, 154, 161). Safe to run more than once. Needs zella_knowledge.sql and zella_website_crawler.sql.
--   * the website reader can now suggest 'product' and 'price' answers (as drafts the owner approves, like every other suggestion)
--   * conflicting answers are found every day: two approved answers about the same thing that disagree are flagged and the owner is told

-- 1. Allow the two new kinds.
do $$
declare c text;
begin
  select conname into c from pg_constraint where conrelid = 'public.knowledge_items'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%''service''%' and pg_get_constraintdef(oid) like '%kind%';
  if c is not null then execute format('alter table public.knowledge_items drop constraint %I', c); end if;
  alter table public.knowledge_items add constraint knowledge_items_kind_check check (kind in ('faq', 'service', 'policy', 'hours', 'other', 'product', 'price'));
end $$;

-- 2. The crawler accepts them.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_website_record_page(uuid,integer,text,text,text,text,text[],jsonb,text)'::regprocedure);
  if d not like '%''product'', ''price''%' then
    d := replace(d, 'v_kind not in (''faq'', ''service'', ''policy'', ''hours'', ''other'')', 'v_kind not in (''faq'', ''service'', ''policy'', ''hours'', ''other'', ''product'', ''price'')');
    if d not like '%''product'', ''price''%' then raise exception 'PATCH_FAILED_RECORD_PAGE'; end if;
    execute d;
  end if;
end $$;

-- 3. Conflicting answers (161). Daily. Flags the newer one; the owner decides which is right.
create or replace function public.zella_detect_knowledge_conflicts()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0; b record; v_biz uuid[] := '{}';
begin
  for r in
    select a.id as older, c.id as newer, a.business_id, a.title
      from public.knowledge_items a
      join public.knowledge_items c on c.business_id = a.business_id and c.kind = a.kind and (c.created_at, c.id) > (a.created_at, a.id)
     where a.status = 'ready' and c.status = 'ready' and c.conflicts_with is null and a.conflicts_with is distinct from c.id
       and (lower(regexp_replace(a.title, '[^a-zA-Z0-9]+', ' ', 'g')) = lower(regexp_replace(c.title, '[^a-zA-Z0-9]+', ' ', 'g')) or a.kind = 'hours')
       and lower(regexp_replace(a.answer, '\s+', ' ', 'g')) <> lower(regexp_replace(c.answer, '\s+', ' ', 'g'))
     limit 100
  loop
    update public.knowledge_items set conflicts_with = r.older where id = r.newer and conflicts_with is null;
    n := n + 1; v_biz := v_biz || r.business_id;
  end loop;
  -- only businesses with a new disagreement are told (not every day for the same one)
  for b in select business_id, count(*) as k from public.knowledge_items where conflicts_with is not null and status = 'ready' and business_id = any (v_biz) group by business_id loop
    perform public.zella_platform_alert('knowledge_conflict', 'Two answers disagree', b.k || ' of your answers disagree with another. Choose which one is right.', 'info', b.business_id, 'knowledge_conflict:' || b.business_id, '{}'::jsonb);
    perform public.zella_notify_owners(b.business_id, 'knowledge_conflict', 'Two of your answers disagree', 'Open the knowledge page and choose which answer is right. The assistant may give mixed answers until you do.', 'warning', 'knowledge');
  end loop;
  return n;
end $$;
revoke all on function public.zella_detect_knowledge_conflicts() from public, anon, authenticated;
grant execute on function public.zella_detect_knowledge_conflicts() to service_role;
