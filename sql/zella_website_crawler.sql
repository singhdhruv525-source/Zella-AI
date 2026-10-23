-- Zella - website knowledge crawler. Safe to run more than once.
-- Needs zella_knowledge.sql and zella_dispatcher.sql (kick trigger) first.
-- The owner adds their own website and approves it. Only approved pages are ever read. Pages found later
-- (sitemap or links on approved pages) wait as "pending" until the owner approves them.
-- Everything found becomes a DRAFT knowledge item the owner must review; nothing goes live by itself.
-- The reading itself (fetching web pages) is done by the n8n workflow "Zella - Website Crawler".

insert into public.platform_settings (key, value) values ('website_crawl_live', 'false'::jsonb) on conflict (key) do nothing;

-- 1. Tables ---------------------------------------------------------------------------------------------------
create table if not exists public.website_sources (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  root_url text not null,
  host text not null,
  status text not null default 'pending_approval' check (status in ('pending_approval', 'active', 'paused')),
  approved_by uuid, approved_at timestamptz,
  auto_approve_new boolean not null default false,
  frequency_hours integer not null default 168 check (frequency_hours between 6 and 720),
  max_pages integer not null default 25 check (max_pages between 1 and 100),
  sitemap_urls text[] not null default '{}',
  next_discovery_at timestamptz, last_discovery_at timestamptz, last_crawl_at timestamptz, last_error text,
  created_at timestamptz not null default now(),
  unique (business_id, host)
);
create table if not exists public.website_pages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  source_id uuid not null references public.website_sources(id) on delete cascade,
  url text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'ignored', 'missing', 'broken')),
  title text, content_hash text, text_excerpt text, http_status integer, fail_count integer not null default 0, last_error text,
  found_via text not null default 'sitemap',
  first_seen_at timestamptz not null default now(), last_seen_at timestamptz, last_fetched_at timestamptz, last_ok_at timestamptz, changed_at timestamptz,
  next_fetch_at timestamptz, claimed_at timestamptz,
  unique (source_id, url)
);
create index if not exists website_pages_due_idx on public.website_pages (next_fetch_at) where status in ('approved', 'broken', 'missing');
create index if not exists website_pages_business_idx on public.website_pages (business_id, status);

alter table public.knowledge_items add column if not exists source_page_id uuid references public.website_pages(id) on delete set null;
alter table public.knowledge_items add column if not exists source_url text;
alter table public.knowledge_items add column if not exists source_key text;
alter table public.knowledge_items add column if not exists conflicts_with uuid;
alter table public.knowledge_items add column if not exists source_stale boolean not null default false;
create index if not exists knowledge_items_source_idx on public.knowledge_items (source_page_id, source_key) where source_page_id is not null;

