-- Zella - spam protection and abuse prevention (2026-10-26). Safe to re-run. Adds tables, functions and triggers;
-- replaces one function (zella_caller_context, built from its live body; the original logic is kept unchanged as
-- zella_caller_context_base). Changes and deletes no existing rows. Design: docs/SPAM_PROTECTION.md.
--
--   spam_settings           one row per business: what its own protection does (secure defaults when absent)
--   spam_list_entries       block and allow lists: per business, or platform-wide (business_id null, block only)
--   spam_incidents          one incident per sender, channel and day, with risk score, reasons and review status
--   spam_incident_events    timeline: detections, each counted source record (once), decisions, notes, list changes
--   platform_settings 'spam_defaults'  platform thresholds (Admin > Security & Abuse)
--
-- Enforcement (all server side; nothing here trusts the browser):
--   calls     zella_caller_context (start of call): blocked / high-risk callers -> the AI ends politely, uses no tools
--             calls insert: repeated calls, AI manipulation in the transcript; callbacks for blocked callers cancelled
--   bookings  appointments before insert, non-staff bookings: blocked contact or over the limit -> kept as a request
--   sms       sms_messages insert (inbound): flooding, links, phrases, lists; auto-replies to blocked senders skipped
--   email     email_messages insert (inbound): same, plus the provider's own spam verdict when it sends one
--   Detection never blocks a legitimate event because detection itself failed: every hook falls back to "allow".
--
-- Rollback: drop the triggers zella_spam_*; drop function zella_caller_context and rename zella_caller_context_base
--   back; drop the four tables; delete from platform_settings where key = 'spam_defaults'.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------------------------------------------

create table if not exists public.spam_settings (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  enabled boolean not null default true,
  call_screening text not null default 'flag' check (call_screening in ('flag', 'screen')),
  ai_spam_handling text not null default 'end_politely' check (ai_spam_handling in ('end_politely', 'take_message')),
  repeat_call_limit integer not null default 5 check (repeat_call_limit between 2 and 50),
  repeat_window_minutes integer not null default 60 check (repeat_window_minutes between 5 and 1440),
  sms_monitoring boolean not null default true,
  sms_flood_limit integer not null default 10 check (sms_flood_limit between 3 and 200),
  email_monitoring boolean not null default true,
  email_flood_limit integer not null default 10 check (email_flood_limit between 3 and 200),
  booking_protection boolean not null default true,
  booking_daily_limit integer not null default 3 check (booking_daily_limit between 1 and 20),
  auto_restrict boolean not null default true,
  notify_high_risk boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table if not exists public.spam_list_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses (id) on delete cascade,      -- null: platform-wide rule
  list text not null check (list in ('block', 'allow')),
  channel text not null check (channel in ('call', 'sms', 'email', 'booking', 'all')),
  value_type text not null check (value_type in ('phone', 'email', 'domain')),
  value text not null check (length(value) between 3 and 254),
  reason text check (reason is null or length(reason) <= 300),
  source text not null default 'manual' check (source in ('manual', 'auto', 'incident')),
  incident_id uuid,
  expires_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid,
  check (business_id is not null or list = 'block')                             -- platform rules only block
);
create unique index if not exists spam_list_entries_live_uq on public.spam_list_entries
  (coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), list, channel, value_type, value) where removed_at is null;
create index if not exists spam_list_entries_lookup_idx on public.spam_list_entries (value) where removed_at is null;

create table if not exists public.spam_incidents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  channel text not null check (channel in ('call', 'sms', 'email', 'booking', 'web', 'other')),
  sender text not null,
  sender_display text,
  customer_id uuid references public.customers (id) on delete set null,
  risk_score integer not null check (risk_score between 0 and 200),
  risk_level text not null check (risk_level in ('low', 'medium', 'high')),
  reasons jsonb not null default '[]'::jsonb,
  action text not null check (action in ('allowed', 'flagged', 'held', 'screened', 'restricted', 'blocked')),
  status text not null default 'new' check (status in ('new', 'under_review', 'confirmed_spam', 'false_positive', 'resolved', 'escalated')),
  assigned_to uuid,
  occurrences integer not null default 1,
  dedupe_key text not null,
  last_source_table text,
  last_source_id uuid,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, dedupe_key)
);
create index if not exists spam_incidents_business_seen_idx on public.spam_incidents (business_id, last_seen_at desc);
create index if not exists spam_incidents_business_status_idx on public.spam_incidents (business_id, status);
create index if not exists spam_incidents_platform_idx on public.spam_incidents (last_seen_at desc, risk_level, status);
create index if not exists spam_incidents_customer_idx on public.spam_incidents (customer_id) where customer_id is not null;

