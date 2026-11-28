-- Zella Voice: the business's own email address, part 8: pending email domains expire after 7 days (owner, 27 Nov
-- 2026; docs/ARCHITECTURE.md §14.4, REQ-BEM-20 to REQ-BEM-26). Needs sql/zella_business_email.sql,
-- sql/zella_business_email_caps.sql and sql/zella_business_email_mailbox_link.sql.
-- A domain a business set up but has not verified (Resend's status pending or failed) holds that domain for the
-- business (one business per domain) and sits in Zella Voice's Resend account. Now:
--   1. business_email_senders.domain_pending_since: when the domain became unverified (a trigger sets it whenever a
--      domain is set up, or a domain becomes unverified, and clears it once verified or gone), and when the day 2 and
--      day 5 reminders went. Domains already pending when this file is applied start their 7 days now.
--   2. zella_business_email_pending_domains_run(): the daily job. Day 2 and day 5: the business's owners and admins get
--      a reminder (zella_notify, a warning, so the platform email path emails it as N1; held as test mode while
--      email_live is off). Day 7: the domain is removed from the business (back to the fallback: the business's name
--      at Zella Voice's address, Reply-To the business email; it can set a domain up again at any time), the business
--      is told, and its Resend domain is queued for removal. A domain is never removed without the day 5 reminder at
--      least 36 hours before, so a job switched on late still warns first.
--   3. zella_business_email_domain_remove_pending(business, admin, reason): a Zella Voice admin with businesses.manage
--      removes a pending domain at once (for example when another business proves it owns it). Reason required;
--      audited; the business is told. A verified domain is never removed this way.
--   4. business_email_domain_removals: the Resend domains waiting to be removed (ARC-4: pending, sending, done, skipped
--      when another business uses that Resend domain again, failed after 5 tries with an admin alert). The
--      business-email edge function removes them at Resend (DELETE /domains/{id}, its existing call): at once for an
--      admin removal, and when the daily job wakes it (zella_business_email_kick_removals: only when there is work,
--      business_email_url is set and the Vault secret zella_business_email_jobs_secret exists; checked by
--      zella_business_email_jobs_check).
--   5. zella_business_email_status also says when an unverified domain is removed (only while the daily job is on, so
--      the screen never promises a removal that will not happen) and whether the person may remove it now.
--   6. The daily job, pg_cron "zella_business_email_pending_domains" at 17:41 UTC, is created switched OFF. Turning it on
--      is a live switch for the owner:
--        select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'zella_business_email_pending_domains'), active := true);
--      Removal at Resend also needs business_email_url (the business-email function's address) set.
-- Nothing here calls Resend or sends anything. zella_business_email_status must be
-- sql/zella_business_email_mailbox_link.sql's version (or already this file's), otherwise VERSION_MISMATCH and nothing
-- changes. Safe to run twice. Rollback: sql/rollback/zella_business_email_pending_domains_rollback.sql
begin;

