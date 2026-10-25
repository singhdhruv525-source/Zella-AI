-- Zella AI: Offers & Promotions engine (Zella Core).
-- Needs: core schema (businesses, industries, plans, subscriptions, payments, platform_admins,
-- platform_alerts, audit_logs, business_members), zella_platform_alert, zella_has_role, is_platform_admin.
-- Safe to run more than once.
--
-- What lives here (Supabase is the authority for all of it):
--   * offers with an explicit lifecycle: draft -> pending_approval -> scheduled -> active -> expired, plus paused and archived
--   * one server-side eligibility engine (business size, industry, plan, business, customer status, country,
--     billing interval, subscription status, first purchase, earlier redemptions), combined with ALL / ANY
--   * claims (redemptions) that are atomic: the offer row is locked, limits are counted inside the lock,
--     and an idempotency key makes a repeated request return the first result
--   * a schedule job that activates and expires offers, lapses unpaid holds and raises admin alerts
--   * automation rules, approvals, an event history, job runs for monitoring, and reports from real records
-- What is deliberately NOT here yet: checkout, renewal pricing, referral rewards, win-back and promotional
-- emails. They need a payment provider and sending, which are not switched on, so they show as Unavailable.
-- Money is kept in whole cents and basis points (1% = 100); no floating point.

-- 1. Business size, set by a Zella admin (never guessed from industry).
alter table public.businesses add column if not exists business_size text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'businesses_business_size_check') then
    alter table public.businesses add constraint businesses_business_size_check check (business_size is null or business_size in ('small', 'medium', 'large'));
  end if;
end $$;

-- 2. Tables
create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 120),
  description text check (description is null or length(description) <= 1000),
  internal_note text check (internal_note is null or length(internal_note) <= 2000),
  offer_type text not null default 'percent_discount' check (offer_type in (
    'percent_discount', 'fixed_discount', 'annual_promo', 'business_specific', 'industry_specific', 'size_specific',
    'promo_code', 'custom_negotiated', 'intro_pricing', 'referral', 'win_back', 'free_trial')),
  status text not null default 'draft' check (status in ('draft', 'pending_approval', 'scheduled', 'active', 'paused', 'expired', 'archived')),
  discount_kind text not null default 'percent' check (discount_kind in ('percent', 'fixed')),
  percent_off_bp integer check (percent_off_bp is null or percent_off_bp between 1 and 10000),
  amount_off_cents bigint check (amount_off_cents is null or amount_off_cents > 0),
  currency text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  duration text not null default 'once' check (duration in ('once', 'repeating', 'forever')),
  duration_months integer check (duration_months is null or duration_months between 1 and 36),
  timezone text not null default 'America/New_York',
  starts_at timestamptz,
  ends_at timestamptz,
  eligibility jsonb not null default '{"match": "all", "rules": []}'::jsonb check (jsonb_typeof(eligibility) = 'object'),
  max_redemptions integer check (max_redemptions is null or max_redemptions > 0),
  max_per_business integer not null default 1 check (max_per_business between 1 and 100),
  code text check (code is null or code ~ '^[A-Za-z0-9_-]{3,40}$'),
  code_case_sensitive boolean not null default false,
  stackable boolean not null default false,
  channels text[] not null default array['dashboard']::text[],
  needs_approval boolean not null default false,
  created_by uuid,
  submitted_by uuid,
  submitted_at timestamptz,
  approved_by uuid,
  approved_at timestamptz,
  activated_at timestamptz,
  paused_at timestamptz,
  expired_at timestamptz,
  archived_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);
-- Codes are unique ignoring case, so "SPRING" and "spring" can never both exist.
create unique index if not exists offers_code_unique on public.offers (lower(code)) where code is not null;
create index if not exists offers_status_idx on public.offers (status, starts_at, ends_at);

create table if not exists public.offer_redemptions (
  id uuid primary key default gen_random_uuid(),
  offer_id uuid not null references public.offers(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'failed', 'reversed', 'cancelled', 'lapsed')),
  source text not null check (source in ('dashboard', 'code', 'admin')),
  idempotency_key text not null check (length(idempotency_key) between 8 and 120),
  terms jsonb not null default '{}'::jsonb,           -- the agreed terms, frozen at claim time
  discount_cents bigint,                              -- worked out on confirmation when the plan price is known
  payment_id uuid references public.payments(id) on delete set null,
  hold_until timestamptz,
  claimed_by uuid,
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  ended_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (idempotency_key)
);
create index if not exists offer_redemptions_offer_idx on public.offer_redemptions (offer_id, status);
create index if not exists offer_redemptions_business_idx on public.offer_redemptions (business_id, status);