create table if not exists public.spam_incident_events (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.spam_incidents (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('detected', 'occurrence', 'status', 'note', 'listed', 'unlisted', 'assigned', 'notified')),
  actor uuid,
  from_status text,
  to_status text,
  note text check (note is null or length(note) <= 1000),
  source_table text,
  source_id uuid,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists spam_incident_events_incident_idx on public.spam_incident_events (incident_id, created_at);
-- Each source record (one call, text, email or booking) is counted once, however many times its webhook arrives.
create unique index if not exists spam_incident_events_source_uq on public.spam_incident_events (source_table, source_id)
  where kind in ('detected', 'occurrence') and source_id is not null;

-- Business owners, admins and managers read their own business's spam data; nobody else. All writes go through the
-- functions below (security definer), never straight from the browser.
alter table public.spam_settings enable row level security;
alter table public.spam_list_entries enable row level security;
alter table public.spam_incidents enable row level security;
alter table public.spam_incident_events enable row level security;
revoke all on public.spam_settings, public.spam_list_entries, public.spam_incidents, public.spam_incident_events from anon, authenticated;
grant select on public.spam_settings, public.spam_list_entries, public.spam_incidents, public.spam_incident_events to authenticated;

drop policy if exists spam_settings_read on public.spam_settings;
create policy spam_settings_read on public.spam_settings for select to authenticated
  using (public.zella_has_role(business_id, array['owner', 'admin', 'manager']));
drop policy if exists spam_list_entries_read on public.spam_list_entries;
create policy spam_list_entries_read on public.spam_list_entries for select to authenticated
  using (business_id is not null and public.zella_has_role(business_id, array['owner', 'admin', 'manager']));
drop policy if exists spam_incidents_read on public.spam_incidents;
create policy spam_incidents_read on public.spam_incidents for select to authenticated
  using (public.zella_has_role(business_id, array['owner', 'admin', 'manager']));
drop policy if exists spam_incident_events_read on public.spam_incident_events;
create policy spam_incident_events_read on public.spam_incident_events for select to authenticated
  using (public.zella_has_role(business_id, array['owner', 'admin', 'manager']));

insert into public.platform_settings (key, value)
values ('spam_defaults', jsonb_build_object(
  'repeat_call_limit', 5, 'repeat_window_minutes', 60, 'sms_flood_limit', 10, 'email_flood_limit', 10,
  'booking_daily_limit', 3, 'medium_score', 40, 'high_score', 70, 'auto_restrict_hours', 24,
  'calls_per_hour_alert', 60, 'incidents_per_day_alert', 20, 'notify_cooldown_per_hour', 3, 'retention_days', 365))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Configuration and lists
-- ---------------------------------------------------------------------------------------------------------------

-- The business's effective settings: platform defaults, then its own row. Without a row protection is on.
create or replace function public.zella_spam_config(p_business_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.platform_settings where key = 'spam_defaults'), '{}'::jsonb)
      || jsonb_build_object('enabled', true, 'call_screening', 'flag', 'ai_spam_handling', 'end_politely', 'sms_monitoring', true,
                            'email_monitoring', true, 'booking_protection', true, 'auto_restrict', true, 'notify_high_risk', true)
      || coalesce((select to_jsonb(s) - 'business_id' - 'updated_at' - 'updated_by' from public.spam_settings s where s.business_id = p_business_id), '{}'::jsonb);
$$;

