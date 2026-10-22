-- Zella automation foundation (Phase 2). Safe to run more than once.
-- Adds only what was missing: a durable event inbox, workflow execution log,
-- dead letters, a consent ledger, message templates and industry defaults.
-- Existing queues (callbacks, reminders, follow-ups, notifications...) are reused.
-- Browsers can only READ these tables. All writes go through the functions below.

-- ---------------------------------------------------------------- helpers
create or replace function public.zella_redact(p text) returns text
language sql immutable set search_path = public as $$
  select left(regexp_replace(coalesce(p, ''), '[A-Za-z0-9_\-\.]{32,}', '[redacted]', 'g'), 500)
$$;

-- ---------------------------------------------------------- 1. event inbox
create table if not exists public.automation_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_type text not null check (event_type ~ '^[a-z_]+\.[a-z_]+$'),
  schema_version int not null default 1,
  source text not null check (source in ('database','vapi','telnyx','website','meta','email','calendar','staff','n8n','billing','system')),
  provider_event_id text,
  idempotency_key text not null check (length(idempotency_key) between 8 and 200),
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object' and pg_column_size(payload) < 65536),
  status text not null default 'received' check (status in ('received','processing','processed','failed','rejected')),
  attempts int not null default 0,
  next_attempt_at timestamptz,
  claimed_at timestamptz,
  error_category text,
  error_message text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint automation_events_dedupe unique (business_id, idempotency_key)
);
create index if not exists automation_events_queue on public.automation_events (next_attempt_at, received_at) where status in ('received','processing');
create index if not exists automation_events_biz on public.automation_events (business_id, received_at desc);
create index if not exists automation_events_corr on public.automation_events (correlation_id);

-- ------------------------------------------------------ 2. execution log
create table if not exists public.workflow_executions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,   -- null = platform workflow
  workflow_key text not null,
  workflow_version text,
  event_id uuid references public.automation_events(id) on delete set null,
  correlation_id uuid,
  status text not null default 'running' check (status in ('running','succeeded','failed','cancelled')),
  current_step text,
  steps jsonb not null default '[]'::jsonb,
  provider_refs jsonb not null default '{}'::jsonb,
  retry_count int not null default 0,
  error_category text,
  error_message text,
  needs_manual boolean not null default false,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists workflow_executions_biz on public.workflow_executions (business_id, started_at desc);
create index if not exists workflow_executions_open on public.workflow_executions (started_at) where status = 'running';

-- ------------------------------------------------------- 3. dead letters
create table if not exists public.automation_dead_letters (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,
  source_table text not null,
  source_id uuid not null,
  event_id uuid references public.automation_events(id) on delete set null,
  reason text not null,
  error_category text,
  status text not null default 'open' check (status in ('open','retried','dismissed')),
  created_at timestamptz not null default now(),
  resolved_by uuid,
  resolved_at timestamptz
);
create unique index if not exists automation_dead_letters_open on public.automation_dead_letters (source_table, source_id) where status = 'open';
create index if not exists automation_dead_letters_biz on public.automation_dead_letters (business_id, created_at desc);

-- ------------------------------------------------------ 4. consent ledger
-- Append-only: every opt-in and opt-out is a new row, never edited or deleted.
create table if not exists public.contact_consents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  phone_digits text,
  email_lower text,
  channel text not null check (channel in ('sms','call','email','whatsapp')),
  purpose text not null default 'marketing' check (purpose in ('transactional','marketing')),
  status text not null check (status in ('opted_in','opted_out')),
  source text not null check (source in ('inbound_sms_keyword','web_form','verbal_call','staff','import','email_link','system')),
  keyword text,
  evidence jsonb not null default '{}'::jsonb,
  recorded_by uuid,
  recorded_at timestamptz not null default now(),
  constraint contact_consents_identity check (customer_id is not null or phone_digits is not null or email_lower is not null)
);
create index if not exists contact_consents_customer on public.contact_consents (business_id, customer_id, channel, recorded_at desc);
create index if not exists contact_consents_phone on public.contact_consents (business_id, phone_digits, channel, recorded_at desc);
create index if not exists contact_consents_email on public.contact_consents (business_id, email_lower, channel, recorded_at desc);