create table if not exists public.offer_events (
  id uuid primary key default gen_random_uuid(),
  offer_id uuid references public.offers(id) on delete restrict,
  business_id uuid references public.businesses(id) on delete set null,
  kind text not null,
  from_status text,
  to_status text,
  actor uuid,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists offer_events_offer_idx on public.offer_events (offer_id, created_at desc);
create index if not exists offer_events_kind_idx on public.offer_events (kind, created_at desc);

create table if not exists public.offer_job_runs (
  id uuid primary key default gen_random_uuid(),
  job text not null,
  trigger text not null default 'schedule' check (trigger in ('schedule', 'manual', 'retry')),
  status text not null default 'running' check (status in ('running', 'succeeded', 'failed', 'partial', 'skipped')),
  processed integer not null default 0,
  failures integer not null default 0,
  error text,
  detail jsonb not null default '{}'::jsonb,
  started_by uuid,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists offer_job_runs_idx on public.offer_job_runs (job, started_at desc);

create table if not exists public.offer_rules (
  key text primary key,
  enabled boolean not null default false,
  config jsonb not null default '{}'::jsonb,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Nothing is read or written directly by browsers: every read and change goes through the functions below.
alter table public.offers enable row level security;
alter table public.offer_redemptions enable row level security;
alter table public.offer_events enable row level security;
alter table public.offer_job_runs enable row level security;
alter table public.offer_rules enable row level security;
revoke all on public.offers, public.offer_redemptions, public.offer_events, public.offer_job_runs, public.offer_rules from anon, authenticated;

-- 3. Automation rule templates. "requires" names what must exist before a rule can run.
insert into public.offer_rules (key, enabled, config) values
  ('auto_activate', true, '{}'),
  ('auto_expire', true, '{}'),
  ('approval_thresholds', true, '{"percent_bp": 3000, "amount_cents": 10000, "max_redemptions": 200, "always_types": ["custom_negotiated"]}'),
  ('claim_hold', true, '{"days": 14}'),
  ('expiry_warning', true, '{"days_before": 3}'),
  ('limit_warning', true, '{"percent": 80}'),
  ('unusual_activity', true, '{"claims_per_hour": 20}'),
  ('completion_report', true, '{}'),
  ('abandoned_checkout', false, '{"delay_hours": 24, "max_reminders": 1}'),
  ('intro_renewal', false, '{}'),
  ('referral', false, '{}'),
  ('win_back', false, '{"inactive_days": 60, "max_contacts": 1}'),
  ('promo_email', false, '{}')
on conflict (key) do nothing;

-- What each rule needs. Billing counts as connected once the payment provider has delivered an event.
create or replace function public.zella_offer_capabilities()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'billing', exists (select 1 from public.billing_events where status = 'processed'),
    'checkout', false,          -- no self-serve checkout in the app yet
    'referral_tracking', false, -- no referral links yet
    'promo_sending', false      -- promotional sending is switched off by the owner
  );
$$;

create or replace function public.zella_offer_rule_requires(p_key text)
returns text[] language sql immutable as $$
  select case p_key
    when 'abandoned_checkout' then array['checkout', 'promo_sending']
    when 'intro_renewal' then array['billing']
    when 'referral' then array['referral_tracking', 'billing']
    when 'win_back' then array['promo_sending']
    when 'promo_email' then array['promo_sending']
    else array[]::text[] end;
$$;

create or replace function public.zella_offer_type_requires(p_type text)
returns text[] language sql immutable as $$
  select case p_type
    when 'intro_pricing' then array['billing']
    when 'referral' then array['referral_tracking', 'billing']
    when 'win_back' then array['promo_sending']
    when 'free_trial' then array['billing', 'checkout']
    else array[]::text[] end;
$$;

create or replace function public.zella_offer_channel_requires(p_channel text)
returns text[] language sql immutable as $$
  select case p_channel
    when 'dashboard' then array[]::text[]
    when 'sales' then array[]::text[]
    when 'pricing_page' then array['checkout']
    when 'signup' then array['checkout']
    when 'checkout' then array['checkout', 'billing']
    when 'email' then array['promo_sending']
    when 'referral' then array['referral_tracking']
    else array['unknown'] end;
$$;

create or replace function public.zella_offer_missing(p_requires text[])
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(r) filter (where coalesce((public.zella_offer_capabilities() ->> r)::boolean, false) is not true), array[]::text[])
  from unnest(coalesce(p_requires, array[]::text[])) r;
$$;

create or replace function public.zella_offer_rule_config(p_key text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when enabled then config else null end from public.offer_rules where key = p_key;
$$;

-- 4. Helpers
create or replace function public.zella_is_zella_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid() and is_active and role = 'zella_owner');
$$;

create or replace function public.zella_offer_log(p_offer uuid, p_kind text, p_from text, p_to text, p_detail jsonb default '{}'::jsonb, p_business uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, actor, detail)
  values (p_offer, p_business, p_kind, p_from, p_to, auth.uid(), coalesce(p_detail, '{}'::jsonb));
  -- Admin actions also go to the platform audit log.
  if auth.uid() is not null and p_kind not like 'claim%' then
    insert into public.audit_logs (user_id, business_id, action, entity_type, entity_id, old_data, new_data)
    values (auth.uid(), p_business, 'offer.' || p_kind, 'offer', p_offer,
            case when p_from is not null then jsonb_build_object('status', p_from) end,
            jsonb_strip_nulls(jsonb_build_object('status', p_to)) || coalesce(p_detail, '{}'::jsonb));
  end if;
end $$;

create or replace function public.zella_offer_needs_approval(o public.offers)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.zella_offer_rule_config('approval_thresholds');
begin
  if c is null then return false; end if;
  return o.offer_type = any (coalesce(array(select jsonb_array_elements_text(c -> 'always_types')), array[]::text[]))
      or (o.discount_kind = 'percent' and coalesce(o.percent_off_bp, 0) >= coalesce((c ->> 'percent_bp')::int, 10001))
      or (o.discount_kind = 'fixed' and coalesce(o.amount_off_cents, 0) >= coalesce((c ->> 'amount_cents')::bigint, 9223372036854775807))
      or (o.max_redemptions is null or o.max_redemptions > coalesce((c ->> 'max_redemptions')::int, 2147483647));
end $$;

-- Everything that must be right before an offer can be scheduled or go live.
create or replace function public.zella_offer_problems(o public.offers)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare p text[] := array[]::text[]; r jsonb; f text; ch text; miss text[];
begin
  if o.name is null or btrim(o.name) = '' then p := p || text 'Give the offer a name.'; end if;
  miss := public.zella_offer_missing(public.zella_offer_type_requires(o.offer_type));
  if cardinality(miss) > 0 then p := p || format('This offer type is not available yet (needs %s).', array_to_string(miss, ', ')); end if;
  if o.discount_kind = 'percent' and o.percent_off_bp is null then p := p || text 'Set the percentage off.'; end if;
  if o.discount_kind = 'fixed' and o.amount_off_cents is null then p := p || text 'Set the amount off.'; end if;
  if o.duration = 'repeating' and o.duration_months is null then p := p || text 'Say for how many months the discount applies.'; end if;
  if o.starts_at is null then p := p || text 'Set a start date.'; end if;
  if o.ends_at is null then p := p || text 'Set an end date.'; end if;
  if o.ends_at is not null and o.ends_at <= now() then p := p || text 'The end date has already passed.'; end if;
  if not exists (select 1 from pg_timezone_names where name = o.timezone) then p := p || text 'Choose a valid time zone.'; end if;
  if o.offer_type = 'promo_code' and o.code is null then p := p || text 'A promotional code offer needs a code.'; end if;
  if cardinality(o.channels) = 0 then p := p || text 'Choose at least one place the offer can appear.'; end if;
  foreach ch in array o.channels loop
    miss := public.zella_offer_missing(public.zella_offer_channel_requires(ch));
    if cardinality(miss) > 0 then p := p || format('"%s" is not available yet (needs %s).', ch, array_to_string(miss, ', ')); end if;
  end loop;
  if coalesce(o.eligibility ->> 'match', 'all') not in ('all', 'any') then p := p || text 'Eligibility must match all or any rules.'; end if;
  for r in select * from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) loop
    f := r ->> 'field';
    if f not in ('business_size', 'industry', 'plan', 'business', 'customer_status', 'country', 'billing_interval',
                 'subscription_status', 'first_purchase', 'never_redeemed') then
      p := p || format('Unknown eligibility rule "%s".', coalesce(f, '?'));
    elsif f in ('first_purchase', 'never_redeemed') then
      if jsonb_typeof(r -> 'value') <> 'boolean' then p := p || format('Rule "%s" needs yes or no.', f); end if;
    elsif jsonb_typeof(r -> 'values') <> 'array' or jsonb_array_length(r -> 'values') = 0 then
      p := p || format('Rule "%s" needs at least one value.', f);
    elsif f = 'business_size' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v not in ('small', 'medium', 'large')) then
      p := p || text 'Business size must be small, medium or large.';
    elsif f = 'industry' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v
                                     where v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.industries i where i.id = v::uuid)) then
      p := p || text 'One of the chosen industries no longer exists.';
    elsif f = 'plan' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v
                                 where v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.plans pl where pl.id = v::uuid)) then
      p := p || text 'One of the chosen plans no longer exists.';
    elsif f = 'business' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v
                                     where v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.businesses b where b.id = v::uuid)) then
      p := p || text 'One of the chosen businesses no longer exists.';
    elsif f = 'customer_status' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v not in ('new', 'existing', 'former')) then
      p := p || text 'Customer status must be new, existing or former.';
    elsif f = 'billing_interval' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v not in ('monthly', 'yearly')) then
      p := p || text 'Billing interval must be monthly or yearly.';
    end if;
  end loop;
  if o.offer_type = 'business_specific' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2 where r2 ->> 'field' = 'business') then
    p := p || text 'A business-specific offer needs a "business" rule.';
  end if;
  if o.offer_type = 'industry_specific' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2 where r2 ->> 'field' = 'industry') then
    p := p || text 'An industry offer needs an "industry" rule.';
  end if;
  if o.offer_type = 'size_specific' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2 where r2 ->> 'field' = 'business_size') then
    p := p || text 'A business-size offer needs a "business size" rule.';
  end if;
  if o.offer_type = 'annual_promo' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2
                                                   where r2 ->> 'field' = 'billing_interval' and r2 -> 'values' ? 'yearly') then
    p := p || text 'An annual promotion needs a "billing interval: yearly" rule.';
  end if;
  return p;
end $$;

