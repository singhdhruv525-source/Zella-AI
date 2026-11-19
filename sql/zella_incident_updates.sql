-- Zella Voice: incident updates, editing an open incident, and a warning before opening a second one for the same
-- problem (docs/ADMIN_AUDIT_2026-11-16.md OPS-12, OPS-11).
--   1. platform_incident_updates: a timeline of progress notes on an incident. Internal: read by admins who can see
--      incidents (businesses.view), written only through zella_incident_post_update.
--   2. zella_incident_post_update(incident, body, notify, ref): support.manage, open incidents only; the page's own id
--      for the update (ref) makes a repeat after a lost response return the saved update instead of a second one. The owners of every
--      active business are told in the app (never by email or text) ONLY when notify is true ("Tell all active
--      businesses", off by default: routine notes never message owners).
--      Incidents don't record which businesses they affect, so the notice goes to all active businesses. Audited as
--      platform.incident_updated.
--   3. zella_incident_edit(incident, title, detail): support.manage, open incidents only; audited as
--      platform.incident_edited with before and after. Nobody is notified.
--   4. zella_open_incident_checked(title, detail, force): the same as zella_open_incident, but first returns the open
--      incidents that look like the same problem (SIMILAR_OPEN) unless force is true. zella_open_incident itself is
--      not changed, so an older web app keeps working whatever the deploy order.
-- Needs sql/zella_admin_permissions.sql applied first (zella_admin_can). Every function is new; each must be absent or
-- exactly this file's version, otherwise the file stops with VERSION_MISMATCH. Running it twice changes nothing.
-- Not here: showing updates on the public status page (zella_public_status is unchanged).
-- Rollback: sql/rollback/zella_incident_updates_rollback.sql (refuses on drift and while updates exist).
begin;

do $$
declare f record;
begin
  if to_regclass('public.platform_incidents') is null or to_regprocedure('public.zella_admin_can(text)') is null
     or to_regprocedure('public.zella_open_incident(text,text)') is null
     or to_regprocedure('public.zella_notify_owners(uuid,text,text,text,text,text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_admin_permissions.sql first)';
  end if;
  -- editing an incident's title must never change what /status shows: the public page shows only the approved public
  -- message (production's zella_public_status, and sql/zella_status_honest.sql), never the internal title
  if to_regprocedure('public.zella_public_status()') is not null
     and position('i.title' in pg_get_functiondef('public.zella_public_status()'::regprocedure)) > 0 then
    raise exception 'VERSION_MISMATCH: zella_public_status shows incident titles; it must show only the public message';
  end if;
  -- a table already there must be this file's own (its mark, below) and exactly its shape, or nothing is installed
  if to_regclass('public.platform_incident_updates') is not null
     and obj_description(to_regclass('public.platform_incident_updates'), 'pg_class') is distinct from 'zella_incident_updates.sql' then
    raise exception 'VERSION_MISMATCH: a platform_incident_updates table this file did not create already exists';
  end if;
  if to_regclass('public.platform_incident_updates') is not null and (
       select string_agg(column_name || ' ' || data_type, ', ' order by column_name) from information_schema.columns
        where table_schema = 'public' and table_name = 'platform_incident_updates')
     is distinct from 'body text, client_ref uuid, created_at timestamp with time zone, created_by uuid, id uuid, incident_id uuid, notified_businesses integer' then
    raise exception 'VERSION_MISMATCH: a different platform_incident_updates table already exists';
  end if;
  -- the replay index, when already there, must enforce one update per incident and page id
  if to_regclass('public.platform_incident_updates_client_ref_idx') is not null and not coalesce((
       select i.indisunique and i.indisvalid and i.indnatts = 2 and i.indnkeyatts = 2 and i.indexprs is null and i.indrelid = to_regclass('public.platform_incident_updates')
          and (select string_agg(coalesce(a.attname, '?'), ',' order by k.n) from unnest(i.indkey) with ordinality k(attnum, n)
                left join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum) = 'incident_id,client_ref'
          and pg_get_expr(i.indpred, i.indrelid) = '(client_ref IS NOT NULL)'
         from pg_index i where i.indexrelid = to_regclass('public.platform_incident_updates_client_ref_idx')), false) then
    raise exception 'VERSION_MISMATCH: platform_incident_updates_client_ref_idx is not the unique index this file creates';
  end if;
  for f in select * from (values
      ('public.zella_incident_post_update(uuid,text,boolean,uuid)', 'e7e5bb22ad48b14d09b41536783ff248'),
      ('public.zella_incident_edit(uuid,text,text)', 'e0215d925eed949c81af4ee8d21ac576'),
      ('public.zella_incident_title_key(text)', '4980429f996f03a32006003ada23cad3'),
      ('public.zella_open_incident_checked(text,text,boolean)', '60baa4d2414a8001635ead319ee6b4e2')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in a version this file was not written for', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.platform_incident_updates (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.platform_incidents(id) on delete cascade,
  body text not null check (length(btrim(body)) between 3 and 1000),
  notified_businesses integer not null default 0,
  created_by uuid,
  -- the page's own id for an update, so sending the same update again (a lost response) saves and notifies once
  client_ref uuid,
  created_at timestamptz not null default now()
);
-- the mark the rollback relies on: this table is this file's (it never drops a table it can't prove it created)
comment on table public.platform_incident_updates is 'zella_incident_updates.sql';
create unique index if not exists platform_incident_updates_client_ref_idx on public.platform_incident_updates (incident_id, client_ref) where client_ref is not null;
create index if not exists platform_incident_updates_incident_idx on public.platform_incident_updates (incident_id, created_at);
alter table public.platform_incident_updates enable row level security;
revoke all on table public.platform_incident_updates from public, anon, authenticated;
grant select on table public.platform_incident_updates to authenticated;
grant all on table public.platform_incident_updates to service_role;
drop policy if exists platform_incident_updates_admin_view on public.platform_incident_updates;
create policy platform_incident_updates_admin_view on public.platform_incident_updates for select to authenticated
  using ((select public.zella_admin_can('businesses.view')));
drop policy if exists zella_mfa_required on public.platform_incident_updates;
create policy zella_mfa_required on public.platform_incident_updates as restrictive for all to authenticated
  using ((select public.zella_mfa_satisfied())) with check ((select public.zella_mfa_satisfied()));

-- the words of a title, for spotting the same problem twice ("SMS delayed!" and "sms delayed")
create or replace function public.zella_incident_title_key(p text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g'));
$$;
revoke all on function public.zella_incident_title_key(text) from public, anon;
grant execute on function public.zella_incident_title_key(text) to authenticated, service_role;

create or replace function public.zella_open_incident_checked(p_title text, p_detail text default null, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_key text := public.zella_incident_title_key(p_title); v_similar jsonb; v_id uuid;
begin
  if not public.zella_admin_can('support.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(btrim(coalesce(p_title, ''))) < 3 then raise exception 'TITLE_REQUIRED'; end if;
  if not coalesce(p_force, false) then
    -- one check at a time, so two admins opening the same problem at once can't both pass the check
    perform pg_advisory_xact_lock(hashtext('zella_open_incident_checked'));
    select jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title, 'created_at', i.created_at) order by i.created_at desc) into v_similar
      from public.platform_incidents i
     where i.status = 'open' and length(v_key) > 0 and length(public.zella_incident_title_key(i.title)) > 0
       and (public.zella_incident_title_key(i.title) = v_key
            or position(v_key in public.zella_incident_title_key(i.title)) > 0
            or position(public.zella_incident_title_key(i.title) in v_key) > 0);
    if v_similar is not null then return jsonb_build_object('opened', false, 'code', 'SIMILAR_OPEN', 'similar', v_similar); end if;
  end if;
  v_id := public.zella_open_incident(p_title, p_detail);
  return jsonb_build_object('opened', true, 'id', v_id);
end $$;
revoke all on function public.zella_open_incident_checked(text, text, boolean) from public, anon;
grant execute on function public.zella_open_incident_checked(text, text, boolean) to authenticated, service_role;

create or replace function public.zella_incident_post_update(p_incident uuid, p_body text, p_notify boolean default false, p_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare i record; v_id uuid; b record; n integer := 0; v_body text := btrim(coalesce(p_body, '')); prior record;
begin
  if not public.zella_admin_can('support.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_body) not between 3 and 1000 then raise exception 'BAD_INPUT'; end if;
  select id, title, status into i from public.platform_incidents where id = p_incident for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  -- the same update sent again (same ref, under the incident's lock): the one already saved, nobody told twice
  if p_ref is not null then
    select id, notified_businesses into prior from public.platform_incident_updates where incident_id = i.id and client_ref = p_ref;
    if found then return jsonb_build_object('id', prior.id, 'notified_businesses', prior.notified_businesses, 'already_saved', true); end if;
  end if;
  if i.status <> 'open' then raise exception 'NOT_OPEN'; end if;
  insert into public.platform_incident_updates (incident_id, body, created_by, client_ref) values (i.id, v_body, auth.uid(), p_ref) returning id into v_id;
  if coalesce(p_notify, false) then
    for b in select id from public.businesses where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
      perform public.zella_notify_owners(b.id, 'incident_update', left(i.title, 120), left(v_body, 300), 'info', 'home');
      n := n + 1;
    end loop;
    -- in the app only: these notices are marked so the email and text delivery never claims them
    update public.staff_notifications set delivery_status = 'skipped', sms_status = 'skipped'
     where kind = 'incident_update' and created_at = now() and delivery_status = 'pending';
    update public.platform_incident_updates set notified_businesses = n where id = v_id;
  end if;
  insert into public.audit_logs (user_id, action, entity_type, entity_id, new_data)
  values (auth.uid(), 'platform.incident_updated', 'platform_incident', i.id, jsonb_build_object('update_id', v_id, 'notified_businesses', n));
  return jsonb_build_object('id', v_id, 'notified_businesses', n);
end $$;
revoke all on function public.zella_incident_post_update(uuid, text, boolean, uuid) from public, anon;
grant execute on function public.zella_incident_post_update(uuid, text, boolean, uuid) to authenticated, service_role;

create or replace function public.zella_incident_edit(p_incident uuid, p_title text, p_detail text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
declare i record; v_title text := left(btrim(coalesce(p_title, '')), 200); v_detail text := nullif(left(btrim(coalesce(p_detail, '')), 1000), '');
begin
  if not public.zella_admin_can('support.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_title) < 3 then raise exception 'TITLE_REQUIRED'; end if;
  select id, title, detail, status into i from public.platform_incidents where id = p_incident for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if i.status <> 'open' then raise exception 'NOT_OPEN'; end if;
  if v_title = i.title and v_detail is not distinct from i.detail then return false; end if;
  update public.platform_incidents set title = v_title, detail = v_detail where id = i.id;
  insert into public.audit_logs (user_id, action, entity_type, entity_id, old_data, new_data)
  values (auth.uid(), 'platform.incident_edited', 'platform_incident', i.id, jsonb_build_object('title', i.title, 'detail', i.detail), jsonb_build_object('title', v_title, 'detail', v_detail));
  return true;
end $$;
revoke all on function public.zella_incident_edit(uuid, text, text) from public, anon;
grant execute on function public.zella_incident_edit(uuid, text, text) to authenticated, service_role;

commit;
