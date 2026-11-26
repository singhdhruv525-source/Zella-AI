-- Zella Voice: the business's own email address, part 7: a Zella Voice admin emails the owner a "Connect your
-- mailbox" link (owner, 27 Nov 2026, "owner, plus admin link"; docs/ARCHITECTURE.md §14.4, REQ-BEM-01 to REQ-BEM-06).
-- Needs sql/zella_business_email.sql, sql/zella_business_email_caps.sql and sql/zella_platform_emails.sql (the outbox
-- the link email goes through).
-- The owner still connects Gmail or Outlook from Settings at any time (sql/zella_business_email_mailbox.sql). In
-- addition, during Create Business a Zella Voice admin with businesses.manage can send the owner a one time link by
-- email. It opens the same connect flow for that business: the owner signs in to Zella Voice, then signs in with Google
-- or Microsoft on their own page. Nobody shares a password, and the admin never gets mailbox access (connecting stays
-- zella_business_email_mailbox_can_connect: the business's own owner or admin, never Zella Voice staff).
--   1. business_email_mailbox_links: one row per link. Only the SHA 256 hash of its token is stored, with the business
--      and the owner it is bound to, who sent it and when it expires (7 days). A new link replaces the open one. Row
--      security on, nobody reads or writes it directly.
--   2. zella_business_email_platform_admin(business, person): an active Zella Voice admin with businesses.manage (the
--      same test as zella_business_email_actor_can's second half). Server only.
--   3. zella_business_email_mailbox_link_issue(business, admin, token hash): server only (business-email). Checks the
--      admin, picks the business's owner (an active owner, else an invited one), refuses when a mailbox is already
--      connected and after 5 links in a day, and answers the owner's address for the email, which business-email writes
--      (email S8) and queues in the platform outbox (zella_queue_platform_email): held as test mode while email_live is
--      off. Audited (never the token or its hash).
--   4. zella_business_email_mailbox_link_redeem(token hash, person): server only (business-email). The link works once,
--      until it expires, only for the owner it was sent to, and only while they are still an active owner of an active
--      business (the role is checked here, on the server). Audited.
--   5. zella_business_email_status also says the latest link's state (open, used, expired, replaced), never its token.
-- zella_business_email_status must be sql/zella_business_email_caps.sql's version (or already this file's), otherwise
-- VERSION_MISMATCH and nothing changes. Safe to run twice. Rollback: sql/rollback/zella_business_email_mailbox_link_rollback.sql
begin;

do $$
declare f record;
begin
  if to_regclass('public.business_email_senders') is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_business_email_mailbox_cap(text,text)') is null then
    raise exception 'VERSION_MISMATCH: apply sql/zella_business_email.sql, sql/zella_business_email_send.sql and sql/zella_business_email_caps.sql first';
  end if;
  if to_regprocedure('public.zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[])') is null then
    raise exception 'VERSION_MISMATCH: apply sql/zella_platform_emails.sql first (the link email goes through the platform outbox)';
  end if;
  if md5(pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure)) not in ('59e30c139362c44863045142ee98aa43', 'ba293561f9b771ea5eab89b9a22e9c85') then
    raise exception 'VERSION_MISMATCH: zella_business_email_status is not a version this file was written for';
  end if;
  for f in select * from (values ('public.zella_business_email_platform_admin(uuid,uuid)', '6ae555b8484689dcd6ba4558fdbabc22'),
                                 ('public.zella_business_email_mailbox_link_issue(uuid,uuid,text)', '4024104d6eb7a859b47dc7b1319140d2'),
                                 ('public.zella_business_email_mailbox_link_redeem(text,uuid)', '5676a811d933fd9b8a3d7027bd1ccd3d')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.sig;
    end if;
  end loop;
  if to_regclass('public.business_email_mailbox_links') is not null and not exists (
       select 1 from pg_description where objoid = to_regclass('public.business_email_mailbox_links') and objsubid = 0 and description like 'Zella Voice: one time%') then
    raise exception 'VERSION_MISMATCH: a different business_email_mailbox_links table already exists';
  end if;
  if md5(pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure)) = '59e30c139362c44863045142ee98aa43' then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    select 'zella_business_email_mailbox_link', 'public.zella_business_email_status(uuid)', d, md5(d)
      from pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure) d
    on conflict (migration, signature) do nothing;
  end if;