-- ------------------------------------------------------- 5. templates
create table if not exists public.message_templates (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,   -- null = platform / industry default
  industry_id uuid references public.industries(id) on delete cascade,
  key text not null check (key ~ '^[a-z_]+$'),
  channel text not null check (channel in ('sms','email','whatsapp')),
  purpose text not null default 'transactional' check (purpose in ('transactional','marketing')),
  locale text not null default 'en-US',
  subject text,
  body text not null check (length(body) between 1 and 1600),
  version int not null default 1,
  status text not null default 'active' check (status in ('draft','active','archived')),
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists message_templates_one_active on public.message_templates
  (coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(industry_id, '00000000-0000-0000-0000-000000000000'::uuid), key, channel, locale)
  where status = 'active';

-- ----------------------------------------------- 6. industry automation defaults
create table if not exists public.industry_automation_defaults (
  industry_id uuid not null references public.industries(id) on delete cascade,
  trigger_type text not null,
  enabled boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  primary key (industry_id, trigger_type)
);

-- ------------------------------------------------------------ security
alter table public.automation_events enable row level security;
alter table public.workflow_executions enable row level security;
alter table public.automation_dead_letters enable row level security;
alter table public.contact_consents enable row level security;
alter table public.message_templates enable row level security;
alter table public.industry_automation_defaults enable row level security;

drop policy if exists "managers read events" on public.automation_events;
create policy "managers read events" on public.automation_events for select to authenticated using (public.zella_can_manage(business_id));
drop policy if exists "managers read executions" on public.workflow_executions;
create policy "managers read executions" on public.workflow_executions for select to authenticated using (business_id is not null and public.zella_can_manage(business_id));
drop policy if exists "managers read dead letters" on public.automation_dead_letters;
create policy "managers read dead letters" on public.automation_dead_letters for select to authenticated using (business_id is not null and public.zella_can_manage(business_id));
drop policy if exists "members read consents" on public.contact_consents;
create policy "members read consents" on public.contact_consents for select to authenticated using (public.zella_is_member(business_id));
drop policy if exists "members read templates" on public.message_templates;
create policy "members read templates" on public.message_templates for select to authenticated using (business_id is null or public.zella_is_member(business_id));
drop policy if exists "signed in read industry defaults" on public.industry_automation_defaults;
create policy "signed in read industry defaults" on public.industry_automation_defaults for select to authenticated using (true);

revoke all on public.automation_events, public.workflow_executions, public.automation_dead_letters,
  public.contact_consents, public.message_templates, public.industry_automation_defaults from anon, authenticated;
grant select on public.automation_events, public.workflow_executions, public.automation_dead_letters,
  public.contact_consents, public.message_templates, public.industry_automation_defaults to authenticated;
grant all on public.automation_events, public.workflow_executions, public.automation_dead_letters,
  public.contact_consents, public.message_templates, public.industry_automation_defaults to service_role;

-- ---------------------------------------------------------- event functions (service role only)
-- Store an event once. A repeat of the same idempotency key returns the first event and changes nothing.
create or replace function public.zella_ingest_event(
  p_business_id uuid, p_event_type text, p_source text, p_idempotency_key text,
  p_payload jsonb default '{}'::jsonb, p_provider_event_id text default null,
  p_correlation_id uuid default null, p_causation_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; b public.businesses;
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then raise exception 'INVALID_BUSINESS'; end if;
  if b.cancelled_at is not null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  insert into public.automation_events (business_id, event_type, source, idempotency_key, payload, provider_event_id, correlation_id, causation_id)
  values (p_business_id, p_event_type, p_source, p_idempotency_key, coalesce(p_payload, '{}'::jsonb), p_provider_event_id, coalesce(p_correlation_id, gen_random_uuid()), p_causation_id)
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.automation_events where business_id = p_business_id and idempotency_key = p_idempotency_key;
    return jsonb_build_object('id', v_id, 'duplicate', true);
  end if;
  return jsonb_build_object('id', v_id, 'duplicate', false);
end $$;

-- Take a batch of events to process. Events stuck "processing" for 10 minutes are taken again.
create or replace function public.zella_claim_events(p_limit int default 20)
returns setof public.automation_events
language plpgsql security definer set search_path = public as $$
begin
  return query
  with picked as (
    select id from public.automation_events
     where (status = 'received' and coalesce(next_attempt_at, now()) <= now())
        or (status = 'processing' and claimed_at < now() - interval '10 minutes')
     order by received_at
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 20), 100))
  )
  update public.automation_events e
     set status = 'processing', attempts = e.attempts + 1, claimed_at = now()
    from picked where e.id = picked.id
  returning e.*;
