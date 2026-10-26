-- Zella - foundations for the admin and business Settings systems (2026-10-26). Safe to re-run.
--
-- Purpose (one section each, all additive: no table is dropped, no row is deleted or rewritten)
--   1. Platform roles and permissions: five restricted admin roles next to zella_owner/super_admin, a permission
--      matrix the owner can change, and zella_admin_can(permission) for trusted code.
--   2. Platform profile, branding and maintenance notice: safe public read (zella_platform_public_info).
--   3. My sessions: list and revoke the signed-in person's own sessions.
--   4. Plan entitlements: plans.limits holds the allowances; zella_business_entitlements() reads them with live
--      usage, and team capacity is enforced when an invitation is created.
--   5. Voice pricing versions and a usage/estimated-cost summary from recorded calls.
--   6. Business usage protection preferences and 70/90/100% usage notices.
--   7. Legal documents with versions, and acceptance records made only by a person's own click.
--   8. brand-assets storage bucket for platform and business logos.
--   9. Notification preferences (business members) and admin alert email opt-out.
--  10. Fixed search_path on seven offer helper functions (Supabase security advisor).
--
-- Needs: zella_workflows.sql (platform_settings, zella_setting), zella_ops_extras.sql (zella_has_role),
--   zella_admin_alerts.sql (zella_claim_admin_alert_email), zella_staff_invites_approvals.sql. pg_cron (already used).
--
-- Authorization
--   Every function checks the caller itself. Business data is only returned to active members of that business;
--   platform data only to active platform admins with the right permission. New tables have row level security on
--   and no write grants to signed-in users: writes go through these functions or the owner-provision-business
--   function (server key, after its own permission check).
--
-- Rollback
--   Each section lists what it creates. The only change to existing objects: platform_admins_role_check allows five
--   more roles (put the old check back only after removing admins with those roles), zella_claim_admin_alert_email
--   skips admins who opted out (re-run zella_admin_alerts.sql to undo), a trigger on business_invitations
--   (drop trigger zella_team_capacity_trg on public.business_invitations) and one on business_phone_numbers
--   (drop trigger zella_phone_capacity_trg on public.business_phone_numbers).
--
-- Validation: see docs/SCHEMA_STATUS.md ("Settings system checks").

-- 1. Platform roles and permissions ---------------------------------------------------------------------------

alter table public.platform_admins drop constraint if exists platform_admins_role_check;
alter table public.platform_admins add constraint platform_admins_role_check check (role in (
  'zella_owner', 'super_admin', 'platform_operations', 'billing_admin', 'support_admin', 'security_admin', 'read_only_admin'));

create table if not exists public.platform_role_permissions (
  role text not null check (role in ('platform_operations', 'billing_admin', 'support_admin', 'security_admin', 'read_only_admin')),
  permission text not null,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (role, permission)
);
alter table public.platform_role_permissions enable row level security;
revoke all on public.platform_role_permissions from anon, authenticated;

-- Starting matrix. zella_owner and super_admin always have everything (super_admin cannot manage admins or roles,
-- as before). Restricted roles only get what is listed; the owner changes this in Settings.
insert into public.platform_role_permissions (role, permission) values
  ('platform_operations', 'businesses.view'), ('platform_operations', 'businesses.manage'), ('platform_operations', 'integrations.manage'),
  ('platform_operations', 'telephony.manage'), ('platform_operations', 'ai.configure'), ('platform_operations', 'support.manage'),
  ('platform_operations', 'analytics.view'), ('platform_operations', 'comms.manage'),
  ('billing_admin', 'businesses.view'), ('billing_admin', 'billing.view'), ('billing_admin', 'billing.manage'), ('billing_admin', 'plans.manage'),
  ('billing_admin', 'analytics.view'),
  ('support_admin', 'businesses.view'), ('support_admin', 'support.manage'), ('support_admin', 'analytics.view'),
  ('security_admin', 'businesses.view'), ('security_admin', 'security.view'), ('security_admin', 'security.manage'), ('security_admin', 'audit.view'),
  ('read_only_admin', 'businesses.view'), ('read_only_admin', 'billing.view'), ('read_only_admin', 'security.view'), ('read_only_admin', 'audit.view'),
  ('read_only_admin', 'analytics.view')
