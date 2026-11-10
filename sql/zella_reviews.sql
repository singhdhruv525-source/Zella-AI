-- Zella - review replies with owner approval (2026-10-28). Safe to re-run.
-- Needs sql/zella_run_all.sql (zella_notify_owners, zella_setting, zella_can_manage) and sql/zella_dispatcher.sql.
--
-- Every new review gets a reply draft straight away (a short template by star rating that never repeats details from
-- the review: no health, legal or money details, nothing that confirms someone is a patient or client). If AI drafts
-- are switched on (review_ai_live), the AI rewrites it from the review text. Nothing is ever posted without an owner,
-- admin or manager approving the exact words. 1-2 star reviews alert the owners; 5-star ones are celebrated.
-- Reviews come from Google (the n8n workflow "Zella - Review Replies" reads each connected Google Business Profile
-- location and posts approved replies) or are added by hand from any site; a hand-added review's approved reply is
-- copied and posted by the owner.
-- Switches (platform settings, all off): reviews_live (read Google and post approved replies), review_ai_live (AI drafts).
-- Rollback: drop table public.reviews, public.review_sources; drop the zella_review_* functions; re-run zella_dispatcher.sql.

create table if not exists public.review_sources (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  provider text not null default 'google' check (provider = 'google'),
  account_id text not null check (account_id ~ '^[0-9]{1,30}$'),
  location_id text not null check (location_id ~ '^[0-9]{1,30}$'),
  status text not null default 'active' check (status in ('active', 'paused', 'error')),
  last_error text,
  consecutive_failures integer not null default 0,
  last_fetched_at timestamptz,
  next_fetch_at timestamptz not null default now(),
  claimed_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  provider text not null check (provider in ('google', 'manual')),
  external_id text not null check (length(external_id) between 1 and 300),
  site text check (site is null or length(site) <= 40),
  author_name text check (author_name is null or length(author_name) <= 120),
  rating smallint check (rating between 1 and 5),
  body text check (body is null or length(body) <= 5000),
  reviewed_at timestamptz not null default now(),
  status text not null default 'drafted' check (status in ('drafted', 'approved', 'posting', 'posted', 'skipped', 'failed', 'replied_elsewhere')),
  draft text check (draft is null or length(draft) <= 4000),
  draft_source text check (draft_source in ('template', 'ai')),
  ai_status text not null default 'none' check (ai_status in ('none', 'pending', 'done', 'failed')),
  ai_attempts integer not null default 0,
  ai_claimed_at timestamptz,
  reply text check (reply is null or length(reply) between 2 and 4000),
  existing_reply text check (existing_reply is null or length(existing_reply) <= 4096),
  decided_by uuid,
  decided_at timestamptz,
  post_attempts integer not null default 0,
  post_claimed_at timestamptz,
  post_error text,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, provider, external_id)
);
create index if not exists reviews_business_idx on public.reviews (business_id, reviewed_at desc);
create index if not exists reviews_work_idx on public.reviews (status, ai_status) where status in ('drafted', 'approved', 'posting');

alter table public.review_sources enable row level security;
alter table public.reviews enable row level security;
drop policy if exists review_sources_read on public.review_sources;
create policy review_sources_read on public.review_sources for select to authenticated using (public.zella_can_manage(business_id));
drop policy if exists reviews_read on public.reviews;
create policy reviews_read on public.reviews for select to authenticated using (public.zella_can_manage(business_id));
revoke insert, update, delete on public.review_sources, public.reviews from anon, authenticated;

insert into public.platform_settings (key, value) values ('reviews_live', 'false'::jsonb), ('review_ai_live', 'false'::jsonb),
  ('review_ai_model', '"claude-haiku-5-5"'::jsonb) on conflict (key) do nothing;