-- 5. Eligibility engine: what Zella knows about a business, from trusted records only.
create or replace function public.zella_offer_facts(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b public.businesses; s public.subscriptions; v_paid boolean; v_had boolean; v_redeemed boolean;
begin
  select * into b from public.businesses where id = p_business;
  if not found then return null; end if;
  select * into s from public.subscriptions where business_id = p_business order by created_at desc limit 1;
  select exists (select 1 from public.payments where business_id = p_business and status = 'succeeded') into v_paid;
  select exists (select 1 from public.subscriptions where business_id = p_business) into v_had;
  select exists (select 1 from public.offer_redemptions where business_id = p_business and status in ('pending', 'confirmed')) into v_redeemed;
  return jsonb_build_object(
    'business', b.id::text,
    'business_size', b.business_size,
    'industry', b.industry_id::text,
    'country', upper(coalesce(b.country, '')),
    'plan', s.plan_id::text,
    'billing_interval', s.billing_interval,
    'subscription_status', coalesce(s.status, 'none'),
    'customer_status', case
      when s.status in ('trial', 'active', 'renewal_due', 'past_due', 'grace_period') then 'existing'
      when v_had then 'former'
      else 'new' end,
    'first_purchase', not v_paid,
    'never_redeemed', not v_redeemed,
    'cancelled', b.cancelled_at is not null,
    'suspended', b.suspended_at is not null);
end $$;

-- Returns one result per rule, so an admin preview can explain exactly why a business does or doesn't qualify.
create or replace function public.zella_offer_rule_results(p_eligibility jsonb, p_facts jsonb)
returns jsonb language plpgsql stable as $$
declare r jsonb; f text; fact text; ok boolean; out jsonb := '[]'::jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p_eligibility -> 'rules', '[]'::jsonb)) loop
    f := r ->> 'field';
    fact := p_facts ->> f;
    if f in ('first_purchase', 'never_redeemed') then
      ok := (p_facts -> f) = (r -> 'value');
    elsif f = 'country' then
      ok := fact is not null and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where upper(v) = fact);
    else
      ok := fact is not null and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v = fact);
    end if;
    out := out || jsonb_build_array(jsonb_build_object('field', f, 'ok', coalesce(ok, false), 'actual', p_facts -> f));
  end loop;
  return out;
end $$;

