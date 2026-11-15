-- Zella Voice: the platform outbox for every email Zella Voice sends to a business (its owner, billing contacts and
-- team): account and setup, sign in and access, summaries, alerts, usage, service, and billing (docs/BUSINESS_EMAILS.md,
-- docs/BILLING_EMAILS.md). Emails to a business's own customers stay in email_messages; this is only Zella Voice
-- writing to its customers.
--
-- Safe by design:
--   never twice   one row per business and dedupe key (`email:<code>:<object id>:<occurrence>`, unique per business);
--                 queueing again returns the first row and changes nothing; another business's key never collides
--   never live by accident   while platform_settings.email_live is not true, a claim marks rows dry_run and hands the
--                 sender nothing, so nothing can leave
--   a lost reply  the sender uses the dedupe key as the provider's idempotency key; a row stuck in sending is claimed
--                 again with the same key; after 5 attempts it is held and an admin alert is raised, never resent blindly
--   optional emails respect the person's choice (notification_preferences, type `email:<code>`, email_enabled false);
--                 mandatory ones (account, service, money) are always sent
--   server only   the browser can't write it; business owners and admins read their own business's rows; platform
--                 admins read all through zella_admin_platform_emails
-- Nothing here sends an email. Rollback: sql/rollback/zella_platform_emails_rollback.sql
begin;

do $$ begin
  if to_regprocedure('public.zella_admin_require(text)') is null or to_regprocedure('public.zella_has_role(uuid,text[])') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: a function this file needs is missing';
  end if;
  if to_regclass('public.platform_emails') is not null and not exists (
       select 1 from pg_description where objoid = to_regclass('public.platform_emails') and objsubid = 0 and description like 'Zella Voice platform outbox%') then
    raise exception 'VERSION_MISMATCH: a different platform_emails table already exists';
  end if;
end $$;

create table if not exists public.platform_emails (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid,                                  -- the person it is for, when it is for one person (optional emails)
  code text not null check (code ~ '^[A-Z][0-9]{1,2}$'),
  dedupe_key text not null check (dedupe_key ~ '^email:[A-Z][0-9]{1,2}:.+' and length(dedupe_key) <= 300),
  to_email text not null check (to_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(to_email) <= 320),
  cc text[] not null default '{}' check (cardinality(cc) <= 3),
  subject text not null check (length(subject) between 1 and 200),
  html text not null check (length(html) between 1 and 200000),
  text_body text not null check (length(text_body) between 1 and 50000),
  mandatory boolean not null,
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'dry_run', 'suppressed', 'failed', 'held')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  provider_message_id text,
  last_error text,
  claim_token uuid,                              -- set by each claim; only that claim may finish the row
  created_at timestamptz not null default now(),
  unique (business_id, dedupe_key)
);
comment on table public.platform_emails is 'Zella Voice platform outbox: every email Zella Voice sends to a business (sql/zella_platform_emails.sql)';
create index if not exists platform_emails_business_idx on public.platform_emails (business_id, created_at desc);
create index if not exists platform_emails_due_idx on public.platform_emails (next_attempt_at) where status in ('queued', 'sending');

alter table public.platform_emails enable row level security;
revoke all on public.platform_emails from public, anon, authenticated;
grant select on public.platform_emails to authenticated;
drop policy if exists platform_emails_read on public.platform_emails;
create policy platform_emails_read on public.platform_emails for select to authenticated
  using (public.zella_has_role(business_id, array['owner', 'admin']));

