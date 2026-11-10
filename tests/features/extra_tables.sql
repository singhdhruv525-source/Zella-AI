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

create table if not exists public.provider_health (provider text primary key, ok boolean, detail text, checked_at timestamptz, claimed_at timestamptz,
  consecutive_failures integer not null default 0, last_ok_at timestamptz);
create table if not exists public.platform_incidents (id uuid primary key default gen_random_uuid(), title text not null, detail text,
  status text not null default 'open' check (status = any (array['open', 'resolved'])), notified_businesses integer not null default 0, created_by uuid,
  resolution_note text, created_at timestamptz not null default now(), resolved_at timestamptz);
create table if not exists public.n8n_dispatch_state (workflow text primary key, last_triggered_at timestamptz, last_count integer not null default 0,
  consecutive_same integer not null default 0, triggers_total bigint not null default 0);

CREATE OR REPLACE FUNCTION public.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.platform_admins AS pa
        WHERE pa.user_id = (SELECT auth.uid())
          AND pa.is_active = true
          AND pa.role IN ('zella_owner', 'super_admin')
    );
$function$
;
CREATE OR REPLACE FUNCTION public.zella_provider_checks_live()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(public.zella_setting('provider_checks_live', 'false'::jsonb) = 'true'::jsonb, false);
$function$
;
CREATE OR REPLACE FUNCTION public.zella_resolve_platform_alerts(p_kind text, p_business_id uuid, p_dedupe_key text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = left(p_note, 300)
   where kind = p_kind and business_id is not distinct from p_business_id and status <> 'resolved' and (p_dedupe_key is null or dedupe_key = p_dedupe_key);
  get diagnostics n = row_count; return n;
end $function$
;

-- production's zella_mark_staff_sms (sql/zella_notify_via.sql), body verbatim, and its trigger
create or replace function public.zella_mark_staff_sms() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_via text := coalesce(nullif(current_setting('zella.notify_via', true), ''), 'both'); v_ok boolean;
begin
  select exists (select 1 from public.business_members m where m.business_id = new.business_id and m.status = 'active' and m.sms_alerts
                  and (new.user_id is null and m.role in ('owner', 'admin') or m.user_id = new.user_id)) into v_ok;
  if v_via = 'sms' then
    if v_ok then new.sms_status := 'pending'; new.delivery_status := 'skipped'; end if;
  elsif v_via = 'email' then
    new.sms_status := null;
  elsif new.severity = 'urgent' and v_ok then
    new.sms_status := 'pending';
  end if;
  return new;
end $$;
drop trigger if exists zella_mark_staff_sms_trg on public.staff_notifications;
create trigger zella_mark_staff_sms_trg before insert on public.staff_notifications for each row execute function public.zella_mark_staff_sms();

-- production's zella_save_my_profile (sql/zella_business_settings.sql), verbatim
CREATE OR REPLACE FUNCTION public.zella_save_my_profile(p_first_name text, p_last_name text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_first text := nullif(left(trim(coalesce(p_first_name, '')), 100), '');
  v_last text := nullif(left(trim(coalesce(p_last_name, '')), 100), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '[\s()-]', '', 'g'), '');
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'BAD_PHONE'; end if;
  update public.profiles set first_name = v_first, last_name = v_last, phone = v_phone where id = auth.uid();
  if not found then
    insert into public.profiles (id, first_name, last_name, phone) values (auth.uid(), v_first, v_last, v_phone);
  end if;
  -- Text alerts need a number; switch them off everywhere if it was removed.
  if v_phone is null then update public.business_members set sms_alerts = false where user_id = auth.uid() and sms_alerts; end if;
  return jsonb_build_object('first_name', v_first, 'last_name', v_last, 'phone', v_phone);
end $function$
;