on conflict do nothing;

-- The caller's active platform role, or null. Any signed-in person may ask about themselves.
create or replace function public.zella_admin_role()
returns text language sql stable security definer set search_path = public as $$
  select pa.role from public.platform_admins pa where pa.user_id = auth.uid() and pa.is_active;
$$;

create or replace function public.zella_admin_can(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when r is null then false
    when r = 'zella_owner' then true
    when r = 'super_admin' then p_permission not in ('admins.manage', 'roles.manage')
    else exists (select 1 from public.platform_role_permissions p where p.role = r and p.permission = p_permission)
  end
  from (select public.zella_admin_role() as r) x;
$$;
revoke all on function public.zella_admin_role(), public.zella_admin_can(text) from public, anon;
grant execute on function public.zella_admin_role(), public.zella_admin_can(text) to authenticated, service_role;

-- 2. Platform profile, branding, maintenance -------------------------------------------------------------------
--    Stored in platform_settings (platform_profile, platform_branding, maintenance), written by the owner function.
--    This read returns only what any visitor may see (it is shown on the sign-in pages).

create or replace function public.zella_platform_public_info()
returns jsonb language sql stable security definer set search_path = public as $$
  with p as (select coalesce((select value from public.platform_settings where key = 'platform_profile'), '{}'::jsonb) v),
       b as (select coalesce((select value from public.platform_settings where key = 'platform_branding'), '{}'::jsonb) v),
       m as (select coalesce((select value from public.platform_settings where key = 'maintenance'), '{}'::jsonb) v)
  select jsonb_strip_nulls(jsonb_build_object(
    'display_name', p.v ->> 'display_name', 'support_email', p.v ->> 'support_email', 'support_phone', p.v ->> 'support_phone',
    'website', p.v ->> 'website', 'logo_url', b.v ->> 'logo_url', 'login_headline', b.v ->> 'login_headline',
    'maintenance', case
      when coalesce((m.v ->> 'active')::boolean, false)
           and coalesce((m.v ->> 'ends_at')::timestamptz > now(), true)
        then jsonb_build_object('state', case when coalesce((m.v ->> 'starts_at')::timestamptz <= now(), true) then 'now' else 'scheduled' end,
                                'message', m.v ->> 'message', 'starts_at', m.v ->> 'starts_at', 'ends_at', m.v ->> 'ends_at')
    end))
  from p, b, m;
$$;
revoke all on function public.zella_platform_public_info() from public;
grant execute on function public.zella_platform_public_info() to anon, authenticated, service_role;

-- 3. My sessions -----------------------------------------------------------------------------------------------
--    Supabase keeps one row per signed-in device in auth.sessions. Removing a row ends that device's refresh token;
--    its current access token still works until it expires (one hour by default).

create or replace function public.zella_my_sessions()
returns jsonb language sql stable security definer set search_path = public, auth as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'created_at', s.created_at, 'last_active_at', coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at),
      'user_agent', left(s.user_agent, 300), 'ip', host(s.ip), 'aal', s.aal,
      'current', s.id::text = coalesce(auth.jwt() ->> 'session_id', '')) order by coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at) desc), '[]'::jsonb)
  from auth.sessions s where s.user_id = auth.uid();
$$;

create or replace function public.zella_revoke_my_session(p_session_id uuid)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if p_session_id::text = coalesce(auth.jwt() ->> 'session_id', '') then raise exception 'USE_SIGN_OUT'; end if;
  delete from auth.sessions where id = p_session_id and user_id = auth.uid();
  if not found then return false; end if;
  insert into public.audit_logs (user_id, action, entity_type, new_data) values (auth.uid(), 'session.revoked', 'session', jsonb_build_object('session_id', p_session_id));
  return true;
end $$;
revoke all on function public.zella_my_sessions(), public.zella_revoke_my_session(uuid) from public, anon;
grant execute on function public.zella_my_sessions(), public.zella_revoke_my_session(uuid) to authenticated;