-- The standard draft. Only the reviewer's first name (when it looks like one) and the business's own name and phone;
-- nothing from the review itself.
create or replace function public.zella_review_template(p_rating integer, p_author text, p_business_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_first text; v_name text; v_phone text; v_hi text;
begin
  v_first := split_part(trim(coalesce(p_author, '')), ' ', 1);
  if v_first !~ '^[[:alpha:]][[:alpha:]''-]{1,29}$' or lower(v_first) in ('a', 'google', 'user', 'anonymous', 'customer') then v_first := null; end if;
  select b.name, coalesce(nullif(b.phone, ''), nullif(b.alternate_phone, '')) into v_name, v_phone from public.businesses b where b.id = p_business_id;
  v_hi := case when v_first is not null then 'Hi ' || v_first || ', thank you' else 'Thank you' end;
  return case
    when p_rating >= 5 then v_hi || ' so much for the kind review! We really appreciate you taking the time, and we look forward to seeing you again.'
    when p_rating = 4 then v_hi || ' for the great review! We''re glad you had a good experience, and we''re always working to make it even better.'
    when p_rating = 3 then v_hi || ' for your feedback. We''d love to hear how we could have made your experience better'
      || coalesce(' - please give us a call at ' || v_phone, '') || '.'
    else case when v_first is not null then 'Hi ' || v_first || ', we''re' else 'We''re' end
      || ' sorry to hear your experience wasn''t what you expected. We take this seriously and would like to make it right. Please contact us'
      || coalesce(' at ' || v_phone, '') || ' so we can talk it through.'
  end;
end $$;
revoke all on function public.zella_review_template(integer, text, uuid) from public, anon, authenticated;

-- New review: standard draft at once, AI rewrite queued when switched on, owners alerted for 1-2 stars.
create or replace function public.zella_review_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'drafted' and new.draft is null then
    new.draft := public.zella_review_template(coalesce(new.rating, 3), new.author_name, new.business_id);
    new.draft_source := 'template';
  end if;
  if new.status = 'drafted' and length(trim(coalesce(new.body, ''))) >= 3
     and coalesce(public.zella_setting('review_ai_live', 'false'::jsonb) = 'true'::jsonb, false) then
    new.ai_status := 'pending';
  end if;
  return new;
end $$;
drop trigger if exists zella_review_before_insert on public.reviews;
create trigger zella_review_before_insert before insert on public.reviews for each row execute function public.zella_review_before_insert();

create or replace function public.zella_review_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'drafted' and new.rating <= 2 then
    begin
      perform public.zella_notify_owners(new.business_id, 'low_review', new.rating || '-star review',
        left(coalesce(new.author_name, 'A customer') || ' left a ' || new.rating || '-star review. A reply draft is ready for you to check.', 300), 'warning', 'reviews');
    exception when others then null; end;
  elsif new.rating = 5 and new.status in ('drafted', 'replied_elsewhere') then
    begin
      perform public.zella_notify(new.business_id, 'five_star_review', '5-star review from ' || coalesce(split_part(new.author_name, ' ', 1), 'a customer'),
        left(coalesce(new.body, 'Five stars, no words needed.'), 300), 'info', 'reviews', new.id);
    exception when others then null; end;
  end if;
  return new;
end $$;
drop trigger if exists zella_review_after_insert on public.reviews;
create trigger zella_review_after_insert after insert on public.reviews for each row execute function public.zella_review_after_insert();
-- Trigger functions run only as triggers; nobody calls them directly.
revoke all on function public.zella_review_before_insert(), public.zella_review_after_insert() from public, anon, authenticated;

-- ---------------------------------------------------------------- owner screens
create or replace function public.zella_reviews_list(p_business_id uuid, p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'source', (select jsonb_build_object('provider', s.provider, 'account_id', s.account_id, 'location_id', s.location_id, 'status', s.status, 'last_fetched_at', s.last_fetched_at, 'last_error', s.last_error)
                 from public.review_sources s where s.business_id = p_business_id),
    'live', coalesce(public.zella_setting('reviews_live', 'false'::jsonb) = 'true'::jsonb, false),
    'ai_live', coalesce(public.zella_setting('review_ai_live', 'false'::jsonb) = 'true'::jsonb, false),
    'counts', (select jsonb_build_object('to_reply', count(*) filter (where status = 'drafted'), 'total', count(*),
                 'average', round(avg(rating)::numeric, 1)) from public.reviews where business_id = p_business_id),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'provider', r.provider, 'site', r.site, 'author_name', r.author_name, 'rating', r.rating,
                   'body', r.body, 'reviewed_at', r.reviewed_at, 'status', r.status, 'draft', r.draft, 'draft_source', r.draft_source,
                   'ai_status', r.ai_status, 'reply', r.reply, 'existing_reply', r.existing_reply, 'decided_at', r.decided_at, 'posted_at', r.posted_at,
                   'post_error', r.post_error) order by (r.status = 'drafted') desc, r.reviewed_at desc)
                  from (select * from public.reviews where business_id = p_business_id and (p_status is null or status = p_status)
                         order by (status = 'drafted') desc, reviewed_at desc limit 200) r), '[]'::jsonb));