create or replace function public.zella_offer_is_eligible(p_offer public.offers, p_business uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare facts jsonb := public.zella_offer_facts(p_business); res jsonb;
begin
  if facts is null or (facts ->> 'cancelled')::boolean or (facts ->> 'suspended')::boolean then return false; end if;
  res := public.zella_offer_rule_results(p_offer.eligibility, facts);
  if jsonb_array_length(res) = 0 then return true; end if;
  if coalesce(p_offer.eligibility ->> 'match', 'all') = 'any' then
    return exists (select 1 from jsonb_array_elements(res) x where (x ->> 'ok')::boolean);
  end if;
  return not exists (select 1 from jsonb_array_elements(res) x where not (x ->> 'ok')::boolean);
end $$;

-- The terms frozen onto a claim, and a short plain-language summary.
create or replace function public.zella_offer_terms(o public.offers)
returns jsonb language sql stable as $$
  select jsonb_build_object('offer_name', o.name, 'offer_type', o.offer_type, 'discount_kind', o.discount_kind,
    'percent_off_bp', o.percent_off_bp, 'amount_off_cents', o.amount_off_cents, 'currency', o.currency,
    'duration', o.duration, 'duration_months', o.duration_months, 'offer_version', o.version, 'ends_at', o.ends_at);
$$;

create or replace function public.zella_offer_summary(o public.offers)
returns text language sql stable as $$
  select case when o.discount_kind = 'percent'
              then rtrim(to_char(o.percent_off_bp / 100.0, 'FM990.99'), '.') || '% off'
              else upper(o.currency) || ' ' || trim(to_char(o.amount_off_cents / 100.0, 'FM999999990.00')) || ' off' end
      || case o.duration when 'once' then ' your next bill'
                         when 'repeating' then ' for ' || o.duration_months || case when o.duration_months = 1 then ' month' else ' months' end
                         else ' for as long as you stay subscribed' end;
$$;

-- 6. Admin: save. New offers start as drafts. Commercial terms can only change while the offer is a draft.
create or replace function public.zella_offer_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.offers; v_tz text; v_start timestamptz; v_end timestamptz; v_channels text[]; v_new boolean := p_id is null;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if v_new then
    insert into public.offers (name, created_by) values (coalesce(nullif(btrim(p_data ->> 'name'), ''), 'Untitled offer'), auth.uid()) returning * into o;
  else
    select * into o from public.offers where id = p_id for update;
    if not found then raise exception 'OFFER_NOT_FOUND'; end if;
  end if;

  -- Wording can change at any time; it doesn't change what anyone agreed to.
  update public.offers set
    name = coalesce(nullif(btrim(p_data ->> 'name'), ''), name),
    description = case when p_data ? 'description' then nullif(btrim(p_data ->> 'description'), '') else description end,
    internal_note = case when p_data ? 'internal_note' then nullif(btrim(p_data ->> 'internal_note'), '') else internal_note end,
    updated_at = now()
  where id = o.id;

  if o.status = 'draft' then
    v_tz := coalesce(nullif(p_data ->> 'timezone', ''), o.timezone);
    if not exists (select 1 from pg_timezone_names where name = v_tz) then raise exception 'BAD_TIMEZONE'; end if;
    -- Start and end arrive as local date-times in the offer's time zone ("2026-11-01T09:00").
    v_start := case when nullif(p_data ->> 'start_local', '') is null then case when p_data ? 'start_local' then null else o.starts_at end
                    else ((p_data ->> 'start_local')::timestamp at time zone v_tz) end;
    v_end := case when nullif(p_data ->> 'end_local', '') is null then case when p_data ? 'end_local' then null else o.ends_at end
                  else ((p_data ->> 'end_local')::timestamp at time zone v_tz) end;
    if v_start is not null and v_end is not null and v_end <= v_start then raise exception 'END_BEFORE_START'; end if;
    v_channels := case when jsonb_typeof(p_data -> 'channels') = 'array'
                       then array(select distinct jsonb_array_elements_text(p_data -> 'channels')) else o.channels end;
    update public.offers set
      offer_type = coalesce(p_data ->> 'offer_type', offer_type),
      discount_kind = coalesce(p_data ->> 'discount_kind', discount_kind),
      percent_off_bp = case when coalesce(p_data ->> 'discount_kind', discount_kind) = 'percent'
                            then coalesce((p_data ->> 'percent_off_bp')::int, percent_off_bp) else null end,
      amount_off_cents = case when coalesce(p_data ->> 'discount_kind', discount_kind) = 'fixed'
                              then coalesce((p_data ->> 'amount_off_cents')::bigint, amount_off_cents) else null end,
      currency = lower(coalesce(nullif(p_data ->> 'currency', ''), currency)),
      duration = coalesce(p_data ->> 'duration', duration),
      duration_months = case when coalesce(p_data ->> 'duration', duration) = 'repeating'
                             then coalesce((p_data ->> 'duration_months')::int, duration_months) else null end,
      timezone = v_tz,
      starts_at = v_start,
      ends_at = v_end,
      eligibility = case when jsonb_typeof(p_data -> 'eligibility') = 'object' then p_data -> 'eligibility' else eligibility end,
      max_redemptions = case when p_data ? 'max_redemptions' then nullif(p_data ->> 'max_redemptions', '')::int else max_redemptions end,
      max_per_business = coalesce(nullif(p_data ->> 'max_per_business', '')::int, max_per_business),
      code = case when p_data ? 'code' then nullif(btrim(p_data ->> 'code'), '') else code end,
      code_case_sensitive = coalesce((p_data ->> 'code_case_sensitive')::boolean, code_case_sensitive),
      stackable = coalesce((p_data ->> 'stackable')::boolean, stackable),
      channels = v_channels,
      version = version + case when v_new then 0 else 1 end
    where id = o.id;
  elsif p_data ?| array['offer_type', 'discount_kind', 'percent_off_bp', 'amount_off_cents', 'duration', 'duration_months', 'start_local',
                        'end_local', 'eligibility', 'max_redemptions', 'max_per_business', 'code', 'channels', 'stackable', 'currency'] then
    raise exception 'TERMS_LOCKED';
  end if;

  select * into o from public.offers where id = o.id;
  update public.offers set needs_approval = public.zella_offer_needs_approval(o) where id = o.id;
  perform public.zella_offer_log(o.id, case when v_new then 'created' else 'edited' end, null, null, jsonb_build_object('version', o.version));
  return o.id;
exception when unique_violation then
  raise exception 'CODE_TAKEN';
end $$;

-- 7. Admin: lifecycle actions. The browser never sets a status directly.
create or replace function public.zella_offer_transition(p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.offers; v_to text; v_problems text[]; v_other_owner boolean;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id for update;
  if not found then raise exception 'OFFER_NOT_FOUND'; end if;

  if p_action = 'submit' then
    if o.status <> 'draft' then raise exception 'BAD_TRANSITION'; end if;
    v_problems := public.zella_offer_problems(o);
    if cardinality(v_problems) > 0 then return jsonb_build_object('ok', false, 'problems', to_jsonb(v_problems)); end if;
    v_to := case when public.zella_offer_needs_approval(o) then 'pending_approval' else 'scheduled' end;
    update public.offers set status = v_to, needs_approval = (v_to = 'pending_approval'), submitted_by = auth.uid(), submitted_at = now(),
           approved_by = null, approved_at = null, updated_at = now() where id = o.id;
  elsif p_action in ('approve', 'reject') then
    if o.status <> 'pending_approval' then raise exception 'BAD_TRANSITION'; end if;
    -- Only a Zella owner approves. Someone who submitted an offer can't approve it themselves
    -- unless they are the only active owner.
    if not public.zella_is_zella_owner() then raise exception 'OWNER_ONLY'; end if;
    select exists (select 1 from public.platform_admins where is_active and role = 'zella_owner' and user_id <> auth.uid()) into v_other_owner;
    if p_action = 'approve' and o.submitted_by = auth.uid() and v_other_owner then raise exception 'SECOND_PERSON_NEEDED'; end if;
    if p_action = 'reject' and nullif(btrim(p_note), '') is null then raise exception 'NOTE_REQUIRED'; end if;
    if p_action = 'approve' then
      v_problems := public.zella_offer_problems(o);
      if cardinality(v_problems) > 0 then return jsonb_build_object('ok', false, 'problems', to_jsonb(v_problems)); end if;
    end if;
    v_to := case when p_action = 'approve' then 'scheduled' else 'draft' end;
    update public.offers set status = v_to, approved_by = case when p_action = 'approve' then auth.uid() end,
           approved_at = case when p_action = 'approve' then now() end, updated_at = now() where id = o.id;
  elsif p_action = 'pause' then
    if o.status not in ('scheduled', 'active') then raise exception 'BAD_TRANSITION'; end if;
    v_to := 'paused';
    update public.offers set status = 'paused', paused_at = now(), updated_at = now() where id = o.id;
  elsif p_action = 'resume' then
    if o.status <> 'paused' then raise exception 'BAD_TRANSITION'; end if;
    if o.ends_at <= now() then
      v_to := 'expired';
      update public.offers set status = 'expired', expired_at = now(), updated_at = now() where id = o.id;
    else
      v_problems := public.zella_offer_problems(o);
      if cardinality(v_problems) > 0 then return jsonb_build_object('ok', false, 'problems', to_jsonb(v_problems)); end if;
      v_to := case when o.starts_at <= now() then 'active' else 'scheduled' end;
      update public.offers set status = v_to, paused_at = null, activated_at = coalesce(activated_at, case when v_to = 'active' then now() end),
             updated_at = now() where id = o.id;
    end if;
  elsif p_action = 'back_to_draft' then
    if o.status not in ('scheduled', 'pending_approval') then raise exception 'BAD_TRANSITION'; end if;
    if exists (select 1 from public.offer_redemptions where offer_id = o.id) then raise exception 'HAS_REDEMPTIONS'; end if;
    v_to := 'draft';
    update public.offers set status = 'draft', approved_by = null, approved_at = null, updated_at = now() where id = o.id;
  elsif p_action = 'archive' then
    if o.status not in ('draft', 'paused', 'expired') then raise exception 'BAD_TRANSITION'; end if;
    v_to := 'archived';
    update public.offers set status = 'archived', archived_at = now(), updated_at = now() where id = o.id;
  elsif p_action = 'end_now' then
    -- Stop a live offer early. Claims already made keep their agreed terms.
    if o.status not in ('active', 'paused', 'scheduled') then raise exception 'BAD_TRANSITION'; end if;
    v_to := 'expired';
    update public.offers set status = 'expired', expired_at = now(), ends_at = least(ends_at, now()), updated_at = now() where id = o.id;
  else
    raise exception 'BAD_ACTION';
  end if;

  perform public.zella_offer_log(o.id, p_action, o.status, v_to, jsonb_strip_nulls(jsonb_build_object('note', nullif(btrim(p_note), ''))));
  -- A scheduled offer whose start has passed goes live straight away rather than waiting for the next run.
  if v_to = 'scheduled' and o.starts_at <= now() then perform public.zella_offers_tick('manual'); end if;
  return jsonb_build_object('ok', true, 'status', (select status from public.offers where id = o.id));
end $$;

-- 8. Claims. One function does every check inside a lock on the offer, so two people at once can't pass a limit.
create or replace function public.zella_offer_redeem_core(p_offer uuid, p_business uuid, p_source text, p_key text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.offers; r public.offer_redemptions; v_reason text; v_hold jsonb := public.zella_offer_rule_config('claim_hold');
        v_total int; v_mine int; v_recent int; v_unusual jsonb := public.zella_offer_rule_config('unusual_activity'); v_limit jsonb;
begin
  if p_key is null or length(p_key) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  -- The same request sent twice returns the first answer.
  select * into r from public.offer_redemptions where idempotency_key = p_key;
  if found then
    if r.offer_id <> p_offer or r.business_id <> p_business then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object('ok', r.status in ('pending', 'confirmed'), 'status', r.status, 'redemption_id', r.id, 'repeat', true);
  end if;

  select * into o from public.offers where id = p_offer for update;
  if not found then v_reason := 'not_found';
  elsif o.status = 'paused' then v_reason := 'paused';
  elsif o.status in ('expired', 'archived') or (o.ends_at is not null and o.ends_at <= now()) then v_reason := 'expired';
  elsif o.status <> 'active' or o.starts_at is null or o.starts_at > now() then v_reason := 'not_started';
  elsif p_source in ('dashboard', 'code') and not ('dashboard' = any (o.channels)) then v_reason := 'not_available_here';
  elsif p_source = 'admin' and not ('sales' = any (o.channels)) and not ('dashboard' = any (o.channels)) then v_reason := 'not_available_here';
  elsif p_source = 'dashboard' and o.code is not null then v_reason := 'code_required';
  elsif not public.zella_offer_is_eligible(o, p_business) then v_reason := 'not_eligible';
  end if;

  if v_reason is null then
    select count(*) filter (where status in ('pending', 'confirmed')),
           count(*) filter (where status in ('pending', 'confirmed') and business_id = p_business)
      into v_total, v_mine from public.offer_redemptions where offer_id = o.id;
    if v_mine >= o.max_per_business then v_reason := 'already_claimed';
    elsif o.max_redemptions is not null and v_total >= o.max_redemptions then v_reason := 'limit_reached';
    elsif not o.stackable and exists (
      select 1 from public.offer_redemptions x join public.offers xo on xo.id = x.offer_id
      where x.business_id = p_business and x.status = 'pending' and x.offer_id <> o.id and not xo.stackable) then
      v_reason := 'cannot_combine';
    end if;
  end if;

  if v_reason is not null then
    perform public.zella_offer_log(case when o.id is not null then o.id end, 'claim_rejected', null, null,
                                   jsonb_build_object('reason', v_reason, 'source', p_source), p_business);
    return jsonb_build_object('ok', false, 'reason', v_reason);
  end if;

  insert into public.offer_redemptions (offer_id, business_id, status, source, idempotency_key, terms, hold_until, claimed_by, note)
  values (o.id, p_business, 'pending', p_source, p_key, public.zella_offer_terms(o),
          now() + make_interval(days => coalesce((v_hold ->> 'days')::int, 14)), auth.uid(), left(nullif(btrim(p_note), ''), 500))
  returning * into r;
  perform public.zella_offer_log(o.id, 'claimed', null, null, jsonb_build_object('source', p_source, 'redemption_id', r.id), p_business);

  -- Admin heads-ups: limit nearly used, limit reached, unusual numbers of claims.
  v_total := v_total + 1;
  v_limit := public.zella_offer_rule_config('limit_warning');
  if o.max_redemptions is not null then
    if v_total >= o.max_redemptions then
      perform public.zella_platform_alert('offer_limit_reached', 'Offer limit reached: ' || o.name,
        format('All %s claims for this offer have been used.', o.max_redemptions), 'info', null, 'limit:' || o.id);
    elsif v_limit is not null and v_total * 100 >= o.max_redemptions * coalesce((v_limit ->> 'percent')::int, 80) then
      perform public.zella_platform_alert('offer_limit_near', 'Offer nearly used up: ' || o.name,
        format('%s of %s claims used.', v_total, o.max_redemptions), 'info', null, 'limitnear:' || o.id);
    end if;
  end if;
  if v_unusual is not null then
    select count(*) into v_recent from public.offer_redemptions where offer_id = o.id and created_at > now() - interval '1 hour';
    if v_recent >= coalesce((v_unusual ->> 'claims_per_hour')::int, 20) then
      perform public.zella_platform_alert('offer_unusual_activity', 'Unusual number of claims: ' || o.name,
        format('%s claims in the last hour. Consider pausing the offer to review.', v_recent), 'warning', null,
        'unusual:' || o.id || ':' || to_char(now(), 'YYYYMMDDHH24'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'status', r.status, 'redemption_id', r.id, 'hold_until', r.hold_until);
end $$;

-- Plain words for each reason. Never says anything about other businesses.
create or replace function public.zella_offer_reason_text(p_reason text)
returns text language sql immutable as $$
  select case p_reason
    when 'not_found' then 'That offer or code is not valid.'
    when 'paused' then 'This offer is paused at the moment.'
    when 'expired' then 'This offer has ended.'
    when 'not_started' then 'This offer has not started yet.'
    when 'not_available_here' then 'This offer is not available here.'
    when 'code_required' then 'This offer needs a code.'
    when 'not_eligible' then 'This offer is not available for your business.'
    when 'already_claimed' then 'Your business has already claimed this offer.'
    when 'limit_reached' then 'This offer has been fully claimed.'
    when 'cannot_combine' then 'You already have another offer waiting to be applied, and this one can''t be combined with it.'
    when 'too_many_attempts' then 'Too many codes were tried. Please wait an hour and try again.'
    else 'This offer can''t be claimed right now.' end;
$$;

-- 9. Business app: offers this business can see, code check, claim, cancel a claim.
create or replace function public.zella_offers_for_business(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'available', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'description', o.description,
        'summary', public.zella_offer_summary(o), 'ends_at', o.ends_at, 'timezone', o.timezone) order by o.ends_at)
      from public.offers o
      where o.status = 'active' and o.starts_at <= now() and o.ends_at > now() and 'dashboard' = any (o.channels) and o.code is null
        and public.zella_offer_is_eligible(o, p_business_id)
        and not exists (select 1 from public.offer_redemptions x where x.offer_id = o.id and x.business_id = p_business_id and x.status in ('pending', 'confirmed'))
        and (o.max_redemptions is null or (select count(*) from public.offer_redemptions x where x.offer_id = o.id and x.status in ('pending', 'confirmed')) < o.max_redemptions)
    ), '[]'::jsonb),
    'claimed', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.terms ->> 'offer_name', 'status', r.status,
        'summary', public.zella_offer_summary(o), 'created_at', r.created_at, 'hold_until', r.hold_until, 'confirmed_at', r.confirmed_at) order by r.created_at desc)
      from public.offer_redemptions r join public.offers o on o.id = r.offer_id
      where r.business_id = p_business_id and r.status in ('pending', 'confirmed')), '[]'::jsonb),
    'billing_connected', (public.zella_offer_capabilities() ->> 'billing')::boolean);
