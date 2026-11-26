-- Zella Voice: the business's own email address (owner, 26 Nov 2026; docs/ARCHITECTURE.md §14.4, "Business email
-- address rules", settles D-19 and D-19a). Every email a business sends to its own customers is to come from the
-- business's name and its own address, set up in Create Business one of two ways:
--   (a) a verified business domain: the business adds the DNS records Zella Voice shows it; Resend's domains API
--       verifies them; Zella Voice then sends from the business address through Resend;
--   (b) a connected Gmail or Outlook mailbox (OAuth): the provider itself sends (Gmail API, Microsoft Graph sendMail).
-- Until one is ready the fallback stays: "<business name> <no-reply@zellavoice.com>", Reply-To the business email.
--
-- This file is the data model and the rules only. Nothing here calls a provider or sends anything, and nothing uses
-- it yet: sending (zella_prepare_email) is wired by sql/zella_business_email_send.sql, the setup screens and the
-- mailbox sign in by the business-email edge function.
--
--   1. business_email_senders: one row per business that started a setup. The domain's DNS records (public values,
--      never secrets) and Resend's domain id (a reference, not a key); the mailbox's provider and account, and the
--      NAME of the Vault secret that holds its refresh token (the token itself only ever lives in Vault, like
--      calendar-connect's). One route at a time: starting one clears the other. A domain belongs to one business
--      (unique), so no business can send as another's domain. Row security on; owners, admins and managers of the
--      business read their own row (never the secret's name); nobody writes it directly.
--   2. Two platform settings, recorded in zella_migration_settings so the rollback removes only what this file added:
--      business_email_routes = {"domain": false, "mailbox": false}: each route is a live switch (ARC-8), off until the
--      owner turns it on; while off, that route's emails use the fallback.
--      business_email_mailbox_caps: each mailbox's daily sending cap (Gmail 500, Google Workspace 2,000, Outlook.com
--      300, Microsoft 365 2,000: under each provider's published limit). The plan's email limit applies on top
--      (zella_message_gate, unchanged).
--   3. Rules, every one checking the person first (TEN-3): an active owner or admin of the business, or an active
--      Zella Voice admin with businesses.manage (the Create Business wizard). Identity is derived by the edge function
--      from the person's own sign in and passed as p_actor with the server key (TEN-4), like calendar-connect.
--        zella_business_email_status(business)              signed in: what the setup screen shows
--        zella_business_email_domain_begin(...)             server: may this address's domain be set up? (no free
--                                                           mailbox domain, not Zella Voice's, not another business's)
--        zella_business_email_domain_saved(...)             server: Resend's domain id and DNS records, kept
--        zella_business_email_domain_checked(...)           server: Resend's verification answer; Verified or not
--        zella_business_email_mailbox_saved(...)            server: a connected mailbox, its token into Vault (only
--                                                           the business's own owner or admin: _mailbox_can_connect)
--        zella_business_email_disconnect(...)               server: back to the fallback, token deleted
--        zella_business_email_sender(business)              server: who sends this business's next email, and how
--        zella_business_email_mailbox_credentials(message)  server: the token for ONE queued mailbox email only
--        zella_business_email_mailbox_refused(message, why) server: the provider refused (daily cap or sign in): that
--                                                           email and the rest of the day go through the fallback,
--                                                           the business is told once per day
--      Every change is audited (route, domain, provider and account; never a token).
-- Every object is new; a function that exists already must be exactly this file's version (VERSION_MISMATCH).
-- Safe to run twice. Needs nothing beyond production's schema (vault, audit_logs, zella_notify, platform_admins).
-- Rollback: sql/rollback/zella_business_email_rollback.sql
begin;

do $$
declare f record;
  mine constant jsonb := '{
    "public.zella_business_email_actor_can(uuid,uuid)": "68a21ec08372af683c9048189406b871",
    "public.zella_business_email_status(uuid)": "5fb484efb0cb4d193f59d1fcf7cac16b",
    "public.zella_business_email_domain_begin(uuid,uuid,text)": "cf389960f779ac299501dfde81bea053",
    "public.zella_business_email_domain_saved(uuid,uuid,text,text,jsonb,text)": "f5f8789b409126d56e638da22edf3ec1",
    "public.zella_business_email_domain_checked(uuid,uuid,text,text,jsonb)": "eb0c479f96b503cb5dcd5f84eda99e2c",
    "public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)": "6dc2549df6f019fa5e61ab57346ff1bc",
    "public.zella_business_email_disconnect(uuid,uuid)": "6f3dfdd9958546b9d33299cc81f473c1",
    "public.zella_business_email_sender(uuid)": "193583411ec9519f57a68684c7ebf224",
    "public.zella_business_email_mailbox_credentials(uuid)": "5b865c1980c24c489815a21505dd8be8",
    "public.zella_business_email_mailbox_refused(uuid,text)": "cd7bd8b6eaa62cbf9bc17317554e039f",
    "public.zella_business_email_records(jsonb)": "3396c6e958f49241e58729e1a499eee0",
    "public.zella_business_email_local_day(uuid)": "49f39fb2939c2bc32ff0aa61792a9ad4",
    "public.zella_business_email_mailbox_can_connect(uuid,uuid)": "dbee48e6a1a2a0742dddc286fb781b87"}';
begin
  if to_regclass('public.businesses') is null or to_regclass('public.business_members') is null or to_regclass('public.audit_logs') is null
     or to_regclass('public.email_messages') is null or to_regclass('public.platform_admins') is null or to_regclass('vault.secrets') is null
     or to_regprocedure('public.zella_notify(uuid,text,text,text,text,text,uuid,uuid)') is null
     or to_regprocedure('public.zella_setting(text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.key;
    end if;
  end loop;
end $$;

-- the same bookkeeping tables other migrations use (created by whichever runs first)
create table if not exists public.zella_migration_settings (migration text not null, key text not null, primary key (migration, key));
alter table public.zella_migration_settings enable row level security;
revoke all on public.zella_migration_settings from public, anon, authenticated;

-- 1. one row per business that started a setup
create table if not exists public.business_email_senders (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  route text check (route in ('domain', 'mailbox')),
  address text check (address is null or (length(address) <= 254 and address = lower(address))),
  domain text check (domain is null or (length(domain) <= 253 and domain = lower(domain))),
  domain_status text not null default 'none' check (domain_status in ('none', 'pending', 'verified', 'failed')),
  resend_domain_id text check (resend_domain_id is null or resend_domain_id ~ '^[A-Za-z0-9_-]{1,100}$'),
  dns_records jsonb not null default '[]'::jsonb check (jsonb_typeof(dns_records) = 'array'),
  domain_checked_at timestamptz,
  domain_verified_at timestamptz,
  mailbox_provider text check (mailbox_provider in ('gmail', 'outlook')),
  mailbox_status text not null default 'none' check (mailbox_status in ('none', 'connected', 'reconnect_needed')),
  mailbox_account text check (mailbox_account is null or (length(mailbox_account) <= 254 and mailbox_account = lower(mailbox_account))),
  mailbox_cap_key text check (mailbox_cap_key in ('gmail', 'google_workspace', 'outlook', 'microsoft_365')),
  mailbox_secret_name text,
  mailbox_connected_at timestamptz,
  cap_reached_on date,
  cap_notified_on date,
  problem_notified_on date,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  -- a domain route has a domain and an address on it; a mailbox route has a provider and an account
  constraint business_email_senders_domain_shape check (route is distinct from 'domain' or (domain is not null and address is not null and address like '%@' || domain)),
  constraint business_email_senders_mailbox_shape check (route is distinct from 'mailbox' or (mailbox_provider is not null and mailbox_account is not null))
);
comment on table public.business_email_senders is 'The business''s own email address for emails to its customers: a verified domain (Resend) or a connected Gmail or Outlook mailbox; tokens only in Vault';
-- one business per domain, whatever its state: nobody can start sending as a domain another business set up
create unique index if not exists business_email_senders_domain_key on public.business_email_senders (domain) where domain is not null;
alter table public.business_email_senders enable row level security;
revoke all on public.business_email_senders from public, anon, authenticated;
grant all on public.business_email_senders to service_role;
-- owners, admins and managers of the business read their own row; the Vault secret's name is not readable
grant select (business_id, route, address, domain, domain_status, dns_records, domain_checked_at, domain_verified_at, mailbox_provider,
              mailbox_status, mailbox_account, mailbox_connected_at, cap_reached_on, updated_at) on public.business_email_senders to authenticated;
drop policy if exists business_email_senders_member_read on public.business_email_senders;
create policy business_email_senders_member_read on public.business_email_senders for select to authenticated
  using (exists (select 1 from public.business_members m where m.business_id = business_email_senders.business_id
                  and m.user_id = (select auth.uid()) and m.status = 'active' and m.role in ('owner', 'admin', 'manager')));
-- counting today's mailbox emails (the daily cap) reads by business and time
create index if not exists email_messages_mailbox_day_idx on public.email_messages (business_id, created_at)
  where direction = 'outbound' and metadata ->> 'transport' in ('gmail', 'outlook');

-- 2. the two settings
with i as (
  insert into public.platform_settings (key, value) values
    ('business_email_routes', '{"domain": false, "mailbox": false}'::jsonb),
    ('business_email_mailbox_caps', '{"gmail": 500, "google_workspace": 2000, "outlook": 300, "microsoft_365": 2000}'::jsonb)
  on conflict (key) do nothing returning key
)
insert into public.zella_migration_settings (migration, key) select 'zella_business_email', key from i on conflict do nothing;

-- 3. the rules
-- may this person set up or change the business's email address? An active owner or admin of an active business, or an
-- active Zella Voice admin with businesses.manage (Create Business). Server only: the person comes from their sign in.
create or replace function public.zella_business_email_actor_can(p_business_id uuid, p_actor uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_business_id is not null and p_actor is not null and (
    exists (select 1 from public.business_members m join public.businesses b on b.id = m.business_id
             where m.business_id = p_business_id and m.user_id = p_actor and m.status = 'active' and m.role in ('owner', 'admin')
               and b.suspended_at is null and b.cancelled_at is null)
    or exists (select 1 from public.platform_admins pa join public.businesses b on b.id = p_business_id
                where pa.user_id = p_actor and pa.is_active and b.cancelled_at is null
                  and (pa.role in ('zella_owner', 'super_admin')
                       or exists (select 1 from public.platform_role_permissions p where p.role = pa.role and p.permission = 'businesses.manage'))))
$$;

-- who may connect the business's mailbox: only its own active owner or admin (they sign in with Google or Microsoft
-- themselves). A Zella Voice admin may set up a domain in Create Business but never a mailbox: the Zella Voice team
-- never holds a business's logins (owner, 26 Nov 2026). Server only.
create or replace function public.zella_business_email_mailbox_can_connect(p_business_id uuid, p_actor uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_business_id is not null and p_actor is not null
     and exists (select 1 from public.business_members m join public.businesses b on b.id = m.business_id
                  where m.business_id = p_business_id and m.user_id = p_actor and m.status = 'active' and m.role in ('owner', 'admin')
                    and b.suspended_at is null and b.cancelled_at is null)
$$;

-- "today" for the business, in its own time zone (DB-10): the daily cap resets at the business's midnight
create or replace function public.zella_business_email_local_day(p_business_id uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce((select nullif(b.timezone, '') from public.businesses b where b.id = p_business_id), 'America/New_York'))::date
$$;

-- Resend's DNS records, kept to the fields the setup page shows (record, type, name, value, ttl, priority, status),
-- short, and only the three record types Resend asks for
create or replace function public.zella_business_email_records(p_records jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'record', left(r ->> 'record', 40), 'type', upper(r ->> 'type'), 'name', left(r ->> 'name', 253), 'value', left(r ->> 'value', 2048),
           'ttl', left(r ->> 'ttl', 20), 'priority', case when (r ->> 'priority') ~ '^[0-9]{1,5}$' then (r ->> 'priority')::integer end,
           'status', left(r ->> 'status', 30))) order by o), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(p_records) = 'array' then p_records else '[]'::jsonb end) with ordinality as e(r, o)
   where o <= 20 and jsonb_typeof(r) = 'object' and upper(r ->> 'type') in ('MX', 'TXT', 'CNAME')
     and coalesce(r ->> 'name', '') <> '' and coalesce(r ->> 'value', '') <> ''
