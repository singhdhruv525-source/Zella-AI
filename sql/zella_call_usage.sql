-- Zella - AI calling usage: ledger, processing, summaries, thresholds, reconciliation, entitlement interface (2026-10-28).
-- Safe to re-run. Needs sql/zella_settings_system.sql (subscriptions, plans, usage functions), sql/zella_voice_reliability.sql
-- (one call row per provider call, status and reconciliation), sql/zella_voice_assistant.sql. Then re-run sql/zella_dispatcher.sql
-- (adds the usage reconciliation to the every-15-minutes group). Changes and deletes no existing rows.
-- Design: docs/MINUTE_USAGE_DESIGN.md. Plan-agnostic: creates no plans, prices, allowances or charges.
--
--   usage_records (existing table, extended)  the ledger: one 'usage' row per AI call, 'adjustment' rows for later changes
--   usage_processing_issues                    what could not be processed yet (missing / invalid duration, failures, mismatches)
--   usage_thresholds                           admin-configured thresholds (empty: configured in a later phase)
--   usage_threshold_events                     each threshold reached, once per business, threshold and period
--   platform setting call_usage_policy         rounding policy (default: exact seconds, for testing)
--   platform setting call_usage_rules          which call categories count, per industry (default: all AI calls)
--
-- Duration source: calls.duration_seconds, written by zella_record_inbound_call from Vapi's end-of-call report
-- (durationSeconds when sent, otherwise endedAt - startedAt from Vapi's own timestamps) or by zella_reconcile_call from
-- Vapi GET /call. Never estimated: a call without a duration is listed as an issue and not counted.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Ledger
-- ---------------------------------------------------------------------------------------------------------------
alter table public.usage_records add column if not exists call_id uuid references public.calls (id) on delete set null;
alter table public.usage_records add column if not exists provider_call_id text;
alter table public.usage_records add column if not exists provider_event_id text;
alter table public.usage_records add column if not exists idempotency_key text;
alter table public.usage_records add column if not exists entry_kind text not null default 'usage';
alter table public.usage_records add column if not exists adjusts_record_id uuid references public.usage_records (id);
alter table public.usage_records add column if not exists usage_category text;
alter table public.usage_records add column if not exists occurred_at timestamptz;
alter table public.usage_records add column if not exists duration_seconds integer;
alter table public.usage_records add column if not exists billable_seconds integer;
alter table public.usage_records add column if not exists telephony_billed_seconds integer;
alter table public.usage_records add column if not exists included_minutes_consumed numeric(12, 4);
alter table public.usage_records add column if not exists policy jsonb;
alter table public.usage_records add column if not exists period_source text;
alter table public.usage_records add column if not exists status text not null default 'recorded';
alter table public.usage_records add column if not exists reconciliation_status text not null default 'ok';
alter table public.usage_records add column if not exists processed_by text;
alter table public.usage_records add column if not exists updated_at timestamptz not null default now();
do $$ begin
  alter table public.usage_records add constraint usage_records_entry_kind_check check (entry_kind in ('usage', 'adjustment', 'reversal'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.usage_records add constraint usage_records_status_check check (status in ('recorded', 'reversed'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.usage_records add constraint usage_records_reconciliation_check check (reconciliation_status in ('ok', 'adjusted', 'discrepancy'));
exception when duplicate_object then null; end $$;
do $$ begin
  -- an AI-call usage row says what it measured: the provider call, raw seconds, billable seconds under its policy.
  -- call_id may become null: the ledger outlives a deleted (e.g. erased) call
  alter table public.usage_records add constraint usage_records_ai_call_check check (usage_type <> 'ai_call'
    or (provider_call_id is not null and duration_seconds is not null and billable_seconds is not null and policy is not null));
exception when duplicate_object then null; end $$;
-- one usage row per call; one row per idempotency key; one row per provider event
create unique index if not exists usage_records_one_call_idx on public.usage_records (usage_type, call_id) where entry_kind = 'usage' and call_id is not null;
create unique index if not exists usage_records_idem_idx on public.usage_records (idempotency_key) where idempotency_key is not null;
create unique index if not exists usage_records_event_idx on public.usage_records (business_id, provider_event_id) where provider_event_id is not null;
create index if not exists usage_records_business_time_idx on public.usage_records (business_id, usage_type, occurred_at);
create index if not exists usage_records_call_idx on public.usage_records (call_id);

create table if not exists public.usage_processing_issues (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses (id) on delete cascade,
  call_id uuid references public.calls (id) on delete cascade,
  kind text not null check (kind in ('missing_duration', 'invalid_duration', 'processing_failed', 'duration_changed', 'summary_mismatch')),
  status text not null default 'open' check (status in ('open', 'escalated', 'resolved')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  detail jsonb not null default '{}'::jsonb,
  escalated_at timestamptz,
  resolved_at timestamptz,
  resolution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- one unresolved issue of a kind per call (or per business for business-level checks)
create unique index if not exists usage_issues_one_open_idx on public.usage_processing_issues
  (kind, coalesce(call_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status <> 'resolved';
create index if not exists usage_issues_due_idx on public.usage_processing_issues (status, next_attempt_at);

create table if not exists public.usage_thresholds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses (id) on delete cascade,     -- null: applies to every business
  measure text not null check (measure in ('percent_of_allowance', 'minutes_in_period')),
  value numeric(12, 2) not null check (value > 0),
  event_type text not null check (event_type in ('approaching', 'reached', 'allowance_limit')),
  enabled boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);
create table if not exists public.usage_threshold_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  threshold_key text not null,
  period_key text not null,
  event_type text not null,
  usage_minutes numeric(12, 4) not null,
  limit_minutes numeric(12, 4),
  notification_id uuid,
  created_at timestamptz not null default now(),
  unique (business_id, threshold_key, period_key)
);

alter table public.usage_processing_issues enable row level security;
alter table public.usage_thresholds enable row level security;
alter table public.usage_threshold_events enable row level security;
revoke all on public.usage_processing_issues, public.usage_thresholds, public.usage_threshold_events from anon, authenticated;
-- the existing "business members can view usage records" select policy stays; nobody but the service role writes
revoke insert, update, delete, truncate on public.usage_records from anon, authenticated;

insert into public.platform_settings (key, value) values
  ('call_usage_policy', '{"increment_seconds": 1, "rounding": "up", "minimum_billable_seconds": 0, "ignore_under_seconds": 0}'::jsonb),
  ('call_usage_rules', '{"counted_categories": ["inbound_ai", "outbound_ai"], "industries": {}}'::jsonb),
  ('call_usage_missing_duration_hours', '6'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Calculation
-- ---------------------------------------------------------------------------------------------------------------
-- billable seconds under a policy: increment (1 = exact seconds, 60 = whole minutes), rounding up / nearest / down,
-- a minimum for any counted call, and calls shorter than ignore_under_seconds not counted
create or replace function public.zella_usage_billable_seconds(p_seconds integer, p_policy jsonb) returns integer
language plpgsql immutable as $$
declare inc integer := greatest(1, least(3600, coalesce((p_policy ->> 'increment_seconds')::int, 1)));
        mode text := coalesce(p_policy ->> 'rounding', 'up');
        min_s integer := greatest(0, coalesce((p_policy ->> 'minimum_billable_seconds')::int, 0));
        ignore_s integer := greatest(0, coalesce((p_policy ->> 'ignore_under_seconds')::int, 0));
        v integer;
begin
  if p_seconds is null or p_seconds < 0 then return null; end if;
  if p_seconds = 0 or p_seconds < ignore_s then return 0; end if;
  v := case mode when 'down' then floor(p_seconds::numeric / inc) * inc when 'nearest' then round(p_seconds::numeric / inc) * inc
                 else ceil(p_seconds::numeric / inc) * inc end;
  return greatest(v, min_s);
end $$;

create or replace function public.zella_usage_policy() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p jsonb := coalesce(public.zella_setting('call_usage_policy', '{}'::jsonb), '{}'::jsonb);
begin
  if jsonb_typeof(p) <> 'object' or coalesce(p ->> 'rounding', 'up') not in ('up', 'nearest', 'down')
     or coalesce(p ->> 'increment_seconds', '1') !~ '^[0-9]{1,4}$' or coalesce(p ->> 'minimum_billable_seconds', '0') !~ '^[0-9]{1,4}$'
     or coalesce(p ->> 'ignore_under_seconds', '0') !~ '^[0-9]{1,4}$' then
    raise exception 'BAD_USAGE_POLICY';
  end if;
  return jsonb_build_object('increment_seconds', coalesce((p ->> 'increment_seconds')::int, 1), 'rounding', coalesce(p ->> 'rounding', 'up'),
                            'minimum_billable_seconds', coalesce((p ->> 'minimum_billable_seconds')::int, 0), 'ignore_under_seconds', coalesce((p ->> 'ignore_under_seconds')::int, 0));
end $$;

-- which kind of call this is, and whether that kind counts for this business's industry (explicit, recorded with the usage)
create or replace function public.zella_call_usage_category(p_call public.calls) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := coalesce(public.zella_setting('call_usage_rules', '{}'::jsonb), '{}'::jsonb); v_cat text; v_key text; v_list jsonb;
begin
  v_cat := case when not coalesce(p_call.ai_handled, false) then null
                when p_call.direction = 'inbound' then 'inbound_ai' when p_call.direction = 'outbound' then 'outbound_ai' else 'other_ai' end;
  if v_cat is null then return jsonb_build_object('category', null, 'counted', false, 'rule', 'not_ai_handled'); end if;
  v_key := public.zella_industry_key_for(p_call.business_id);
  v_list := coalesce(r #> array['industries', v_key, 'counted_categories'], r -> 'counted_categories', '["inbound_ai", "outbound_ai"]'::jsonb);
  return jsonb_build_object('category', v_cat, 'counted', v_list ? v_cat, 'industry', v_key,
                            'rule', case when r #> array['industries', v_key, 'counted_categories'] is not null then 'industry:' || v_key else 'default' end);
end $$;

-- the billing period a call falls in: the subscription's own period when it has one, otherwise only the call itself
-- (no calendar months, no invented renewal dates)
create or replace function public.zella_usage_period_for(p_business_id uuid, p_at timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions;
begin
  select * into s from public.subscriptions x where x.business_id = p_business_id and x.current_period_start is not null and x.current_period_end is not null
     and p_at >= x.current_period_start and p_at < x.current_period_end order by x.created_at desc limit 1;
  if s.id is not null then return jsonb_build_object('source', 'subscription', 'subscription_id', s.id, 'from', s.current_period_start, 'to', s.current_period_end); end if;
  return jsonb_build_object('source', 'call', 'subscription_id', null, 'from', p_at, 'to', p_at);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Processing one call (idempotent; the call row is locked, so concurrent runs for one call queue up)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_usage_open_issue(p_business_id uuid, p_call_id uuid, p_kind text, p_error text, p_detail jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.usage_processing_issues (business_id, call_id, kind, last_error, detail, attempts, next_attempt_at)
  values (p_business_id, p_call_id, p_kind, left(p_error, 300), coalesce(p_detail, '{}'::jsonb), 0, now() + interval '15 minutes')
  on conflict (kind, coalesce(call_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status <> 'resolved'
  do update set last_error = excluded.last_error, detail = excluded.detail, updated_at = now();
end $$;

create or replace function public.zella_process_call_usage(p_call_id uuid, p_source text default 'event', p_event_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.calls; v_cat jsonb; v_policy jsonb; v_bill integer; v_rec public.usage_records; v_period jsonb;
        v_current integer; v_delta integer; v_delta_bill integer; v_id uuid; v_at timestamptz; v_hours integer;
begin
  select * into c from public.calls where id = p_call_id for update;
  if c.id is null then return jsonb_build_object('result', 'not_found'); end if;
  if nullif(c.external_call_id, '') is null then return jsonb_build_object('result', 'no_provider_call_id'); end if;
  v_cat := public.zella_call_usage_category(c);
  if not (v_cat ->> 'counted')::boolean then return jsonb_build_object('result', 'not_counted', 'reason', v_cat ->> 'rule', 'category', v_cat ->> 'category'); end if;
  -- the call has to be over, with the report in (or reconciled), before its length is final
  if c.ended_at is null or coalesce(c.metadata ->> 'awaiting_report', 'false') = 'true' then return jsonb_build_object('result', 'pending'); end if;
  v_at := coalesce(c.started_at, c.answered_at, c.created_at);
  if c.duration_seconds is null then
    v_hours := coalesce((public.zella_setting('call_usage_missing_duration_hours', '6'::jsonb) #>> '{}')::int, 6);
    if c.ended_at < now() - make_interval(hours => v_hours) then
      perform public.zella_usage_open_issue(c.business_id, c.id, 'missing_duration', 'The provider has not reported a duration for this call.');
    end if;
    return jsonb_build_object('result', 'missing_duration');
  end if;
  if c.duration_seconds < 0 or c.duration_seconds > 86400 then
    perform public.zella_usage_open_issue(c.business_id, c.id, 'invalid_duration', 'Reported duration ' || c.duration_seconds || ' s is not plausible.');
    return jsonb_build_object('result', 'invalid_duration');
  end if;

  select * into v_rec from public.usage_records where usage_type = 'ai_call' and call_id = c.id and entry_kind = 'usage';
  if v_rec.id is null then
    v_policy := public.zella_usage_policy() || jsonb_build_object('category_rule', v_cat ->> 'rule', 'industry', v_cat ->> 'industry');
    v_bill := public.zella_usage_billable_seconds(c.duration_seconds, v_policy);
    v_period := public.zella_usage_period_for(c.business_id, v_at);
    insert into public.usage_records (business_id, subscription_id, usage_type, quantity, unit, period_start, period_end, source_id, metadata,
        call_id, provider_call_id, provider_event_id, idempotency_key, entry_kind, usage_category, occurred_at, duration_seconds, billable_seconds,
        policy, period_source, processed_by)
    values (c.business_id, (v_period ->> 'subscription_id')::uuid, 'ai_call', round(v_bill / 60.0, 4), 'minute', (v_period ->> 'from')::timestamptz,
        (v_period ->> 'to')::timestamptz, c.id, jsonb_build_object('ended_at_source', c.metadata ->> 'ended_at_source'),
        c.id, c.external_call_id, nullif(left(p_event_id, 200), ''), 'ai_call:' || c.external_call_id, 'usage', v_cat ->> 'category', v_at,
        c.duration_seconds, v_bill, v_policy, v_period ->> 'source', left(coalesce(p_source, 'event'), 40))
    on conflict do nothing
    returning id into v_id;
    update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'recorded', updated_at = now()
     where call_id = c.id and status <> 'resolved' and kind in ('missing_duration', 'invalid_duration', 'processing_failed');
    begin perform public.zella_evaluate_call_usage_thresholds(c.business_id); exception when others then null; end;
    return jsonb_build_object('result', case when v_id is null then 'unchanged' else 'recorded' end, 'usage_record_id', coalesce(v_id, (select id from public.usage_records where usage_type = 'ai_call' and call_id = c.id and entry_kind = 'usage')));
  end if;

  -- already recorded: a later, different provider duration becomes an adjustment (history kept), using the original policy
  select v_rec.duration_seconds + coalesce(sum(a.duration_seconds), 0) into v_current
    from public.usage_records a where a.adjusts_record_id = v_rec.id and a.entry_kind = 'adjustment';
  if v_current = c.duration_seconds then return jsonb_build_object('result', 'unchanged', 'usage_record_id', v_rec.id); end if;
  v_delta := c.duration_seconds - v_current;
  v_delta_bill := public.zella_usage_billable_seconds(c.duration_seconds, v_rec.policy)
                  - (v_rec.billable_seconds + coalesce((select sum(a.billable_seconds) from public.usage_records a where a.adjusts_record_id = v_rec.id and a.entry_kind = 'adjustment'), 0));
  insert into public.usage_records (business_id, subscription_id, usage_type, quantity, unit, period_start, period_end, source_id, metadata,
      call_id, provider_call_id, idempotency_key, entry_kind, adjusts_record_id, usage_category, occurred_at, duration_seconds, billable_seconds,
      policy, period_source, reconciliation_status, processed_by)
  values (v_rec.business_id, v_rec.subscription_id, 'ai_call', round(v_delta_bill / 60.0, 4), 'minute', v_rec.period_start, v_rec.period_end, c.id,
      jsonb_build_object('previous_seconds', v_current, 'new_seconds', c.duration_seconds, 'ended_at_source', c.metadata ->> 'ended_at_source'),
      c.id, c.external_call_id, 'ai_call:' || c.external_call_id || ':adj:' || v_current || '>' || c.duration_seconds, 'adjustment', v_rec.id,
      v_rec.usage_category, v_rec.occurred_at, v_delta, v_delta_bill, v_rec.policy, v_rec.period_source, 'adjusted', left(coalesce(p_source, 'event'), 40))
  on conflict do nothing returning id into v_id;
  update public.usage_records set reconciliation_status = 'adjusted', updated_at = now() where id = v_rec.id;
  update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'adjusted', updated_at = now()
   where call_id = c.id and status <> 'resolved' and kind in ('duration_changed', 'processing_failed');
  begin perform public.zella_evaluate_call_usage_thresholds(c.business_id); exception when others then null; end;
  return jsonb_build_object('result', 'adjusted', 'usage_record_id', v_rec.id, 'adjustment_id', v_id, 'delta_seconds', v_delta);
end $$;

-- every change to a call's end, duration or report state is offered to the ledger; a failure never breaks the call write
create or replace function public.zella_calls_usage_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_err text;
begin
  if new.ended_at is null or not coalesce(new.ai_handled, false) then return new; end if;
  if tg_op = 'UPDATE' and old.duration_seconds is not distinct from new.duration_seconds and old.ended_at is not distinct from new.ended_at
     and (old.metadata ->> 'awaiting_report') is not distinct from (new.metadata ->> 'awaiting_report') then return new; end if;
  begin
    perform public.zella_process_call_usage(new.id, 'call_update');
  exception when others then
    get stacked diagnostics v_err = message_text;
    begin perform public.zella_usage_open_issue(new.business_id, new.id, 'processing_failed', v_err); exception when others then null; end;
  end;
  return new;
end $$;
drop trigger if exists zella_calls_usage on public.calls;
create trigger zella_calls_usage after insert or update on public.calls for each row execute function public.zella_calls_usage_trg();

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Summaries (authoritative: computed from the ledger)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_call_usage_totals(p_business_id uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public as $$
  with r as (select * from public.usage_records u where u.business_id = p_business_id and u.usage_type = 'ai_call' and u.status = 'recorded'
                and u.occurred_at >= p_from and u.occurred_at < p_to)
  select jsonb_build_object(
    'calls', (select count(*) from r where entry_kind = 'usage'),
    'duration_seconds', coalesce((select sum(duration_seconds) from r), 0),
    'billable_seconds', coalesce((select sum(billable_seconds) from r), 0),
    'usage_minutes', coalesce((select round(sum(quantity), 4) from r), 0),
    'by_category', coalesce((select jsonb_object_agg(usage_category, jsonb_build_object('calls', n, 'minutes', m)) from
        (select usage_category, count(*) filter (where entry_kind = 'usage') n, round(sum(quantity), 4) m from r group by usage_category) x), '{}'::jsonb),
    'adjustments', jsonb_build_object('count', (select count(*) from r where entry_kind = 'adjustment'),
                                      'minutes', coalesce((select round(sum(quantity), 4) from r where entry_kind = 'adjustment'), 0)),
    'last_processed_at', (select max(created_at) from public.usage_records u where u.business_id = p_business_id and u.usage_type = 'ai_call'));
$$;

-- the allowance, only when a subscription and a plan say so; otherwise "not configured" (never zero, never exhausted)
create or replace function public.zella_call_allowance(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; v_limit numeric; v_used numeric; v_raw text;
begin
  s := public.zella_current_subscription(p_business_id);
  if s.id is null then return jsonb_build_object('configured', false, 'reason', 'no_active_subscription'); end if;
  if s.current_period_start is null or s.current_period_end is null then return jsonb_build_object('configured', false, 'reason', 'no_billing_period', 'subscription_id', s.id); end if;
  select p.limits ->> 'voice_minutes' into v_raw from public.plans p where p.id = s.plan_id;
  if v_raw is null or v_raw !~ '^[0-9]+(\.[0-9]+)?$' then return jsonb_build_object('configured', false, 'reason', 'no_minute_allowance_in_plan', 'subscription_id', s.id); end if;
  v_limit := v_raw::numeric;
  v_used := (public.zella_call_usage_totals(p_business_id, s.current_period_start, s.current_period_end) ->> 'usage_minutes')::numeric;
  return jsonb_build_object('configured', true, 'subscription_id', s.id, 'subscription_status', s.status, 'period_from', s.current_period_start, 'period_to', s.current_period_end,
    'included_minutes', v_limit, 'consumed_minutes', v_used, 'remaining_minutes', greatest(v_limit - v_used, 0),
    'percent_used', case when v_limit > 0 then round(v_used * 100 / v_limit, 1) end, 'exhausted', v_limit > 0 and v_used >= v_limit);
end $$;

-- for members of the business and platform admins with billing.view; with no range, the subscription's own period
create or replace function public.zella_call_usage_summary(p_business_id uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.subscriptions; v_from timestamptz := p_from; v_to timestamptz := p_to; v_src text := 'range';
begin
  -- a signed-in user must belong to the business (or be a billing admin); no user = the server (anon can't execute this)
  if auth.uid() is not null and not (public.zella_is_member(p_business_id) or public.zella_admin_can('billing.view')) then raise exception 'NOT_ALLOWED'; end if;
  if v_from is null or v_to is null then
    s := public.zella_current_subscription(p_business_id);
    if s.current_period_start is null or s.current_period_end is null then
      return jsonb_build_object('period', jsonb_build_object('available', false, 'reason', 'Choose a date range: no billing period is configured.'),
                                'allowance', public.zella_call_allowance(p_business_id));
    end if;
    v_from := s.current_period_start; v_to := s.current_period_end; v_src := 'subscription';
  end if;
  if v_to <= v_from or v_to - v_from > interval '400 days' then raise exception 'BAD_RANGE'; end if;
  return jsonb_build_object(
    'period', jsonb_build_object('available', true, 'source', v_src, 'from', v_from, 'to', v_to),
    'totals', public.zella_call_usage_totals(p_business_id, v_from, v_to),
    'pending', (select count(*) from public.calls c where c.business_id = p_business_id and c.ai_handled and coalesce(c.started_at, c.created_at) >= v_from
                  and coalesce(c.started_at, c.created_at) < v_to and not exists (select 1 from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id)),
    'issues', jsonb_build_object('open', (select count(*) from public.usage_processing_issues i where i.business_id = p_business_id and i.status = 'open'),
                                 'escalated', (select count(*) from public.usage_processing_issues i where i.business_id = p_business_id and i.status = 'escalated')),
    'allowance', public.zella_call_allowance(p_business_id));
end $$;

-- usage history, newest first; the caller's number is shown only as its last four digits
create or replace function public.zella_call_usage_records(p_business_id uuid, p_from timestamptz, p_to timestamptz, p_limit integer default 25, p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  -- a signed-in user must belong to the business (or be a billing admin); no user = the server (anon can't execute this)
  if auth.uid() is not null and not (public.zella_is_member(p_business_id) or public.zella_admin_can('billing.view')) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object('total', (select count(*) from public.usage_records u where u.business_id = p_business_id and u.usage_type = 'ai_call' and u.occurred_at >= p_from and u.occurred_at < p_to),
    'rows', coalesce((select jsonb_agg(x order by x ->> 'occurred_at' desc, x ->> 'created_at' desc) from (
      select jsonb_build_object('id', u.id, 'occurred_at', u.occurred_at, 'created_at', u.created_at, 'kind', u.entry_kind, 'category', u.usage_category,
               'duration_seconds', u.duration_seconds, 'billable_seconds', u.billable_seconds, 'minutes', u.quantity, 'status', u.status,
               'reconciliation', u.reconciliation_status, 'call_status', c.status, 'direction', c.direction,
               'caller', case when length(public.zella_digits(c.from_number)) >= 4 then '•••' || right(public.zella_digits(c.from_number), 4) end) x
        from public.usage_records u left join public.calls c on c.id = u.call_id
       where u.business_id = p_business_id and u.usage_type = 'ai_call' and u.occurred_at >= p_from and u.occurred_at < p_to
       order by u.occurred_at desc, u.created_at desc limit greatest(1, least(coalesce(p_limit, 25), 100)) offset greatest(0, coalesce(p_offset, 0))) y), '[]'::jsonb));
end $$;

-- the existing usage count (Billing > Usage, threshold notices) now reads AI minutes from the ledger
do $$
begin
  perform public.zella_patch_function('public.zella_usage_counts(uuid,timestamptz,timestamptz)', 'zella_usage_from_ledger',
    $a$'voice_minutes', coalesce((select round(sum(duration_seconds) / 60.0, 1) from public.calls
                                where business_id = p_business_id and ai_handled and created_at >= p_from and created_at < p_to), 0),$a$,
    $a$'voice_minutes', coalesce((select round(sum(u.quantity), 1) from public.usage_records u /* zella_usage_from_ledger */
                                where u.business_id = p_business_id and u.usage_type = 'ai_call' and u.status = 'recorded' and u.occurred_at >= p_from and u.occurred_at < p_to), 0),$a$);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Entitlement interface (prepared; NOT used for call admission yet)
-- ---------------------------------------------------------------------------------------------------------------
-- status: not_configured | active | exhausted | inactive | error. would_permit says what a future hard limit would
-- decide; enforced is false until call admission is deliberately wired to it. Not configured is not "unlimited".
create or replace function public.zella_call_entitlement_check(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a jsonb; s public.subscriptions; v_fallback text; v_status text;
begin
  select coalesce(u.fallback, 'take_message') into v_fallback from public.business_usage_preferences u where u.business_id = p_business_id;
  v_fallback := coalesce(v_fallback, 'take_message');
  begin
    if exists (select 1 from public.subscriptions x where x.business_id = p_business_id)
       and public.zella_current_subscription(p_business_id) is null then
      select * into s from public.subscriptions x where x.business_id = p_business_id order by x.created_at desc limit 1;
      return jsonb_build_object('status', 'inactive', 'would_permit', false, 'enforced', false, 'reason', 'subscription_' || s.status,
                                'fallback', v_fallback, 'note', 'Not enforced: calls are handled as before.');
    end if;
    a := public.zella_call_allowance(p_business_id);
    if not (a ->> 'configured')::boolean then
      return jsonb_build_object('status', 'not_configured', 'would_permit', null, 'enforced', false, 'reason', a ->> 'reason',
                                'note', 'No minute entitlement is configured. This is not unlimited; calls are handled as before until plans are set up.');
    end if;
    v_status := case when (a ->> 'exhausted')::boolean then 'exhausted' else 'active' end;
    return jsonb_build_object('status', v_status, 'would_permit', v_status = 'active', 'enforced', false,
                              'reason', case when v_status = 'exhausted' then 'allowance_used' else 'within_allowance' end,
                              'usage_minutes', a -> 'consumed_minutes', 'limit_minutes', a -> 'included_minutes', 'remaining_minutes', a -> 'remaining_minutes',
                              'fallback', case when v_status = 'exhausted' then v_fallback end);
  exception when others then
    return jsonb_build_object('status', 'error', 'would_permit', null, 'enforced', false, 'reason', 'usage_data_unavailable',
                              'note', 'Temporary error: calls are handled as before.');
  end;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Thresholds (one event per business, threshold and period; in-app notice; email/SMS by the existing delivery)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_evaluate_call_usage_thresholds(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare a jsonb; v_used numeric; v_limit numeric; v_period text; t record; n integer := 0; v_key text; v_hit boolean; v_ev uuid; v_note uuid;
        v_legacy integer[];
begin
  a := public.zella_call_allowance(p_business_id);
  if not (a ->> 'configured')::boolean then return 0; end if;     -- nothing to measure against: no events, no notices
  v_used := (a ->> 'consumed_minutes')::numeric; v_limit := (a ->> 'included_minutes')::numeric;
  v_period := a ->> 'period_from';
  select coalesce(u.notify_thresholds, '{70,90,100}') into v_legacy from public.business_usage_preferences u where u.business_id = p_business_id;
  v_legacy := coalesce(v_legacy, '{70,90,100}');
  for t in
    select 'pct:' || x::text as key, 'percent_of_allowance' as measure, x::numeric as value,
           case when x >= 100 then 'allowance_limit' when x >= 90 then 'reached' else 'approaching' end as event_type
      from unnest(v_legacy) x
    union all
    select 'th:' || h.id::text, h.measure, h.value, h.event_type from public.usage_thresholds h
     where h.enabled and (h.business_id is null or h.business_id = p_business_id)
    order by 3 desc
  loop
    v_hit := case t.measure when 'percent_of_allowance' then v_limit > 0 and v_used * 100 / v_limit >= t.value else v_used >= t.value end;
    continue when not v_hit;
    v_key := v_period || ':' || t.key;
    -- a threshold already notified under the old key (business_usage_preferences.notified) is not notified again
    continue when t.key like 'pct:%' and exists (select 1 from public.business_usage_preferences u where u.business_id = p_business_id and u.notified ? (v_period || ':' || t.value::int));
    insert into public.usage_threshold_events (business_id, threshold_key, period_key, event_type, usage_minutes, limit_minutes)
    values (p_business_id, t.key, v_period, t.event_type, v_used, v_limit) on conflict do nothing returning id into v_ev;
    continue when v_ev is null;
    perform public.zella_notify_owners(p_business_id, 'usage_threshold',
      case when t.event_type = 'allowance_limit' then 'Your included AI minutes are used up'
           when t.measure = 'percent_of_allowance' then 'You have used ' || t.value::int || '% of your AI minutes'
           else 'AI calling has reached ' || t.value || ' minutes this period' end,
      round(v_used) || ' of ' || round(v_limit) || ' minutes this period. Open Settings > Billing > Calling usage.',
      case when t.event_type = 'allowance_limit' then 'urgent' else 'warning' end, 'settings');
    select id into v_note from public.staff_notifications where business_id = p_business_id and kind = 'usage_threshold' order by created_at desc limit 1;
    update public.usage_threshold_events set notification_id = v_note where id = v_ev;
    if t.key like 'pct:%' then
      insert into public.business_usage_preferences (business_id, notified) values (p_business_id, jsonb_build_object(v_period || ':' || t.value::int, now()))
      on conflict (business_id) do update set notified = public.business_usage_preferences.notified || jsonb_build_object(v_period || ':' || t.value::int, now());
    end if;
    n := n + 1;
    exit when t.measure = 'percent_of_allowance';   -- the highest percentage reached is enough; lower ones are implied
  end loop;
  return n;
end $$;

-- the existing hourly job keeps its name and schedule and now evaluates from the ledger
create or replace function public.zella_check_usage_thresholds() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select b.id from public.businesses b where b.suspended_at is null and b.cancelled_at is null loop
    begin n := n + public.zella_evaluate_call_usage_thresholds(r.id); exception when others then null; end;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. Reconciliation (every 15 minutes through the dispatcher's scheduled jobs; also callable by an admin)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_reconcile_call_usage(p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v jsonb; n_new integer := 0; n_adj integer := 0; n_retry integer := 0; n_esc integer := 0; n_missing integer := 0; n_mismatch integer := 0;
        v_lim integer := greatest(1, least(coalesce(p_limit, 200), 1000));
begin
  -- a. ended AI calls with no usage yet, and recorded calls whose provider duration changed since
  for r in select c.id from public.calls c
            where c.ai_handled and c.ended_at is not null and c.ended_at < now() - interval '10 minutes' and coalesce(c.metadata ->> 'awaiting_report', 'false') <> 'true'
              and (not exists (select 1 from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id and u.entry_kind = 'usage')
                   or c.duration_seconds is distinct from (select sum(u.duration_seconds)::int from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id))
              and not exists (select 1 from public.usage_processing_issues i where i.call_id = c.id and i.status = 'escalated')
            order by c.ended_at limit v_lim loop
    begin
      v := public.zella_process_call_usage(r.id, 'reconcile');
      if v ->> 'result' = 'recorded' then n_new := n_new + 1; elsif v ->> 'result' = 'adjusted' then n_adj := n_adj + 1;
      elsif v ->> 'result' = 'missing_duration' then n_missing := n_missing + 1; end if;
    exception when others then
      perform public.zella_usage_open_issue((select business_id from public.calls where id = r.id), r.id, 'processing_failed', sqlerrm);
    end;
  end loop;
  -- b. failed processing: retried with a growing wait, at most 5 times, then escalated once
  for r in select * from public.usage_processing_issues i where i.status = 'open' and i.kind = 'processing_failed' and i.next_attempt_at <= now()
            order by i.next_attempt_at limit v_lim for update skip locked loop
    if r.attempts >= 5 then
      update public.usage_processing_issues set status = 'escalated', escalated_at = now(), updated_at = now() where id = r.id;
      perform public.zella_platform_alert('usage_processing_failed', 'Calling usage could not be recorded', 'A call''s usage failed 5 times: ' || left(coalesce(r.last_error, ''), 200),
                                          'warning', r.business_id, 'usage-failed:' || to_char(now(), 'YYYY-MM-DD'));
      n_esc := n_esc + 1; continue;
    end if;
    update public.usage_processing_issues set attempts = attempts + 1, next_attempt_at = now() + make_interval(mins => 15 * power(2, r.attempts)::int), updated_at = now() where id = r.id;
    begin
      v := public.zella_process_call_usage(r.call_id, 'retry');
      n_retry := n_retry + 1;
    exception when others then
      update public.usage_processing_issues set last_error = left(sqlerrm, 300) where id = r.id;
    end;
  end loop;
  -- c. calls the provider never sent a duration for: listed (not estimated), escalated once after a day
  for r in select i.* from public.usage_processing_issues i where i.status = 'open' and i.kind in ('missing_duration', 'invalid_duration') and i.created_at < now() - interval '24 hours' loop
    update public.usage_processing_issues set status = 'escalated', escalated_at = now(), updated_at = now() where id = r.id;
    perform public.zella_platform_alert('usage_missing_duration', 'Calls without a provider duration', 'At least one call has had no usable duration for a day and is not counted.',
                                        'warning', r.business_id, 'usage-duration:' || to_char(now(), 'YYYY-MM-DD'));
    n_esc := n_esc + 1;
  end loop;
  -- d. ledger vs calls over the last 35 days, per business (one open issue per business until it matches again)
  for r in select c.business_id, sum(c.duration_seconds) as call_secs,
                  (select coalesce(sum(u.duration_seconds), 0) from public.usage_records u where u.business_id = c.business_id and u.usage_type = 'ai_call' and u.status = 'recorded'
                     and u.call_id in (select c2.id from public.calls c2 where c2.business_id = c.business_id and c2.ai_handled and c2.ended_at >= now() - interval '35 days' and c2.ended_at < now() - interval '1 hour')) as ledger_secs
             from public.calls c
            where c.ai_handled and c.ended_at >= now() - interval '35 days' and c.ended_at < now() - interval '1 hour' and c.duration_seconds is not null
              and (public.zella_call_usage_category(c) ->> 'counted')::boolean
            group by c.business_id loop
    if r.call_secs is distinct from r.ledger_secs then
      perform public.zella_usage_open_issue(r.business_id, null, 'summary_mismatch', 'Calls total ' || r.call_secs || ' s, ledger ' || r.ledger_secs || ' s (last 35 days).',
                                            jsonb_build_object('call_seconds', r.call_secs, 'ledger_seconds', r.ledger_secs));
      n_mismatch := n_mismatch + 1;
    else
      update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'matches', updated_at = now()
       where business_id = r.business_id and call_id is null and kind = 'summary_mismatch' and status <> 'resolved';
    end if;
  end loop;
  return jsonb_build_object('recorded', n_new, 'adjusted', n_adj, 'retried', n_retry, 'escalated', n_esc, 'missing_duration', n_missing, 'mismatches', n_mismatch);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 8. Admin tools (billing.view to read, billing.manage to retry; every retry is audited)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function public.zella_admin_call_usage(p_business_id uuid default null, p_from timestamptz default null, p_to timestamptz default null,
    p_limit integer default 50, p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now() + interval '1 day');
begin
  if not public.zella_admin_can('billing.view') then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'records', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('id', u.id, 'business_id', u.business_id, 'business', b.name, 'occurred_at', u.occurred_at, 'kind', u.entry_kind,
                 'category', u.usage_category, 'duration_seconds', u.duration_seconds, 'billable_seconds', u.billable_seconds, 'minutes', u.quantity,
                 'provider_call_id', u.provider_call_id, 'reconciliation', u.reconciliation_status, 'processed_by', u.processed_by, 'created_at', u.created_at) x
          from public.usage_records u join public.businesses b on b.id = u.business_id
         where u.usage_type = 'ai_call' and (p_business_id is null or u.business_id = p_business_id) and u.occurred_at >= v_from and u.occurred_at < v_to
         order by u.occurred_at desc limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(0, coalesce(p_offset, 0))) y), '[]'::jsonb),
    'issues', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'business_id', i.business_id, 'business', b.name, 'call_id', i.call_id, 'kind', i.kind,
                 'status', i.status, 'attempts', i.attempts, 'last_error', i.last_error, 'detail', i.detail, 'created_at', i.created_at, 'next_attempt_at', i.next_attempt_at)
               order by i.created_at desc)
          from public.usage_processing_issues i left join public.businesses b on b.id = i.business_id
         where i.status <> 'resolved' and (p_business_id is null or i.business_id = p_business_id)), '[]'::jsonb),
    'threshold_events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'business_id', e.business_id, 'business', b.name, 'threshold', e.threshold_key,
                 'period', e.period_key, 'event_type', e.event_type, 'usage_minutes', e.usage_minutes, 'limit_minutes', e.limit_minutes, 'created_at', e.created_at,
                 'delivery_status', n.delivery_status, 'delivery_error', n.delivery_error) order by e.created_at desc)
          from public.usage_threshold_events e join public.businesses b on b.id = e.business_id left join public.staff_notifications n on n.id = e.notification_id
         where (p_business_id is null or e.business_id = p_business_id) and e.created_at >= v_from), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action, 'business_id', a.business_id, 'user_id', a.user_id, 'detail', a.new_data) order by a.created_at desc)
          from (select * from public.audit_logs where action like 'billing.usage%' and (p_business_id is null or business_id = p_business_id) order by created_at desc limit 50) a), '[]'::jsonb),
    'policy', public.zella_usage_policy(),
    'can_retry', public.zella_admin_can('billing.manage'));
end $$;

create or replace function public.zella_admin_retry_usage(p_issue_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i public.usage_processing_issues; v jsonb;
begin
  if auth.uid() is null or not public.zella_admin_can('billing.manage') then raise exception 'NOT_ALLOWED'; end if;
  select * into i from public.usage_processing_issues where id = p_issue_id for update;
  if i.id is null then raise exception 'NOT_FOUND'; end if;
  if i.status = 'resolved' then raise exception 'ALREADY_RESOLVED'; end if;
  if i.call_id is null then
    v := public.zella_reconcile_call_usage(200);
  else
    update public.usage_processing_issues set status = 'open', attempts = 0, next_attempt_at = now(), updated_at = now() where id = i.id;
    v := public.zella_process_call_usage(i.call_id, 'admin_retry');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (i.business_id, auth.uid(), 'billing.usage_retry', 'usage_processing_issue', i.id, to_jsonb(i), v);
  return v;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 9. Permissions
-- ---------------------------------------------------------------------------------------------------------------
revoke all on function public.zella_usage_billable_seconds(integer, jsonb), public.zella_usage_policy(), public.zella_call_usage_category(public.calls),
  public.zella_usage_period_for(uuid, timestamptz), public.zella_usage_open_issue(uuid, uuid, text, text, jsonb), public.zella_process_call_usage(uuid, text, text),
  public.zella_calls_usage_trg(), public.zella_call_usage_totals(uuid, timestamptz, timestamptz), public.zella_call_allowance(uuid),
  public.zella_call_entitlement_check(uuid), public.zella_evaluate_call_usage_thresholds(uuid), public.zella_reconcile_call_usage(integer) from public, anon, authenticated;
grant execute on function public.zella_usage_billable_seconds(integer, jsonb), public.zella_usage_policy(), public.zella_process_call_usage(uuid, text, text),
  public.zella_call_usage_totals(uuid, timestamptz, timestamptz), public.zella_call_allowance(uuid), public.zella_call_entitlement_check(uuid),
  public.zella_evaluate_call_usage_thresholds(uuid), public.zella_reconcile_call_usage(integer) to service_role;
revoke all on function public.zella_call_usage_summary(uuid, timestamptz, timestamptz), public.zella_call_usage_records(uuid, timestamptz, timestamptz, integer, integer),
  public.zella_admin_call_usage(uuid, timestamptz, timestamptz, integer, integer), public.zella_admin_retry_usage(uuid) from public, anon;
grant execute on function public.zella_call_usage_summary(uuid, timestamptz, timestamptz), public.zella_call_usage_records(uuid, timestamptz, timestamptz, integer, integer),
  public.zella_admin_call_usage(uuid, timestamptz, timestamptz, integer, integer), public.zella_admin_retry_usage(uuid) to authenticated, service_role;
revoke all on function public.zella_check_usage_thresholds() from public, anon, authenticated;
grant execute on function public.zella_check_usage_thresholds() to service_role;

create or replace function public.zella_call_usage_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ledger_columns', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'usage_records' and column_name = 'billable_seconds'),
    'one_usage_per_call', to_regclass('public.usage_records_one_call_idx') is not null,
    'calls_trigger', exists (select 1 from pg_trigger where tgname = 'zella_calls_usage'),
    'usage_counts_from_ledger', pg_get_functiondef('public.zella_usage_counts(uuid,timestamptz,timestamptz)'::regprocedure) like '%zella_usage_from_ledger%',
    'thresholds_from_ledger', pg_get_functiondef('public.zella_check_usage_thresholds()'::regprocedure) like '%zella_evaluate_call_usage_thresholds%',
    'policy_valid', (select public.zella_usage_policy() is not null));
$$;
revoke all on function public.zella_call_usage_status() from public, anon, authenticated;
grant execute on function public.zella_call_usage_status() to service_role;