end $$;

create or replace function public.zella_offer_find_code(p_code text)
returns public.offers language sql stable security definer set search_path = public as $$
  select o.* from public.offers o
  where o.code is not null and case when o.code_case_sensitive then o.code = btrim(p_code) else lower(o.code) = lower(btrim(p_code)) end
  limit 1;
$$;

create or replace function public.zella_offer_check_code(p_business_id uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.offers; v_tries int; v_reason text;
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  select count(*) into v_tries from public.offer_events
  where business_id = p_business_id and kind = 'code_rejected' and created_at > now() - interval '1 hour';
  if v_tries >= 10 then return jsonb_build_object('ok', false, 'reason', 'too_many_attempts', 'message', public.zella_offer_reason_text('too_many_attempts')); end if;
  o := public.zella_offer_find_code(left(coalesce(p_code, ''), 60));
  if o.id is null then v_reason := 'not_found';
  elsif o.status = 'paused' then v_reason := 'paused';
  elsif o.status in ('expired', 'archived') or o.ends_at <= now() then v_reason := 'expired';
  elsif o.status <> 'active' or o.starts_at > now() then v_reason := 'not_found';  -- don't reveal codes that aren't live
  elsif not ('dashboard' = any (o.channels)) then v_reason := 'not_found';
  elsif not public.zella_offer_is_eligible(o, p_business_id) then v_reason := 'not_eligible';
  end if;
  if v_reason is not null then
    insert into public.offer_events (offer_id, business_id, kind, actor, detail)
    values (case when v_reason <> 'not_found' then o.id end, p_business_id, 'code_rejected', auth.uid(), jsonb_build_object('reason', v_reason));
    return jsonb_build_object('ok', false, 'reason', v_reason, 'message', public.zella_offer_reason_text(v_reason));
  end if;
  return jsonb_build_object('ok', true, 'offer', jsonb_build_object('id', o.id, 'name', o.name, 'description', o.description,
    'summary', public.zella_offer_summary(o), 'ends_at', o.ends_at, 'timezone', o.timezone));
end $$;

-- Only the business owner can claim: it changes what the business will pay.
create or replace function public.zella_offer_claim(p_business_id uuid, p_offer_id uuid, p_code text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.offers; v_res jsonb; v_source text := case when nullif(btrim(p_code), '') is not null then 'code' else 'dashboard' end;
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner']) then raise exception 'OWNER_ONLY'; end if;
  if v_source = 'code' then
    o := public.zella_offer_find_code(left(p_code, 60));
    if o.id is null or (p_offer_id is not null and o.id <> p_offer_id) then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', public.zella_offer_reason_text('not_found'));
    end if;
  else
    o.id := p_offer_id;
  end if;
  v_res := public.zella_offer_redeem_core(o.id, p_business_id, v_source, p_idempotency_key);
  return v_res || case when v_res ? 'reason' then jsonb_build_object('message', public.zella_offer_reason_text(v_res ->> 'reason')) else '{}'::jsonb end;
end $$;

create or replace function public.zella_offer_cancel_claim(p_redemption_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.offer_redemptions;
begin
  select * into r from public.offer_redemptions where id = p_redemption_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is null or not (public.zella_has_role(r.business_id, array['owner']) or public.is_platform_admin()) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'pending' then raise exception 'NOT_PENDING'; end if;
  update public.offer_redemptions set status = 'cancelled', ended_at = now(), updated_at = now() where id = r.id;
  perform public.zella_offer_log(r.offer_id, 'claim_cancelled', 'pending', 'cancelled', jsonb_build_object('redemption_id', r.id), r.business_id);
end $$;

-- 10. Admin: apply an offer to one business (sales and negotiated deals), change a claim, set business size.
create or replace function public.zella_offer_apply_admin(p_offer_id uuid, p_business_id uuid, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res jsonb;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  v_res := public.zella_offer_redeem_core(p_offer_id, p_business_id, 'admin', p_idempotency_key, p_note);
  return v_res || case when v_res ? 'reason' then jsonb_build_object('message', public.zella_offer_reason_text(v_res ->> 'reason')) else '{}'::jsonb end;
end $$;

create or replace function public.zella_offer_set_redemption(p_id uuid, p_status text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.offer_redemptions;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if p_status not in ('cancelled', 'reversed') then raise exception 'BAD_STATUS'; end if;
  if nullif(btrim(p_note), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  select * into r from public.offer_redemptions where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_status = 'cancelled' and r.status <> 'pending' then raise exception 'NOT_PENDING'; end if;
  if p_status = 'reversed' and r.status <> 'confirmed' then raise exception 'NOT_CONFIRMED'; end if;
  update public.offer_redemptions set status = p_status, ended_at = now(), note = left(p_note, 500), updated_at = now() where id = r.id;
  perform public.zella_offer_log(r.offer_id, 'claim_' || p_status, r.status, p_status, jsonb_build_object('redemption_id', r.id, 'note', p_note), r.business_id);
end $$;

create or replace function public.zella_set_business_size(p_business_id uuid, p_size text)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if p_size is not null and p_size not in ('small', 'medium', 'large') then raise exception 'BAD_SIZE'; end if;
  select business_size into v_old from public.businesses where id = p_business_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.businesses set business_size = p_size, updated_at = now() where id = p_business_id;
  insert into public.audit_logs (user_id, business_id, action, entity_type, entity_id, old_data, new_data)
  values (auth.uid(), p_business_id, 'business.size_changed', 'business', p_business_id, jsonb_build_object('size', v_old), jsonb_build_object('size', p_size));
end $$;

-- 11. Billing link. A claim is confirmed only by a real, verified payment (from the billing webhook).
create or replace function public.zella_offer_on_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare r public.offer_redemptions; v_price numeric; v_cents bigint;
begin
  if new.status = 'succeeded' and (tg_op = 'INSERT' or old.status is distinct from 'succeeded') then
    for r in select * from public.offer_redemptions where business_id = new.business_id and status = 'pending' order by created_at for update loop
      -- The standard price from the plan, when one is set, gives the discount value for reports.
      select case when s.billing_interval = 'yearly' then pl.price_yearly else pl.price_monthly end into v_price
      from public.subscriptions s join public.plans pl on pl.id = s.plan_id where s.id = new.subscription_id;
      v_cents := case when r.terms ->> 'discount_kind' = 'fixed' then (r.terms ->> 'amount_off_cents')::bigint
                      when v_price is not null and v_price > 0 then round(v_price * 100 * (r.terms ->> 'percent_off_bp')::int / 10000) end;
      update public.offer_redemptions set status = 'confirmed', payment_id = new.id, confirmed_at = now(), discount_cents = v_cents, updated_at = now() where id = r.id;
      insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
      values (r.offer_id, r.business_id, 'claim_confirmed', 'pending', 'confirmed', jsonb_build_object('redemption_id', r.id, 'payment_id', new.id));
    end loop;
  elsif new.status = 'refunded' and tg_op = 'UPDATE' and old.status is distinct from 'refunded' then
    for r in select * from public.offer_redemptions where payment_id = new.id and status = 'confirmed' for update loop
      update public.offer_redemptions set status = 'reversed', ended_at = now(), updated_at = now() where id = r.id;
      insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
      values (r.offer_id, r.business_id, 'claim_reversed', 'confirmed', 'reversed', jsonb_build_object('redemption_id', r.id, 'payment_id', new.id));
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists zella_offer_payment_trg on public.payments;
create trigger zella_offer_payment_trg after insert or update of status on public.payments
  for each row execute function public.zella_offer_on_payment();

-- A cancelled subscription releases claims that were never paid.
create or replace function public.zella_offer_on_subscription()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('cancelled', 'expired') and old.status is distinct from new.status then
    with c as (
      update public.offer_redemptions set status = 'cancelled', ended_at = now(), note = 'Subscription ended before payment', updated_at = now()
      where business_id = new.business_id and status = 'pending' returning id, offer_id, business_id)
    insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
    select offer_id, business_id, 'claim_cancelled', 'pending', 'cancelled', jsonb_build_object('redemption_id', id, 'why', 'subscription_ended') from c;
  end if;
  return new;
end $$;
drop trigger if exists zella_offer_subscription_trg on public.subscriptions;
create trigger zella_offer_subscription_trg after update of status on public.subscriptions
  for each row execute function public.zella_offer_on_subscription();

-- 12. Schedule job: activate, expire, lapse unpaid holds, warn before expiry, report on completion.
-- Runs from the database scheduler (every 5 minutes once the dispatcher is switched on) and from "Run now".
-- Safe to run twice at once: a lock lets only one run work, and each step re-checks the current state.
create or replace function public.zella_offers_tick(p_trigger text default 'schedule')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_run uuid; o public.offers; v_problems text[]; v_done int := 0; v_fail int := 0; v_lapsed int := 0; v_warn jsonb; v_counts jsonb;
begin
  if auth.uid() is not null and not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if not pg_try_advisory_xact_lock(hashtext('zella_offers_tick')) then
    insert into public.offer_job_runs (job, trigger, status, started_by, finished_at, detail)
    values ('offers_tick', p_trigger, 'skipped', auth.uid(), now(), '{"why": "another run was in progress"}');
    return jsonb_build_object('status', 'skipped');
  end if;
  insert into public.offer_job_runs (job, trigger, started_by) values ('offers_tick', p_trigger, auth.uid()) returning id into v_run;

  -- Activate offers whose start time has come, after checking they are still valid.
  if public.zella_offer_rule_config('auto_activate') is not null or p_trigger <> 'schedule' then
    for o in select * from public.offers where status = 'scheduled' and starts_at <= now() and ends_at > now() order by starts_at for update skip locked loop
      begin
        v_problems := public.zella_offer_problems(o);
        if cardinality(v_problems) > 0 then
          v_fail := v_fail + 1;
          insert into public.offer_events (offer_id, kind, from_status, to_status, detail)
          values (o.id, 'activation_failed', 'scheduled', 'scheduled', jsonb_build_object('problems', to_jsonb(v_problems), 'run_id', v_run));
          perform public.zella_platform_alert('offer_activation_failed', 'Offer could not go live: ' || o.name,
            array_to_string(v_problems, ' '), 'warning', null, 'activate:' || o.id);
        else
          update public.offers set status = 'active', activated_at = now(), updated_at = now() where id = o.id;
          insert into public.offer_events (offer_id, kind, from_status, to_status, detail)
          values (o.id, 'activated', 'scheduled', 'active', jsonb_build_object('run_id', v_run));
          perform public.zella_resolve_platform_alerts('offer_activation_failed', null, 'activate:' || o.id, 'Went live');
          v_done := v_done + 1;
        end if;
      exception when others then
        v_fail := v_fail + 1;
        insert into public.offer_events (offer_id, kind, detail) values (o.id, 'activation_error', jsonb_build_object('error', sqlerrm, 'run_id', v_run));
      end;
    end loop;
  end if;

  -- Expire offers whose end time has passed. Claims already made keep their terms.
  if public.zella_offer_rule_config('auto_expire') is not null or p_trigger <> 'schedule' then
    for o in select * from public.offers where status in ('scheduled', 'active', 'paused', 'pending_approval') and ends_at <= now() for update skip locked loop
      update public.offers set status = 'expired', expired_at = now(), updated_at = now() where id = o.id;
      select jsonb_build_object('claims', count(*), 'confirmed', count(*) filter (where status = 'confirmed'), 'pending', count(*) filter (where status = 'pending'))
        into v_counts from public.offer_redemptions where offer_id = o.id;
      insert into public.offer_events (offer_id, kind, from_status, to_status, detail)
      values (o.id, 'expired', o.status, 'expired', jsonb_build_object('run_id', v_run) || v_counts);
      if public.zella_offer_rule_config('completion_report') is not null then
        perform public.zella_platform_alert('offer_completed', 'Offer ended: ' || o.name,
          format('%s claims, %s paid, %s still waiting for payment.', v_counts ->> 'claims', v_counts ->> 'confirmed', v_counts ->> 'pending'),
          'info', null, 'completed:' || o.id);
      end if;
      v_done := v_done + 1;
    end loop;
  end if;

  -- Unpaid claims are released after the hold period so they stop counting toward limits.
  with l as (
    update public.offer_redemptions set status = 'lapsed', ended_at = now(), updated_at = now()
    where status = 'pending' and hold_until < now() returning id, offer_id, business_id)
  insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
  select offer_id, business_id, 'claim_lapsed', 'pending', 'lapsed', jsonb_build_object('redemption_id', id) from l;
  get diagnostics v_lapsed = row_count;

  -- One heads-up a few days before an offer ends.
  v_warn := public.zella_offer_rule_config('expiry_warning');
  if v_warn is not null then
    for o in select * from public.offers x where x.status = 'active'
               and x.ends_at <= now() + make_interval(days => coalesce((v_warn ->> 'days_before')::int, 3))
               and not exists (select 1 from public.offer_events e where e.offer_id = x.id and e.kind = 'expiry_warning') loop
      insert into public.offer_events (offer_id, kind, detail) values (o.id, 'expiry_warning', jsonb_build_object('ends_at', o.ends_at));
      perform public.zella_platform_alert('offer_ending_soon', 'Offer ending soon: ' || o.name,
        'Ends ' || to_char(o.ends_at at time zone o.timezone, 'Mon DD, YYYY HH12:MI AM') || ' (' || o.timezone || ').', 'info', null, 'ending:' || o.id);
    end loop;
  end if;

  update public.offer_job_runs set status = case when v_fail > 0 then case when v_done > 0 then 'partial' else 'failed' end else 'succeeded' end,
         processed = v_done + v_lapsed, failures = v_fail, finished_at = now(),
         detail = jsonb_build_object('changed', v_done, 'lapsed', v_lapsed, 'failed', v_fail)
  where id = v_run;
  return jsonb_build_object('status', case when v_fail > 0 then 'partial' else 'succeeded' end, 'changed', v_done, 'lapsed', v_lapsed, 'failed', v_fail);
exception when others then
  -- Everything this run changed is undone; the failure itself is recorded and raises one admin alert.
  insert into public.offer_job_runs (job, trigger, status, failures, error, started_by, finished_at)
  values ('offers_tick', p_trigger, 'failed', 1, left(sqlerrm, 500), auth.uid(), now());
  perform public.zella_platform_alert('offer_job_failed', 'Offer schedule job failed', left(sqlerrm, 500), 'warning', null, 'offers_tick');
  return jsonb_build_object('status', 'failed', 'error', left(sqlerrm, 200));
end $$;

-- 13. Admin reads
create or replace function public.zella_offers_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'offers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'offer_type', o.offer_type, 'status', o.status, 'summary', public.zella_offer_summary(o),
        'starts_at', o.starts_at, 'ends_at', o.ends_at, 'timezone', o.timezone, 'code', o.code, 'channels', o.channels,
        'max_redemptions', o.max_redemptions, 'needs_approval', o.needs_approval, 'updated_at', o.updated_at,
        'claims', (select count(*) from public.offer_redemptions r where r.offer_id = o.id and r.status in ('pending', 'confirmed')),
        'confirmed', (select count(*) from public.offer_redemptions r where r.offer_id = o.id and r.status = 'confirmed'),
        'problems', case when o.status in ('draft', 'pending_approval', 'scheduled', 'paused') then to_jsonb(public.zella_offer_problems(o)) else '[]'::jsonb end
      ) order by case o.status when 'active' then 0 when 'pending_approval' then 1 when 'scheduled' then 2 when 'paused' then 3 when 'draft' then 4 when 'expired' then 5 else 6 end, o.updated_at desc)
      from public.offers o), '[]'::jsonb),
    'capabilities', public.zella_offer_capabilities(),
    'is_owner', public.zella_is_zella_owner(),
    'me', auth.uid());
end $$;

create or replace function public.zella_offer_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.offers; v_start_local text; v_end_local text;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id;
  if not found then raise exception 'OFFER_NOT_FOUND'; end if;
  return jsonb_build_object(
    'offer', to_jsonb(o) || jsonb_build_object(
      'start_local', to_char(o.starts_at at time zone o.timezone, 'YYYY-MM-DD"T"HH24:MI'),
      'end_local', to_char(o.ends_at at time zone o.timezone, 'YYYY-MM-DD"T"HH24:MI'),
      'summary', public.zella_offer_summary(o),
      'problems', to_jsonb(public.zella_offer_problems(o)),
      'needs_approval_now', public.zella_offer_needs_approval(o)),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'from', e.from_status, 'to', e.to_status,
        'detail', e.detail, 'created_at', e.created_at, 'business', b.name,
        'actor', (select u.email from auth.users u where u.id = e.actor)) order by e.created_at desc)
      from (select * from public.offer_events where offer_id = o.id order by created_at desc limit 100) e
      left join public.businesses b on b.id = e.business_id), '[]'::jsonb),
    'redemptions', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'business_id', r.business_id, 'business', b.name,
        'status', r.status, 'source', r.source, 'created_at', r.created_at, 'confirmed_at', r.confirmed_at, 'hold_until', r.hold_until,
        'discount_cents', r.discount_cents, 'note', r.note) order by r.created_at desc)
      from public.offer_redemptions r join public.businesses b on b.id = r.business_id where r.offer_id = o.id), '[]'::jsonb));