-- 4. Plan entitlements -----------------------------------------------------------------------------------------
--    plans.limits keys (all optional; a missing key means "no limit set"):
--      voice_minutes, sms_messages, phone_numbers, team_members, locations, automations, integrations (numbers)
--      reporting ('standard' | 'advanced'), support_level ('standard' | 'priority' | 'dedicated'), onboarding ('self' | 'guided' | 'done_for_you')
--    The core CRM is in every plan and is never a limit.

create or replace function public.zella_current_subscription(p_business_id uuid)
returns public.subscriptions language sql stable security definer set search_path = public as $$
  select s.* from public.subscriptions s
   where s.business_id = p_business_id and s.status in ('trial', 'active', 'renewal_due', 'past_due', 'grace_period')
   order by s.created_at desc limit 1;
$$;
revoke all on function public.zella_current_subscription(uuid) from public, anon, authenticated;
grant execute on function public.zella_current_subscription(uuid) to service_role;

create or replace function public.zella_usage_counts(p_business_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'voice_minutes', coalesce((select round(sum(duration_seconds) / 60.0, 1) from public.calls
                                where business_id = p_business_id and ai_handled and created_at >= p_from and created_at < p_to), 0),
    'sms_messages', (select count(*) from public.sms_messages where business_id = p_business_id and direction = 'outbound'
                      and status <> 'failed' and created_at >= p_from and created_at < p_to),
    'phone_numbers', (select count(*) from public.business_phone_numbers where business_id = p_business_id and status = 'active'),
    'team_members', (select count(*) from public.business_members where business_id = p_business_id and status = 'active')
                    + (select count(*) from public.business_invitations where business_id = p_business_id and status in ('pending', 'sent') and role <> 'owner'),
    'automations', (select count(*) from public.automations where business_id = p_business_id and status = 'active'),
    'integrations', (select count(*) from public.integrations where business_id = p_business_id and status = 'active'));