create table if not exists public.knowledge_versions (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.knowledge_items(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  version integer not null, title text, question text, answer text, status text, changed_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists knowledge_versions_item_idx on public.knowledge_versions (item_id, created_at desc);

alter table public.website_sources enable row level security;
alter table public.website_pages enable row level security;
alter table public.knowledge_versions enable row level security;
drop policy if exists website_sources_read on public.website_sources;
create policy website_sources_read on public.website_sources for select to authenticated using (public.zella_is_member(business_id));
drop policy if exists website_pages_read on public.website_pages;
create policy website_pages_read on public.website_pages for select to authenticated using (public.zella_is_member(business_id));
drop policy if exists knowledge_versions_read on public.knowledge_versions;
create policy knowledge_versions_read on public.knowledge_versions for select to authenticated using (public.zella_is_member(business_id));
grant select on public.website_sources, public.website_pages, public.knowledge_versions to authenticated;

-- Members cannot point a knowledge item at another business's page or fake a website source.
create or replace function public.zella_knowledge_source_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_service boolean := coalesce(auth.role(), 'service_role') = 'service_role' and auth.uid() is null;
begin
  if v_service then return new; end if;
  if tg_op = 'INSERT' then
    new.source_page_id := null; new.source_url := null; new.source_key := null; new.conflicts_with := null; new.source_stale := false;
  else
    new.source_page_id := old.source_page_id; new.source_url := old.source_url; new.source_key := old.source_key; new.conflicts_with := old.conflicts_with;
    -- an owner who edits or approves the item has looked at it, so the "website changed" flag is cleared
    if (new.title, new.answer, new.status) is distinct from (old.title, old.answer, old.status) then new.source_stale := false; else new.source_stale := old.source_stale; end if;
  end if;
  return new;
end $$;
drop trigger if exists zella_knowledge_source_guard_trg on public.knowledge_items;
create trigger zella_knowledge_source_guard_trg before insert or update on public.knowledge_items for each row execute function public.zella_knowledge_source_guard();

-- Version history (163): every change to the words or status of a knowledge item is kept.
create or replace function public.zella_knowledge_version_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or (new.title, new.question, new.answer, new.status, new.version) is distinct from (old.title, old.question, old.answer, old.status, old.version) then
    insert into public.knowledge_versions (item_id, business_id, version, title, question, answer, status, changed_by)
    values (new.id, new.business_id, new.version, new.title, new.question, new.answer, new.status, auth.uid());
  end if;
  return new;
end $$;
drop trigger if exists zella_knowledge_version_log_trg on public.knowledge_items;
create trigger zella_knowledge_version_log_trg after insert or update on public.knowledge_items for each row execute function public.zella_knowledge_version_log();

-- 2. Safe addresses (322). The same rules are applied again in n8n before anything is fetched. ----------------------
create or replace function public.zella_website_url_ok(p_url text) returns boolean
language plpgsql immutable set search_path = public as $$
declare u text := lower(coalesce(p_url, '')); v_host text; v_port text;
begin
  if length(u) < 10 or length(u) > 2000 or u ~ '\s' or u ~ '[<>"''\\]' then return false; end if;
  if u !~ '^https?://[a-z0-9.-]+(:[0-9]{1,5})?(/|\?|$)' then return false; end if;      -- no user@, no brackets (IPv6), no odd characters in the host
  v_host := substring(u from '^https?://([a-z0-9.-]+)');
  v_port := substring(u from '^https?://[a-z0-9.-]+:([0-9]{1,5})');
  if v_port is not null and v_port not in ('80', '443') then return false; end if;
  if v_host !~ '\.' or v_host ~ '^\.|\.$|\.\.' then return false; end if;
  if v_host ~ '^[0-9.]+$' then return false; end if;                                    -- numeric addresses
  if v_host ~ '(^|\.)(localhost|local|internal|lan|home|corp|intranet|localdomain|test|invalid|example)$' then return false; end if;
  if length(v_host) > 253 then return false; end if;
  return true;
end $$;

create or replace function public.zella_website_same_site(p_host text, p_url text) returns boolean
language sql immutable as $$
  select regexp_replace(lower(coalesce(substring(p_url from '^https?://([a-z0-9.-]+)'), '')), '^www\.', '') = regexp_replace(lower(coalesce(p_host, '')), '^www\.', '');
$$;

-- 3. Owner actions --------------------------------------------------------------------------------------------
create or replace function public.zella_website_add_source(p_business_id uuid, p_url text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_url text := regexp_replace(trim(coalesce(p_url, '')), '#.*$', ''); v_host text; v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if v_url !~* '^https?://' then v_url := 'https://' || v_url; end if;
  if not public.zella_website_url_ok(v_url) then raise exception 'BAD_URL'; end if;
  v_host := lower(substring(v_url from '^https?://([a-z0-9.-]+)'));
  if (select count(*) from public.website_sources where business_id = p_business_id) >= 3
     and not exists (select 1 from public.website_sources where business_id = p_business_id and host = regexp_replace(v_host, '^www\.', '')) then raise exception 'TOO_MANY_SITES'; end if;
  insert into public.website_sources (business_id, root_url, host) values (p_business_id, v_url, regexp_replace(v_host, '^www\.', ''))
  on conflict (business_id, host) do update set root_url = excluded.root_url returning id into v_id;
  return v_id;
end $$;

-- Approving the site is the owner confirming "this is my website and Zella may read these pages".
create or replace function public.zella_website_approve_source(p_source_id uuid, p_auto_approve_new boolean default false, p_frequency_hours integer default 168) returns boolean
language plpgsql security definer set search_path = public as $$
declare s public.website_sources%rowtype;
begin
  select * into s from public.website_sources where id = p_source_id;
  if not found or not public.zella_has_role(s.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_website_url_ok(s.root_url) then raise exception 'BAD_URL'; end if;
  update public.website_sources set status = 'active', approved_by = auth.uid(), approved_at = now(), auto_approve_new = coalesce(p_auto_approve_new, false),
         frequency_hours = greatest(6, least(coalesce(p_frequency_hours, 168), 720)), next_discovery_at = now(), last_error = null where id = s.id;
  insert into public.website_pages (business_id, source_id, url, status, found_via, next_fetch_at, last_seen_at)
  values (s.business_id, s.id, s.root_url, 'approved', 'owner', now(), now())
  on conflict (source_id, url) do update set status = 'approved', next_fetch_at = now(), fail_count = 0;
  return true;
end $$;

create or replace function public.zella_website_set_source(p_source_id uuid, p_paused boolean default null, p_auto_approve_new boolean default null, p_frequency_hours integer default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare s public.website_sources%rowtype;
begin
  select * into s from public.website_sources where id = p_source_id;
  if not found or not public.zella_has_role(s.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if s.status = 'pending_approval' then raise exception 'NOT_APPROVED'; end if;
  update public.website_sources set status = case when p_paused is null then status when p_paused then 'paused' else 'active' end,
         auto_approve_new = coalesce(p_auto_approve_new, auto_approve_new),
         frequency_hours = greatest(6, least(coalesce(p_frequency_hours, frequency_hours), 720)) where id = s.id;
  return true;
end $$;

create or replace function public.zella_website_remove_source(p_source_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare s public.website_sources%rowtype;
begin
  select * into s from public.website_sources where id = p_source_id;
  if not found or not public.zella_has_role(s.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  -- stopping a site keeps its history: reading stops, pages are ignored, knowledge made from it stays for the owner to keep or archive
  update public.website_sources set status = 'paused', next_discovery_at = null where id = s.id;
  update public.website_pages set status = 'ignored', next_fetch_at = null where source_id = s.id;
  return true;
end $$;

-- Approve or ignore a page found by the crawler.
create or replace function public.zella_website_set_page(p_page_id uuid, p_approve boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare p public.website_pages%rowtype;
begin
  select * into p from public.website_pages where id = p_page_id;
  if not found or not public.zella_has_role(p.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_approve then
    if not public.zella_website_url_ok(p.url) or not exists (select 1 from public.website_sources s where s.id = p.source_id and s.status <> 'pending_approval' and public.zella_website_same_site(s.host, p.url)) then raise exception 'BAD_URL'; end if;
    update public.website_pages set status = 'approved', fail_count = 0, next_fetch_at = now() where id = p.id;
  else
    update public.website_pages set status = 'ignored', next_fetch_at = null where id = p.id;
  end if;
  return true;
end $$;

-- 4. Work for n8n ----------------------------------------------------------------------------------------------
create or replace function public.zella_website_crawl_live() returns boolean
language sql stable set search_path = public as $$ select coalesce(public.zella_setting('website_crawl_live', 'false'::jsonb) = 'true'::jsonb, false); $$;

create or replace function public.zella_website_claim(p_limit integer default 6) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb := '[]'::jsonb; s record; p record; n integer := 0; v_lim integer := greatest(1, least(coalesce(p_limit, 6), 15));
begin
  if not public.zella_website_crawl_live() then return v; end if;
  perform public.zella_website_mark_stale();     -- stale-knowledge check rides along with every crawl
  -- a claimed job that never reports back (n8n stopped) is simply offered again after an hour
  for s in select ws.* from public.website_sources ws join public.businesses b on b.id = ws.business_id
            where ws.status = 'active' and ws.next_discovery_at <= now() and b.suspended_at is null and b.cancelled_at is null
            order by ws.next_discovery_at limit 3 for update of ws skip locked loop
    update public.website_sources set next_discovery_at = now() + interval '1 hour' where id = s.id;
    v := v || jsonb_build_array(jsonb_build_object('kind', 'discover', 'source_id', s.id, 'host', s.host, 'root_url', s.root_url,
           'url', coalesce(s.sitemap_urls[1], regexp_replace(s.root_url, '^(https?://[^/?]+).*$', '\1') || '/sitemap.xml')));
    n := n + 1;
  end loop;
  for p in select wp.*, ws.host from public.website_pages wp
             join public.website_sources ws on ws.id = wp.source_id and ws.status = 'active'
             join public.businesses b on b.id = wp.business_id and b.suspended_at is null and b.cancelled_at is null
            where wp.status in ('approved', 'broken', 'missing') and wp.next_fetch_at <= now() and (wp.claimed_at is null or wp.claimed_at < now() - interval '10 minutes')
            order by wp.next_fetch_at limit greatest(1, v_lim - n) for update of wp skip locked loop
    update public.website_pages set claimed_at = now(), next_fetch_at = now() + interval '1 hour' where id = p.id;
    v := v || jsonb_build_array(jsonb_build_object('kind', 'page', 'page_id', p.id, 'host', p.host, 'url', p.url));
  end loop;
  return v;
end $$;
revoke execute on function public.zella_website_claim(integer) from public, anon, authenticated;
grant execute on function public.zella_website_claim(integer) to service_role;

-- The sitemap was read: new addresses become pending pages (or approved, if the owner chose that).
create or replace function public.zella_website_record_discovery(p_source_id uuid, p_sitemap_url text, p_urls text[], p_child_sitemaps text[], p_status integer, p_error text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare s public.website_sources%rowtype; u text; v_new integer := 0; v_count integer; v_children text[] := '{}'; v_rest text[]; v_ins integer;
begin
  select * into s from public.website_sources where id = p_source_id;
  if not found or s.status <> 'active' then return 0; end if;
  v_rest := array(select x from unnest(s.sitemap_urls) x where x is distinct from p_sitemap_url);
  if p_error is not null or p_status is null or p_status >= 400 or p_status = 0 then
    update public.website_sources set sitemap_urls = v_rest, last_discovery_at = now(), next_discovery_at = now() + (frequency_hours || ' hours')::interval, last_error = case when coalesce(p_status, 0) = 404 then null else left(coalesce(p_error, 'sitemap HTTP ' || coalesce(p_status::text, 'none')), 200) end where id = s.id;
    return 0;
  end if;
  select count(*) into v_count from public.website_pages where source_id = s.id and status <> 'ignored';
  foreach u in array coalesce(p_urls, '{}') loop
    exit when v_count >= s.max_pages;
    u := regexp_replace(u, '#.*$', '');
    continue when not public.zella_website_url_ok(u) or not public.zella_website_same_site(s.host, u) or u ~* '\.(jpe?g|png|gif|webp|svg|pdf|zip|mp4|mp3|css|js|ico|xml)(\?|$)';
    insert into public.website_pages (business_id, source_id, url, status, found_via, next_fetch_at, last_seen_at)
    values (s.business_id, s.id, u, case when s.auto_approve_new then 'approved' else 'pending' end, 'sitemap', case when s.auto_approve_new then now() end, now())
    on conflict (source_id, url) do update set last_seen_at = now();
    get diagnostics v_ins = row_count;
    if (select first_seen_at > now() - interval '1 minute' from public.website_pages where source_id = s.id and url = u) then v_new := v_new + 1; v_count := v_count + 1; end if;
  end loop;
  foreach u in array coalesce(p_child_sitemaps, '{}') loop
    continue when not public.zella_website_url_ok(u) or not public.zella_website_same_site(s.host, u) or array_length(v_children, 1) >= 5;
    v_children := v_children || u;
  end loop;
  update public.website_sources set sitemap_urls = (select coalesce(array_agg(distinct x), '{}') from unnest(v_rest || v_children) x),
         last_discovery_at = now(), last_error = null,
         next_discovery_at = case when array_length(v_rest || v_children, 1) > 0 then now() else now() + (frequency_hours || ' hours')::interval end where id = s.id;
  if v_new > 0 and not s.auto_approve_new then
    perform public.zella_notify_owners(s.business_id, 'website_new_pages', v_new || ' new page' || case when v_new = 1 then '' else 's' end || ' found on your website',
      'Choose which ones Zella may read. Nothing is read until you approve it.', 'info', 'knowledge');
  end if;
  return v_new;
end $$;
revoke execute on function public.zella_website_record_discovery(uuid, text, text[], text[], integer, text) from public, anon, authenticated;
grant execute on function public.zella_website_record_discovery(uuid, text, text[], text[], integer, text) to service_role;

-- A page was read. p_items are suggestions found on it: [{kind, title, answer, key}].
create or replace function public.zella_website_record_page(p_page_id uuid, p_http_status integer, p_final_url text, p_title text, p_text text, p_hash text,
                                                           p_links text[], p_items jsonb, p_error text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.website_pages%rowtype; s public.website_sources%rowtype; it jsonb; u text; v_kind text; v_title text; v_answer text; v_key text;
        v_new_items integer := 0; v_changed boolean := false; v_ex public.knowledge_items%rowtype; v_other uuid; v_links integer := 0; v_count integer; v_wait integer;
begin
  select * into p from public.website_pages where id = p_page_id;
  if not found or p.status not in ('approved', 'broken', 'missing') then return jsonb_build_object('result', 'ignored'); end if;
  select * into s from public.website_sources where id = p.source_id;
  if not found or s.status <> 'active' then return jsonb_build_object('result', 'ignored'); end if;
  update public.website_pages set claimed_at = null, last_fetched_at = now() where id = p.id;
  update public.website_sources set last_crawl_at = now() where id = s.id;

  -- moved to another address on the same site
  if p_http_status between 300 and 399 then
    if nullif(p_final_url, '') is not null and public.zella_website_url_ok(p_final_url) and public.zella_website_same_site(s.host, p_final_url) and p_final_url <> p.url and p.fail_count < 3
       and not exists (select 1 from public.website_pages where source_id = s.id and url = p_final_url) then
      update public.website_pages set url = p_final_url, fail_count = fail_count + 1, next_fetch_at = now() + interval '1 minute', last_error = 'moved' where id = p.id;
      return jsonb_build_object('result', 'moved');
    end if;
    p_http_status := 0; p_error := coalesce(p_error, 'redirect_not_followed');
  end if;

  if p_http_status between 200 and 299 and p_error is null then
    v_changed := p.content_hash is not null and p.content_hash is distinct from p_hash;
    update public.website_pages set status = 'approved', http_status = p_http_status, fail_count = 0, last_error = null, last_ok_at = now(), last_seen_at = now(),
           title = left(p_title, 200), text_excerpt = left(p_text, 20000), content_hash = p_hash,
           changed_at = case when v_changed then now() else changed_at end,
           next_fetch_at = now() + (s.frequency_hours || ' hours')::interval where id = p.id;

    -- links to other pages on the same site (new-page detection)
    select count(*) into v_count from public.website_pages where source_id = s.id and status <> 'ignored';
    foreach u in array coalesce(p_links, '{}') loop
      exit when v_count >= s.max_pages or v_links >= 25;
      u := regexp_replace(u, '#.*$', '');
      continue when not public.zella_website_url_ok(u) or not public.zella_website_same_site(s.host, u) or u ~* '\.(jpe?g|png|gif|webp|svg|pdf|zip|mp4|mp3|css|js|ico|xml)(\?|$)';
      continue when exists (select 1 from public.website_pages where source_id = s.id and url = u);
      insert into public.website_pages (business_id, source_id, url, status, found_via, next_fetch_at, last_seen_at)
      values (s.business_id, s.id, u, case when s.auto_approve_new then 'approved' else 'pending' end, 'link', case when s.auto_approve_new then now() end, now());
      v_links := v_links + 1; v_count := v_count + 1;
    end loop;
    if v_links > 0 and not s.auto_approve_new then
      perform public.zella_notify_owners(s.business_id, 'website_new_pages', v_links || ' new page' || case when v_links = 1 then '' else 's' end || ' found on your website',
        'Choose which ones Zella may read. Nothing is read until you approve it.', 'info', 'knowledge');
    end if;

    -- the page changed: knowledge made from it needs a second look
    if v_changed then
      update public.knowledge_items set source_stale = true where source_page_id = p.id and status in ('ready', 'processing');
    end if;

    -- suggestions become drafts; a different answer for something already known is a draft that points at the old one
    if jsonb_typeof(p_items) = 'array' then
      for it in select * from jsonb_array_elements(p_items) limit 15 loop
        v_kind := it ->> 'kind'; v_title := left(trim(coalesce(it ->> 'title', '')), 100); v_answer := left(trim(coalesce(it ->> 'answer', '')), 1500);
        v_key := left(coalesce(nullif(trim(it ->> 'key'), ''), v_kind || ':' || lower(v_title)), 120);
        continue when v_kind not in ('faq', 'service', 'policy', 'hours', 'other') or length(v_title) < 3 or length(v_answer) < 8;
        select * into v_ex from public.knowledge_items where source_page_id = p.id and source_key = v_key and status <> 'archived' order by (status = 'draft') desc, updated_at desc limit 1;
        if found then
          if lower(regexp_replace(v_ex.answer, '\s+', ' ', 'g')) = lower(regexp_replace(v_answer, '\s+', ' ', 'g')) then
            update public.knowledge_items set source_stale = false where id = v_ex.id and source_stale;
          elsif v_ex.status = 'draft' then
            update public.knowledge_items set answer = v_answer, title = v_title, source_stale = false where id = v_ex.id;
          else
            insert into public.knowledge_items (business_id, kind, title, question, answer, status, source_page_id, source_url, source_key, conflicts_with)
            select p.business_id, v_kind, v_title, case when v_kind = 'faq' then v_title end, v_answer, 'draft', p.id, p.url, v_key, v_ex.id
             where not exists (select 1 from public.knowledge_items d where d.source_page_id = p.id and d.source_key = v_key and d.status = 'draft');
            if found then v_new_items := v_new_items + 1; end if;
          end if;
        else
          -- opening hours: the website may disagree with hours the owner already wrote by hand
          v_other := null;
          if v_kind = 'hours' then
            select id into v_other from public.knowledge_items where business_id = p.business_id and kind = 'hours' and status = 'ready' and source_page_id is null limit 1;
          end if;
          insert into public.knowledge_items (business_id, kind, title, question, answer, status, source_page_id, source_url, source_key, conflicts_with)
          values (p.business_id, v_kind, v_title, case when v_kind = 'faq' then v_title end, v_answer, 'draft', p.id, p.url, v_key, v_other);
          v_new_items := v_new_items + 1;
        end if;
      end loop;
    end if;
    if v_new_items > 0 or v_changed then
      perform public.zella_notify_owners(s.business_id, 'website_review', case when v_changed then 'Your website changed' else 'Zella found answers on your website' end,
        case when v_changed then 'A page changed. Check the suggested updates before your assistant uses them.' else v_new_items || ' suggested answer' || case when v_new_items = 1 then '' else 's' end || ' are waiting for you to review.' end, 'info', 'knowledge');
    end if;
    perform public.zella_resolve_platform_alerts('website_page_broken', p.business_id, p.id::text, 'Page works again');
    return jsonb_build_object('result', 'ok', 'changed', v_changed, 'new_items', v_new_items, 'new_links', v_links);
  end if;

  -- the page is gone (404/410) or broken (anything else); one failure is not trusted
  update public.website_pages set http_status = nullif(p_http_status, 0), fail_count = fail_count + 1, last_error = left(coalesce(p_error, 'HTTP ' || coalesce(p_http_status::text, 'none')), 200) where id = p.id returning fail_count into v_count;
  v_wait := least(24, v_count * 2);
  if p_http_status in (404, 410) and v_count >= 2 then
    update public.website_pages set status = 'missing', next_fetch_at = now() + interval '7 days' where id = p.id;
    if p.status <> 'missing' then
      update public.knowledge_items set source_stale = true where source_page_id = p.id and status in ('ready', 'processing');
      perform public.zella_notify_owners(s.business_id, 'website_page_removed', 'A page was removed from your website',
        coalesce(p.title, p.url) || ' no longer exists. Answers that came from it may be out of date.', 'warning', 'knowledge');
    end if;
    return jsonb_build_object('result', 'missing');
  elsif v_count >= 3 then
    update public.website_pages set status = 'broken', next_fetch_at = now() + interval '24 hours' where id = p.id;
    if p.status <> 'broken' then
      perform public.zella_platform_alert('website_page_broken', 'A page on a customer website cannot be read', left(p.url || ': ' || coalesce(p_error, 'HTTP ' || coalesce(p_http_status::text, 'none')), 200), 'info', p.business_id, p.id::text);
      perform public.zella_notify_owners(s.business_id, 'website_page_broken', 'A page on your website cannot be read',
        coalesce(p.title, p.url) || ' did not load the last few times. Check that the link still works.', 'warning', 'knowledge');
    end if;
    return jsonb_build_object('result', 'broken');
  end if;
  update public.website_pages set next_fetch_at = now() + (v_wait || ' hours')::interval where id = p.id;
  return jsonb_build_object('result', 'retry');
end $$;
revoke execute on function public.zella_website_record_page(uuid, integer, text, text, text, text, text[], jsonb, text) from public, anon, authenticated;
grant execute on function public.zella_website_record_page(uuid, integer, text, text, text, text, text[], jsonb, text) to service_role;

-- Stale knowledge (165): answers from a website that has not been read successfully for three crawl periods.
create or replace function public.zella_website_mark_stale() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer; b record;
begin
  update public.knowledge_items k set source_stale = true
    from public.website_pages p join public.website_sources s on s.id = p.source_id
   where k.source_page_id = p.id and k.status = 'ready' and not k.source_stale and s.status = 'active'
     and coalesce(p.last_ok_at, p.first_seen_at) < now() - ((s.frequency_hours * 3) || ' hours')::interval;
  get diagnostics n = row_count;
  for b in select business_id, count(*) c from public.knowledge_items where source_stale and status = 'ready' group by 1 loop
    perform public.zella_platform_alert('knowledge_stale', 'Some website answers may be out of date', b.c || ' answers need a check', 'info', b.business_id, 'knowledge_stale:' || b.business_id::text);
  end loop;
  return n;
end $$;
revoke execute on function public.zella_website_mark_stale() from public, anon, authenticated;
grant execute on function public.zella_website_mark_stale() to service_role;

create or replace function public.zella_website_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'live', public.zella_website_crawl_live(),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'url', root_url, 'status', status, 'auto_approve_new', auto_approve_new, 'frequency_hours', frequency_hours,
                'last_crawl_at', last_crawl_at, 'last_error', last_error) order by created_at) from public.website_sources where business_id = p_business_id), '[]'::jsonb),
    'pages', coalesce((select jsonb_object_agg(status, c) from (select status, count(*) c from public.website_pages where business_id = p_business_id group by 1) x), '{}'::jsonb),
    'drafts_waiting', (select count(*) from public.knowledge_items where business_id = p_business_id and status = 'draft' and source_page_id is not null),
    'needs_check', (select count(*) from public.knowledge_items where business_id = p_business_id and source_stale and status = 'ready'));
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_website_add_source(uuid,text)', 'zella_website_approve_source(uuid,boolean,integer)', 'zella_website_set_source(uuid,boolean,boolean,integer)',
                           'zella_website_remove_source(uuid)', 'zella_website_set_page(uuid,boolean)', 'zella_website_status(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  foreach f in array array['zella_website_crawl_live()', 'zella_website_url_ok(text)', 'zella_website_same_site(text,text)', 'zella_knowledge_source_guard()', 'zella_knowledge_version_log()', 'zella_website_mark_stale()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