-- Queue one email (the server renders it with web/src/emails/businessEmails.js). Returns the row's id; the same key
-- again returns the first row unchanged.
create or replace function public.zella_queue_platform_email(p_business uuid, p_code text, p_dedupe_key text, p_to text, p_subject text,
                                                             p_html text, p_text text, p_mandatory boolean, p_user uuid default null, p_cc text[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status text := 'queued';
begin
  if p_mandatory is null then raise exception 'MANDATORY_REQUIRED'; end if;
  if p_dedupe_key is null or left(p_dedupe_key, length('email:' || coalesce(p_code, '') || ':')) <> 'email:' || coalesce(p_code, '') || ':' then
    raise exception 'BAD_KEY: the key must start with email:<code>:';
  end if;
  select id into v_id from public.platform_emails where business_id = p_business and dedupe_key = p_dedupe_key;
  if v_id is not null then return v_id; end if;
  if not p_mandatory and p_user is not null and exists (
       select 1 from public.notification_preferences np
        where np.business_id = p_business and np.user_id = p_user and np.notification_type = 'email:' || p_code and not np.email_enabled) then
    v_status := 'suppressed';
  end if;
  insert into public.platform_emails (business_id, user_id, code, dedupe_key, to_email, cc, subject, html, text_body, mandatory, status)
  values (p_business, p_user, p_code, p_dedupe_key, lower(trim(p_to)), coalesce(p_cc, '{}'), p_subject, p_html, p_text, p_mandatory, v_status)
  on conflict (business_id, dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from public.platform_emails where business_id = p_business and dedupe_key = p_dedupe_key; end if;
  return v_id;
end $$;

-- The sender takes due emails. While email_live is off, due rows become dry_run and nothing is handed out.
create or replace function public.zella_claim_platform_emails(p_limit integer default 20)
returns setof public.platform_emails language plpgsql security definer set search_path = public as $$
declare v_live boolean := coalesce((select value::text = 'true' from public.platform_settings where key = 'email_live'), false);
        r record;
begin
  -- held: a send that kept failing or never answered; a person decides
  for r in update public.platform_emails set status = 'held', last_error = coalesce(last_error, 'no answer from the provider')
            where status in ('queued', 'sending') and attempts >= 5 and next_attempt_at <= now()
            returning id, business_id, code, dedupe_key loop
    perform public.zella_platform_alert('platform_email_held', 'An email to a business is held', 'Email ' || r.code || ' was tried 5 times. Check it before sending it again.',
                                        'warning', r.business_id, 'platform_email_held:' || r.dedupe_key, jsonb_build_object('email_id', r.id));
  end loop;
  if not v_live then
    update public.platform_emails set status = 'dry_run' where status = 'queued' and next_attempt_at <= now();
    return;
  end if;
  return query
    update public.platform_emails e set status = 'sending', attempts = e.attempts + 1, claimed_at = now(), claim_token = gen_random_uuid(),
           next_attempt_at = now() + interval '10 minutes'   -- not answered in 10 minutes: claimed again with the same key
     where e.id in (select id from public.platform_emails
                     where status in ('queued', 'sending') and next_attempt_at <= now() and attempts < 5
                     order by next_attempt_at limit least(greatest(coalesce(p_limit, 20), 1), 100)
                     for update skip locked)
    returning e.*;
end $$;

-- The sender reports back with the claim_token it was handed. A late answer from an older claim (the row was claimed
-- again after 10 minutes) changes nothing. A failure waits longer each time (1, 4, 9, 16 minutes); the fifth is held.
create or replace function public.zella_finish_platform_email(p_id uuid, p_claim_token uuid, p_ok boolean, p_provider_id text default null, p_error text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  update public.platform_emails set
         status = case when p_ok then 'sent' else 'queued' end,
         sent_at = case when p_ok then now() else sent_at end,
         provider_message_id = coalesce(p_provider_id, provider_message_id),
         last_error = case when p_ok then null else left(coalesce(p_error, 'unknown error'), 500) end,
         next_attempt_at = case when p_ok then next_attempt_at else now() + make_interval(mins => attempts * attempts) end
   where id = p_id and status = 'sending' and claim_token = p_claim_token
  returning status into v_status;
  return coalesce(v_status, 'NOT_THIS_CLAIM');
end $$;

-- Admin view: every platform email, newest first, without the bodies.
create or replace function public.zella_admin_platform_emails(p_business uuid default null, p_status text default null, p_code text default null,
                                                              p_limit integer default 25, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select e.id, e.business_id, b.name as business_name, e.code, e.to_email, e.subject, e.mandatory, e.status, e.attempts,
             e.last_error, e.created_at, e.sent_at
        from public.platform_emails e join public.businesses b on b.id = e.business_id
       where (p_business is null or e.business_id = p_business) and (p_status is null or e.status = p_status) and (p_code is null or e.code = p_code))
    select jsonb_build_object('total', (select count(*) from f),
             'rows', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from f order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb)));
end $$;

revoke all on function public.zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[]) from public, anon, authenticated;
revoke all on function public.zella_claim_platform_emails(integer) from public, anon, authenticated;
revoke all on function public.zella_finish_platform_email(uuid,uuid,boolean,text,text) from public, anon, authenticated;
revoke all on function public.zella_admin_platform_emails(uuid,text,text,integer,integer) from public, anon;
grant execute on function public.zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[]) to service_role;
grant execute on function public.zella_claim_platform_emails(integer) to service_role;
grant execute on function public.zella_finish_platform_email(uuid,uuid,boolean,text,text) to service_role;
grant execute on function public.zella_admin_platform_emails(uuid,text,text,integer,integer) to authenticated;

commit;