do $$
declare f record;
begin
  if to_regclass('public.business_email_senders') is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_business_email_platform_admin(uuid,uuid)') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null
     or not exists (select 1 from pg_proc p where p.pronamespace = to_regnamespace('vault') and p.proname = 'create_secret') then
    raise exception 'VERSION_MISMATCH: apply sql/zella_business_email.sql, sql/zella_business_email_caps.sql and sql/zella_business_email_mailbox_link.sql first';
  end if;
  if md5(pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure)) not in ('ba293561f9b771ea5eab89b9a22e9c85', '15745e93ec89f04f6fa22fa20b85228c') then
    raise exception 'VERSION_MISMATCH: zella_business_email_status is not a version this file was written for';
  end if;
  for f in select * from (values ('public.zella_business_email_pending_since_trg()', '9b6d336ce14a5096cf1f075b7a983e54'),
                                 ('public.zella_business_email_domain_drop(uuid,uuid,text,text)', '736448d25dcc36634b65ad38966df151'),
                                 ('public.zella_business_email_pending_domains_run()', 'd3c7164ac643a4b61ba892f8a9725ac0'),
                                 ('public.zella_business_email_domain_remove_pending(uuid,uuid,text)', 'cd1a655a0a4352d4bfd3a8028f1dc835'),
                                 ('public.zella_business_email_domain_removals_claim(integer,uuid)', 'a55adc87ab3c6d8028e1ed1fbfbb2dc9'),
                                 ('public.zella_business_email_domain_removal_done(uuid,uuid,boolean,integer)', 'a56206c0579942e97c17f7d6c7eb7464'),
                                 ('public.zella_business_email_kick_removals()', 'efe4579b0295168604861a7b7dd91803'),
                                 ('public.zella_business_email_jobs_check(text)', 'd4e517045a0bbd94a2dedaedb6315c0f')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.sig;
    end if;
  end loop;
  if to_regclass('public.business_email_domain_removals') is not null and not exists (
       select 1 from pg_description where objoid = to_regclass('public.business_email_domain_removals') and objsubid = 0 and description like 'Zella Voice: Resend domains%') then
    raise exception 'VERSION_MISMATCH: a different business_email_domain_removals table already exists';
  end if;
  if md5(pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure)) = 'ba293561f9b771ea5eab89b9a22e9c85' then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    select 'zella_business_email_pending_domains', 'public.zella_business_email_status(uuid)', d, md5(d)
      from pg_get_functiondef('public.zella_business_email_status(uuid)'::regprocedure) d
    on conflict (migration, signature) do nothing;
  end if;
end $$;

-- 1. when a domain became unverified, and the reminders
alter table public.business_email_senders add column if not exists domain_pending_since timestamptz;
alter table public.business_email_senders add column if not exists domain_reminded_day2_at timestamptz;
alter table public.business_email_senders add column if not exists domain_reminded_day5_at timestamptz;

create or replace function public.zella_business_email_pending_since_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.route is distinct from 'domain' or new.domain_status not in ('pending', 'failed') then
    new.domain_pending_since := null; new.domain_reminded_day2_at := null; new.domain_reminded_day5_at := null;
  elsif tg_op = 'INSERT' or old.route is distinct from 'domain' or old.domain is distinct from new.domain or old.domain_status not in ('pending', 'failed') then
    -- a new domain, or one that just became unverified: its 7 days start now
    new.domain_pending_since := now(); new.domain_reminded_day2_at := null; new.domain_reminded_day5_at := null;
  elsif new.domain_pending_since is null then
    new.domain_pending_since := now();
  end if;
  return new;
end $$;
revoke all on function public.zella_business_email_pending_since_trg() from public, anon, authenticated;
drop trigger if exists zella_business_email_pending_since on public.business_email_senders;
create trigger zella_business_email_pending_since before insert or update on public.business_email_senders
  for each row execute function public.zella_business_email_pending_since_trg();
-- domains already pending start their 7 days now
update public.business_email_senders set domain_pending_since = now()
 where route = 'domain' and domain_status in ('pending', 'failed') and domain_pending_since is null;
create index if not exists business_email_senders_pending_idx on public.business_email_senders (domain_pending_since)
  where route = 'domain' and domain_status in ('pending', 'failed');