$$;

-- What the setup screen shows (signed in): owners, admins and managers of the business, or a Zella Voice admin with
-- businesses.view. Never a token or the secret's name.
create or replace function public.zella_business_email_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.business_email_senders; b record; v_routes jsonb; v_reply text; v_active text; v_day date;
begin
  if not (exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                   and m.status = 'active' and m.role in ('owner', 'admin', 'manager'))
          or coalesce(public.zella_admin_can('businesses.view'), false)) then
    raise exception 'NOT_ALLOWED';
  end if;
  select x.id, x.name, x.email into b from public.businesses x where x.id = p_business_id;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  v_routes := coalesce(public.zella_setting('business_email_routes', '{}'::jsonb), '{}'::jsonb);
  v_reply := nullif(lower(trim(coalesce(b.email, ''))), '');
  v_day := public.zella_business_email_local_day(p_business_id);
  v_active := public.zella_business_email_sender(p_business_id) ->> 'sender_route';
  return jsonb_build_object(
    'route', s.route,                  -- the route set up (or being set up), or null: the fallback
    'active_route', v_active,          -- the route the next email actually uses: domain, mailbox or fallback
    'address', coalesce(s.address, case when s.route = 'mailbox' then s.mailbox_account end),
    'domain', s.domain, 'domain_status', coalesce(s.domain_status, 'none'), 'dns_records', coalesce(s.dns_records, '[]'::jsonb),
    'domain_checked_at', s.domain_checked_at, 'domain_verified_at', s.domain_verified_at,
    'mailbox_provider', s.mailbox_provider, 'mailbox_status', coalesce(s.mailbox_status, 'none'), 'mailbox_account', s.mailbox_account,
    'mailbox_connected_at', s.mailbox_connected_at, 'cap_reached_today', s.cap_reached_on is not distinct from v_day and s.cap_reached_on is not null,
    'routes_live', jsonb_build_object('domain', coalesce(v_routes ->> 'domain', 'false') = 'true', 'mailbox', coalesce(v_routes ->> 'mailbox', 'false') = 'true'),
    'fallback', jsonb_build_object('from_name', left(regexp_replace(coalesce(b.name, ''), '[\r\n"<>]+', ' ', 'g'), 80),
                                   'reply_to', case when public.zella_valid_email(v_reply) then v_reply end));