end $$;

-- Report the result. Temporary failures are retried with a growing delay (max 5 tries).
-- Permanent failures, or too many tries, go to the dead-letter list for a person to review.
create or replace function public.zella_complete_event(
  p_event_id uuid, p_ok boolean, p_error_category text default null, p_error text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare e public.automation_events; v_temp boolean;
begin
  select * into e from public.automation_events where id = p_event_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_ok then
    update public.automation_events set status = 'processed', processed_at = now(), error_category = null, error_message = null where id = e.id;
    return 'processed';
  end if;
  v_temp := coalesce(p_error_category, 'unknown_error') in ('rate_limited','temporary_network','provider_timeout','unknown_error');
  if v_temp and e.attempts < 5 then
    update public.automation_events
       set status = 'received', next_attempt_at = now() + make_interval(secs => least(3600, 30 * power(2, e.attempts)::int)),
           error_category = coalesce(p_error_category, 'unknown_error'), error_message = public.zella_redact(p_error)
     where id = e.id;
    return 'retry';
  end if;
  update public.automation_events
     set status = 'failed', processed_at = now(), error_category = coalesce(p_error_category, 'unknown_error'), error_message = public.zella_redact(p_error)
   where id = e.id;
  insert into public.automation_dead_letters (business_id, source_table, source_id, event_id, reason, error_category)
  values (e.business_id, 'automation_events', e.id, e.id, coalesce(public.zella_redact(p_error), 'Failed'), coalesce(p_error_category, 'unknown_error'))
  on conflict do nothing;
  return 'dead_letter';
end $$;

-- ------------------------------------------------------ execution log functions
create or replace function public.zella_start_execution(
  p_workflow_key text, p_business_id uuid default null, p_event_id uuid default null,
  p_workflow_version text default null, p_correlation_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_business_id is not null and not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  insert into public.workflow_executions (workflow_key, business_id, event_id, workflow_version, correlation_id)
  values (p_workflow_key, p_business_id, p_event_id, p_workflow_version, p_correlation_id)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.zella_finish_execution(
  p_execution_id uuid, p_ok boolean, p_step text default null, p_steps jsonb default null,
  p_provider_refs jsonb default null, p_error_category text default null, p_error text default null,
  p_needs_manual boolean default false
) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.workflow_executions
     set status = case when p_ok then 'succeeded' else 'failed' end,
         current_step = coalesce(p_step, current_step),
         steps = coalesce(p_steps, steps),
         provider_refs = coalesce(p_provider_refs, provider_refs),
         error_category = case when p_ok then null else coalesce(p_error_category, 'unknown_error') end,
         error_message = case when p_ok then null else public.zella_redact(p_error) end,
         needs_manual = case when p_ok then false else coalesce(p_needs_manual, false) end,
         finished_at = now()
   where id = p_execution_id and status = 'running';
  return found;
end $$;

-- Executions still "running" after the given minutes (n8n crashed or hung).
create or replace function public.zella_stuck_executions(p_minutes int default 15)
returns setof public.workflow_executions
language sql security definer set search_path = public as $$
  select * from public.workflow_executions where status = 'running' and started_at < now() - make_interval(mins => greatest(1, p_minutes));
$$;

-- ---------------------------------------------------------- dead letters (managers)
create or replace function public.zella_retry_dead_letter(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare d public.automation_dead_letters;
begin
  select * into d from public.automation_dead_letters where id = p_id for update;
  if not found or d.business_id is null or not public.zella_can_manage(d.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  if d.source_table <> 'automation_events' then raise exception 'MANUAL_ONLY'; end if;
  update public.automation_events set status = 'received', attempts = 0, next_attempt_at = null, error_category = null, error_message = null, processed_at = null where id = d.source_id;
  update public.automation_dead_letters set status = 'retried', resolved_by = auth.uid(), resolved_at = now() where id = d.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (d.business_id, auth.uid(), 'automation.dead_letter_retried', 'automation_event', d.source_id, jsonb_build_object('reason', d.reason), '{}'::jsonb);
  return true;
end $$;

create or replace function public.zella_dismiss_dead_letter(p_id uuid, p_note text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare d public.automation_dead_letters;
begin
  select * into d from public.automation_dead_letters where id = p_id for update;
  if not found or d.business_id is null or not public.zella_can_manage(d.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  update public.automation_dead_letters set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = d.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (d.business_id, auth.uid(), 'automation.dead_letter_dismissed', 'automation_event', d.source_id, jsonb_build_object('reason', d.reason), jsonb_build_object('note', left(p_note, 300)));
  return true;
end $$;

-- ------------------------------------------------------------ consent
-- Record an opt-in or opt-out. An opt-out also switches off the matching do-not flag on the customer.
-- Callable by the service (n8n, for STOP replies) or by staff of that business.
create or replace function public.zella_record_consent(
  p_business_id uuid, p_channel text, p_status text, p_source text,
  p_customer_id uuid default null, p_phone text default null, p_email text default null,
  p_purpose text default 'marketing', p_keyword text default null, p_evidence jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid; v_cust uuid := p_customer_id; v_digits text := public.zella_digits(p_phone);
begin
  if v_uid is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_uid is not null and p_source = 'inbound_sms_keyword' then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if v_cust is not null and not exists (select 1 from public.customers where id = v_cust and business_id = p_business_id) then raise exception 'TENANT_MISMATCH'; end if;
  if v_cust is null and v_digits is not null then
    select id into v_cust from public.customers where business_id = p_business_id and public.zella_digits(phone) = v_digits order by created_at limit 1;
  end if;
  if v_cust is null and p_email is not null then
    select id into v_cust from public.customers where business_id = p_business_id and lower(email) = lower(p_email) order by created_at limit 1;
  end if;
  insert into public.contact_consents (business_id, customer_id, phone_digits, email_lower, channel, purpose, status, source, keyword, evidence, recorded_by)
  values (p_business_id, v_cust, v_digits, nullif(lower(trim(coalesce(p_email, ''))), ''), p_channel, coalesce(p_purpose, 'marketing'), p_status, p_source, upper(left(p_keyword, 20)), coalesce(p_evidence, '{}'::jsonb), v_uid)
  returning id into v_id;
  if v_cust is not null and p_status = 'opted_out' then
    update public.customers set
      do_not_sms = do_not_sms or p_channel = 'sms',
      do_not_call = do_not_call or p_channel = 'call',
      do_not_email = do_not_email or p_channel = 'email',
      updated_at = now()
     where id = v_cust;
  elsif v_cust is not null and p_status = 'opted_in' and p_source in ('inbound_sms_keyword','email_link') then
    update public.customers set
      do_not_sms = do_not_sms and p_channel <> 'sms',
      do_not_email = do_not_email and p_channel <> 'email',
      updated_at = now()
     where id = v_cust;
  end if;
  return v_id;
end $$;

-- Read an inbound text and apply STOP / START / HELP rules. Service role only.
create or replace function public.zella_handle_inbound_sms_keyword(p_business_id uuid, p_from text, p_body text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text := upper(regexp_replace(trim(coalesce(p_body, '')), '[^A-Za-z]', '', 'g'));
begin
  if k in ('STOP','STOPALL','UNSUBSCRIBE','CANCEL','END','QUIT') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'marketing', k);
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_out', 'keyword', k);
  elsif k in ('START','UNSTOP','YES') and exists (
      select 1 from public.contact_consents where business_id = p_business_id and phone_digits = public.zella_digits(p_from) and channel = 'sms' and status = 'opted_out') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_in', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_in', 'keyword', k);
  elsif k = 'HELP' then
    return jsonb_build_object('action', 'help');
  end if;
  return jsonb_build_object('action', 'none');
end $$;

-- May we contact this person on this channel for this purpose? The newest record wins.
-- Marketing needs a recorded opt-in. Transactional is allowed unless they opted out or are marked do-not-contact.
create or replace function public.zella_can_contact(p_business_id uuid, p_customer_id uuid, p_channel text, p_purpose text default 'transactional')
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare c public.customers; v_latest text; v_digits text; v_mail text;
begin
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if not found then return false; end if;
  if c.do_not_contact then return false; end if;
  if p_channel = 'sms' and c.do_not_sms then return false; end if;
  if p_channel = 'call' and c.do_not_call then return false; end if;
  if p_channel = 'email' and c.do_not_email then return false; end if;
  v_digits := public.zella_digits(c.phone); v_mail := lower(c.email);
  select status into v_latest from public.contact_consents
   where business_id = p_business_id and channel = p_channel and purpose = p_purpose
     and (customer_id = c.id or (v_digits is not null and phone_digits = v_digits) or (v_mail is not null and email_lower = v_mail))
   order by recorded_at desc limit 1;
  if v_latest = 'opted_out' then return false; end if;
  if p_purpose = 'marketing' then return v_latest = 'opted_in'; end if;
  return true;
end $$;

-- ---------------------------------------------------------- templates
-- Best match wins: this business, then this industry, then the platform default.
create or replace function public.zella_resolve_template(p_business_id uuid, p_key text, p_channel text, p_locale text default 'en-US')
returns public.message_templates
language sql stable security definer set search_path = public as $$
  select t.* from public.message_templates t
   join public.businesses b on b.id = p_business_id
   where t.key = p_key and t.channel = p_channel and t.status = 'active' and t.locale = coalesce(p_locale, 'en-US')
     and (t.business_id = p_business_id or (t.business_id is null and (t.industry_id = b.industry_id or t.industry_id is null)))
   order by (t.business_id is not null) desc, (t.industry_id is not null) desc, t.version desc
   limit 1;
$$;

-- Save a new version of this business's own wording. The old version is archived, never deleted.
create or replace function public.zella_save_template(p_business_id uuid, p_key text, p_channel text, p_body text, p_subject text default null, p_locale text default 'en-US')
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_ver int; v_id uuid; v_purpose text;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_body ~* '\$[0-9]|[0-9]\s*(usd|dollars)' then raise exception 'NO_PRICES'; end if;
  select coalesce(max(version), 0) + 1 into v_ver from public.message_templates where business_id = p_business_id and key = p_key and channel = p_channel and locale = p_locale;
  select coalesce((select purpose from public.message_templates where key = p_key and channel = p_channel and business_id is null limit 1), 'transactional') into v_purpose;
  update public.message_templates set status = 'archived' where business_id = p_business_id and key = p_key and channel = p_channel and locale = p_locale and status = 'active';
  insert into public.message_templates (business_id, key, channel, purpose, locale, subject, body, version, created_by)
  values (p_business_id, p_key, p_channel, v_purpose, p_locale, p_subject, p_body, v_ver, auth.uid())
  returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'template.saved', 'message_template', v_id, '{}'::jsonb, jsonb_build_object('key', p_key, 'channel', p_channel, 'version', v_ver));
  return v_id;
end $$;

-- ---------------------------------------------------------- industry defaults
-- Create the starter automations a business of this industry should have.
-- Existing rows are never changed. Everything starts paused (or disabled) until the business goes live.
create or replace function public.zella_apply_industry_defaults(p_business_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare b public.businesses; d record; v_n int := 0; v_name text; v_desc text; v_actions jsonb; v_uid uuid := auth.uid();
begin
  if v_uid is not null and not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into b from public.businesses where id = p_business_id;
  if not found or b.cancelled_at is not null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  for d in select * from public.industry_automation_defaults where industry_id = b.industry_id loop
    if exists (select 1 from public.automations where business_id = p_business_id and trigger_type = d.trigger_type) then continue; end if;
    select name, descr, acts into v_name, v_desc, v_actions from (values
      ('appointment_reminder','Appointment reminders','Reminds customers before their appointment.','[{"type":"send_reminder"}]'::jsonb),
      ('appointment_confirmation','Appointment confirmation','Asks customers to confirm or check in for their appointment.','[{"type":"request_confirmation"}]'::jsonb),
      ('no_show_follow_up','No-show follow-up','Reaches out after a missed appointment to offer a new time.','[{"type":"follow_up"}]'::jsonb),
      ('missed_call_follow_up','Missed-call follow-up','Calls back or texts when a call is missed.','[{"type":"call_back"}]'::jsonb),
      ('new_lead_callback','New-lead callback','Contacts new leads quickly.','[{"type":"call_back"}]'::jsonb),
      ('post_appointment_follow_up','Post-appointment follow-up','Thanks the customer after their visit.','[{"type":"follow_up"}]'::jsonb),
      ('quote_follow_up','Quote follow-up','Follows up on quotes that have not been answered.','[{"type":"follow_up"}]'::jsonb),
      ('lead_reactivation','Lead reactivation','Reaches out to leads that went quiet.','[{"type":"follow_up"}]'::jsonb),
      ('waitlist_offer','Waitlist offers','Offers open slots to people on the waitlist.','[{"type":"offer_slot"}]'::jsonb),
      ('staff_unavailable','Staff unavailable','Contacts customers when a team member becomes unavailable.','[{"type":"rebook"}]'::jsonb)
    ) as t(kind, name, descr, acts) where kind = d.trigger_type;
    if v_name is null then continue; end if;
    insert into public.automations (business_id, name, description, trigger_type, status, trigger_config, actions, conditions, created_by)
    values (p_business_id, v_name, v_desc, d.trigger_type, case when d.enabled then 'paused' else 'disabled' end,
            public.zella_clean_automation_config(d.trigger_type, d.config), v_actions, '{}'::jsonb, v_uid);
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
    values (p_business_id, v_uid, 'automation.defaults_applied', 'business', p_business_id, '{}'::jsonb, jsonb_build_object('created', v_n));
  end if;
  return v_n;
end $$;

-- ---------------------------------------------------------- permissions on functions
revoke all on function public.zella_redact(text) from public, anon;
revoke all on function public.zella_ingest_event(uuid, text, text, text, jsonb, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.zella_claim_events(int) from public, anon, authenticated;
revoke all on function public.zella_complete_event(uuid, boolean, text, text) from public, anon, authenticated;
revoke all on function public.zella_start_execution(text, uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.zella_finish_execution(uuid, boolean, text, jsonb, jsonb, text, text, boolean) from public, anon, authenticated;
revoke all on function public.zella_stuck_executions(int) from public, anon, authenticated;
revoke all on function public.zella_handle_inbound_sms_keyword(uuid, text, text) from public, anon, authenticated;
revoke all on function public.zella_can_contact(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.zella_resolve_template(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.zella_retry_dead_letter(uuid) from public, anon;
revoke all on function public.zella_dismiss_dead_letter(uuid, text) from public, anon;
revoke all on function public.zella_record_consent(uuid, text, text, text, uuid, text, text, text, text, jsonb) from public, anon;
revoke all on function public.zella_save_template(uuid, text, text, text, text, text) from public, anon;
revoke all on function public.zella_apply_industry_defaults(uuid) from public, anon;

grant execute on function public.zella_redact(text) to authenticated, service_role;
grant execute on function public.zella_ingest_event(uuid, text, text, text, jsonb, text, uuid, uuid) to service_role;
grant execute on function public.zella_claim_events(int) to service_role;
grant execute on function public.zella_complete_event(uuid, boolean, text, text) to service_role;
grant execute on function public.zella_start_execution(text, uuid, uuid, text, uuid) to service_role;
grant execute on function public.zella_finish_execution(uuid, boolean, text, jsonb, jsonb, text, text, boolean) to service_role;
grant execute on function public.zella_stuck_executions(int) to service_role;
grant execute on function public.zella_handle_inbound_sms_keyword(uuid, text, text) to service_role;
grant execute on function public.zella_can_contact(uuid, uuid, text, text) to service_role;
grant execute on function public.zella_resolve_template(uuid, text, text, text) to service_role;
grant execute on function public.zella_retry_dead_letter(uuid) to authenticated, service_role;
grant execute on function public.zella_dismiss_dead_letter(uuid, text) to authenticated, service_role;
grant execute on function public.zella_record_consent(uuid, text, text, text, uuid, text, text, text, text, jsonb) to authenticated, service_role;
grant execute on function public.zella_save_template(uuid, text, text, text, text, text) to authenticated, service_role;
grant execute on function public.zella_apply_industry_defaults(uuid) to authenticated, service_role;

-- ---------------------------------------------------------- starter data (platform configuration, not customer data)
-- Plain wording. No prices. Every text tells the person how to opt out.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, body)
select null, null, v.key, 'sms', 'transactional', v.body
from (values
  ('appointment_confirmation', 'Hi {{first_name}}, your {{appointment}} with {{business}} is booked for {{date}} at {{time}}. Reply STOP to opt out.'),
  ('appointment_reminder', 'Hi {{first_name}}, a reminder of your {{appointment}} with {{business}} on {{date}} at {{time}}. Reply C to confirm or R to reschedule. Reply STOP to opt out.'),
  ('missed_call_follow_up', 'Hi, this is {{business}}. We missed your call. Reply here and we will get back to you. Reply STOP to opt out.'),
  ('no_show_follow_up', 'Hi {{first_name}}, we missed you at {{business}} today. Reply to book a new time. Reply STOP to opt out.'),
  ('callback_acknowledgement', 'Hi {{first_name}}, thanks for contacting {{business}}. A team member will call you back soon. Reply STOP to opt out.'),
  ('lead_acknowledgement', 'Hi {{first_name}}, thanks for getting in touch with {{business}}. We will be in contact shortly. Reply STOP to opt out.')
) as v(key, body)
where not exists (select 1 from public.message_templates t where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = 'sms' and t.status = 'active');

-- Which automations each industry starts with. Every value passes zella_clean_automation_config when applied.
with sets(slug, kinds) as (values
  ('dental',               array['appointment_reminder','appointment_confirmation','no_show_follow_up','missed_call_follow_up','new_lead_callback','waitlist_offer','post_appointment_follow_up']),
  ('healthcare',           array['appointment_reminder','appointment_confirmation','no_show_follow_up','missed_call_follow_up','new_lead_callback','waitlist_offer']),
  ('beauty-salon',         array['appointment_reminder','appointment_confirmation','no_show_follow_up','missed_call_follow_up','waitlist_offer','post_appointment_follow_up']),
  ('fitness',              array['appointment_reminder','no_show_follow_up','missed_call_follow_up','new_lead_callback','lead_reactivation','waitlist_offer']),
  ('legal',                array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up']),
  ('financial-services',   array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up']),
  ('professional-services',array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up','lead_reactivation']),
  ('education',            array['appointment_reminder','missed_call_follow_up','new_lead_callback','lead_reactivation']),
  ('automotive',           array['appointment_reminder','appointment_confirmation','missed_call_follow_up','new_lead_callback','quote_follow_up','post_appointment_follow_up']),
  ('plumbing',             array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up','post_appointment_follow_up','staff_unavailable']),
  ('hvac',                 array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up','post_appointment_follow_up','staff_unavailable']),
  ('electrical',           array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up','post_appointment_follow_up','staff_unavailable']),
  ('home-services',        array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up','post_appointment_follow_up','staff_unavailable']),
  ('real-estate',          array['appointment_reminder','missed_call_follow_up','new_lead_callback','lead_reactivation']),
  ('restaurant',           array['appointment_reminder','appointment_confirmation','missed_call_follow_up','waitlist_offer','post_appointment_follow_up']),
  ('hospitality',          array['appointment_reminder','appointment_confirmation','missed_call_follow_up','new_lead_callback','post_appointment_follow_up']),
  ('travel',               array['appointment_reminder','missed_call_follow_up','new_lead_callback','quote_follow_up','post_appointment_follow_up']),
  ('ecommerce',            array['missed_call_follow_up','new_lead_callback','lead_reactivation','post_appointment_follow_up']),
  ('other',                array['appointment_reminder','missed_call_follow_up','new_lead_callback'])
), cfg(kind, config) as (values
  ('appointment_reminder',      '{"hours_before":[24,2],"channel":"sms"}'::jsonb),
  ('appointment_confirmation',  '{"hours_before":24,"channel":"sms"}'::jsonb),
  ('no_show_follow_up',         '{"minutes_after":15,"channel":"sms"}'::jsonb),
  ('missed_call_follow_up',     '{"minutes_after":5,"max_attempts":2,"fallback_sms":true}'::jsonb),
  ('new_lead_callback',         '{"minutes_after":5,"max_attempts":2,"fallback_sms":true}'::jsonb),
  ('post_appointment_follow_up','{"hours_after":24,"channel":"sms"}'::jsonb),
  ('quote_follow_up',           '{"hours_after":48,"max_attempts":2,"channel":"sms"}'::jsonb),
  ('lead_reactivation',         '{"days_inactive":30,"channel":"sms"}'::jsonb),
  ('waitlist_offer',            '{"offers":3,"offer_minutes":30,"channel":"sms"}'::jsonb),
  ('staff_unavailable',         '{"channel":"sms"}'::jsonb)
)
insert into public.industry_automation_defaults (industry_id, trigger_type, enabled, config)
select i.id, k, true, cfg.config
from sets join public.industries i on i.slug = sets.slug
cross join lateral unnest(sets.kinds) as k
join cfg on cfg.kind = k
on conflict (industry_id, trigger_type) do nothing;