-- 4. the Resend domains waiting to be removed
create table if not exists public.business_email_domain_removals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  domain text not null check (length(domain) <= 253),
  resend_domain_id text not null check (resend_domain_id ~ '^[A-Za-z0-9_-]{1,100}$'),
  reason text not null check (reason in ('expired', 'admin')),
  status text not null default 'pending' check (status in ('pending', 'sending', 'done', 'skipped', 'failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  claim_token uuid,
  claimed_at timestamptz,
  last_error text check (last_error is null or length(last_error) <= 200),
  created_by uuid,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
comment on table public.business_email_domain_removals is 'Zella Voice: Resend domains of expired or admin removed pending business email domains, waiting to be removed at Resend';
create unique index if not exists business_email_domain_removals_open_key on public.business_email_domain_removals (resend_domain_id) where status in ('pending', 'sending');
create index if not exists business_email_domain_removals_due_idx on public.business_email_domain_removals (next_attempt_at) where status in ('pending', 'sending');
create index if not exists business_email_domain_removals_business_idx on public.business_email_domain_removals (business_id, created_at desc);
alter table public.business_email_domain_removals enable row level security;
revoke all on public.business_email_domain_removals from public, anon, authenticated;
grant all on public.business_email_domain_removals to service_role;

-- the edge function's address (empty: nothing is called) and the call secret, made here and kept only in Vault; the
-- rollback removes them only if this file made them
do $$ begin
  if not exists (select 1 from public.platform_settings where key = 'business_email_url') then
    insert into public.platform_settings (key, value) values ('business_email_url', '""'::jsonb);
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_business_email_pending_domains', 'created: platform_settings.business_email_url', 'created by this migration', md5('created'))
    on conflict (migration, signature) do nothing;
  end if;
  if not exists (select 1 from vault.secrets where name = 'zella_business_email_jobs_secret') then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'zella_business_email_jobs_secret',
                                'Zella Voice: business-email edge function call secret (domain removals)');
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_business_email_pending_domains', 'created: vault zella_business_email_jobs_secret', 'created by this migration', md5('created'))
    on conflict (migration, signature) do nothing;
  end if;
end $$;

create or replace function public.zella_business_email_jobs_check(p_secret text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'zella_business_email_jobs_secret' limit 1;
  return v is not null and length(v) >= 32 and p_secret is not null and p_secret = v;
end $$;

-- a pending domain leaves the business: back to the fallback, its Resend domain queued for removal, audited, the
-- business told. Internal: called by the daily job and by an admin's removal only.
create or replace function public.zella_business_email_domain_drop(p_business_id uuid, p_actor uuid, p_why text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.business_email_senders; v_removal uuid;
begin
  if p_why not in ('expired', 'admin') then raise exception 'BAD_REASON'; end if;
  select * into s from public.business_email_senders where business_id = p_business_id for update;
  if s.business_id is null or s.route is distinct from 'domain' or s.domain_status not in ('pending', 'failed') then
    return jsonb_build_object('ok', false, 'reason', 'NOT_PENDING');
  end if;
  update public.business_email_senders
     set route = null, address = null, domain = null, domain_status = 'none', resend_domain_id = null, dns_records = '[]'::jsonb, domain_checked_at = null,
         domain_verified_at = null, cap_reached_on = null, updated_at = now(), updated_by = p_actor
   where business_id = p_business_id;
  if s.resend_domain_id is not null then
    insert into public.business_email_domain_removals (business_id, domain, resend_domain_id, reason, created_by)
    values (p_business_id, s.domain, s.resend_domain_id, p_why, p_actor)
    on conflict (resend_domain_id) where status in ('pending', 'sending') do nothing returning id into v_removal;
    if v_removal is null then
      select id into v_removal from public.business_email_domain_removals where resend_domain_id = s.resend_domain_id and status in ('pending', 'sending');
    end if;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, case when p_why = 'expired' then 'business_email.domain_expired' else 'business_email.domain_removed_by_admin' end, 'business', p_business_id,
          jsonb_build_object('route', s.route, 'domain', s.domain, 'domain_status', s.domain_status, 'domain_pending_since', s.domain_pending_since),
          jsonb_strip_nulls(jsonb_build_object('route', 'fallback', 'reason', p_reason, 'removal_id', v_removal)));
  perform public.zella_notify(p_business_id, 'business_email_domain_removed', 'Your email domain was removed from your setup',
    case when p_why = 'expired'
         then s.domain || ' wasn''t verified within 7 days, so it was removed. Customer emails keep coming from Zella Voice''s address with your business name, and replies still reach your email. You can set it up again at any time in Settings, Business email address.'
         else 'The Zella Voice team removed ' || s.domain || ', which wasn''t verified, from your business email setup. Customer emails keep coming from Zella Voice''s address with your business name, and replies still reach your email. Contact Zella Voice support with any questions.' end,
    'warning', 'settings', null, null);
  return jsonb_build_object('ok', true, 'removal_id', v_removal, 'domain', s.domain);
end $$;

-- 2. the daily job: reminders on day 2 and day 5, removal from day 7 (never sooner than 36 hours after the day 5
-- reminder). At most 200 businesses a run; the rest the next day.
create or replace function public.zella_business_email_pending_domains_run() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_r2 integer := 0; v_r5 integer := 0; v_expired integer := 0; v_kick text; v_res jsonb; v_until text;
begin
  for r in select s.business_id, s.domain, s.domain_pending_since, s.domain_reminded_day2_at, s.domain_reminded_day5_at,
                  coalesce(nullif(b.timezone, ''), 'America/New_York') as tz
             from public.business_email_senders s join public.businesses b on b.id = s.business_id
            where s.route = 'domain' and s.domain_status in ('pending', 'failed') and s.domain_pending_since <= now() - interval '2 days'
            order by s.domain_pending_since limit 200 for update of s skip locked loop
    if r.domain_pending_since <= now() - interval '7 days' and r.domain_reminded_day5_at <= now() - interval '36 hours' then
      v_res := public.zella_business_email_domain_drop(r.business_id, null, 'expired', null);
      if (v_res ->> 'ok')::boolean then v_expired := v_expired + 1; end if;
    elsif r.domain_pending_since <= now() - interval '5 days' then
      if r.domain_reminded_day5_at is null then
        v_until := to_char(greatest(r.domain_pending_since + interval '7 days', now() + interval '36 hours') at time zone r.tz, 'FMDD Mon YYYY');
        perform public.zella_notify(r.business_id, 'business_email_domain_pending', 'Your email domain still isn''t verified',
          'The DNS records for ' || r.domain || ' still aren''t working, so customer emails come from Zella Voice''s address with your business name. Add the records where your domain is managed, then press Verify in Settings, Business email address. If it isn''t verified by ' || v_until || ', it is removed from your setup, and you can set it up again at any time.',
          'warning', 'settings', null, null);
        update public.business_email_senders set domain_reminded_day5_at = now() where business_id = r.business_id;
        v_r5 := v_r5 + 1;
      end if;
    elsif r.domain_reminded_day2_at is null then
      v_until := to_char((r.domain_pending_since + interval '7 days') at time zone r.tz, 'FMDD Mon YYYY');
      perform public.zella_notify(r.business_id, 'business_email_domain_pending', 'Your email domain isn''t verified yet',
        'The DNS records for ' || r.domain || ' aren''t working yet, so customer emails come from Zella Voice''s address with your business name. Add the records where your domain is managed, then press Verify in Settings, Business email address. If it isn''t verified by ' || v_until || ', it is removed from your setup, and you can set it up again at any time.',
        'warning', 'settings', null, null);
      update public.business_email_senders set domain_reminded_day2_at = now() where business_id = r.business_id;
      v_r2 := v_r2 + 1;
    end if;
  end loop;
  begin
    v_kick := public.zella_business_email_kick_removals();
  exception when others then
    v_kick := 'kick_failed';   -- the next run, or an admin's removal, wakes it again
    raise warning 'zella_business_email_kick_removals: %', sqlerrm;
  end;
  return jsonb_build_object('reminded_day_2', v_r2, 'reminded_day_5', v_r5, 'expired', v_expired, 'removals', v_kick);
end $$;

-- 3. a Zella Voice admin removes a pending domain at once. Server only (business-email, which then removes it at Resend).
create or replace function public.zella_business_email_domain_remove_pending(p_business_id uuid, p_actor uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.zella_business_email_platform_admin(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then return jsonb_build_object('ok', false, 'reason', 'REASON_REQUIRED'); end if;
  return public.zella_business_email_domain_drop(p_business_id, p_actor, 'admin', left(btrim(p_reason), 300));
end $$;

-- 4. the removals at Resend. Server only (business-email). A Resend domain a business uses again is never removed;
-- after 5 tries a removal is failed with an admin alert. p_id claims one removal (an admin's, at once).
create or replace function public.zella_business_email_domain_removals_claim(p_limit integer default 10, p_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare x record; v jsonb;
begin
  update public.business_email_domain_removals r set status = 'skipped', last_error = 'in_use', done_at = now()
   where r.status in ('pending', 'sending') and exists (select 1 from public.business_email_senders s where s.resend_domain_id = r.resend_domain_id);
  for x in update public.business_email_domain_removals set status = 'failed', done_at = now()
            where status in ('pending', 'sending') and attempts >= 5 and next_attempt_at <= now()
            returning id, business_id, domain loop
    perform public.zella_platform_alert('business_email_domain_removal_failed', 'An email domain was not removed from Resend',
      'Resend did not confirm removing ' || x.domain || ' after 5 tries. Remove it in Resend by hand; the business already sends from the fallback.',
      'warning', x.business_id, 'business_email_domain_removal:' || x.id, jsonb_build_object('removal_id', x.id));
  end loop;
  with c as (
    update public.business_email_domain_removals r set status = 'sending', attempts = r.attempts + 1, claimed_at = now(), claim_token = gen_random_uuid(),
           next_attempt_at = now() + interval '10 minutes'
     where r.id in (select id from public.business_email_domain_removals
                     where status in ('pending', 'sending') and next_attempt_at <= now() and attempts < 5 and (p_id is null or id = p_id)
                     order by next_attempt_at limit least(greatest(coalesce(p_limit, 10), 1), 25) for update skip locked)
    returning r.id, r.resend_domain_id, r.claim_token)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'resend_domain_id', c.resend_domain_id, 'claim_token', c.claim_token)), '[]'::jsonb) into v from c;
  return v;
end $$;

-- Resend's answer for one claimed removal: removed (2xx, or 404: already gone), else tried again later
create or replace function public.zella_business_email_domain_removal_done(p_id uuid, p_claim_token uuid, p_ok boolean, p_http_status integer) returns text
language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  update public.business_email_domain_removals
     set status = case when p_ok then 'done' else 'pending' end, done_at = case when p_ok then now() end,
         last_error = case when p_ok then null else left('Resend answered ' || coalesce(p_http_status::text, 'nothing (timed out)'), 200) end,
         next_attempt_at = case when p_ok then next_attempt_at else now() + make_interval(mins => attempts * attempts * 10) end
   where id = p_id and status = 'sending' and claim_token = p_claim_token
  returning status into v;
  return coalesce(v, 'NOT_THIS_CLAIM');
end $$;

-- wake business-email only when a removal is due, it is set up, and the secret exists
create or replace function public.zella_business_email_kick_removals() returns text
language plpgsql security definer set search_path = '' as $$
declare v_url text := nullif(trim(public.zella_setting('business_email_url', '""'::jsonb) #>> '{}'), ''); v_secret text;
begin
  if not exists (select 1 from public.business_email_domain_removals where status in ('pending', 'sending') and next_attempt_at <= now()) then return 'nothing_due'; end if;
  if v_url is null or v_url !~ '^https://' then return 'not_set_up'; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_business_email_jobs_secret' limit 1;
  if v_secret is null then return 'no_secret'; end if;
  perform net.http_post(url := v_url, body := '{"action": "domain_removals"}'::jsonb,
                        headers := jsonb_build_object('Content-Type', 'application/json', 'X-Zella-Secret', v_secret), timeout_milliseconds := 25000);
  return 'called';
end $$;

-- 5. what the setup screen shows (sql/zella_business_email_mailbox_link.sql's), now with when an unverified domain is
-- removed (only while the daily job is on) and whether this person may remove it now
create or replace function public.zella_business_email_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.business_email_senders; b record; v_routes jsonb; v_reply text; v_active text; v_day date; v_sent integer; v_link jsonb;
        v_job_on boolean := false; v_expires timestamptz;
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
  -- an unverified domain's removal date, only while the daily job is on (otherwise nothing is removed)
  if s.route = 'domain' and s.domain_status in ('pending', 'failed') and s.domain_pending_since is not null and to_regclass('cron.job') is not null then
    execute 'select exists (select 1 from cron.job where jobname = $1 and active)' into v_job_on using 'zella_business_email_pending_domains';
    if v_job_on then
      v_expires := greatest(s.domain_pending_since + interval '7 days', s.domain_reminded_day5_at + interval '36 hours',
                            case when s.domain_reminded_day5_at is null and s.domain_pending_since <= now() - interval '5 days' then now() + interval '36 hours' end);
    end if;
  end if;
  return jsonb_build_object(
    'route', s.route,                  -- the route set up (or being set up), or null: the fallback
    'active_route', v_active,          -- the route the next email actually uses: domain, mailbox or fallback
    'address', coalesce(s.address, case when s.route = 'mailbox' then s.mailbox_account end),
    'domain', s.domain, 'domain_status', coalesce(s.domain_status, 'none'), 'dns_records', coalesce(s.dns_records, '[]'::jsonb),
    'domain_checked_at', s.domain_checked_at, 'domain_verified_at', s.domain_verified_at,
    -- pending domains (owner, 27 Nov 2026): when it became unverified, when it is removed, whether this person may remove it now
    'domain_pending_since', s.domain_pending_since, 'domain_expires_at', v_expires,
    'domain_expires_on', to_char(v_expires at time zone coalesce(nullif(b.timezone, ''), 'America/New_York'), 'FMDD Mon YYYY'),
    'can_remove_pending', s.route = 'domain' and s.domain_status in ('pending', 'failed') and coalesce(public.zella_admin_can('businesses.manage'), false),
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

-- who may call what (SEC-6, SEC-7): every new function is server only; the drop helper is for the functions above only
revoke all on function public.zella_business_email_domain_drop(uuid,uuid,text,text), public.zella_business_email_pending_domains_run(),
  public.zella_business_email_domain_remove_pending(uuid,uuid,text), public.zella_business_email_domain_removals_claim(integer,uuid),
  public.zella_business_email_domain_removal_done(uuid,uuid,boolean,integer), public.zella_business_email_kick_removals(),
  public.zella_business_email_jobs_check(text) from public, anon, authenticated;
grant execute on function public.zella_business_email_domain_remove_pending(uuid,uuid,text), public.zella_business_email_domain_removals_claim(integer,uuid),
  public.zella_business_email_domain_removal_done(uuid,uuid,boolean,integer), public.zella_business_email_jobs_check(text) to service_role;

-- 6. the daily job, created switched OFF (a live switch for the owner). Supabase does not allow editing cron.job
-- directly, so it is switched off with cron.alter_job; the direct update is only for a pg_cron without alter_job.
do $$ declare v_id bigint; begin
  if to_regnamespace('cron') is not null and not exists (select 1 from cron.job where jobname = 'zella_business_email_pending_domains') then
    v_id := cron.schedule('zella_business_email_pending_domains', '41 17 * * *', 'select public.zella_business_email_pending_domains_run()');
    if to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null then
      perform cron.alter_job(job_id := v_id, active := false);
    else
      update cron.job set active = false where jobid = v_id;
    end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_business_email_pending_domains', 'created: cron zella_business_email_pending_domains', 'created by this migration', md5('created'))
    on conflict (migration, signature) do nothing;
  end if;
end $$;

do $$
declare f record;
begin
  for f in select * from (values ('public.zella_business_email_status(uuid)', '15745e93ec89f04f6fa22fa20b85228c'), ('public.zella_business_email_pending_since_trg()', '9b6d336ce14a5096cf1f075b7a983e54'),
                                 ('public.zella_business_email_domain_drop(uuid,uuid,text,text)', '736448d25dcc36634b65ad38966df151'),
                                 ('public.zella_business_email_pending_domains_run()', 'd3c7164ac643a4b61ba892f8a9725ac0'),
                                 ('public.zella_business_email_domain_remove_pending(uuid,uuid,text)', 'cd1a655a0a4352d4bfd3a8028f1dc835'),
                                 ('public.zella_business_email_domain_removals_claim(integer,uuid)', 'a55adc87ab3c6d8028e1ed1fbfbb2dc9'),
                                 ('public.zella_business_email_domain_removal_done(uuid,uuid,boolean,integer)', 'a56206c0579942e97c17f7d6c7eb7464'),
                                 ('public.zella_business_email_kick_removals()', 'efe4579b0295168604861a7b7dd91803'),
                                 ('public.zella_business_email_jobs_check(text)', 'd4e517045a0bbd94a2dedaedb6315c0f')) as t(sig, want) loop
    if md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.sig; end if;
  end loop;
end $$;

commit;