$$;
revoke all on function public.zella_usage_counts(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.zella_usage_counts(uuid, timestamptz, timestamptz) to service_role;

-- For members of the business (and platform admins with businesses.view): plan, allowances and usage this period.
create or replace function public.zella_business_entitlements(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; p public.plans; v_from timestamptz; v_to timestamptz;
begin
  if not (public.zella_is_member(p_business_id) or public.zella_admin_can('businesses.view')) then raise exception 'NOT_ALLOWED'; end if;
  s := public.zella_current_subscription(p_business_id);
  if s.id is not null then select * into p from public.plans where id = s.plan_id; end if;
  v_from := coalesce(s.current_period_start, date_trunc('month', now()));
  v_to := coalesce(s.current_period_end, date_trunc('month', now()) + interval '1 month');
  return jsonb_build_object(
    'subscription', case when s.id is null then null else jsonb_build_object('id', s.id, 'status', s.status, 'billing_interval', s.billing_interval,
       'provider', s.provider, 'trial_end_at', s.trial_end_at, 'current_period_start', s.current_period_start,
       'current_period_end', s.current_period_end, 'grace_period_end_at', s.grace_period_end_at, 'cancelled_at', s.cancelled_at) end,
    'plan', case when p.id is null then null else jsonb_build_object('id', p.id, 'name', p.name, 'slug', p.slug, 'price_monthly', p.price_monthly,
       'price_yearly', p.price_yearly, 'currency', p.currency) end,
    'limits', coalesce(p.limits, '{}'::jsonb),
    'core_crm', true,
    'period', jsonb_build_object('from', v_from, 'to', v_to, 'calendar_month', s.id is null),
    'usage', public.zella_usage_counts(p_business_id, v_from, v_to));
end $$;
revoke all on function public.zella_business_entitlements(uuid) from public, anon;
grant execute on function public.zella_business_entitlements(uuid) to authenticated, service_role;

-- Trusted check for numeric allowances. No plan, or no number for the key = allowed (nothing configured yet).
create or replace function public.zella_entitlement_allows(p_business_id uuid, p_key text, p_add numeric default 1)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; v_limit numeric; v_used numeric;
begin
  s := public.zella_current_subscription(p_business_id);
  if s.id is null then return true; end if;
  select nullif(p.limits ->> p_key, '')::numeric into v_limit from public.plans p where p.id = s.plan_id;
  if v_limit is null then return true; end if;
  v_used := coalesce((public.zella_usage_counts(p_business_id, coalesce(s.current_period_start, date_trunc('month', now())),
                       coalesce(s.current_period_end, date_trunc('month', now()) + interval '1 month')) ->> p_key)::numeric, 0);
  return v_used + coalesce(p_add, 0) <= v_limit;
exception when invalid_text_representation then return true;
end $$;
revoke all on function public.zella_entitlement_allows(uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.zella_entitlement_allows(uuid, text, numeric) to service_role;

create or replace function public.zella_team_capacity_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role <> 'owner' and not public.zella_entitlement_allows(new.business_id, 'team_members', 1) then
    raise exception 'TEAM_LIMIT_REACHED';
  end if;
  return new;
end $$;
drop trigger if exists zella_team_capacity_trg on public.business_invitations;
create trigger zella_team_capacity_trg before insert on public.business_invitations for each row execute function public.zella_team_capacity_trg();

create or replace function public.zella_phone_capacity_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active')
     and not public.zella_entitlement_allows(new.business_id, 'phone_numbers', 1) then
    raise exception 'PHONE_NUMBER_LIMIT_REACHED';
  end if;
  return new;
end $$;
drop trigger if exists zella_phone_capacity_trg on public.business_phone_numbers;
create trigger zella_phone_capacity_trg before insert or update of status on public.business_phone_numbers for each row execute function public.zella_phone_capacity_trg();
revoke execute on function public.zella_team_capacity_trg(), public.zella_phone_capacity_trg() from public, anon, authenticated;

-- 5. Voice pricing and usage -----------------------------------------------------------------------------------

create table if not exists public.voice_pricing (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('vapi', 'telnyx', 'twilio', 'llm', 'other')),
  component text not null default 'per_minute' check (component in ('per_minute')),
  unit_cost numeric(12, 6) not null check (unit_cost >= 0),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  billing_increment_seconds integer not null default 60 check (billing_increment_seconds between 1 and 3600),
  effective_from timestamptz not null,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (provider, component, effective_from)
);
alter table public.voice_pricing enable row level security;
revoke all on public.voice_pricing from anon, authenticated;

-- Estimated voice cost from recorded calls: each call rounded up to the provider's increment, priced at the rate
-- that was in effect when the call started. Provider-reported charges are not available yet.
create or replace function public.zella_voice_usage_summary(p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (
    select c.business_id, c.started_at, coalesce(c.started_at, c.created_at) as at, coalesce(c.duration_seconds, 0) as secs
      from public.calls c where coalesce(c.started_at, c.created_at) >= p_from and coalesce(c.started_at, c.created_at) < p_to and c.ai_handled),
  priced as (
    select c.business_id, c.secs, pr.provider, pr.currency,
           ceil(c.secs::numeric / pr.billing_increment_seconds) * pr.billing_increment_seconds / 60.0 * pr.unit_cost as cost
      from c join lateral (
        select distinct on (v.provider) v.* from public.voice_pricing v where v.effective_from <= c.at order by v.provider, v.effective_from desc) pr on true)
  select jsonb_build_object(
    'calls', (select count(*) from c),
    'minutes', (select round(coalesce(sum(secs), 0) / 60.0, 1) from c),
    'priced', exists (select 1 from public.voice_pricing),
    'estimated_cost', (select coalesce(jsonb_object_agg(currency, total), '{}'::jsonb) from (select currency, round(sum(cost), 2) total from priced group by currency) t),
    'by_provider', (select coalesce(jsonb_agg(jsonb_build_object('provider', provider, 'currency', currency, 'estimated_cost', total)), '[]'::jsonb)
                      from (select provider, currency, round(sum(cost), 2) total from priced group by provider, currency) t),
    'by_business', (select coalesce(jsonb_agg(jsonb_build_object('business_id', x.business_id, 'name', b.name, 'calls', x.n, 'minutes', x.minutes) order by x.minutes desc), '[]'::jsonb)
                      from (select business_id, count(*) n, round(sum(secs) / 60.0, 1) minutes from c group by business_id) x join public.businesses b on b.id = x.business_id));
$$;
revoke all on function public.zella_voice_usage_summary(timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.zella_voice_usage_summary(timestamptz, timestamptz) to service_role;

-- 6. Business usage protection ---------------------------------------------------------------------------------
--    The business's own choice about paid usage beyond its allowance. Nothing is ever charged from here: Zella has
--    no payment provider connected yet, and when one is, it must read this before charging.

create table if not exists public.business_usage_preferences (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  notify_thresholds integer[] not null default '{70,90,100}' check (notify_thresholds <@ '{50,70,80,90,100}'::integer[]),
  overage_mode text not null default 'stop' check (overage_mode in ('stop', 'pay_as_you_go', 'auto_top_up')),
  spend_limit_cents bigint check (spend_limit_cents is null or spend_limit_cents between 0 and 100000000),
  fallback text not null default 'take_message' check (fallback in ('take_message', 'forward_to_business', 'voicemail_only')),
  authorized_by uuid,
  authorized_at timestamptz,
  notified jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.business_usage_preferences enable row level security;
revoke all on public.business_usage_preferences from anon, authenticated;

create or replace function public.zella_usage_preferences(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.business_usage_preferences;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into r from public.business_usage_preferences where business_id = p_business_id;
  return jsonb_build_object('notify_thresholds', coalesce(r.notify_thresholds, '{70,90,100}'), 'overage_mode', coalesce(r.overage_mode, 'stop'),
    'spend_limit_cents', r.spend_limit_cents, 'fallback', coalesce(r.fallback, 'take_message'), 'authorized_at', r.authorized_at,
    'can_edit', public.zella_has_role(p_business_id, array['owner']) and auth.uid() is not null);
end $$;

-- Owner only: this is the authorization for paid usage.
create or replace function public.zella_save_usage_preferences(p_business_id uuid, p_thresholds integer[], p_mode text, p_spend_limit_cents bigint, p_fallback text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare old jsonb;
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner']) then raise exception 'NOT_ALLOWED'; end if;
  if p_mode not in ('stop', 'pay_as_you_go', 'auto_top_up') then raise exception 'BAD_INPUT'; end if;
  if p_mode <> 'stop' and (p_spend_limit_cents is null or p_spend_limit_cents <= 0) then raise exception 'SPEND_LIMIT_REQUIRED'; end if;
  select to_jsonb(u) into old from public.business_usage_preferences u where business_id = p_business_id;
  insert into public.business_usage_preferences (business_id, notify_thresholds, overage_mode, spend_limit_cents, fallback, authorized_by, authorized_at, updated_at)
  values (p_business_id, coalesce(p_thresholds, '{70,90,100}'), p_mode, case when p_mode = 'stop' then null else p_spend_limit_cents end, p_fallback,
          auth.uid(), now(), now())
  on conflict (business_id) do update set notify_thresholds = excluded.notify_thresholds, overage_mode = excluded.overage_mode,
    spend_limit_cents = excluded.spend_limit_cents, fallback = excluded.fallback, authorized_by = excluded.authorized_by,
    authorized_at = excluded.authorized_at, updated_at = now();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'billing.usage_preferences_updated', 'business', p_business_id,
          old - 'notified', jsonb_build_object('overage_mode', p_mode, 'spend_limit_cents', p_spend_limit_cents, 'fallback', p_fallback, 'thresholds', p_thresholds));
  return public.zella_usage_preferences(p_business_id);
exception when check_violation then raise exception 'BAD_INPUT';
end $$;
revoke all on function public.zella_usage_preferences(uuid), public.zella_save_usage_preferences(uuid, integer[], text, bigint, text) from public, anon;
grant execute on function public.zella_usage_preferences(uuid), public.zella_save_usage_preferences(uuid, integer[], text, bigint, text) to authenticated, service_role;

-- Hourly: tell owners once per period when voice minutes pass a threshold of the plan allowance.
create or replace function public.zella_check_usage_thresholds()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; e jsonb; v_limit numeric; v_used numeric; v_pct numeric; t integer; v_key text; n integer := 0;
begin
  for r in select b.id from public.businesses b where b.suspended_at is null and b.cancelled_at is null loop
    e := public.zella_business_entitlements_internal(r.id);
    v_limit := nullif(e -> 'limits' ->> 'voice_minutes', '')::numeric;
    if v_limit is null or v_limit <= 0 then continue; end if;
    v_used := coalesce((e -> 'usage' ->> 'voice_minutes')::numeric, 0);
    v_pct := v_used * 100 / v_limit;
    for t in select unnest(coalesce((select notify_thresholds from public.business_usage_preferences where business_id = r.id), '{70,90,100}')) order by 1 desc loop
      continue when v_pct < t;
      v_key := (e -> 'period' ->> 'from') || ':' || t;
      if exists (select 1 from public.business_usage_preferences u where u.business_id = r.id and u.notified ? v_key) then exit; end if;
      perform public.zella_notify_owners(r.id, 'usage_threshold',
        case when t >= 100 then 'Your included AI minutes are used up' else 'You have used ' || t || '% of your AI minutes' end,
        round(v_used) || ' of ' || round(v_limit) || ' minutes this period. Open Settings, Billing to see your options.',
        case when t >= 100 then 'urgent' else 'warning' end, 'settings');
      insert into public.business_usage_preferences (business_id, notified) values (r.id, jsonb_build_object(v_key, now()))
      on conflict (business_id) do update set notified = public.business_usage_preferences.notified || jsonb_build_object(v_key, now());
      n := n + 1;
      exit;
    end loop;
  end loop;
  return n;
end $$;

-- Same as zella_business_entitlements without the caller check, for scheduled jobs.
create or replace function public.zella_business_entitlements_internal(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; p public.plans; v_from timestamptz; v_to timestamptz;
begin
  s := public.zella_current_subscription(p_business_id);
  if s.id is not null then select * into p from public.plans where id = s.plan_id; end if;
  v_from := coalesce(s.current_period_start, date_trunc('month', now()));
  v_to := coalesce(s.current_period_end, date_trunc('month', now()) + interval '1 month');
  return jsonb_build_object('limits', coalesce(p.limits, '{}'::jsonb), 'period', jsonb_build_object('from', v_from, 'to', v_to),
                            'usage', public.zella_usage_counts(p_business_id, v_from, v_to));
end $$;
revoke all on function public.zella_check_usage_thresholds(), public.zella_business_entitlements_internal(uuid) from public, anon, authenticated;
grant execute on function public.zella_check_usage_thresholds(), public.zella_business_entitlements_internal(uuid) to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'zella_usage_thresholds';
    perform cron.schedule('zella_usage_thresholds', '23 * * * *', 'select public.zella_check_usage_thresholds()');
  end if;
end $$;

-- 7. Legal documents -------------------------------------------------------------------------------------------

create table if not exists public.legal_documents (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('terms', 'privacy', 'acceptable_use', 'dpa', 'cookies', 'ai_disclosure', 'recording_consent')),
  version text not null check (version ~ '^[0-9A-Za-z.\-]{1,20}$'),
  title text not null check (length(title) between 3 and 200),
  body text not null default '',
  status text not null default 'draft' check (status in ('draft', 'in_review', 'published', 'retired')),
  requires_acceptance boolean not null default false,
  effective_at timestamptz,
  reviewed_by uuid, reviewed_at timestamptz,
  published_by uuid, published_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (kind, version)
);
create unique index if not exists legal_documents_one_published on public.legal_documents (kind) where status = 'published';
alter table public.legal_documents enable row level security;
revoke all on public.legal_documents from anon, authenticated;
drop policy if exists legal_documents_published_read on public.legal_documents;
create policy legal_documents_published_read on public.legal_documents for select to authenticated using (status = 'published');
grant select on public.legal_documents to authenticated;

create table if not exists public.legal_acceptances (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.legal_documents(id),
  business_id uuid references public.businesses(id) on delete cascade,
  user_id uuid not null,
  accepted_at timestamptz not null default now(),
  unique (document_id, business_id, user_id)
);
alter table public.legal_acceptances enable row level security;
revoke all on public.legal_acceptances from anon, authenticated;
drop policy if exists legal_acceptances_read on public.legal_acceptances;
create policy legal_acceptances_read on public.legal_acceptances for select to authenticated
  using (user_id = auth.uid() or (business_id is not null and public.zella_has_role(business_id, array['owner', 'admin'])));
grant select on public.legal_acceptances to authenticated;

-- A person accepts for themselves (and, as owner/admin, on behalf of their business). Never done automatically.
create or replace function public.zella_accept_legal_document(p_document_id uuid, p_business_id uuid default null)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if not exists (select 1 from public.legal_documents where id = p_document_id and status = 'published') then raise exception 'NOT_FOUND'; end if;
  if p_business_id is not null and not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.legal_acceptances (document_id, business_id, user_id) values (p_document_id, p_business_id, auth.uid()) on conflict do nothing;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'legal.accepted', 'legal_document', p_document_id);
  return true;
end $$;
revoke all on function public.zella_accept_legal_document(uuid, uuid) from public, anon;
grant execute on function public.zella_accept_legal_document(uuid, uuid) to authenticated;

-- 8. Logos -----------------------------------------------------------------------------------------------------
--    Public bucket (logos appear on sign-in pages and emails). platform/... is written by platform admins with
--    platform.configure; business/<business id>/... by that business's owners and admins; user/<user id>/... by that
--    person (profile picture). PNG, JPEG, WebP, 2 MB.
--    SVG is not allowed (it can carry scripts).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand-assets', 'brand-assets', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];

create or replace function public.zella_can_write_brand_asset(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when p_name like 'platform/%' then public.zella_admin_can('platform.configure')
    when p_name ~ '^business/[0-9a-f-]{36}/' then auth.uid() is not null and public.zella_has_role(split_part(p_name, '/', 2)::uuid, array['owner', 'admin'])
    when p_name like 'user/%' then auth.uid() is not null and split_part(p_name, '/', 2) = auth.uid()::text
    else false end;
$$;
revoke all on function public.zella_can_write_brand_asset(text) from public, anon;
grant execute on function public.zella_can_write_brand_asset(text) to authenticated;

drop policy if exists brand_assets_insert on storage.objects;
create policy brand_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'brand-assets' and public.zella_can_write_brand_asset(name));
drop policy if exists brand_assets_update on storage.objects;
create policy brand_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'brand-assets' and public.zella_can_write_brand_asset(name));
drop policy if exists brand_assets_delete on storage.objects;
create policy brand_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand-assets' and public.zella_can_write_brand_asset(name));

-- Business logo: owners/admins set businesses.logo_url, only to a file in this bucket for their own business.
create or replace function public.zella_set_business_logo(p_business_id uuid, p_url text)
returns text language plpgsql security definer set search_path = public as $$
declare v_url text := nullif(trim(coalesce(p_url, '')), '');
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if v_url is not null and position('/storage/v1/object/public/brand-assets/business/' || p_business_id::text || '/' in v_url) = 0 then raise exception 'BAD_LOGO_URL'; end if;
  update public.businesses set logo_url = v_url, updated_at = now() where id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'business.logo_updated', 'business', p_business_id, jsonb_build_object('logo', v_url is not null));
  return v_url;
end $$;
revoke all on function public.zella_set_business_logo(uuid, text) from public, anon;
grant execute on function public.zella_set_business_logo(uuid, text) to authenticated;

-- 9. Notification preferences ----------------------------------------------------------------------------------
--    notification_preferences.email_enabled is read by zella_claim_owner_emails for each kind of notification.

create or replace function public.zella_my_notification_prefs(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_object_agg(np.notification_type, np.email_enabled) from public.notification_preferences np
                    where np.business_id = p_business_id and np.user_id = auth.uid()), '{}'::jsonb);
end $$;

create or replace function public.zella_set_my_notification_pref(p_business_id uuid, p_kind text, p_email boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_kind !~ '^[a-z_]{2,60}$' or p_email is null then raise exception 'BAD_INPUT'; end if;
  insert into public.notification_preferences (business_id, user_id, notification_type, email_enabled)
  values (p_business_id, auth.uid(), p_kind, p_email)
  on conflict (business_id, user_id, notification_type) do update set email_enabled = excluded.email_enabled, updated_at = now();
  return p_email;
end $$;
revoke all on function public.zella_my_notification_prefs(uuid), public.zella_set_my_notification_pref(uuid, text, boolean) from public, anon;
grant execute on function public.zella_my_notification_prefs(uuid), public.zella_set_my_notification_pref(uuid, text, boolean) to authenticated;

-- Admins can stop the platform alert email digest for themselves.
create table if not exists public.admin_alert_prefs (
  user_id uuid primary key,
  email_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.admin_alert_prefs enable row level security;
revoke all on public.admin_alert_prefs from anon, authenticated;

create or replace function public.zella_my_admin_alert_email(p_enabled boolean default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare v boolean;
begin
  if public.zella_admin_role() is null then raise exception 'NOT_ALLOWED'; end if;
  if p_enabled is not null then
    insert into public.admin_alert_prefs (user_id, email_enabled) values (auth.uid(), p_enabled)
    on conflict (user_id) do update set email_enabled = excluded.email_enabled, updated_at = now();
  end if;
  select email_enabled into v from public.admin_alert_prefs where user_id = auth.uid();
  return coalesce(v, true);
end $$;
revoke all on function public.zella_my_admin_alert_email(boolean) from public, anon;
grant execute on function public.zella_my_admin_alert_email(boolean) to authenticated;

do $$
declare d text;
begin
  if to_regprocedure('public.zella_claim_admin_alert_email(integer)') is null then return; end if;
  d := pg_get_functiondef('public.zella_claim_admin_alert_email(integer)'::regprocedure);
  if d not like '%admin_alert_prefs%' then
    d := replace(d, 'where p.is_active and u.email is not null',
      'where p.is_active and u.email is not null and not exists (select 1 from public.admin_alert_prefs ap where ap.user_id = p.user_id and not ap.email_enabled)');
    if d not like '%admin_alert_prefs%' then raise exception 'PATCH_FAILED_ADMIN_ALERT_PREFS'; end if;
    execute d;
  end if;
end $$;

-- 10. Fixed search_path for the offer helpers the security advisor listed ---------------------------------------

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname like 'zella\_%'
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
  end loop;
end $$;

-- 11. Security reporting for the admin Settings (server key only) ----------------------------------------------

-- Row level security coverage of public tables, and policies that let everyone read.
create or replace function public.zella_rls_coverage()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tables', count(*),
    'with_rls', count(*) filter (where c.relrowsecurity),
    'without_rls', coalesce(jsonb_agg(c.relname order by c.relname) filter (where not c.relrowsecurity), '[]'::jsonb),
    'with_business_id', count(*) filter (where exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'business_id' and not a.attisdropped)),
    'policies', (select count(*) from pg_policies where schemaname = 'public'),
    'checked_at', now())
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r';
$$;
revoke all on function public.zella_rls_coverage() from public, anon, authenticated;
grant execute on function public.zella_rls_coverage() to service_role;
do $$ begin
  if to_regprocedure('public.zella_tenant_leak_check()') is not null then grant execute on function public.zella_tenant_leak_check() to service_role; end if;
end $$;

-- 12. Profile picture -------------------------------------------------------------------------------------------

create or replace function public.zella_set_my_avatar(p_url text)
returns text language plpgsql security definer set search_path = public as $$
declare v_url text := nullif(trim(coalesce(p_url, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if v_url is not null and position('/storage/v1/object/public/brand-assets/user/' || auth.uid()::text || '/' in v_url) = 0 then raise exception 'BAD_AVATAR_URL'; end if;
  update public.profiles set avatar_url = v_url, updated_at = now() where id = auth.uid();
  if not found then insert into public.profiles (id, avatar_url) values (auth.uid(), v_url); end if;
  return v_url;
end $$;
revoke all on function public.zella_set_my_avatar(text) from public, anon;
grant execute on function public.zella_set_my_avatar(text) to authenticated;

create or replace function public.zella_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('first_name', p.first_name, 'last_name', p.last_name, 'phone', p.phone, 'avatar_url', p.avatar_url)
    from public.profiles p where p.id = auth.uid();
$$;
revoke all on function public.zella_my_profile() from public, anon;
grant execute on function public.zella_my_profile() to authenticated;
