-- Zella - email sender support. Safe to run more than once.
-- Adds: email dry-run switch, email preparation (consent + template + safe HTML), an outbound email log
-- with duplicate protection, and a reminder claim that can be limited to one channel.
-- Nothing here sends an email. Sending is done by the n8n "Zella - Email Sender" workflow.

-- 1. Platform switches. Stay off until an email provider is connected and a sender address is verified.
insert into public.platform_settings (key, value) values ('email_live', 'false'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('email_from_address', '""'::jsonb) on conflict (key) do nothing;

-- 2. Two extra email states (dry run, blocked) and one outbound row per dedupe key per business.
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.email_messages'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%queued%';
  if c is not null then execute format('alter table public.email_messages drop constraint %I', c); end if;
  alter table public.email_messages add constraint email_messages_status_check
    check (status in ('queued','sent','delivered','failed','received','dry_run','blocked'));
end $$;

create unique index if not exists email_messages_dedupe_idx
  on public.email_messages (business_id, (metadata ->> 'dedupe_key'))
  where metadata ->> 'dedupe_key' is not null;

-- 3. Starter email templates (appointment confirmation and reminder). A business can override them.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, v.key, 'email', 'transactional', 'en-US', v.subject, v.body, 1, 'active'
  from (values
    ('appointment_confirmation', 'Your {{appointment}} is booked for {{date}}',
     E'Hi {{first_name}},\n\nYour {{appointment}} with {{business}} is booked for {{date}} at {{time}}.\n\nIf you need to change it, please contact {{business}}.'),
    ('appointment_reminder', 'Reminder: {{appointment}} on {{date}} at {{time}}',
     E'Hi {{first_name}},\n\nThis is a reminder of your {{appointment}} with {{business}} on {{date}} at {{time}}.\n\nIf you can no longer make it, please let {{business}} know.')
  ) as v(key, subject, body)
 where not exists (
   select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = v.key and t.channel = 'email' and t.locale = 'en-US' and t.status = 'active');

-- 4. Prepare an email: consent, valid address, template, placeholders, safe HTML.
--    Returns what to send, or why not. Marketing email is refused until unsubscribe links exist.
create or replace function public.zella_prepare_email(
  p_business_id uuid, p_customer_id uuid, p_template_key text,
  p_vars jsonb default '{}'::jsonb, p_purpose text default 'transactional')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  b public.businesses; c public.customers; t public.message_templates;
  v_body text; v_subject text; v_to text; v_html text; kv record; v_val text;
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_purpose text := case when p_purpose = 'marketing' then 'marketing' else 'transactional' end;
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_business', 'live', v_live); end if;
  if b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'business_not_available', 'live', v_live);
  end if;
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_customer', 'live', v_live); end if;
  if v_purpose = 'marketing' then
    return jsonb_build_object('allowed', false, 'reason', 'marketing_email_not_ready', 'live', v_live);
  end if;
  if not public.zella_can_contact(p_business_id, p_customer_id, 'email', v_purpose) then
    return jsonb_build_object('allowed', false, 'reason', 'no_consent', 'live', v_live);
  end if;

  v_to := lower(trim(coalesce(c.email, '')));
  if v_to !~ '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' or length(v_to) > 254 then
    return jsonb_build_object('allowed', false, 'reason', 'no_valid_email', 'live', v_live);
  end if;

  select * into t from public.zella_resolve_template(p_business_id, p_template_key, 'email', 'en-US');
  if t.id is null then return jsonb_build_object('allowed', false, 'reason', 'no_template', 'live', v_live); end if;

  v_body := t.body;
  v_subject := coalesce(t.subject, '');
  -- Values go in with line breaks removed, so a customer name can never add email headers or extra paragraphs.
  v_val := coalesce(nullif(trim(regexp_replace(c.first_name, '[\r\n]+', ' ', 'g')), ''), 'there');
  v_body := replace(v_body, '{{first_name}}', v_val);     v_subject := replace(v_subject, '{{first_name}}', v_val);
  v_val := regexp_replace(b.name, '[\r\n]+', ' ', 'g');
  v_body := replace(v_body, '{{business}}', v_val);       v_subject := replace(v_subject, '{{business}}', v_val);
  for kv in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_val := left(regexp_replace(kv.value, '[\r\n]+', ' ', 'g'), 200);
    v_body := replace(v_body, '{{' || kv.key || '}}', v_val);
    v_subject := replace(v_subject, '{{' || kv.key || '}}', v_val);
  end loop;
  if v_body ~ '\{\{[^}]*\}\}' or v_subject ~ '\{\{[^}]*\}\}' then
    return jsonb_build_object('allowed', false, 'reason', 'unfilled_placeholder', 'live', v_live);
  end if;
  v_subject := left(trim(v_subject), 200);
  if v_subject = '' then return jsonb_build_object('allowed', false, 'reason', 'no_subject', 'live', v_live); end if;

  -- Plain text body is kept as written; the HTML copy has every special character escaped.
  v_html := replace(replace(replace(replace(replace(v_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
  v_html := '<p>' || replace(replace(v_html, E'\n\n', '</p><p>'), E'\n', '<br>') || '</p>';

  return jsonb_build_object('allowed', true, 'reason', null, 'live', v_live, 'to', v_to, 'from', v_from,
    'from_name', left(regexp_replace(b.name, '[\r\n"<>]+', ' ', 'g'), 80),
    'reply_to', nullif(lower(trim(coalesce(to_jsonb(b) ->> 'email', ''))), ''),
    'subject', v_subject, 'body_text', v_body, 'body_html', v_html,
    'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose);
end $$;

-- 5. Log an outbound email before sending. A repeat of the same dedupe key is not sent twice.
--    If the earlier try failed, the same key is allowed to try again.
create or replace function public.zella_log_outbound_email(
  p_business_id uuid, p_customer_id uuid, p_to text, p_from text, p_subject text,
  p_body_text text, p_body_html text, p_dedupe_key text, p_status text default 'queued', p_meta jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.email_messages;
begin
  if p_dedupe_key is null or length(p_dedupe_key) < 8 then raise exception 'INVALID_DEDUPE_KEY'; end if;
  if p_status not in ('queued', 'dry_run', 'blocked') then raise exception 'INVALID_STATUS'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then
    raise exception 'TENANT_MISMATCH';
  end if;
  insert into public.email_messages (business_id, customer_id, direction, status, from_email, to_email, subject, body_text, body_html, metadata)
  values (p_business_id, p_customer_id, 'outbound', p_status, nullif(p_from, ''), p_to, left(p_subject, 300), left(p_body_text, 20000), left(p_body_html, 40000),
          coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('dedupe_key', p_dedupe_key))
  on conflict (business_id, (metadata ->> 'dedupe_key')) where metadata ->> 'dedupe_key' is not null do nothing
  returning * into r;
  if r.id is not null then return jsonb_build_object('id', r.id, 'duplicate', false, 'status', r.status); end if;

  select * into r from public.email_messages where business_id = p_business_id and metadata ->> 'dedupe_key' = p_dedupe_key;
  if r.status = 'failed' and p_status = 'queued' then
    update public.email_messages set status = 'queued', updated_at = now() where id = r.id;
    return jsonb_build_object('id', r.id, 'duplicate', false, 'status', 'queued');
  end if;
  return jsonb_build_object('id', r.id, 'duplicate', true, 'status', r.status);
end $$;

-- 6. Record what happened after the send attempt.
create or replace function public.zella_update_outbound_email(
  p_id uuid, p_status text, p_external_id text default null, p_error text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('sent', 'failed') then raise exception 'INVALID_STATUS'; end if;
  update public.email_messages
     set status = p_status,
         external_message_id = coalesce(left(p_external_id, 200), external_message_id),
         sent_at = case when p_status = 'sent' then now() else sent_at end,
         metadata = case when p_error is null then metadata else metadata || jsonb_build_object('error', left(p_error, 300)) end,
         updated_at = now()
   where id = p_id and direction = 'outbound' and status in ('queued', 'failed');
  if not found then raise exception 'NOT_FOUND'; end if;
  return p_status;
end $$;

-- 7. Claim due reminders for ONE channel. The text sender keeps working unchanged because the
--    channel defaults to 'sms'; the email sender asks for 'email'. Same rules as before otherwise.
drop function if exists public.zella_claim_reminders(integer);
create or replace function public.zella_claim_reminders(p_limit integer default 25, p_channel text default 'sms')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res jsonb := '[]'::jsonb; r record; a record; c record; b record; v_staff text;
        v_channel text := case when p_channel = 'email' then 'email' else 'sms' end;
begin
  for r in select * from public.appointment_reminders where status = 'pending' and due_at <= now() and channel = v_channel order by due_at
           limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked loop
    select * into a from public.appointments where id = r.appointment_id;
    select * into c from public.customers where id = r.customer_id;
    select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = r.business_id;
    if a.id is null or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or (r.kind in ('reminder', 'confirmation_request') and a.start_time <= now()) then
      update public.appointment_reminders set status = 'skipped', error = 'appointment_no_longer_active' where id = r.id; continue;
    end if;
    if b.suspended_at is not null or b.cancelled_at is not null or c.id is null or coalesce(c.do_not_contact, false) or (public.zella_digits(c.phone) is null and nullif(trim(coalesce(c.email, '')), '') is null) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $$;

-- Only the service role (n8n) may call these.
do $$
declare f text;
begin
  foreach f in array array[
    'zella_prepare_email(uuid,uuid,text,jsonb,text)',
    'zella_log_outbound_email(uuid,uuid,text,text,text,text,text,text,text,jsonb)',
    'zella_update_outbound_email(uuid,text,text,text)',
    'zella_claim_reminders(integer,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