end $$;

-- 1. the links: a hash only, bound to one business and one owner, used once, 7 days
create table if not exists public.business_email_mailbox_links (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  owner_id uuid not null references auth.users (id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'open' check (status in ('open', 'used', 'replaced')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  check (expires_at > created_at and expires_at <= created_at + interval '7 days'),
  check ((status = 'used') = (used_at is not null))
);
comment on table public.business_email_mailbox_links is 'Zella Voice: one time "Connect your mailbox" links an admin emails to a business owner (hash only, 7 days, used once)';
create index if not exists business_email_mailbox_links_business_idx on public.business_email_mailbox_links (business_id, created_at desc);
create index if not exists business_email_mailbox_links_owner_idx on public.business_email_mailbox_links (owner_id);
alter table public.business_email_mailbox_links enable row level security;
revoke all on public.business_email_mailbox_links from public, anon, authenticated;
grant all on public.business_email_mailbox_links to service_role;

-- 2. an active Zella Voice admin who may manage businesses (Create Business). Server only.
create or replace function public.zella_business_email_platform_admin(p_business_id uuid, p_actor uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_business_id is not null and p_actor is not null
     and exists (select 1 from public.platform_admins pa join public.businesses b on b.id = p_business_id
                  where pa.user_id = p_actor and pa.is_active and b.cancelled_at is null
                    and (pa.role in ('zella_owner', 'super_admin')
                         or exists (select 1 from public.platform_role_permissions p where p.role = pa.role and p.permission = 'businesses.manage')))
$$;

-- 3. a Zella Voice admin sends the owner a link. Server only (business-email writes and queues the email).
create or replace function public.zella_business_email_mailbox_link_issue(p_business_id uuid, p_actor uuid, p_token_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b record; o record; s public.business_email_senders; v_id uuid; v_exp timestamptz := now() + interval '7 days'; v_recent integer;
begin
  if not public.zella_business_email_platform_admin(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'reason', 'BAD_REQUEST'); end if;
  -- one issue at a time per business
  select x.id, x.name, x.timezone, x.suspended_at, x.cancelled_at into b from public.businesses x where x.id = p_business_id for update;
  if b.id is null or b.suspended_at is not null or b.cancelled_at is not null then return jsonb_build_object('ok', false, 'reason', 'BUSINESS_NOT_ACTIVE'); end if;
  -- the business's owner: an active one first, else one still to accept the invitation
  select m.user_id, m.status, lower(trim(coalesce(u.email, ''))) as email into o
    from public.business_members m join auth.users u on u.id = m.user_id
   where m.business_id = p_business_id and m.role = 'owner' and m.status in ('active', 'invited')
   order by (m.status = 'active') desc, m.created_at, m.user_id limit 1;
  if o.user_id is null then return jsonb_build_object('ok', false, 'reason', 'NO_OWNER'); end if;
  if o.email !~ '^[^@\s,;<>"]+@[^@\s,;<>"]+\.[^@\s,;<>"]+$' or length(o.email) > 254 then return jsonb_build_object('ok', false, 'reason', 'NO_OWNER_EMAIL'); end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  if s.route = 'mailbox' and s.mailbox_status = 'connected' then return jsonb_build_object('ok', false, 'reason', 'ALREADY_CONNECTED'); end if;
  select count(*) into v_recent from public.business_email_mailbox_links where business_id = p_business_id and created_at > now() - interval '1 day';
  if v_recent >= 5 then return jsonb_build_object('ok', false, 'reason', 'TOO_MANY_LINKS'); end if;
  update public.business_email_mailbox_links set status = 'replaced' where business_id = p_business_id and status = 'open';
  insert into public.business_email_mailbox_links (business_id, owner_id, token_hash, created_by, expires_at)
  values (p_business_id, o.user_id, p_token_hash, p_actor, v_exp) returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, 'business_email.mailbox_link_sent', 'business', p_business_id, null,
          jsonb_build_object('link_id', v_id, 'owner_id', o.user_id, 'expires_at', v_exp));
  return jsonb_build_object('ok', true, 'link_id', v_id, 'owner_id', o.user_id, 'owner_invited', o.status = 'invited', 'to', o.email,
    'business_name', left(btrim(regexp_replace(coalesce(b.name, ''), '[\r\n"<>]+', ' ', 'g')), 80), 'expires_at', v_exp,
    'expires_on', to_char(v_exp at time zone coalesce(nullif(b.timezone, ''), 'America/New_York'), 'FMDD Mon YYYY'),
    'email_live', coalesce((select value::text = 'true' from public.platform_settings where key = 'email_live'), false));
end $$;

-- 4. the owner opens the link (signed in). Server only (business-email). Used once.
create or replace function public.zella_business_email_mailbox_link_redeem(p_token_hash text, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.business_email_mailbox_links; v_name text;
begin
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' or p_actor is null then return jsonb_build_object('ok', false, 'reason', 'MAILBOX_LINK_NOT_FOUND'); end if;
  select * into l from public.business_email_mailbox_links where token_hash = p_token_hash for update;
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'MAILBOX_LINK_NOT_FOUND'); end if;
  if l.status = 'used' then return jsonb_build_object('ok', false, 'reason', 'MAILBOX_LINK_USED'); end if;
  if l.status = 'replaced' then return jsonb_build_object('ok', false, 'reason', 'MAILBOX_LINK_REPLACED'); end if;
  if l.expires_at <= now() then return jsonb_build_object('ok', false, 'reason', 'MAILBOX_LINK_EXPIRED'); end if;
  if l.owner_id <> p_actor then return jsonb_build_object('ok', false, 'reason', 'MAILBOX_LINK_NOT_YOURS'); end if;
  -- the role, on the server: still an active owner of an active business
  if not exists (select 1 from public.business_members m join public.businesses b on b.id = m.business_id
                  where m.business_id = l.business_id and m.user_id = p_actor and m.role = 'owner' and m.status = 'active'
                    and b.suspended_at is null and b.cancelled_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_OWNER');
  end if;
  update public.business_email_mailbox_links set status = 'used', used_at = now() where id = l.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (l.business_id, p_actor, 'business_email.mailbox_link_opened', 'business', l.business_id, null, jsonb_build_object('link_id', l.id));
  select left(btrim(regexp_replace(coalesce(x.name, ''), '[\r\n"<>]+', ' ', 'g')), 80) into v_name from public.businesses x where x.id = l.business_id;
  return jsonb_build_object('ok', true, 'business_id', l.business_id, 'business_name', v_name);
end $$;

-- 5. what the setup screen shows (sql/zella_business_email_caps.sql's), now with the latest link's state
create or replace function public.zella_business_email_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.business_email_senders; b record; v_routes jsonb; v_reply text; v_active text; v_day date; v_sent integer; v_link jsonb;
begin
  if not (exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                   and m.status = 'active' and m.role in ('owner', 'admin', 'manager'))
          or coalesce(public.zella_admin_can('businesses.view'), false)) then
    raise exception 'NOT_ALLOWED';
  end if;
  select x.id, x.name, x.email, x.timezone into b from public.businesses x where x.id = p_business_id;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  v_routes := coalesce(public.zella_setting('business_email_routes', '{}'::jsonb), '{}'::jsonb);
  v_reply := nullif(lower(trim(coalesce(b.email, ''))), '');
  v_day := public.zella_business_email_local_day(p_business_id);
  v_active := public.zella_business_email_sender(p_business_id) ->> 'sender_route';
  if s.route = 'mailbox' then
    select count(*) into v_sent from public.email_messages m
     where m.business_id = p_business_id and m.direction = 'outbound' and m.metadata ->> 'transport' in ('gmail', 'outlook')
       and m.status in ('queued', 'sent', 'delivered') and m.created_at >= (v_day::timestamp at time zone coalesce(nullif(b.timezone, ''), 'America/New_York'));
  end if;
  -- the latest "Connect your mailbox" link: its state and dates only, never its token or hash
  select jsonb_build_object('status', case when l.status = 'open' and l.expires_at <= now() then 'expired' else l.status end,
                            'sent_at', l.created_at, 'expires_at', l.expires_at, 'used_at', l.used_at,
                            'expires_on', to_char(l.expires_at at time zone coalesce(nullif(b.timezone, ''), 'America/New_York'), 'FMDD Mon YYYY'))
    into v_link from public.business_email_mailbox_links l where l.business_id = p_business_id order by l.created_at desc, l.id limit 1;
  return jsonb_build_object(
    'route', s.route,                  -- the route set up (or being set up), or null: the fallback
    'active_route', v_active,          -- the route the next email actually uses: domain, mailbox or fallback
    'address', coalesce(s.address, case when s.route = 'mailbox' then s.mailbox_account end),
    'domain', s.domain, 'domain_status', coalesce(s.domain_status, 'none'), 'dns_records', coalesce(s.dns_records, '[]'::jsonb),
    'domain_checked_at', s.domain_checked_at, 'domain_verified_at', s.domain_verified_at,
    'mailbox_provider', s.mailbox_provider, 'mailbox_status', coalesce(s.mailbox_status, 'none'), 'mailbox_account', s.mailbox_account,
    'mailbox_connected_at', s.mailbox_connected_at, 'cap_reached_today', s.cap_reached_on is not distinct from v_day and s.cap_reached_on is not null,
    -- the limits (owner, 27 Nov 2026): the type, its daily cap (the lowest for the provider when the type isn't known),
    -- the per minute cap, and today's mailbox emails
    'mailbox_type', case when s.route = 'mailbox' then coalesce(s.mailbox_cap_key, 'unknown') end,
    'mailbox_daily_cap', case when s.route = 'mailbox' then public.zella_business_email_mailbox_cap(s.mailbox_provider, s.mailbox_cap_key) end,
    'mailbox_per_minute', case when s.route = 'mailbox' then public.zella_business_email_mailbox_cap(s.mailbox_provider, 'per_minute') end,
    'mailbox_sent_today', v_sent,
    'mailbox_link', v_link,
    'routes_live', jsonb_build_object('domain', coalesce(v_routes ->> 'domain', 'false') = 'true', 'mailbox', coalesce(v_routes ->> 'mailbox', 'false') = 'true'),
    'fallback', jsonb_build_object('from_name', left(regexp_replace(coalesce(b.name, ''), '[\r\n"<>]+', ' ', 'g'), 80),
                                   'reply_to', case when public.zella_valid_email(v_reply) then v_reply end));
end $$;

-- who may call what (SEC-6, SEC-7): all three new functions are server only
revoke all on function public.zella_business_email_platform_admin(uuid,uuid), public.zella_business_email_mailbox_link_issue(uuid,uuid,text),
  public.zella_business_email_mailbox_link_redeem(text,uuid) from public, anon, authenticated;
grant execute on function public.zella_business_email_platform_admin(uuid,uuid), public.zella_business_email_mailbox_link_issue(uuid,uuid,text),
  public.zella_business_email_mailbox_link_redeem(text,uuid) to service_role;

do $$
declare f record;
begin
  for f in select * from (values ('public.zella_business_email_status(uuid)', 'ba293561f9b771ea5eab89b9a22e9c85'), ('public.zella_business_email_platform_admin(uuid,uuid)', '6ae555b8484689dcd6ba4558fdbabc22'),
                                 ('public.zella_business_email_mailbox_link_issue(uuid,uuid,text)', '4024104d6eb7a859b47dc7b1319140d2'),
                                 ('public.zella_business_email_mailbox_link_redeem(text,uuid)', '5676a811d933fd9b8a3d7027bd1ccd3d')) as t(sig, want) loop
    if md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.sig; end if;
  end loop;
end $$;

commit;