end $$;

-- How many businesses this offer would reach today, with a short sample, before anything goes live.
create or replace function public.zella_offer_audience(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.offers;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id;
  if not found then raise exception 'OFFER_NOT_FOUND'; end if;
  return (
    with e as (select b.id, b.name, b.business_size, public.zella_offer_is_eligible(o, b.id) ok from public.businesses b)
    select jsonb_build_object(
      'eligible', count(*) filter (where ok),
      'total', count(*),
      'missing_size', count(*) filter (where business_size is null),
      'names', coalesce((select jsonb_agg(x.name) from (select name from e where ok order by name limit 8) x), '[]'::jsonb))
    from e);
end $$;

-- Per-business check with a reason for each rule (admin only).
create or replace function public.zella_offer_explain(p_id uuid, p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.offers; facts jsonb;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id;
  facts := public.zella_offer_facts(p_business_id);
  return jsonb_build_object('eligible', public.zella_offer_is_eligible(o, p_business_id), 'match', coalesce(o.eligibility ->> 'match', 'all'),
    'facts', facts, 'rules', public.zella_offer_rule_results(o.eligibility, facts));
end $$;

-- 14. Automation rules, monitoring and reports
-- Whether the database scheduler that runs the offer job is switched on (it is part of go-live).
create or replace function public.zella_offer_scheduler_on()
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v boolean;
begin
  execute 'select exists (select 1 from cron.job where command ilike ''%zella_run_schedule_group%every5%'' and active)' into v;
  return coalesce(v, false);
exception when others then
  return false;
end $$;

create or replace function public.zella_offer_rules_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'rules', coalesce((select jsonb_agg(jsonb_build_object('key', r.key, 'enabled', r.enabled, 'config', r.config, 'updated_at', r.updated_at,
        'requires', to_jsonb(public.zella_offer_rule_requires(r.key)),
        'missing', to_jsonb(public.zella_offer_missing(public.zella_offer_rule_requires(r.key))),
        'updated_by', (select u.email from auth.users u where u.id = r.updated_by)) order by r.key)
      from public.offer_rules r), '[]'::jsonb),
    'last_run', (select to_jsonb(j) from (select status, trigger, started_at, finished_at, processed, failures, error from public.offer_job_runs
                 where job = 'offers_tick' and status <> 'skipped' order by started_at desc limit 1) j),
    'last_success', (select max(finished_at) from public.offer_job_runs where job = 'offers_tick' and status = 'succeeded'),
    'scheduler_on', public.zella_offer_scheduler_on(),
    'capabilities', public.zella_offer_capabilities(),
    'is_owner', public.zella_is_zella_owner());
end $$;

create or replace function public.zella_offer_rule_save(p_key text, p_enabled boolean, p_config jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_old public.offer_rules; v_miss text[] := public.zella_offer_missing(public.zella_offer_rule_requires(p_key)); k text; v jsonb;
begin
  if not public.zella_is_zella_owner() then raise exception 'OWNER_ONLY'; end if;
  select * into v_old from public.offer_rules where key = p_key for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_enabled and cardinality(v_miss) > 0 then raise exception 'RULE_UNAVAILABLE'; end if;
  if jsonb_typeof(coalesce(p_config, '{}'::jsonb)) <> 'object' then raise exception 'BAD_CONFIG'; end if;
  -- Only known settings, as whole numbers in sensible ranges.
  for k, v in select * from jsonb_each(coalesce(p_config, '{}'::jsonb)) loop
    if not (v_old.config ? k) then raise exception 'BAD_CONFIG'; end if;
    if k = 'always_types' then
      if jsonb_typeof(v) <> 'array' then raise exception 'BAD_CONFIG'; end if;
    elsif jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < 0 or (v #>> '{}')::numeric > 100000000 or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric) then
      raise exception 'BAD_CONFIG';
    end if;
  end loop;
  update public.offer_rules set enabled = p_enabled, config = v_old.config || coalesce(p_config, '{}'::jsonb), updated_by = auth.uid(), updated_at = now() where key = p_key;
  insert into public.audit_logs (user_id, action, entity_type, old_data, new_data)
  values (auth.uid(), 'offer_rule.updated', 'offer_rule', jsonb_build_object('key', p_key, 'enabled', v_old.enabled, 'config', v_old.config),
          jsonb_build_object('key', p_key, 'enabled', p_enabled, 'config', v_old.config || coalesce(p_config, '{}'::jsonb)));
  -- Approval thresholds changed: re-check offers still waiting.
  if p_key = 'approval_thresholds' then
    update public.offers o set needs_approval = public.zella_offer_needs_approval(o) where o.status = 'draft';
  end if;
end $$;

create or replace function public.zella_offer_monitor(p_filter text default 'all', p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'runs', coalesce((select jsonb_agg(to_jsonb(j) order by j.started_at desc) from (
        select id, job, trigger, status, processed, failures, error, detail, started_at, finished_at,
               (select u.email from auth.users u where u.id = started_by) as started_by
        from public.offer_job_runs
        where p_filter = 'all' or (p_filter = 'failed' and status in ('failed', 'partial')) or (p_filter = 'succeeded' and status = 'succeeded')
           or (p_filter = 'retried' and trigger = 'retry') or (p_filter = 'pending' and status = 'running')
        order by started_at desc limit least(greatest(p_limit, 1), 500)) j), '[]'::jsonb),
    'failures', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'offer_id', e.offer_id, 'offer', o.name,
        'detail', e.detail, 'created_at', e.created_at) order by e.created_at desc)
      from (select * from public.offer_events where kind in ('activation_failed', 'activation_error') order by created_at desc limit 50) e
      left join public.offers o on o.id = e.offer_id), '[]'::jsonb),
    'rejections', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'count', n)) from (
        select detail ->> 'reason' reason, count(*) n from public.offer_events
        where kind in ('claim_rejected', 'code_rejected') and created_at > now() - interval '7 days' group by 1 order by 2 desc) x), '[]'::jsonb));