end $$;
revoke all on function public.zella_reviews_list(uuid, text) from public, anon;
grant execute on function public.zella_reviews_list(uuid, text) to authenticated;

-- A review from any site, pasted by the owner, to get a reply draft.
create or replace function public.zella_review_add(p_business_id uuid, p_site text, p_author text, p_rating integer, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'INVALID_RATING'; end if;
  if length(trim(coalesce(p_body, ''))) > 5000 then raise exception 'REVIEW_TOO_LONG'; end if;
  if (select count(*) from public.reviews where business_id = p_business_id and provider = 'manual' and created_at > now() - interval '1 day') >= 50 then
    raise exception 'TOO_MANY_REVIEWS';
  end if;
  insert into public.reviews (business_id, provider, external_id, site, author_name, rating, body)
  values (p_business_id, 'manual', gen_random_uuid()::text, nullif(trim(left(coalesce(p_site, ''), 40)), ''), nullif(trim(left(coalesce(p_author, ''), 120)), ''),
          p_rating, nullif(trim(p_body), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.zella_review_add(uuid, text, text, integer, text) from public, anon;
grant execute on function public.zella_review_add(uuid, text, text, integer, text) to authenticated;

-- approve (with the exact words), skip, or reopen. A Google reply is posted by the workflow once reviews_live is on.
create or replace function public.zella_review_decide(p_review_id uuid, p_action text, p_reply text default null)
returns text language plpgsql security definer set search_path = public as $$
declare r public.reviews; v_reply text;
begin
  select * into r from public.reviews where id = p_review_id for update;
  if r.id is null or auth.uid() is null or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_action = 'approve' then
    if r.status not in ('drafted', 'failed') then raise exception 'ALREADY_DECIDED'; end if;
    v_reply := trim(regexp_replace(coalesce(p_reply, ''), '[\x01-\x09\x0B-\x1F\x7F]', '', 'g'));
    if length(v_reply) < 2 or length(v_reply) > 4000 then raise exception 'REPLY_LENGTH'; end if;
    if v_reply ~ '<[a-zA-Z/!]' then raise exception 'REPLY_TEXT'; end if;
    update public.reviews set status = 'approved', reply = v_reply, decided_by = auth.uid(), decided_at = now(), post_error = null,
           post_attempts = 0, updated_at = now() where id = r.id;
    return case when r.provider = 'manual' then 'copy_and_post' when coalesce(public.zella_setting('reviews_live', 'false'::jsonb) = 'true'::jsonb, false)
                 and exists (select 1 from public.review_sources s where s.business_id = r.business_id and s.status = 'active') then 'will_post' else 'waiting_for_google' end;
  elsif p_action = 'skip' then
    if r.status not in ('drafted', 'failed', 'approved') then raise exception 'ALREADY_DECIDED'; end if;
    update public.reviews set status = 'skipped', decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = r.id;
    return 'skipped';
  elsif p_action = 'reopen' then
    if r.status not in ('skipped', 'approved', 'failed') then raise exception 'ALREADY_DECIDED'; end if;
    update public.reviews set status = 'drafted', reply = null, decided_by = null, decided_at = null, updated_at = now() where id = r.id;
    return 'reopened';
  end if;
  raise exception 'INVALID_ACTION';
end $$;
revoke all on function public.zella_review_decide(uuid, text, text) from public, anon;
grant execute on function public.zella_review_decide(uuid, text, text) to authenticated;

-- Connect a Google Business Profile location (the numeric account and location ids from Google). Owners and admins.
-- Zella's Google account must be a manager of the profile; the workflow uses that one Google login for every business.
create or replace function public.zella_review_source_save(p_business_id uuid, p_account_id text, p_location_id text, p_active boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if p_account_id is null or p_location_id is null then
    delete from public.review_sources where business_id = p_business_id;
    return true;
  end if;
  if trim(p_account_id) !~ '^[0-9]{1,30}$' or trim(p_location_id) !~ '^[0-9]{1,30}$' then raise exception 'INVALID_GOOGLE_IDS'; end if;
  insert into public.review_sources (business_id, account_id, location_id, status, created_by)
  values (p_business_id, trim(p_account_id), trim(p_location_id), case when coalesce(p_active, true) then 'active' else 'paused' end, auth.uid())
  on conflict (business_id) do update set account_id = excluded.account_id, location_id = excluded.location_id, status = excluded.status,
    last_error = null, consecutive_failures = 0, next_fetch_at = now(), updated_at = now();
  return true;
end $$;
revoke all on function public.zella_review_source_save(uuid, text, text, boolean) from public, anon;
grant execute on function public.zella_review_source_save(uuid, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------- the n8n workflow (service role only)
-- What is waiting, for the dispatcher (0 unless switched on).
create or replace function public.zella_review_work_waiting() returns integer
language sql stable security definer set search_path = public as $$
  select (case when coalesce(public.zella_setting('reviews_live', 'false'::jsonb) = 'true'::jsonb, false) then
            (select count(*) from public.review_sources where status = 'active' and next_fetch_at <= now() and (claimed_at is null or claimed_at < now() - interval '10 minutes'))
          + (select count(*) from public.reviews r join public.review_sources s on s.business_id = r.business_id and s.status = 'active'
              where r.provider = 'google' and ((r.status = 'approved' and r.post_attempts < 5) or (r.status = 'posting' and r.post_claimed_at < now() - interval '15 minutes')))
          else 0 end
        + case when coalesce(public.zella_setting('review_ai_live', 'false'::jsonb) = 'true'::jsonb, false) then
            (select count(*) from public.reviews where status = 'drafted' and ai_status = 'pending' and ai_attempts < 3 and (ai_claimed_at is null or ai_claimed_at < now() - interval '10 minutes'))
          else 0 end)::integer;
$$;
revoke all on function public.zella_review_work_waiting() from public, anon, authenticated;

create or replace function public.zella_review_claim_fetch(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not coalesce(public.zella_setting('reviews_live', 'false'::jsonb) = 'true'::jsonb, false) then return '[]'::jsonb; end if;
  with c as (
    update public.review_sources s set claimed_at = now()
     where s.business_id in (select business_id from public.review_sources x join public.businesses b on b.id = x.business_id
                              where x.status = 'active' and x.next_fetch_at <= now() and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')
                                and b.suspended_at is null and b.cancelled_at is null
                              order by x.next_fetch_at limit least(greatest(coalesce(p_limit, 10), 1), 25) for update of x skip locked)
    returning s.business_id, s.account_id, s.location_id)
  select coalesce(jsonb_agg(jsonb_build_object('business_id', business_id, 'account_id', account_id, 'location_id', location_id)), '[]'::jsonb) into v from c;
  return v;
end $$;
revoke all on function public.zella_review_claim_fetch(integer) from public, anon, authenticated;

-- The reviews Google returned (already reduced by the workflow to the fields below), or the failure.
-- p_items: [{external_id, author_name, rating 1-5, body, reviewed_at, existing_reply}]
create or replace function public.zella_review_ingest(p_business_id uuid, p_status_code integer, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.review_sources; it jsonb; v_new integer := 0; v_seen integer := 0; v_rating integer; v_ext text; v_ins boolean;
begin
  select * into s from public.review_sources where business_id = p_business_id for update;
  if s.business_id is null then return jsonb_build_object('ok', false, 'reason', 'no_source'); end if;
  if coalesce(p_status_code, 0) not between 200 and 299 or jsonb_typeof(p_items) <> 'array' then
    update public.review_sources set claimed_at = null, consecutive_failures = consecutive_failures + 1,
           last_error = left('Google answered ' || coalesce(p_status_code::text, 'nothing'), 200),
           status = case when consecutive_failures + 1 >= 5 then 'error' else status end,
           next_fetch_at = now() + least(interval '6 hours', interval '15 minutes' * power(2, least(consecutive_failures, 4))), updated_at = now()
     where business_id = p_business_id;
    if s.consecutive_failures + 1 = 5 then
      begin
        perform public.zella_notify_owners(p_business_id, 'reviews_disconnected', 'Google reviews stopped syncing',
          'Zella could not read your Google reviews 5 times in a row. Check that Zella is still a manager of your Google Business Profile.', 'warning', 'reviews');
      exception when others then null; end;
    end if;
    return jsonb_build_object('ok', false, 'reason', 'fetch_failed');
  end if;
  for it in select * from jsonb_array_elements(p_items) limit 200 loop
    v_ext := left(nullif(trim(coalesce(it ->> 'external_id', '')), ''), 300);
    v_rating := case when (it ->> 'rating') ~ '^[1-5]$' then (it ->> 'rating')::integer end;
    continue when v_ext is null or v_rating is null;
    v_seen := v_seen + 1;
    insert into public.reviews (business_id, provider, external_id, site, author_name, rating, body, reviewed_at, existing_reply, status)
    values (p_business_id, 'google', v_ext, 'Google', nullif(left(trim(coalesce(it ->> 'author_name', '')), 120), ''), v_rating,
            nullif(left(trim(coalesce(it ->> 'body', '')), 5000), ''),
            coalesce(case when (it ->> 'reviewed_at') ~ '^\d{4}-\d{2}-\d{2}T' then (it ->> 'reviewed_at')::timestamptz end, now()),
            nullif(left(trim(coalesce(it ->> 'existing_reply', '')), 4096), ''),
            case when nullif(trim(coalesce(it ->> 'existing_reply', '')), '') is not null then 'replied_elsewhere' else 'drafted' end)
    on conflict (business_id, provider, external_id) do update
       set body = excluded.body, rating = excluded.rating, author_name = excluded.author_name, existing_reply = excluded.existing_reply,
           status = case when excluded.existing_reply is not null and public.reviews.status in ('drafted', 'failed') then 'replied_elsewhere' else public.reviews.status end,
           updated_at = now()
     where public.reviews.body is distinct from excluded.body or public.reviews.rating is distinct from excluded.rating
        or public.reviews.existing_reply is distinct from excluded.existing_reply
    returning (xmax = 0) into v_ins;
    if coalesce(v_ins, false) then v_new := v_new + 1; end if;
    v_ins := null;
  end loop;
  update public.review_sources set claimed_at = null, consecutive_failures = 0, last_error = null, status = 'active', last_fetched_at = now(),
         next_fetch_at = now() + interval '6 hours', updated_at = now() where business_id = p_business_id;
  return jsonb_build_object('ok', true, 'seen', v_seen, 'new', v_new);
end $$;
revoke all on function public.zella_review_ingest(uuid, integer, jsonb) from public, anon, authenticated;

create or replace function public.zella_review_claim_ai(p_limit integer default 5) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; v_model text := coalesce(nullif(trim(public.zella_setting('review_ai_model', '"claude-haiku-5-5"'::jsonb) #>> '{}'), ''), 'claude-haiku-5-5');
begin
  if not coalesce(public.zella_setting('review_ai_live', 'false'::jsonb) = 'true'::jsonb, false) then return '[]'::jsonb; end if;
  with c as (
    update public.reviews r set ai_claimed_at = now(), ai_attempts = ai_attempts + 1
     where r.id in (select id from public.reviews where status = 'drafted' and ai_status = 'pending' and ai_attempts < 3
                      and (ai_claimed_at is null or ai_claimed_at < now() - interval '10 minutes')
                    order by created_at limit least(greatest(coalesce(p_limit, 5), 1), 10) for update skip locked)
    returning r.id, r.business_id, r.rating, r.author_name, r.body, r.draft)
  select coalesce(jsonb_agg(jsonb_build_object('review_id', c.id, 'rating', c.rating, 'author_first_name', split_part(coalesce(c.author_name, ''), ' ', 1),
           'body', c.body, 'standard_draft', c.draft, 'model', v_model, 'business', b.name, 'phone', coalesce(nullif(b.phone, ''), b.alternate_phone),
           'industry', (select i.slug from public.industries i where i.id = b.industry_id))), '[]'::jsonb) into v
    from c join public.businesses b on b.id = c.business_id;
  return v;
end $$;
revoke all on function public.zella_review_claim_ai(integer) from public, anon, authenticated;

-- The AI's rewrite. Kept only while nobody has decided yet; an empty or unusable answer keeps the standard draft.
create or replace function public.zella_review_save_ai_draft(p_review_id uuid, p_draft text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_draft, ''));
begin
  if length(v) < 20 or length(v) > 1500 or v ~ '(https?://|www\.|<[a-zA-Z/!])' then
    update public.reviews set ai_status = case when ai_attempts >= 3 then 'failed' else 'pending' end, ai_claimed_at = null, updated_at = now()
     where id = p_review_id and ai_status = 'pending';
    return 'kept_standard';
  end if;
  update public.reviews set draft = v, draft_source = 'ai', ai_status = 'done', ai_claimed_at = null, updated_at = now()
   where id = p_review_id and status = 'drafted' and ai_status = 'pending';
  return case when found then 'saved' else 'already_decided' end;
end $$;
revoke all on function public.zella_review_save_ai_draft(uuid, text) from public, anon, authenticated;

create or replace function public.zella_review_claim_posts(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not coalesce(public.zella_setting('reviews_live', 'false'::jsonb) = 'true'::jsonb, false) then return '[]'::jsonb; end if;
  with c as (
    update public.reviews r set status = 'posting', post_claimed_at = now(), post_attempts = post_attempts + 1, updated_at = now()
     where r.id in (select x.id from public.reviews x join public.review_sources s on s.business_id = x.business_id and s.status = 'active'
                     where x.provider = 'google' and ((x.status = 'approved' and x.post_attempts < 5) or (x.status = 'posting' and x.post_claimed_at < now() - interval '15 minutes'))
                     order by x.decided_at limit least(greatest(coalesce(p_limit, 10), 1), 25) for update of x skip locked)
    returning r.id, r.business_id, r.external_id, r.reply)
  select coalesce(jsonb_agg(jsonb_build_object('review_id', c.id, 'account_id', s.account_id, 'location_id', s.location_id, 'external_id', c.external_id, 'reply', c.reply)), '[]'::jsonb) into v
    from c join public.review_sources s on s.business_id = c.business_id;
  return v;
end $$;
revoke all on function public.zella_review_claim_posts(integer) from public, anon, authenticated;

create or replace function public.zella_review_post_result(p_review_id uuid, p_status_code integer) returns text
language plpgsql security definer set search_path = public as $$
declare r public.reviews;
begin
  select * into r from public.reviews where id = p_review_id and status = 'posting' for update;
  if r.id is null then return 'not_posting'; end if;
  if coalesce(p_status_code, 0) between 200 and 299 then
    update public.reviews set status = 'posted', posted_at = now(), post_error = null, existing_reply = reply, updated_at = now() where id = r.id;
    return 'posted';
  end if;
  update public.reviews set status = case when r.post_attempts >= 5 then 'failed' else 'approved' end,
         post_error = left('Google answered ' || coalesce(p_status_code::text, 'nothing'), 200), updated_at = now() where id = r.id;
  if r.post_attempts >= 5 then
    begin
      perform public.zella_notify_owners(r.business_id, 'review_reply_failed', 'A review reply could not be posted',
        'Zella tried 5 times to post your approved reply on Google. Open Reviews to try again or post it yourself.', 'warning', 'reviews');
    exception when others then null; end;
    return 'failed';
  end if;
  return 'will_retry';
end $$;
revoke all on function public.zella_review_post_result(uuid, integer) from public, anon, authenticated;

grant execute on function public.zella_review_work_waiting(), public.zella_review_claim_fetch(integer), public.zella_review_ingest(uuid, integer, jsonb),
  public.zella_review_claim_ai(integer), public.zella_review_save_ai_draft(uuid, text), public.zella_review_claim_posts(integer),
  public.zella_review_post_result(uuid, integer) to service_role;

create or replace function public.zella_reviews_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('tables', to_regclass('public.reviews') is not null and to_regclass('public.review_sources') is not null,
    'dispatcher_lane', coalesce(pg_get_functiondef(to_regprocedure('public.zella_dispatch_n8n()')) like '%review-replies%', false));
$$;
revoke all on function public.zella_reviews_status() from public, anon, authenticated;
grant execute on function public.zella_reviews_status() to service_role;
