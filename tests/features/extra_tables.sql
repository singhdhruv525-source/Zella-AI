-- Staging only: production tables and functions the features need that the voice-reliability copy (zvoice) lacks.
-- Copied from the production catalog on 2026-10-28 (message_templates columns/indexes; function bodies verbatim).
create table if not exists public.message_templates (
  id uuid primary key default gen_random_uuid(), business_id uuid, industry_id uuid, key text not null, channel text not null,
  purpose text not null default 'transactional', locale text not null default 'en-US', subject text, body text not null,
  version integer not null default 1, status text not null default 'active', created_by uuid, created_at timestamptz not null default now());
create unique index if not exists message_templates_one_active on public.message_templates (coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(industry_id, '00000000-0000-0000-0000-000000000000'::uuid), key, channel, locale) where status = 'active';

create table if not exists public.followup_tasks (
  id uuid primary key default gen_random_uuid(), business_id uuid not null, customer_id uuid, appointment_id uuid, call_id uuid,
  kind text not null, channel text not null default 'call' check (channel = any (array['call', 'sms', 'email'])), due_at timestamptz not null,
  status text not null default 'pending' check (status = any (array['pending', 'in_progress', 'done', 'failed', 'cancelled', 'skipped'])),
  attempts integer not null default 0, max_attempts integer not null default 2, outcome text, outcome_notes text, provider_call_id text,
  claimed_at timestamptz, completed_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  entity_ref uuid, vars jsonb not null default '{}'::jsonb);
create unique index if not exists followup_tasks_one_per_appointment_idx on public.followup_tasks (appointment_id, kind)
  where appointment_id is not null and status = any (array['pending', 'in_progress']);

CREATE OR REPLACE FUNCTION public.zella_can_contact(p_business_id uuid, p_customer_id uuid, p_channel text, p_purpose text DEFAULT 'transactional'::text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if p_purpose = 'marketing' then return coalesce(v_latest = 'opted_in', false); end if;
  return true;
end $function$
;

CREATE OR REPLACE FUNCTION public.zella_prepare_sms(p_business_id uuid, p_customer_id uuid, p_template_key text, p_vars jsonb DEFAULT '{}'::jsonb, p_purpose text DEFAULT 'transactional'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b public.businesses; c public.customers; t public.message_templates;
  v_body text; v_to text; v_digits text; v_raw text; kv record; v_hour int;
  v_live boolean := coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(public.zella_setting('sms_from_number', '""'::jsonb) #>> '{}', '');
  v_purpose text := case when p_purpose = 'marketing' then 'marketing' else 'transactional' end;
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_business', 'live', v_live); end if;
  if b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'business_not_available', 'live', v_live);
  end if;
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_customer', 'live', v_live); end if;
  if not public.zella_can_contact(p_business_id, p_customer_id, 'sms', v_purpose) then
    return jsonb_build_object('allowed', false, 'reason', 'no_consent', 'live', v_live);
  end if;

  v_raw := coalesce(c.phone, '');
  v_digits := regexp_replace(v_raw, '\D', '', 'g');
  if v_raw like '+%' and length(v_digits) between 8 and 15 then v_to := '+' || v_digits;
  elsif length(v_digits) = 10 then v_to := '+1' || v_digits;
  elsif length(v_digits) = 11 and left(v_digits, 1) = '1' then v_to := '+' || v_digits;
  end if;
  if v_to is null then return jsonb_build_object('allowed', false, 'reason', 'no_valid_phone', 'live', v_live); end if;

  if v_purpose = 'marketing' and coalesce(public.zella_setting('sms_marketing_allowed', 'false'::jsonb) = 'true'::jsonb, false) = false then
    return jsonb_build_object('allowed', false, 'reason', 'sms_marketing_off', 'live', v_live);
  end if;
  if v_purpose = 'marketing' then
    v_hour := extract(hour from (now() at time zone coalesce(b.timezone, 'America/New_York')));
    if v_hour < 8 or v_hour >= 21 then
      return jsonb_build_object('allowed', false, 'reason', 'quiet_hours', 'live', v_live);
    end if;
  end if;

  select * into t from public.zella_resolve_template(p_business_id, p_template_key, 'sms', 'en-US');
  if t.id is null then return jsonb_build_object('allowed', false, 'reason', 'no_template', 'live', v_live); end if;

  v_body := t.body;
  v_body := replace(v_body, '{{first_name}}', coalesce(nullif(trim(c.first_name), ''), 'there'));
  v_body := replace(v_body, '{{business}}', b.name);
  for kv in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_body := replace(v_body, '{{' || kv.key || '}}', left(kv.value, 200));
  end loop;
  if v_body ~ '\{\{[^}]*\}\}' then
    return jsonb_build_object('allowed', false, 'reason', 'unfilled_placeholder', 'live', v_live);
  end if;

  return jsonb_build_object('allowed', true, 'reason', null, 'live', v_live, 'to', v_to, 'from', v_from,
    'body', v_body, 'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose);
end $function$
;

CREATE OR REPLACE FUNCTION public.zella_resolve_template(p_business_id uuid, p_key text, p_channel text, p_locale text DEFAULT 'en-US'::text)
 RETURNS message_templates
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select t.* from public.message_templates t
   join public.businesses b on b.id = p_business_id
   where t.key = p_key and t.channel = p_channel and t.status = 'active' and t.locale = coalesce(p_locale, 'en-US')
     and (t.business_id = p_business_id or (t.business_id is null and (t.industry_id = b.industry_id or t.industry_id is null)))
   order by (t.business_id is not null) desc, (t.industry_id is not null) desc, t.version desc
   limit 1;
$function$
;

create table if not exists public.profiles (id uuid primary key, first_name text, last_name text, phone text, avatar_url text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), portal_id text);