end $$;

create or replace function public.zella_offer_retry()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  -- Retrying is always safe: the job looks at the current state and only changes what is due.
  return public.zella_offers_tick('retry');
end $$;

-- Reports from real records only. Definitions:
--   claims       = claims made in the date range (any status)
--   paid         = claims confirmed by a verified payment
--   paid rate    = paid / claims (claim-to-paid; offer views are not tracked, so no view-based rate)
--   gross paid   = amount of the payments that confirmed claims, each payment counted once (attribution: the payment
--                  that confirmed the claim; per offer, a payment that confirmed claims on two offers counts for both)
--   refunded     = the part of that amount later refunded
--   discount     = discount value given on confirmed claims, where the plan price was known
create or replace function public.zella_offer_report(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return (
    with r as (
      select x.*, o.name offer_name, b.business_size, i.name industry, p.amount paid_amount, p.status pay_status
      from public.offer_redemptions x
      join public.offers o on o.id = x.offer_id
      join public.businesses b on b.id = x.business_id
      left join public.industries i on i.id = b.industry_id
      left join public.payments p on p.id = x.payment_id
      where x.created_at >= p_from and x.created_at < p_to),
    agg as (
      select r.*, (status in ('confirmed', 'reversed')) as paid from r)
    select jsonb_build_object(
      'from', p_from, 'to', p_to,
      'totals', (select jsonb_build_object('claims', count(*), 'paid', count(*) filter (where paid),
          'reversed', count(*) filter (where status = 'reversed'), 'pending', count(*) filter (where status = 'pending'),
          'lapsed', count(*) filter (where status in ('lapsed', 'cancelled')),
          -- One payment can confirm several claims, so money is counted once per payment.
          'gross_paid_cents', coalesce((select sum(round(p.amount * 100)) from public.payments p where p.id in (select payment_id from agg where paid)), 0),
          'refunded_cents', coalesce((select sum(round(p.amount * 100)) from public.payments p where p.status = 'refunded' and p.id in (select payment_id from agg where paid)), 0),
          'discount_cents', coalesce(sum(discount_cents) filter (where status = 'confirmed'), 0),
          'discount_unknown', count(*) filter (where status = 'confirmed' and discount_cents is null)) from agg),
      'by_offer', coalesce((select jsonb_agg(row_to_json(t)) from (
          select offer_id, offer_name, count(*) claims, count(*) filter (where paid) paid,
                 coalesce(sum(round(paid_amount * 100)) filter (where paid), 0) gross_paid_cents,
                 coalesce(sum(discount_cents) filter (where status = 'confirmed'), 0) discount_cents
          from agg group by 1, 2 order by 3 desc) t), '[]'::jsonb),
      'by_size', coalesce((select jsonb_agg(row_to_json(t)) from (
          select coalesce(business_size, 'not set') size, count(*) claims, count(*) filter (where paid) paid from agg group by 1 order by 2 desc) t), '[]'::jsonb),
      'by_industry', coalesce((select jsonb_agg(row_to_json(t)) from (
          select coalesce(industry, 'Unassigned') industry, count(*) claims, count(*) filter (where paid) paid from agg group by 1 order by 2 desc) t), '[]'::jsonb),
      'by_source', coalesce((select jsonb_agg(row_to_json(t)) from (
          select source, count(*) claims, count(*) filter (where paid) paid from agg group by 1 order by 2 desc) t), '[]'::jsonb))
  );
end $$;

-- 15. Permissions: browsers can call only the public entry points; checks inside each decide who may act.
do $$
declare f text;
begin
  foreach f in array array[
    'zella_offer_capabilities()', 'zella_offer_missing(text[])', 'zella_offer_rule_config(text)', 'zella_offer_log(uuid,text,text,text,jsonb,uuid)',
    'zella_offer_needs_approval(public.offers)', 'zella_offer_problems(public.offers)', 'zella_offer_facts(uuid)',
    'zella_offer_is_eligible(public.offers,uuid)', 'zella_offer_redeem_core(uuid,uuid,text,text,text)', 'zella_offer_find_code(text)',
    'zella_offer_on_payment()', 'zella_offer_on_subscription()', 'zella_offers_tick(text)', 'zella_is_zella_owner()', 'zella_offer_scheduler_on()']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array[
    'zella_offer_save(uuid,jsonb)', 'zella_offer_transition(uuid,text,text)', 'zella_offers_for_business(uuid)', 'zella_offer_check_code(uuid,text)',
    'zella_offer_claim(uuid,uuid,text,text)', 'zella_offer_cancel_claim(uuid)', 'zella_offer_apply_admin(uuid,uuid,text,text)',
    'zella_offer_set_redemption(uuid,text,text)', 'zella_set_business_size(uuid,text)', 'zella_offers_list()', 'zella_offer_detail(uuid)',
    'zella_offer_audience(uuid)', 'zella_offer_explain(uuid,uuid)', 'zella_offer_rules_list()', 'zella_offer_rule_save(text,boolean,jsonb)',
    'zella_offer_monitor(text,int)', 'zella_offer_retry()', 'zella_offer_report(timestamptz,timestamptz)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