end $$;

-- May this address's domain be set up for sending? Server only (business-email, before it asks Resend).
-- Answers the domain to add at Resend, and Resend's id when this business already added it.
create or replace function public.zella_business_email_domain_begin(p_business_id uuid, p_actor uuid, p_address text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_addr text := lower(trim(coalesce(p_address, ''))); v_dom text; s public.business_email_senders;
begin
  if not public.zella_business_email_actor_can(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  if length(v_addr) > 254 or v_addr !~ '^[a-z0-9._%+-]{1,64}@[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' then
    return jsonb_build_object('ok', false, 'reason', 'BAD_ADDRESS');
  end if;
  v_dom := split_part(v_addr, '@', 2);
  -- a free mailbox's domain can't be verified by a business: those connect the mailbox instead (Gmail, Outlook) or
  -- keep the fallback
  if v_dom in ('gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'msn.com', 'yahoo.com', 'ymail.com', 'aol.com',
               'icloud.com', 'me.com', 'mac.com', 'proton.me', 'protonmail.com', 'gmx.com', 'mail.com', 'zoho.com') then
    return jsonb_build_object('ok', false, 'reason', 'FREE_MAILBOX_DOMAIN');
  end if;
  if v_dom = 'zellavoice.com' or v_dom like '%.zellavoice.com' or v_dom = 'zellaai.in' or v_dom like '%.zellaai.in' then
    return jsonb_build_object('ok', false, 'reason', 'PLATFORM_DOMAIN');
  end if;
  if exists (select 1 from public.business_email_senders x where x.domain = v_dom and x.business_id <> p_business_id) then
    return jsonb_build_object('ok', false, 'reason', 'DOMAIN_TAKEN');
  end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  return jsonb_build_object('ok', true, 'address', v_addr, 'domain', v_dom,
    'resend_domain_id', case when s.domain = v_dom then s.resend_domain_id end,
    -- a different domain this business added before: business-email removes it at Resend
    'replaces_domain_id', case when s.domain is distinct from v_dom then s.resend_domain_id end);
end $$;

-- Resend added the domain (or already had it): keep its id and the DNS records to show. Server only.
-- This becomes the business's route; a connected mailbox is disconnected (its token deleted).
create or replace function public.zella_business_email_domain_saved(p_business_id uuid, p_actor uuid, p_address text, p_resend_domain_id text,
                                                                    p_records jsonb, p_provider_status text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_begin jsonb; s public.business_email_senders; v_status text;
begin
  v_begin := public.zella_business_email_domain_begin(p_business_id, p_actor, p_address);
  if not (v_begin ->> 'ok')::boolean then return v_begin; end if;
  if coalesce(p_resend_domain_id, '') !~ '^[A-Za-z0-9_-]{1,100}$' then return jsonb_build_object('ok', false, 'reason', 'BAD_PROVIDER_ANSWER'); end if;
  v_status := case p_provider_status when 'verified' then 'verified' when 'failed' then 'failed' else 'pending' end;
  select * into s from public.business_email_senders where business_id = p_business_id for update;
  if s.mailbox_secret_name is not null then delete from vault.secrets where name = s.mailbox_secret_name; end if;
  insert into public.business_email_senders as x (business_id, route, address, domain, domain_status, resend_domain_id, dns_records, domain_checked_at,
                                                  domain_verified_at, mailbox_provider, mailbox_status, mailbox_account, mailbox_cap_key, mailbox_secret_name,
                                                  mailbox_connected_at, cap_reached_on, updated_at, updated_by)
  values (p_business_id, 'domain', v_begin ->> 'address', v_begin ->> 'domain', v_status, p_resend_domain_id, public.zella_business_email_records(p_records), now(),
          case when v_status = 'verified' then now() end, null, 'none', null, null, null, null, null, now(), p_actor)
  on conflict (business_id) do update set route = 'domain', address = excluded.address, domain = excluded.domain, domain_status = excluded.domain_status,
    resend_domain_id = excluded.resend_domain_id, dns_records = excluded.dns_records, domain_checked_at = now(),
    domain_verified_at = case when excluded.domain_status = 'verified' then coalesce(case when x.domain = excluded.domain then x.domain_verified_at end, now()) end,
    mailbox_provider = null, mailbox_status = 'none', mailbox_account = null, mailbox_cap_key = null, mailbox_secret_name = null, mailbox_connected_at = null,
    cap_reached_on = null, updated_at = now(), updated_by = p_actor;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, 'business_email.domain_started', 'business', p_business_id,
          jsonb_strip_nulls(jsonb_build_object('route', s.route, 'domain', s.domain, 'mailbox_provider', s.mailbox_provider, 'mailbox_account', s.mailbox_account)),
          jsonb_build_object('route', 'domain', 'address', v_begin ->> 'address', 'domain', v_begin ->> 'domain', 'domain_status', v_status));
  return jsonb_build_object('ok', true, 'domain_status', v_status, 'disconnected_mailbox', s.mailbox_secret_name is not null);
end $$;

-- Resend's answer to "verify": Verified, still pending (DNS can take a while), or failed. Server only.
create or replace function public.zella_business_email_domain_checked(p_business_id uuid, p_actor uuid, p_resend_domain_id text, p_provider_status text,
                                                                      p_records jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.business_email_senders; v_status text;
begin
  if not public.zella_business_email_actor_can(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  select * into s from public.business_email_senders where business_id = p_business_id for update;
  -- only the domain this business has set up now: an answer about any other is ignored
  if s.business_id is null or s.route is distinct from 'domain' or s.resend_domain_id is distinct from p_resend_domain_id then
    return jsonb_build_object('ok', false, 'reason', 'NOT_SET_UP');
  end if;
  v_status := case p_provider_status when 'verified' then 'verified' when 'failed' then 'failed' else 'pending' end;
  update public.business_email_senders
     set domain_status = v_status, domain_checked_at = now(),
         dns_records = case when jsonb_array_length(public.zella_business_email_records(p_records)) > 0 then public.zella_business_email_records(p_records) else dns_records end,
         domain_verified_at = case when v_status = 'verified' then coalesce(domain_verified_at, now()) end,
         updated_at = now(), updated_by = p_actor
   where business_id = p_business_id;
  if v_status is distinct from s.domain_status then
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
    values (p_business_id, p_actor, case when v_status = 'verified' then 'business_email.domain_verified' else 'business_email.domain_status' end, 'business', p_business_id,
            jsonb_build_object('domain', s.domain, 'domain_status', s.domain_status), jsonb_build_object('domain', s.domain, 'domain_status', v_status));
  end if;
  return jsonb_build_object('ok', true, 'domain_status', v_status);
end $$;

-- A mailbox connected through the provider's sign in (business-email, after the code exchange). Server only.
-- The refresh token goes into Vault and nowhere else; the account becomes the From address. A domain set up before is
-- dropped (business-email removes it at Resend with the id answered here).
create or replace function public.zella_business_email_mailbox_saved(p_business_id uuid, p_actor uuid, p_provider text, p_account_email text,
                                                                     p_refresh_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.business_email_senders; v_name text; v_acct text := lower(trim(coalesce(p_account_email, ''))); v_dom text; v_cap text;
begin
  if p_provider not in ('gmail', 'outlook') then return jsonb_build_object('ok', false, 'reason', 'BAD_PROVIDER'); end if;
  if not public.zella_business_email_mailbox_can_connect(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'NO_TOKEN'); end if;
  if length(v_acct) > 254 or v_acct !~ '^[a-z0-9._%+-]{1,64}@[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' then
    return jsonb_build_object('ok', false, 'reason', 'NO_ACCOUNT_EMAIL');   -- the From address must be the mailbox's own
  end if;
  v_dom := split_part(v_acct, '@', 2);
  v_cap := case when p_provider = 'gmail' then case when v_dom in ('gmail.com', 'googlemail.com') then 'gmail' else 'google_workspace' end
                else case when v_dom in ('outlook.com', 'hotmail.com', 'live.com', 'msn.com') then 'outlook' else 'microsoft_365' end end;
  select * into s from public.business_email_senders where business_id = p_business_id for update;
  v_name := 'zella_mail_' || p_provider || '_' || p_business_id::text;
  if s.mailbox_secret_name is not null and s.mailbox_secret_name <> v_name then delete from vault.secrets where name = s.mailbox_secret_name; end if;
  if exists (select 1 from vault.secrets where name = v_name) then
    perform vault.update_secret((select id from vault.secrets where name = v_name), p_refresh_token);
  else
    perform vault.create_secret(p_refresh_token, v_name);
  end if;
  insert into public.business_email_senders as x (business_id, route, address, domain, domain_status, resend_domain_id, dns_records, domain_checked_at, domain_verified_at,
                                                  mailbox_provider, mailbox_status, mailbox_account, mailbox_cap_key, mailbox_secret_name, mailbox_connected_at,
                                                  cap_reached_on, updated_at, updated_by)
  values (p_business_id, 'mailbox', null, null, 'none', null, '[]'::jsonb, null, null, p_provider, 'connected', v_acct, v_cap, v_name, now(), null, now(), p_actor)
  on conflict (business_id) do update set route = 'mailbox', address = null, domain = null, domain_status = 'none', resend_domain_id = null, dns_records = '[]'::jsonb,
    domain_checked_at = null, domain_verified_at = null, mailbox_provider = excluded.mailbox_provider, mailbox_status = 'connected', mailbox_account = excluded.mailbox_account,
    mailbox_cap_key = excluded.mailbox_cap_key, mailbox_secret_name = excluded.mailbox_secret_name, mailbox_connected_at = now(), cap_reached_on = null,
    updated_at = now(), updated_by = p_actor;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, 'business_email.mailbox_connected', 'business', p_business_id,
          jsonb_strip_nulls(jsonb_build_object('route', s.route, 'domain', s.domain, 'mailbox_provider', s.mailbox_provider, 'mailbox_account', s.mailbox_account)),
          jsonb_build_object('route', 'mailbox', 'mailbox_provider', p_provider, 'mailbox_account', v_acct));
  return jsonb_build_object('ok', true, 'account', v_acct, 'removed_domain_id', s.resend_domain_id);
end $$;

-- Back to the fallback: the mailbox's token is deleted from Vault; the domain's Resend id is answered so business-email
-- can remove it at Resend. Server only. Nothing else changes; emails already sent stay as they were.
create or replace function public.zella_business_email_disconnect(p_business_id uuid, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.business_email_senders;
begin
  if not public.zella_business_email_actor_can(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  select * into s from public.business_email_senders where business_id = p_business_id for update;
  if s.business_id is null or (s.route is null and s.domain is null and s.mailbox_secret_name is null) then
    return jsonb_build_object('ok', true, 'changed', false, 'removed_domain_id', null);
  end if;
  if s.mailbox_secret_name is not null then delete from vault.secrets where name = s.mailbox_secret_name; end if;
  update public.business_email_senders
     set route = null, address = null, domain = null, domain_status = 'none', resend_domain_id = null, dns_records = '[]'::jsonb, domain_checked_at = null,
         domain_verified_at = null, mailbox_provider = null, mailbox_status = 'none', mailbox_account = null, mailbox_cap_key = null, mailbox_secret_name = null,
         mailbox_connected_at = null, cap_reached_on = null, updated_at = now(), updated_by = p_actor
   where business_id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, 'business_email.disconnected', 'business', p_business_id,
          jsonb_strip_nulls(jsonb_build_object('route', s.route, 'domain', s.domain, 'mailbox_provider', s.mailbox_provider, 'mailbox_account', s.mailbox_account)),
          jsonb_build_object('route', 'fallback'));
  return jsonb_build_object('ok', true, 'changed', true, 'removed_domain_id', s.resend_domain_id);
end $$;

-- Who sends this business's next email to a customer, and how. Server only; read only. The answer is merged over what
-- zella_prepare_email worked out, so only the sender fields are here:
--   domain   the verified domain's address, through Resend (only the plan limit applies)
--   mailbox  the connected mailbox's account, through the provider (the plan limit and the mailbox's daily cap)
--   fallback "<business name> <email_from_address>", Reply-To the business email (the built fallback)
-- with sender_route (domain, mailbox or fallback), transport (resend, gmail or outlook) and sender_note (why not the
-- business's own address, or null). A route whose switch (business_email_routes) is off, a domain not verified, a mailbox that needs reconnecting, or a
-- mailbox at its daily cap (reached, or refused by the provider today) all use the fallback, with the reason in "note".
create or replace function public.zella_business_email_sender(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.business_email_senders; b record; v_routes jsonb; v_reply text; v_name text; v_note text; v_day date; v_cap integer; v_sent integer;
        v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
begin
  select x.id, x.name, x.email into b from public.businesses x where x.id = p_business_id;
  if b.id is null then return jsonb_build_object('sender_route', 'fallback', 'sender_note', 'unknown_business'); end if;
  v_name := left(btrim(regexp_replace(coalesce(b.name, ''), '[\r\n"<>]+', ' ', 'g')), 80);
  v_reply := nullif(lower(trim(coalesce(b.email, ''))), '');
  if not coalesce(public.zella_valid_email(v_reply), false) or v_reply !~ '^[^@\s,;<>"]+@[^@\s,;<>"]+\.[^@\s,;<>"]+$' then v_reply := null; end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  v_routes := coalesce(public.zella_setting('business_email_routes', '{}'::jsonb), '{}'::jsonb);
  if s.route = 'domain' then
    if s.domain_status <> 'verified' then v_note := 'domain_not_verified';
    elsif coalesce(v_routes ->> 'domain', 'false') <> 'true' then v_note := 'domain_route_off';
    else
      return jsonb_build_object('sender_route', 'domain', 'transport', 'resend', 'from', s.address, 'from_name', v_name, 'reply_to', s.address, 'sender_note', null);
    end if;
  elsif s.route = 'mailbox' then
    v_day := public.zella_business_email_local_day(p_business_id);
    if s.mailbox_status <> 'connected' then v_note := 'mailbox_reconnect_needed';
    elsif coalesce(v_routes ->> 'mailbox', 'false') <> 'true' then v_note := 'mailbox_route_off';
    elsif s.cap_reached_on = v_day then v_note := 'mailbox_daily_cap';
    else
      v_cap := case when (public.zella_setting('business_email_mailbox_caps', '{}'::jsonb) ->> s.mailbox_cap_key) ~ '^[0-9]{1,7}$'
                    then (public.zella_setting('business_email_mailbox_caps', '{}'::jsonb) ->> s.mailbox_cap_key)::integer else 300 end;
      -- today's mailbox emails, at the business's midnight; queued ones count, so a busy run can't go over
      select count(*) into v_sent from public.email_messages m
       where m.business_id = p_business_id and m.direction = 'outbound' and m.metadata ->> 'transport' in ('gmail', 'outlook')
         and m.status in ('queued', 'sent', 'delivered')
         and m.created_at >= (v_day::timestamp at time zone coalesce((select nullif(x.timezone, '') from public.businesses x where x.id = p_business_id), 'America/New_York'));
      if v_sent >= v_cap then v_note := 'mailbox_daily_cap';
      else
        return jsonb_build_object('sender_route', 'mailbox', 'transport', s.mailbox_provider, 'from', s.mailbox_account, 'from_name', v_name, 'reply_to', s.mailbox_account, 'sender_note', null);
      end if;
    end if;
  end if;
  return jsonb_build_object('sender_route', 'fallback', 'transport', 'resend', 'from', v_from, 'from_name', v_name, 'sender_note', v_note)
         || case when v_reply is not null then jsonb_build_object('reply_to', v_reply) else '{}'::jsonb end;
end $$;

-- The mailbox's refresh token for ONE email: an outbound email still queued, logged for this business's connected
-- mailbox provider and from its account. Server only (n8n, just before it sends); nothing else ever reads the token.
create or replace function public.zella_business_email_mailbox_credentials(p_message_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m record; s public.business_email_senders; v_token text;
begin
  select e.id, e.business_id, e.status, e.direction, e.from_email, e.metadata ->> 'transport' as transport into m
    from public.email_messages e where e.id = p_message_id;
  if m.id is null or m.direction <> 'outbound' or m.status <> 'queued' or m.transport not in ('gmail', 'outlook') then
    return jsonb_build_object('ok', false, 'reason', 'not_a_queued_mailbox_email');
  end if;
  select * into s from public.business_email_senders where business_id = m.business_id;
  if s.route is distinct from 'mailbox' or s.mailbox_status <> 'connected' or s.mailbox_provider is distinct from m.transport
     or lower(coalesce(m.from_email, '')) is distinct from s.mailbox_account or s.mailbox_secret_name is null then
    return jsonb_build_object('ok', false, 'reason', 'mailbox_not_connected');
  end if;
  select d.decrypted_secret into v_token from vault.decrypted_secrets d where d.name = s.mailbox_secret_name limit 1;
  if v_token is null then return jsonb_build_object('ok', false, 'reason', 'mailbox_not_connected'); end if;
  return jsonb_build_object('ok', true, 'provider', s.mailbox_provider, 'account', s.mailbox_account, 'refresh_token', v_token);
end $$;

-- The mailbox's provider refused an email. Server only (n8n, after the send). p_reason:
--   quota    the provider's daily cap: the rest of the business's day goes through the fallback
--   sign_in  the token no longer works (revoked, expired, password changed): the mailbox needs reconnecting, and
--            until then everything goes through the fallback
-- Either way the email is failed with that reason, its reminder or follow up is put back due now WITHOUT using up one
-- of its tries (so it goes out through the fallback on the next run), and the business is told once per day.
create or replace function public.zella_business_email_mailbox_refused(p_message_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m record; s public.business_email_senders; v_day date; v_told boolean := false; v_requeued text;
begin
  if p_reason not in ('quota', 'sign_in') then raise exception 'BAD_REASON'; end if;
  select e.id, e.business_id, e.status, e.direction, e.metadata into m from public.email_messages e where e.id = p_message_id for update;
  if m.id is null or m.direction <> 'outbound' or m.metadata ->> 'transport' not in ('gmail', 'outlook') then raise exception 'NOT_FOUND'; end if;
  v_day := public.zella_business_email_local_day(m.business_id);
  select * into s from public.business_email_senders where business_id = m.business_id for update;
  if s.business_id is not null and s.route = 'mailbox' then
    if p_reason = 'quota' then
      update public.business_email_senders set cap_reached_on = v_day, updated_at = now() where business_id = m.business_id;
    else
      update public.business_email_senders set mailbox_status = 'reconnect_needed', updated_at = now() where business_id = m.business_id;
    end if;
    -- once per day for each kind of problem
    if (p_reason = 'quota' and s.cap_notified_on is distinct from v_day) or (p_reason = 'sign_in' and s.problem_notified_on is distinct from v_day) then
      perform public.zella_notify(m.business_id,
        case when p_reason = 'quota' then 'business_email_daily_cap' else 'business_email_reconnect' end,
        case when p_reason = 'quota' then 'Your mailbox reached its daily sending limit'
             else 'Reconnect your mailbox to send from your own address' end,
        case when p_reason = 'quota'
             then 'Your ' || case when s.mailbox_provider = 'gmail' then 'Gmail' else 'Outlook' end || ' mailbox stopped sending for today. Today''s other customer emails go out from Zella Voice''s address with your business name, and replies still reach your email. They go from your own address again tomorrow. A verified business domain has no daily limit.'
             else 'Your ' || case when s.mailbox_provider = 'gmail' then 'Gmail' else 'Outlook' end || ' mailbox no longer lets Zella Voice send. Customer emails go out from Zella Voice''s address with your business name until it is reconnected in Settings, Business email.' end,
        'warning', 'settings', null, null);
      if p_reason = 'quota' then update public.business_email_senders set cap_notified_on = v_day where business_id = m.business_id;
      else update public.business_email_senders set problem_notified_on = v_day where business_id = m.business_id; end if;
      v_told := true;
    end if;
  end if;
  if m.status = 'queued' then
    update public.email_messages set status = 'failed', updated_at = now(),
           metadata = metadata || jsonb_build_object('error', case when p_reason = 'quota' then 'mailbox_daily_cap' else 'mailbox_sign_in' end)
     where id = m.id;
  end if;
  -- the item that sent it goes back, due now, with its try given back: the next run sends it through the fallback
  if (m.metadata ->> 'reminder_id') ~ '^[0-9a-f-]{36}$' then
    update public.appointment_reminders set status = 'pending', due_at = now(), attempts = greatest(attempts - 1, 0)
     where id = (m.metadata ->> 'reminder_id')::uuid and business_id = m.business_id and status = 'sending'
    returning 'reminder' into v_requeued;
  elsif (m.metadata ->> 'task_id') ~ '^[0-9a-f-]{36}$' then
    update public.followup_tasks set status = 'pending', due_at = now(), attempts = greatest(attempts - 1, 0), updated_at = now()
     where id = (m.metadata ->> 'task_id')::uuid and business_id = m.business_id and status = 'in_progress'
    returning 'task' into v_requeued;
  end if;
  return jsonb_build_object('ok', true, 'requeued', v_requeued, 'told_business', v_told);
end $$;

-- who may call what (SEC-6, SEC-7): the setup screen's read for signed in people; everything else the server only
revoke all on function public.zella_business_email_actor_can(uuid,uuid), public.zella_business_email_mailbox_can_connect(uuid,uuid), public.zella_business_email_local_day(uuid),
  public.zella_business_email_records(jsonb), public.zella_business_email_status(uuid),
  public.zella_business_email_domain_begin(uuid,uuid,text), public.zella_business_email_domain_saved(uuid,uuid,text,text,jsonb,text),
  public.zella_business_email_domain_checked(uuid,uuid,text,text,jsonb), public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text),
  public.zella_business_email_disconnect(uuid,uuid), public.zella_business_email_sender(uuid),
  public.zella_business_email_mailbox_credentials(uuid), public.zella_business_email_mailbox_refused(uuid,text) from public, anon, authenticated;
grant execute on function public.zella_business_email_actor_can(uuid,uuid), public.zella_business_email_mailbox_can_connect(uuid,uuid), public.zella_business_email_local_day(uuid),
  public.zella_business_email_records(jsonb), public.zella_business_email_status(uuid),
  public.zella_business_email_domain_begin(uuid,uuid,text), public.zella_business_email_domain_saved(uuid,uuid,text,text,jsonb,text),
  public.zella_business_email_domain_checked(uuid,uuid,text,text,jsonb), public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text),
  public.zella_business_email_disconnect(uuid,uuid), public.zella_business_email_sender(uuid),
  public.zella_business_email_mailbox_credentials(uuid), public.zella_business_email_mailbox_refused(uuid,text) to service_role;
grant execute on function public.zella_business_email_status(uuid) to authenticated;

commit;
