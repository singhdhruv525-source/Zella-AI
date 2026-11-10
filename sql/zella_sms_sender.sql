-- Zella - text sender support (item 14). Safe to run more than once.
-- Adds: dry-run switch, message preparation (consent + template), outbound message log with
-- duplicate protection, and a way to skip a reminder without retrying it.
-- Nothing here sends a text. Sending is done by the n8n "Zella - SMS Sender" workflow.

-- 1. Platform switch. Stays false until Telnyx is connected and a business is ready.
insert into public.platform_settings (key, value) values ('sms_live', 'false'::jsonb)
  on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('sms_from_number', '""'::jsonb)
  on conflict (key) do nothing;

-- 2. Allow the two extra message states used by the sender.
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.sms_messages'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%queued%';
  if c is not null then execute format('alter table public.sms_messages drop constraint %I', c); end if;
  alter table public.sms_messages add constraint sms_messages_status_check
    check (status in ('queued','sent','delivered','failed','received','dry_run','blocked'));
end $$;

-- One outbound row per dedupe key per business (stops double texts).
create unique index if not exists sms_messages_dedupe_idx
  on public.sms_messages (business_id, (metadata ->> 'dedupe_key'))
  where metadata ->> 'dedupe_key' is not null;

-- 3. Prepare a text: consent, valid number, template, placeholders. Returns what to send, or why not.
create or replace function public.zella_prepare_sms(
  p_business_id uuid, p_customer_id uuid, p_template_key text,
  p_vars jsonb default '{}'::jsonb, p_purpose text default 'transactional')
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- 4. Log an outbound text before sending. A repeat of the same dedupe key is not sent twice.
--    If the earlier try failed, the same key is allowed to try again.
create or replace function public.zella_log_outbound_sms(
  p_business_id uuid, p_customer_id uuid, p_to text, p_from text, p_body text,
  p_dedupe_key text, p_status text default 'queued', p_meta jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.sms_messages;
begin
  if p_dedupe_key is null or length(p_dedupe_key) < 8 then raise exception 'INVALID_DEDUPE_KEY'; end if;
  if p_status not in ('queued', 'dry_run', 'blocked') then raise exception 'INVALID_STATUS'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then
    raise exception 'TENANT_MISMATCH';
  end if;
  insert into public.sms_messages (business_id, customer_id, direction, status, from_number, to_number, message_body, metadata)
  values (p_business_id, p_customer_id, 'outbound', p_status, nullif(p_from, ''), p_to, left(p_body, 1600),
          coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('dedupe_key', p_dedupe_key))
  on conflict (business_id, (metadata ->> 'dedupe_key')) where metadata ->> 'dedupe_key' is not null do nothing
  returning * into r;
  if r.id is not null then return jsonb_build_object('id', r.id, 'duplicate', false, 'status', r.status); end if;

  select * into r from public.sms_messages where business_id = p_business_id and metadata ->> 'dedupe_key' = p_dedupe_key;
  if r.status = 'failed' and p_status = 'queued' then
    update public.sms_messages set status = 'queued', updated_at = now() where id = r.id;
    return jsonb_build_object('id', r.id, 'duplicate', false, 'status', 'queued');
  end if;
  return jsonb_build_object('id', r.id, 'duplicate', true, 'status', r.status);
end $$;

-- 5. Record what happened after the send attempt.
create or replace function public.zella_update_outbound_sms(
  p_id uuid, p_status text, p_external_id text default null, p_error text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('sent', 'failed') then raise exception 'INVALID_STATUS'; end if;
  update public.sms_messages
     set status = p_status,
         external_message_id = coalesce(left(p_external_id, 200), external_message_id),
         sent_at = case when p_status = 'sent' then now() else sent_at end,
         metadata = case when p_error is null then metadata else metadata || jsonb_build_object('error', left(p_error, 300)) end,
         updated_at = now()
   where id = p_id and direction = 'outbound' and status in ('queued', 'failed');
  if not found then raise exception 'NOT_FOUND'; end if;
  return p_status;
end $$;

-- 6. Skip a claimed reminder for a known reason (no consent, dry run...). Not retried, no staff alert.
create or replace function public.zella_skip_reminder(p_reminder_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
begin
  update public.appointment_reminders set status = 'skipped', error = left(coalesce(p_reason, 'skipped'), 300)
   where id = p_reminder_id and status = 'sending';
  if not found then return 'not_sending'; end if;
  return 'skipped';
end $$;

-- Only the service role (n8n) may call these.
do $$
declare f text;
begin
  foreach f in array array[
    'zella_prepare_sms(uuid,uuid,text,jsonb,text)',
    'zella_log_outbound_sms(uuid,uuid,text,text,text,text,text,jsonb)',
    'zella_update_outbound_sms(uuid,text,text,text)',
    'zella_skip_reminder(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