-- Which list (if any) a sender is on for a channel. Platform blocks win; a business's allow list wins over its own
-- block list and over detection; expired and removed entries never count.
create or replace function public.zella_spam_listed(p_business_id uuid, p_channel text, p_phone text, p_email text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_phone text := public.zella_digits(p_phone); v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
        v_domain text := nullif(split_part(coalesce(v_email, ''), '@', 2), ''); r record;
begin
  for r in
    select e.id, e.list, (e.business_id is null) as platform
      from public.spam_list_entries e
     where e.removed_at is null and (e.expires_at is null or e.expires_at > now())
       and (e.business_id is null or e.business_id = p_business_id)
       and e.channel in (p_channel, 'all')
       and ((e.value_type = 'phone' and e.value = v_phone) or (e.value_type = 'email' and e.value = v_email) or (e.value_type = 'domain' and e.value = v_domain))
     order by (e.business_id is null and e.list = 'block') desc, (e.list = 'allow') desc
     limit 1
  loop
    return jsonb_build_object('list', r.list, 'scope', case when r.platform then 'platform' else 'business' end, 'entry_id', r.id);
  end loop;
  return null;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Risk assessment (no side effects)
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_spam_assess(p_business_id uuid, p_channel text, p_phone text, p_email text, p_text text, p_extra jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg jsonb := public.zella_spam_config(p_business_id);
  listed jsonb := public.zella_spam_listed(p_business_id, p_channel, p_phone, p_email);
  v_phone text := public.zella_digits(p_phone);
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_text text := lower(coalesce(p_text, ''));
  v_offset integer := coalesce((p_extra ->> 'recent_offset')::integer, 0);
  v_window integer := coalesce((cfg ->> 'repeat_window_minutes')::integer, 60);
  v_limit integer; v_n integer := 0; v_links integer;
  score integer := 0; reasons jsonb := '[]'::jsonb; v_level text; v_action text;
  add_reason text;
begin
  if listed ->> 'list' = 'allow' then
    return jsonb_build_object('score', 0, 'level', null, 'action', 'allowed', 'listed', listed,
      'reasons', jsonb_build_array(jsonb_build_object('code', 'allowlisted', 'label', 'On the business''s allow list', 'points', 0)));
  end if;
  if listed ->> 'list' = 'block' then
    score := score + 100;
    reasons := reasons || jsonb_build_object('code', 'blocklisted', 'points', 100,
      'label', case when listed ->> 'scope' = 'platform' then 'On a Zella platform block rule' else 'On the business''s block list' end);
  end if;

  -- Business detection only when its protection is on; platform rules (above) always apply.
  if coalesce((cfg ->> 'enabled')::boolean, true) then
    if p_channel = 'call' then
      v_limit := coalesce((cfg ->> 'repeat_call_limit')::integer, 5);
      if v_phone is null then
        score := score + 10; reasons := reasons || jsonb_build_object('code', 'no_caller_id', 'label', 'Caller ID withheld', 'points', 10);
      else
        select count(*) + v_offset into v_n from public.calls
         where business_id = p_business_id and direction = 'inbound' and public.zella_digits(from_number) = v_phone
           and created_at > now() - make_interval(mins => v_window);
      end if;
    elsif p_channel = 'sms' and coalesce((cfg ->> 'sms_monitoring')::boolean, true) then
      v_limit := coalesce((cfg ->> 'sms_flood_limit')::integer, 10);
      select count(*) + v_offset into v_n from public.sms_messages
       where business_id = p_business_id and direction = 'inbound' and public.zella_digits(from_number) = v_phone
         and created_at > now() - make_interval(mins => v_window);
    elsif p_channel = 'email' and coalesce((cfg ->> 'email_monitoring')::boolean, true) then
      v_limit := coalesce((cfg ->> 'email_flood_limit')::integer, 10);
      select count(*) + v_offset into v_n from public.email_messages
       where business_id = p_business_id and direction = 'inbound' and lower(from_email) = v_email
         and created_at > now() - make_interval(mins => v_window);
    elsif p_channel = 'booking' and coalesce((cfg ->> 'booking_protection')::boolean, true) then
      v_limit := coalesce((cfg ->> 'booking_daily_limit')::integer, 3);
      select count(*) + v_offset into v_n from public.appointments a
       where a.business_id = p_business_id and a.created_at > now() - interval '24 hours'
         and coalesce(a.metadata ->> 'source', '') <> 'staff'
         and a.customer_id = nullif(p_extra ->> 'customer_id', '')::uuid;
      if v_n > v_limit then   -- the limit is how many are allowed; v_n includes the one being made
        score := score + 45;
        reasons := reasons || jsonb_build_object('code', 'booking_limit', 'points', 45,
          'label', format('%s bookings from the same contact in 24 hours (limit %s)', v_n, v_limit));
      end if;
      v_limit := null;  -- handled above
    end if;

    if v_limit is not null and v_n >= v_limit then
      score := score + 40;
      reasons := reasons || jsonb_build_object('code', 'repeat_contact', 'points', 40,
        'label', format('%s %s from the same sender in %s minutes (limit %s)', v_n, case p_channel when 'call' then 'calls' when 'sms' then 'texts' else 'emails' end, v_window, v_limit));
      if v_n >= v_limit * 2 then
        score := score + 25; reasons := reasons || jsonb_build_object('code', 'flood', 'label', 'Far above the usual volume', 'points', 25);
      end if;
    end if;

    if v_text <> '' then
      if v_text ~ '(bit\.ly|tinyurl\.com|t\.co/|goo\.gl|is\.gd|ow\.ly|cutt\.ly|rb\.gy|shorturl\.at|tiny\.cc)' or v_text ~ 'https?://\d{1,3}(\.\d{1,3}){3}' then
        score := score + 25; reasons := reasons || jsonb_build_object('code', 'suspicious_link', 'label', 'Shortened or numeric web link', 'points', 25);
      end if;
      select count(*) into v_links from regexp_matches(v_text, 'https?://', 'g');
      if v_links >= 3 then
        score := score + 15; reasons := reasons || jsonb_build_object('code', 'many_links', 'label', format('%s links in one message', v_links), 'points', 15);
      end if;
      if v_text ~ '(gift ?cards?|bitcoin|crypto|wire transfer|you (have )?won|claim your (prize|reward)|verify your account|account (is |has been )?suspended|urgent payment|seo (services|ranking)|guaranteed (ranking|leads)|loan approv|act now)' then
        score := score + 20; reasons := reasons || jsonb_build_object('code', 'spam_phrase', 'label', 'Common spam wording', 'points', 20);
      end if;
      if v_text ~ '(ignore (all |any |your )?(previous|prior|earlier) instructions|system prompt|developer mode|reveal (your|the) (instructions|prompt)|jailbreak|act as (an? )?(admin|administrator|developer)|another business''?s? (data|customers))' then
        score := score + 30; reasons := reasons || jsonb_build_object('code', 'ai_manipulation', 'label', 'Tried to override the AI''s instructions or reach other data', 'points', 30);
      end if;
    end if;

    if coalesce((p_extra ->> 'provider_spam')::boolean, false) then
      score := score + 40; reasons := reasons || jsonb_build_object('code', 'provider_flag', 'label', 'Marked as spam by the email provider', 'points', 40);
    end if;
  end if;

  score := least(score, 200);
  v_level := case when score >= coalesce((cfg ->> 'high_score')::integer, 70) then 'high'
                  when score >= coalesce((cfg ->> 'medium_score')::integer, 40) then 'medium'
                  when score > 0 then 'low' end;
  v_action := case
    when listed ->> 'list' = 'block' then 'blocked'
    when v_level is null or v_level = 'low' then 'allowed'
    when p_channel = 'booking' then 'held'
    when v_level = 'high' and coalesce((cfg ->> 'auto_restrict')::boolean, true) and jsonb_array_length(reasons) >= 2 then 'restricted'
    when v_level = 'high' and p_channel = 'call' and cfg ->> 'call_screening' = 'screen' then 'screened'
    else 'flagged' end;
  return jsonb_build_object('score', score, 'level', v_level, 'action', v_action, 'reasons', reasons, 'listed', listed);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Recording an incident (idempotent per source record)
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_spam_mask(p_sender text)
returns text language sql immutable set search_path = public as $$
  select case when p_sender is null or p_sender = 'unknown' then 'an unknown sender'
              when p_sender ~ '@' then left(split_part(p_sender, '@', 1), 1) || '…@' || split_part(p_sender, '@', 2)
              else '…' || right(p_sender, 4) end;
$$;

create or replace function public.zella_spam_record(p_business_id uuid, p_channel text, p_phone text, p_email text, p_display text,
                                                     p_customer_id uuid, p_source_table text, p_source_id uuid, p_assessment jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := public.zella_spam_config(p_business_id);
  v_sender text := coalesce(public.zella_digits(p_phone), nullif(lower(trim(coalesce(p_email, ''))), ''), 'unknown');
  v_key text; v_id uuid; v_inserted boolean; v_level text := p_assessment ->> 'level'; v_action text := p_assessment ->> 'action';
  v_occ integer; v_labels text;
begin
  -- Only medium and high risk, or a block-list match, become incidents; low signals are not stored.
  if v_action is null or v_action = 'allowed' or v_level is null or (v_level = 'low' and v_action <> 'blocked') then return null; end if;

  -- Already counted this call / text / email / booking (a repeated webhook): nothing more to do.
  if p_source_id is not null then
    select incident_id into v_id from public.spam_incident_events
     where source_table = p_source_table and source_id = p_source_id and kind in ('detected', 'occurrence') limit 1;
    if v_id is not null then return v_id; end if;
  end if;

  v_key := p_channel || ':' || v_sender || ':' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD');
  insert into public.spam_incidents as i (business_id, channel, sender, sender_display, customer_id, risk_score, risk_level, reasons, action,
                                          dedupe_key, last_source_table, last_source_id)
  values (p_business_id, p_channel, v_sender, left(p_display, 120), p_customer_id, (p_assessment ->> 'score')::integer, v_level,
          coalesce(p_assessment -> 'reasons', '[]'::jsonb), v_action, v_key, p_source_table, p_source_id)
  on conflict (business_id, dedupe_key) do update set
    occurrences = i.occurrences + 1,
    last_seen_at = now(), updated_at = now(),
    risk_score = greatest(i.risk_score, excluded.risk_score),
    risk_level = case when 'high' in (i.risk_level, excluded.risk_level) then 'high' when 'medium' in (i.risk_level, excluded.risk_level) then 'medium' else 'low' end,
    reasons = (select coalesce(jsonb_agg(r order by (r ->> 'points')::int desc), '[]'::jsonb)
                 from (select distinct on (r ->> 'code') r from jsonb_array_elements(i.reasons || excluded.reasons) r order by r ->> 'code', (r ->> 'points')::int desc) x),
    action = case when array_position(array['allowed','flagged','held','screened','restricted','blocked'], excluded.action)
                     > array_position(array['allowed','flagged','held','screened','restricted','blocked'], i.action) then excluded.action else i.action end,
    customer_id = coalesce(i.customer_id, excluded.customer_id),
    status = case when i.status = 'resolved' then 'new' else i.status end,   -- a resolved sender who comes back is reopened
    last_source_table = excluded.last_source_table, last_source_id = excluded.last_source_id
  returning id, (xmax = 0), occurrences into v_id, v_inserted, v_occ;

  insert into public.spam_incident_events (incident_id, business_id, kind, source_table, source_id, detail)
  values (v_id, p_business_id, case when v_inserted then 'detected' else 'occurrence' end, p_source_table, p_source_id,
          jsonb_build_object('score', p_assessment -> 'score', 'action', v_action, 'reasons', p_assessment -> 'reasons'))
  on conflict do nothing;

  -- A temporary, channel-only restriction: never permanent, never from one signal (zella_spam_assess decides).
  if v_action = 'restricted' and v_sender <> 'unknown' then
    insert into public.spam_list_entries (business_id, list, channel, value_type, value, reason, source, incident_id, expires_at)
    values (p_business_id, 'block', case when p_channel = 'booking' then 'booking' else p_channel end,
            case when v_sender ~ '@' then 'email' else 'phone' end, v_sender,
            'Automatic temporary restriction after high-risk activity', 'auto', v_id,
            now() + make_interval(hours => coalesce((cfg ->> 'auto_restrict_hours')::integer, 24)))
    on conflict do nothing;
    if found then
      insert into public.spam_incident_events (incident_id, business_id, kind, detail)
      values (v_id, p_business_id, 'listed', jsonb_build_object('list', 'block', 'channel', p_channel, 'temporary_hours', coalesce((cfg ->> 'auto_restrict_hours')::integer, 24)));
    end if;
  end if;

  -- Tell the business about a new high-risk incident, at most a few times an hour (no message content, masked sender).
  if v_inserted and v_level = 'high' and coalesce((cfg ->> 'notify_high_risk')::boolean, true)
     and public.zella_rate_limit('spam_notify:' || p_business_id, coalesce((cfg ->> 'notify_cooldown_per_hour')::integer, 3), 3600) then
    select string_agg(r ->> 'label', '; ') into v_labels from jsonb_array_elements(p_assessment -> 'reasons') r;
    perform public.zella_notify(p_business_id, 'spam_high_risk',
      'High-risk ' || case p_channel when 'call' then 'call' when 'sms' then 'text' when 'email' then 'email' when 'booking' then 'booking' else 'activity' end || ' flagged',
      'From ' || public.zella_spam_mask(v_sender) || '. ' || coalesce(v_labels, '') || '. Review it in Spam protection.', 'warning', 'spam', v_id, null);
    insert into public.spam_incident_events (incident_id, business_id, kind, detail) values (v_id, p_business_id, 'notified', '{}'::jsonb);
  end if;

  -- Platform view: one grouped alert when a single sender floods a business.
  if v_occ = coalesce((cfg ->> 'incidents_per_day_alert')::integer, 20) then
    perform public.zella_platform_alert('spam_flood', 'Spam flood at a business',
      format('%s %s events from one sender today', v_occ, p_channel), 'warning', p_business_id, 'spam:' || v_key, jsonb_build_object('incident_id', v_id));
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Enforcement hooks
-- ---------------------------------------------------------------------------------------------------------------

-- Calls, once the call is saved: repeated calls, AI manipulation in the transcript, list matches. Cancels the
-- automatic callback for a blocked or restricted caller. Also watches for unusual call volume (cost).
create or replace function public.zella_spam_call_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare a jsonb; v_id uuid; v_hour integer; cfg jsonb;
begin
  if new.direction is distinct from 'inbound' then return new; end if;
  begin
    a := public.zella_spam_assess(new.business_id, 'call', new.from_number, null, new.transcript, '{}'::jsonb);
    v_id := public.zella_spam_record(new.business_id, 'call', new.from_number, null, new.from_number, new.customer_id, 'calls', new.id, a);
    if a ->> 'action' in ('blocked', 'restricted') then
      update public.callbacks set status = 'cancelled', updated_at = now()
       where call_id = new.id and status not in ('completed', 'cancelled');
    end if;
    cfg := public.zella_spam_config(new.business_id);
    select count(*) into v_hour from public.calls where business_id = new.business_id and direction = 'inbound' and created_at > now() - interval '1 hour';
    if v_hour >= coalesce((cfg ->> 'calls_per_hour_alert')::integer, 60) then
      perform public.zella_platform_alert('call_volume_spike', 'Unusual call volume', format('%s inbound calls in the last hour', v_hour),
        'warning', new.business_id, 'calls:' || to_char(date_trunc('hour', now()), 'YYYY-MM-DD"T"HH24'), '{}'::jsonb);
    end if;
  exception when others then
    raise warning 'spam check skipped for call %: %', new.id, sqlerrm;   -- never lose a call because detection failed
  end;
  return new;
end $$;
drop trigger if exists zella_spam_call on public.calls;
create trigger zella_spam_call after insert on public.calls for each row execute function public.zella_spam_call_trg();

create or replace function public.zella_spam_sms_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare a jsonb;
begin
  if new.direction is distinct from 'inbound' then return new; end if;
  begin
    a := public.zella_spam_assess(new.business_id, 'sms', new.from_number, null, new.message_body, '{}'::jsonb);
    perform public.zella_spam_record(new.business_id, 'sms', new.from_number, null, new.from_number, new.customer_id, 'sms_messages', new.id, a);
  exception when others then
    raise warning 'spam check skipped for text %: %', new.id, sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zella_spam_sms on public.sms_messages;
create trigger zella_spam_sms after insert on public.sms_messages for each row execute function public.zella_spam_sms_trg();

create or replace function public.zella_spam_email_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare a jsonb; v_provider boolean;
begin
  if new.direction is distinct from 'inbound' then return new; end if;
  begin
    v_provider := lower(coalesce(new.metadata ->> 'spam', new.metadata ->> 'spam_verdict', new.metadata ->> 'is_spam', '')) in ('true', 'spam', 'yes', 'fail');
    a := public.zella_spam_assess(new.business_id, 'email', null, new.from_email,
                                  coalesce(new.subject, '') || ' ' || left(coalesce(new.body_text, ''), 5000),
                                  jsonb_build_object('provider_spam', v_provider));
    perform public.zella_spam_record(new.business_id, 'email', null, new.from_email, new.from_email, new.customer_id, 'email_messages', new.id, a);
  exception when others then
    raise warning 'spam check skipped for email %: %', new.id, sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zella_spam_email on public.email_messages;
create trigger zella_spam_email after insert on public.email_messages for each row execute function public.zella_spam_email_trg();

-- Bookings not made by a signed-in team member (AI receptionist, online booking, reschedule links): a blocked
-- contact, or one over the daily limit, is kept as a request for the team to confirm. Nothing is silently dropped,
-- nothing held is confirmed automatically, and staff bookings are never touched.
create or replace function public.zella_spam_booking_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare a jsonb; c record;
begin
  if auth.uid() is not null or coalesce(new.metadata ->> 'source', '') = 'staff' or new.customer_id is null
     or coalesce(new.booking_state, 'confirmed') <> 'confirmed' then
    return new;
  end if;
  begin
    select phone, email into c from public.customers where id = new.customer_id;
    a := public.zella_spam_assess(new.business_id, 'booking', c.phone, c.email, null,
                                  jsonb_build_object('customer_id', new.customer_id, 'recent_offset', 1));
    if a ->> 'action' in ('blocked', 'held', 'restricted') then
      new.booking_state := 'requested';
      new.metadata := coalesce(new.metadata, '{}'::jsonb) || jsonb_build_object('spam_hold', jsonb_build_object('score', a -> 'score', 'action', a -> 'action', 'reasons', a -> 'reasons'));
    end if;
  exception when others then
    raise warning 'booking spam check skipped: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zella_spam_booking_guard on public.appointments;
create trigger zella_spam_booking_guard before insert on public.appointments for each row execute function public.zella_spam_booking_guard();

create or replace function public.zella_spam_booking_record()
returns trigger language plpgsql security definer set search_path = public as $$
declare c record; a jsonb;
begin
  if not (new.metadata ? 'spam_hold') then return new; end if;
  begin
    select phone, email into c from public.customers where id = new.customer_id;
    a := jsonb_build_object('score', (new.metadata -> 'spam_hold' ->> 'score')::int,
      'level', case when (new.metadata -> 'spam_hold' ->> 'score')::int >= 70 then 'high' else 'medium' end,
      'action', case when new.metadata -> 'spam_hold' ->> 'action' = 'blocked' then 'blocked' else 'held' end,
      'reasons', new.metadata -> 'spam_hold' -> 'reasons');
    perform public.zella_spam_record(new.business_id, 'booking', c.phone, c.email, coalesce(c.phone, c.email), new.customer_id, 'appointments', new.id, a);
  exception when others then
    raise warning 'booking spam record skipped: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zella_spam_booking_record on public.appointments;
create trigger zella_spam_booking_record after insert on public.appointments for each row execute function public.zella_spam_booking_record();

-- No automatic replies (HELP replies, quick replies) to a sender blocked for texts.
create or replace function public.zella_spam_reply_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_phone text; l jsonb;
begin
  if new.kind not like 'reply\_%' or new.customer_id is null or new.channel <> 'sms' then return new; end if;
  begin
    select phone into v_phone from public.customers where id = new.customer_id;
    l := public.zella_spam_listed(new.business_id, 'sms', v_phone, null);
    if l ->> 'list' = 'block' then
      new.status := 'skipped'; new.outcome := 'spam_blocked'; new.completed_at := now();
    end if;
  exception when others then
    raise warning 'reply spam check skipped: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zella_spam_reply_guard on public.followup_tasks;
create trigger zella_spam_reply_guard before insert on public.followup_tasks for each row execute function public.zella_spam_reply_guard();

-- Calls, at the start (before the AI speaks): the original caller context, plus a screening decision the AI must
-- follow. The booking guard above enforces the same decision for bookings even if the AI ignores it.
do $$
begin
  if to_regprocedure('public.zella_caller_context_base(uuid,text)') is null then
    execute $f$
create or replace function public.zella_caller_context_base(p_business_id uuid, p_phone text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $b$
declare v_cust uuid; v_first text; v_calls integer; v_last timestamptz; v_up boolean; v_cb boolean;
begin
  if public.zella_digits(p_phone) is null then return jsonb_build_object('known', false); end if;
  select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_phone, null) m where m.certainty = 'exact' limit 1;
  select count(*), max(started_at) into v_calls, v_last from public.calls
   where business_id = p_business_id and direction = 'inbound' and (customer_id = v_cust and v_cust is not null or public.zella_digits(from_number) = public.zella_digits(p_phone));
  if v_cust is null then
    return jsonb_build_object('known', false, 'previous_calls', v_calls, 'repeat_caller', v_calls > 0,
      'say', case when v_calls > 0 then 'This number has called before but is not a saved customer. Do not assume a name; ask for it.' else 'New caller. Ask for their name.' end);
  end if;
  select nullif(trim(first_name), '') into v_first from public.customers where id = v_cust;
  select exists (select 1 from public.appointments where customer_id = v_cust and business_id = p_business_id and start_time > now() and status not in ('cancelled', 'no_show', 'completed')) into v_up;
  select exists (select 1 from public.callbacks where customer_id = v_cust and business_id = p_business_id and status not in ('completed', 'cancelled')) into v_cb;
  return jsonb_build_object('known', true, 'first_name', v_first, 'previous_calls', v_calls, 'repeat_caller', v_calls > 0,
    'last_call_days_ago', case when v_last is null then null else greatest(0, floor(extract(epoch from now() - v_last) / 86400))::int end,
    'has_upcoming_appointment', v_up, 'has_open_callback', v_cb,
    'say', 'Known customer' || coalesce(' (' || v_first || ')', '') || '. You may greet them by first name. Caller ID can be wrong, so ask them to confirm their name before you share or change anything about an appointment.'
           || case when v_cb then ' The team already has a callback open for them; mention that someone will be in touch rather than creating another.' else '' end);
end $b$
$f$;
  end if;
end $$;
revoke all on function public.zella_caller_context_base(uuid, text) from public, anon, authenticated;

create or replace function public.zella_caller_context(p_business_id uuid, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare base jsonb := public.zella_caller_context_base(p_business_id, p_phone); a jsonb; cfg jsonb; v_say text;
begin
  begin
    a := public.zella_spam_assess(p_business_id, 'call', p_phone, null, null, jsonb_build_object('recent_offset', 1));
    if a ->> 'action' in ('blocked', 'restricted', 'screened') then
      cfg := public.zella_spam_config(p_business_id);
      v_say := case when cfg ->> 'ai_spam_handling' = 'take_message' and a ->> 'action' <> 'blocked'
        then 'Spam protection: this call is high risk. Do not book, change, cancel or share anything and do not use any tools except taking a short message. Be polite and brief.'
        else 'Spam protection: this caller is not accepted. Do not book, change, cancel or share anything and do not use any tools. Politely say the business can''t take this call and end it.' end;
      return base || jsonb_build_object('say', v_say, 'screening', jsonb_build_object('decision', a ->> 'action', 'level', a ->> 'level'));
    end if;
    if a ->> 'action' = 'flagged' then
      return base || jsonb_build_object('screening', jsonb_build_object('decision', 'flagged', 'level', a ->> 'level'),
        'say', coalesce(base ->> 'say', '') || ' This caller has been flagged as possible spam: help normally, but don''t share details about other customers or the business''s systems.');
    end if;
  exception when others then
    raise warning 'call screening skipped: %', sqlerrm;   -- screening is optional; the call continues
  end;
  return base;
end $$;
revoke all on function public.zella_caller_context(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_caller_context(uuid, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Business functions (CRM). Each checks the caller's role in that business; business ids from the browser are
--    only accepted together with that check.
-- ---------------------------------------------------------------------------------------------------------------

create or replace function public.zella_spam_overview(p_business_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_len interval := p_to - p_from; v_since timestamptz; r jsonb; prev integer;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_to <= p_from or v_len > interval '400 days' then raise exception 'BAD_RANGE'; end if;
  select created_at into v_since from public.businesses where id = p_business_id;
  select jsonb_build_object(
    'total', count(*),
    'new', count(*) filter (where status = 'new'),
    'unreviewed', count(*) filter (where status in ('new', 'under_review', 'escalated')),
    'confirmed', count(*) filter (where status = 'confirmed_spam'),
    'false_positive', count(*) filter (where status = 'false_positive'),
    'resolved', count(*) filter (where status = 'resolved'),
    'escalated', count(*) filter (where status = 'escalated'),
    'blocked', count(*) filter (where action in ('blocked', 'restricted', 'screened')),
    'held', count(*) filter (where action = 'held'),
    'high', count(*) filter (where risk_level = 'high'),
    'occurrences', coalesce(sum(occurrences), 0),
    'by_channel', jsonb_build_object('call', count(*) filter (where channel = 'call'), 'sms', count(*) filter (where channel = 'sms'),
      'email', count(*) filter (where channel = 'email'), 'booking', count(*) filter (where channel = 'booking'),
      'other', count(*) filter (where channel in ('web', 'other'))))
    into r from public.spam_incidents where business_id = p_business_id and first_seen_at >= p_from and first_seen_at < p_to;
  -- A comparison only when the business existed for the whole previous period.
  if v_since <= p_from - v_len then
    select count(*) into prev from public.spam_incidents where business_id = p_business_id and first_seen_at >= p_from - v_len and first_seen_at < p_from;
  end if;
  return r || jsonb_build_object('previous_total', prev,
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'count', n) order by d) from (
      select (first_seen_at at time zone coalesce((select timezone from public.businesses where id = p_business_id), 'UTC'))::date d, count(*) n
        from public.spam_incidents where business_id = p_business_id and first_seen_at >= p_from and first_seen_at < p_to group by 1) x), '[]'::jsonb));
end $$;

create or replace function public.zella_spam_review(p_incident_id uuid, p_status text, p_note text default null, p_block boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i record;
begin
  select * into i from public.spam_incidents where id = p_incident_id for update;
  if not found or not public.zella_has_role(i.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_status not in ('new', 'under_review', 'confirmed_spam', 'false_positive', 'resolved', 'escalated') then raise exception 'BAD_STATUS'; end if;
  if p_status = 'false_positive' and coalesce(trim(p_note), '') = '' then p_note := 'Marked as not spam'; end if;
  update public.spam_incidents set status = p_status, updated_at = now() where id = i.id;
  insert into public.spam_incident_events (incident_id, business_id, kind, actor, from_status, to_status, note)
  values (i.id, i.business_id, 'status', auth.uid(), i.status, p_status, left(nullif(trim(p_note), ''), 1000));
  -- Not spam: lift any automatic restriction it caused, so the sender isn't held back by a mistake.
  if p_status = 'false_positive' then
    update public.spam_list_entries set removed_at = now(), removed_by = auth.uid()
     where incident_id = i.id and source = 'auto' and removed_at is null;
  end if;
  if p_block and p_status = 'confirmed_spam' and i.sender <> 'unknown' then
    perform public.zella_spam_list_add(i.business_id, 'block', case when i.channel in ('call', 'sms', 'email', 'booking') then i.channel else 'all' end,
                                       i.sender, 'Confirmed spam', null, i.id);
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (i.business_id, auth.uid(), 'spam.incident_' || p_status, 'spam_incident', i.id, jsonb_build_object('status', i.status), jsonb_build_object('status', p_status, 'blocked', p_block));
  return jsonb_build_object('id', i.id, 'status', p_status);
end $$;

create or replace function public.zella_spam_note(p_incident_id uuid, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare i record; v_id uuid;
begin
  select id, business_id into i from public.spam_incidents where id = p_incident_id;
  if not found or not public.zella_has_role(i.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'EMPTY_NOTE'; end if;
  insert into public.spam_incident_events (incident_id, business_id, kind, actor, note) values (i.id, i.business_id, 'note', auth.uid(), left(trim(p_note), 1000)) returning id into v_id;
  return v_id;
end $$;

create or replace function public.zella_spam_assign(p_incident_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare i record;
begin
  select id, business_id, assigned_to into i from public.spam_incidents where id = p_incident_id for update;
  if not found or not public.zella_has_role(i.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_user_id is not null and not exists (select 1 from public.business_members where business_id = i.business_id and user_id = p_user_id and status = 'active') then raise exception 'NOT_A_MEMBER'; end if;
  update public.spam_incidents set assigned_to = p_user_id, updated_at = now() where id = i.id;
  insert into public.spam_incident_events (incident_id, business_id, kind, actor, detail) values (i.id, i.business_id, 'assigned', auth.uid(), jsonb_build_object('to', p_user_id, 'from', i.assigned_to));
end $$;

-- Business lists. The value decides its type: an address is an email, "@domain" or "domain.com" a domain, else a phone.
create or replace function public.zella_spam_list_add(p_business_id uuid, p_list text, p_channel text, p_value text, p_reason text default null,
                                                      p_hours integer default null, p_incident_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_value text := lower(trim(coalesce(p_value, ''))); v_type text; v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_list not in ('block', 'allow') or p_channel not in ('call', 'sms', 'email', 'booking', 'all') then raise exception 'BAD_INPUT'; end if;
  if v_value ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then v_type := 'email';
  elsif v_value ~ '^@?[a-z0-9.-]+\.[a-z]{2,}$' then v_type := 'domain'; v_value := ltrim(v_value, '@');
  elsif public.zella_digits(v_value) is not null and length(public.zella_digits(v_value)) >= 7 then v_type := 'phone'; v_value := public.zella_digits(v_value);
  else raise exception 'BAD_VALUE'; end if;
  if p_hours is not null and (p_hours < 1 or p_hours > 8760) then raise exception 'BAD_INPUT'; end if;
  -- The opposite list entry for the same sender and channel ends; a sender is never on both.
  update public.spam_list_entries set removed_at = now(), removed_by = auth.uid()
   where business_id = p_business_id and list <> p_list and channel = p_channel and value_type = v_type and value = v_value and removed_at is null;
  insert into public.spam_list_entries (business_id, list, channel, value_type, value, reason, source, incident_id, expires_at, created_by)
  values (p_business_id, p_list, p_channel, v_type, v_value, left(nullif(trim(p_reason), ''), 300),
          case when p_incident_id is null then 'manual' else 'incident' end, p_incident_id,
          case when p_hours is null then null else now() + make_interval(hours => p_hours) end, auth.uid())
  on conflict do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.spam_list_entries where business_id = p_business_id and list = p_list and channel = p_channel
       and value_type = v_type and value = v_value and removed_at is null;
  end if;
  if p_incident_id is not null then
    insert into public.spam_incident_events (incident_id, business_id, kind, actor, detail)
    values (p_incident_id, p_business_id, 'listed', auth.uid(), jsonb_build_object('list', p_list, 'channel', p_channel));
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'spam.list_added', 'spam_list_entry', v_id, jsonb_build_object('list', p_list, 'channel', p_channel, 'type', v_type, 'hours', p_hours));
  return v_id;
end $$;

create or replace function public.zella_spam_list_remove(p_entry_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  select * into e from public.spam_list_entries where id = p_entry_id;
  -- Platform rules (no business) can't be changed here; only Zella admins manage them.
  if not found or e.business_id is null or not public.zella_has_role(e.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.spam_list_entries set removed_at = now(), removed_by = auth.uid() where id = e.id and removed_at is null;
  if e.incident_id is not null then
    insert into public.spam_incident_events (incident_id, business_id, kind, actor, detail) values (e.incident_id, e.business_id, 'unlisted', auth.uid(), jsonb_build_object('list', e.list, 'channel', e.channel));
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data)
  values (e.business_id, auth.uid(), 'spam.list_removed', 'spam_list_entry', e.id, jsonb_build_object('list', e.list, 'channel', e.channel, 'type', e.value_type));
end $$;

-- Settings: owners and admins. Platform rules and limits keep applying whatever is chosen here.
create or replace function public.zella_spam_settings_save(p_business_id uuid, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cur jsonb := public.zella_spam_config(p_business_id); s jsonb := coalesce(p_settings, '{}'::jsonb);
        n jsonb; before jsonb;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  select to_jsonb(x) - 'business_id' - 'updated_at' - 'updated_by' into before from public.spam_settings x where business_id = p_business_id;
  n := cur || s;
  insert into public.spam_settings as t (business_id, enabled, call_screening, ai_spam_handling, repeat_call_limit, repeat_window_minutes, sms_monitoring,
                                         sms_flood_limit, email_monitoring, email_flood_limit, booking_protection, booking_daily_limit, auto_restrict,
                                         notify_high_risk, updated_at, updated_by)
  values (p_business_id, (n ->> 'enabled')::boolean, n ->> 'call_screening', n ->> 'ai_spam_handling', (n ->> 'repeat_call_limit')::int,
          (n ->> 'repeat_window_minutes')::int, (n ->> 'sms_monitoring')::boolean, (n ->> 'sms_flood_limit')::int, (n ->> 'email_monitoring')::boolean,
          (n ->> 'email_flood_limit')::int, (n ->> 'booking_protection')::boolean, (n ->> 'booking_daily_limit')::int, (n ->> 'auto_restrict')::boolean,
          (n ->> 'notify_high_risk')::boolean, now(), auth.uid())
  on conflict (business_id) do update set enabled = excluded.enabled, call_screening = excluded.call_screening, ai_spam_handling = excluded.ai_spam_handling,
    repeat_call_limit = excluded.repeat_call_limit, repeat_window_minutes = excluded.repeat_window_minutes, sms_monitoring = excluded.sms_monitoring,
    sms_flood_limit = excluded.sms_flood_limit, email_monitoring = excluded.email_monitoring, email_flood_limit = excluded.email_flood_limit,
    booking_protection = excluded.booking_protection, booking_daily_limit = excluded.booking_daily_limit, auto_restrict = excluded.auto_restrict,
    notify_high_risk = excluded.notify_high_risk, updated_at = now(), updated_by = auth.uid();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'spam.settings_updated', 'business', p_business_id, before, s);
  return public.zella_spam_config(p_business_id);
end $$;

-- What the settings screen needs: effective settings and which channels this business actually has.
create or replace function public.zella_spam_settings_get(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare mods text[];
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(array_agg(im.slug), '{}') into mods from public.business_modules bm join public.industry_modules im on im.id = bm.module_id
   where bm.business_id = p_business_id and bm.enabled;
  return jsonb_build_object('settings', public.zella_spam_config(p_business_id),
    'saved', exists (select 1 from public.spam_settings where business_id = p_business_id),
    'channels', jsonb_build_object('call', 'calls' = any (mods) or 'ai-receptionist' = any (mods), 'sms', 'sms' = any (mods),
                                   'email', 'email' = any (mods), 'booking', 'calendar' = any (mods)),
    'can_edit', public.zella_has_role(p_business_id, array['owner', 'admin']));
end $$;

-- Hourly: remind about high-risk incidents left unreviewed for a day (once each), and keep data no longer than the
-- platform retention (resolved and not-spam incidents only; expired list entries). Scheduled with the other Zella
-- jobs, which are switched on at go-live.
create or replace function public.zella_spam_hourly()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0; purged integer := 0; v_days integer;
begin
  for r in select i.id, i.business_id, i.channel from public.spam_incidents i
            where i.status in ('new', 'escalated') and i.risk_level = 'high' and i.first_seen_at < now() - interval '24 hours'
              and not exists (select 1 from public.spam_incident_events e where e.incident_id = i.id and e.kind = 'notified' and e.detail ->> 'reminder' = 'true')
            limit 200 loop
    perform public.zella_notify(r.business_id, 'spam_unreviewed', 'Spam incident waiting for review',
      'A high-risk ' || r.channel || ' incident has been waiting more than a day.', 'info', 'spam', r.id, null);
    insert into public.spam_incident_events (incident_id, business_id, kind, detail) values (r.id, r.business_id, 'notified', '{"reminder": "true"}');
    n := n + 1;
  end loop;
  select coalesce((value ->> 'retention_days')::int, 365) into v_days from public.platform_settings where key = 'spam_defaults';
  delete from public.spam_incidents where status in ('resolved', 'false_positive') and last_seen_at < now() - make_interval(days => greatest(coalesce(v_days, 365), 30));
  get diagnostics purged = row_count;
  delete from public.spam_list_entries where (removed_at is not null and removed_at < now() - interval '90 days') or (expires_at is not null and expires_at < now() - interval '90 days');
  return jsonb_build_object('reminders', n, 'purged', purged);
end $$;

do $$
declare v_have boolean;
begin
  -- Dynamic SQL: databases without pg_cron simply skip this. Created switched off (on at go-live with the other zella
  -- jobs); a re-run never touches a job that already exists, so it won't switch off one an admin turned on.
  if to_regclass('cron.job') is not null then
    execute $q$select exists (select 1 from cron.job where jobname = 'zella_spam_hourly')$q$ into v_have;
    if not v_have then
      execute $q$select cron.schedule('zella_spam_hourly', '17 * * * *', 'select public.zella_spam_hourly()')$q$;
      execute $q$update cron.job set active = false where jobname = 'zella_spam_hourly'$q$;
    end if;
  end if;
end $$;

-- Who may call what. Detection, recording and the hourly job: server only. Review and lists: signed-in members
-- (each function checks the role in that business).
revoke all on function public.zella_spam_config(uuid), public.zella_spam_listed(uuid, text, text, text),
  public.zella_spam_assess(uuid, text, text, text, text, jsonb), public.zella_spam_record(uuid, text, text, text, text, uuid, text, uuid, jsonb),
  public.zella_spam_hourly(), public.zella_spam_mask(text) from public, anon, authenticated;
revoke all on function public.zella_spam_overview(uuid, timestamptz, timestamptz), public.zella_spam_review(uuid, text, text, boolean),
  public.zella_spam_note(uuid, text), public.zella_spam_assign(uuid, uuid), public.zella_spam_list_add(uuid, text, text, text, text, integer, uuid),
  public.zella_spam_list_remove(uuid), public.zella_spam_settings_save(uuid, jsonb), public.zella_spam_settings_get(uuid) from public, anon;
grant execute on function public.zella_spam_overview(uuid, timestamptz, timestamptz), public.zella_spam_review(uuid, text, text, boolean),
  public.zella_spam_note(uuid, text), public.zella_spam_assign(uuid, uuid), public.zella_spam_list_add(uuid, text, text, text, text, integer, uuid),
  public.zella_spam_list_remove(uuid), public.zella_spam_settings_save(uuid, jsonb), public.zella_spam_settings_get(uuid) to authenticated;
revoke all on function public.zella_spam_call_trg(), public.zella_spam_sms_trg(), public.zella_spam_email_trg(), public.zella_spam_booking_guard(),
  public.zella_spam_booking_record(), public.zella_spam_reply_guard() from public, anon, authenticated;
