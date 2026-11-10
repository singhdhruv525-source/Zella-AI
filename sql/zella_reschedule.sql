-- Zella - the Reschedule button. Safe to run more than once.
-- Needs zella_followup_emails.sql first (it moves a reminder to the other channel when needed).
-- What changes for customers:
--   * Appointment texts and emails (booking confirmation and reminders) go out on their own. Nobody has to
--     reply to anything. The only thing a customer can do is tap "Reschedule" and pick a new time.
--   * The old "reply C to confirm" and "reply R to reschedule" steps are gone.
--   * STOP still works. Anyone who replies STOP is never texted again (carriers and the law require it).
-- The link opens a small public page (/r/<code>). The code works for one appointment only, and stops
-- working once that appointment has passed or been cancelled.

-- 1. Where the public page lives. Leave empty until the domain is ready: messages then go out without a link.
--    Example value: "https://app.yourdomain.com"
insert into public.platform_settings (key, value) values ('app_base_url', '""'::jsonb) on conflict (key) do nothing;

-- 2. One row per link that was given out. Only the hash of the code is stored.
create table if not exists public.appointment_reschedule_links (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  uses integer not null default 0
);
create index if not exists appointment_reschedule_links_appt_idx on public.appointment_reschedule_links (appointment_id);
alter table public.appointment_reschedule_links enable row level security;
revoke all on public.appointment_reschedule_links from anon, authenticated;

-- 3. Make a link for one appointment. Returns the line to put in a message, or '' when no web address is set.
create or replace function public.zella_reschedule_line(p_appointment_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_base text := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
  v_token text; a record;
begin
  if v_base = '' or v_base !~ '^https://[^\s]+$' then return ''; end if;
  select id, business_id into a from public.appointments where id = p_appointment_id;
  if a.id is null then return ''; end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.appointment_reschedule_links (appointment_id, business_id, token_hash)
  values (a.id, a.business_id, encode(sha256(convert_to(v_token, 'utf8')), 'hex'));
  return ' Need a new time? ' || v_base || '/r/' || v_token;
end $$;

-- 4. Look up a link. Says what the page may show, or why the link no longer works.
create or replace function public.zella_reschedule_lookup(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; a record; b record; c record; v_dur integer;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into a from public.appointments where id = l.appointment_id;
  select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = l.business_id;
  if a.id is null or b.id is null or b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  if a.status in ('cancelled', 'no_show', 'completed') then
    return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name);
  end if;
  if coalesce(a.booking_state, 'confirmed') <> 'confirmed' then
    return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name);
  end if;
  if a.start_time <= now() then
    return jsonb_build_object('ok', false, 'reason', 'past', 'business', b.name);
  end if;
  select nullif(trim(coalesce(first_name, '')), '') as first_name into c from public.customers where id = a.customer_id;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  return jsonb_build_object('ok', true, 'business', b.name, 'timezone', b.tz, 'first_name', c.first_name,
    'appointment', jsonb_build_object('title', a.title, 'start', a.start_time, 'end', a.end_time, 'minutes', v_dur));
end $$;

-- 5. Free times for the next two weeks, for the same length of visit and the same person.
create or replace function public.zella_reschedule_slots(p_token text, p_days integer default 14)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; a record; v_info jsonb; v_dur integer; v_res jsonb;
begin
  v_info := public.zella_reschedule_lookup(p_token);
  if not coalesce((v_info ->> 'ok')::boolean, false) then return v_info; end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  select * into a from public.appointments where id = l.appointment_id;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  select coalesce(jsonb_agg(jsonb_build_object('start', s.slot_start, 'end', s.slot_end) order by s.slot_start), '[]'::jsonb) into v_res
    from public.zella_available_slots(a.business_id, now() + interval '30 minutes', now() + make_interval(days => greatest(1, least(coalesce(p_days, 14), 30))),
                                      v_dur, a.staff_id, 30, 200, a.id) s;
  return jsonb_build_object('ok', true, 'slots', v_res);
end $$;

-- 6. Move the appointment. The calendar rules decide whether the time is really free.
--    The appointment trigger then rebuilds the reminders and tells the business.
create or replace function public.zella_reschedule_confirm(p_token text, p_start timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; v_info jsonb; v_res jsonb;
begin
  v_info := public.zella_reschedule_lookup(p_token);
  if not coalesce((v_info ->> 'ok')::boolean, false) then return v_info; end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  begin
    v_res := public.zella_reschedule_appointment(l.appointment_id, p_start, null, 'customer');
  exception when others then
    if sqlerrm in ('SLOT_TAKEN', 'BAD_TIME') then return jsonb_build_object('ok', false, 'reason', 'slot_taken'); end if;
    if sqlerrm = 'NOT_RESCHEDULABLE' then return jsonb_build_object('ok', false, 'reason', 'not_available'); end if;
    raise;
  end;
  update public.appointment_reschedule_links set last_used_at = now(), uses = uses + 1 where id = l.id;
  return jsonb_build_object('ok', true, 'new_start', v_res ->> 'new_start');
end $$;

-- 7. Reminders no longer ask the customer to confirm. Anything of that kind still waiting is cancelled.
update public.appointment_reminders set status = 'cancelled', error = 'no_reply_needed'
 where kind = 'confirmation_request' and status in ('pending');

create or replace function public.zella_replace_reminders(p_appointment_id uuid, p_send_confirmation boolean default false, p_reason text default 'booked')
returns void language plpgsql security definer set search_path = public as $$
declare a record; v_rem record; v_conf record; v_hours numeric[]; h numeric;
begin
  update public.appointment_reminders set status = 'cancelled', error = 'replaced' where appointment_id = p_appointment_id and status in ('pending');
  select * into a from public.appointments where id = p_appointment_id;
  if not found or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or a.start_time <= now() then return; end if;

  select x.* into v_rem from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_reminder' and x.status = 'active' limit 1;
  if v_rem.id is not null then
    v_hours := case when v_rem.trigger_config ? 'hours_before' and jsonb_typeof(v_rem.trigger_config -> 'hours_before') = 'array'
                    then array(select jsonb_array_elements_text(v_rem.trigger_config -> 'hours_before')::numeric) else array[24]::numeric[] end;
    foreach h in array v_hours loop
      if a.start_time - make_interval(secs => h * 3600) > now() then
        insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
        values (a.business_id, a.id, a.customer_id, 'reminder', h, p_reason, a.start_time - make_interval(secs => h * 3600), coalesce(v_rem.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
      end if;
    end loop;
  end if;
  -- the booking message. No "please confirm" message follows it: the customer only ever has the Reschedule button.
  select x.* into v_conf from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_confirmation' and x.status = 'active' limit 1;
  if v_conf.id is not null and p_send_confirmation then
    insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, reason, due_at, channel)
    values (a.business_id, a.id, a.customer_id, 'confirmation', p_reason, now(), coalesce(v_conf.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
  end if;
end $$;
revoke all on function public.zella_replace_reminders(uuid, boolean, text) from public, anon, authenticated;

-- 8. The claim now hands the workflow the Reschedule line for each message.
--    (Same as the version in zella_followup_emails.sql, which moves a reminder to the other channel when the
--    customer cannot be reached on this one, plus the Reschedule line.)
create or replace function public.zella_claim_reminders(p_limit integer default 25, p_channel text default 'sms')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res jsonb := '[]'::jsonb; r record; a record; c record; b record; v_staff text;
        v_channel text := case when p_channel = 'email' then 'email' else 'sms' end;
        v_phone_ok boolean; v_email_ok boolean;
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
    v_phone_ok := public.zella_digits(c.phone) is not null and not coalesce(c.do_not_sms, false);
    v_email_ok := public.zella_valid_email(c.email) and not coalesce(c.do_not_email, false);
    if v_channel = 'sms' and not v_phone_ok and v_email_ok then
      update public.appointment_reminders set channel = 'email' where id = r.id; continue;
    elsif v_channel = 'email' and not v_email_ok and v_phone_ok then
      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;
    end if;
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'reschedule_line', public.zella_reschedule_line(a.id),
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $$;

-- 9. Message wording. No "Reply C / Reply R". A business that wrote its own wording keeps it.
update public.message_templates set body = 'Hi {{first_name}}, your {{appointment}} with {{business}} is booked for {{date}} at {{time}}.{{reschedule_line}} Reply STOP to opt out.'
 where business_id is null and industry_id is null and key = 'appointment_confirmation' and channel = 'sms' and status = 'active';
update public.message_templates set body = 'Hi {{first_name}}, a reminder of your {{appointment}} with {{business}} on {{date}} at {{time}}.{{reschedule_line}} Reply STOP to opt out.'
 where business_id is null and industry_id is null and key = 'appointment_reminder' and channel = 'sms' and status = 'active';
update public.message_templates set body = E'Hi {{first_name}},\n\nYour {{appointment}} with {{business}} is booked for {{date}} at {{time}}.{{reschedule_line}}'
 where business_id is null and industry_id is null and key = 'appointment_confirmation' and channel = 'email' and status = 'active';
update public.message_templates set body = E'Hi {{first_name}},\n\nThis is a reminder of your {{appointment}} with {{business}} on {{date}} at {{time}}.{{reschedule_line}}'
 where business_id is null and industry_id is null and key = 'appointment_reminder' and channel = 'email' and status = 'active';

-- 10. Replies. C / R are no longer special. STOP, START and HELP work as before.
create or replace function public.zella_handle_inbound_sms_keyword(p_business_id uuid, p_from text, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k text := upper(regexp_replace(trim(coalesce(p_body, '')), '[^A-Za-z]', '', 'g'));
  v_cust uuid; v_name text; v_tz text;
begin
  select m.customer_id into v_cust from public.zella_match_customer(p_business_id, p_from, null) m where m.certainty = 'exact' limit 1;
  select coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), p_from) into v_name from public.customers c where c.id = v_cust;
  v_name := coalesce(v_name, p_from);
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;

  if not exists (select 1 from public.sms_messages where business_id = p_business_id and direction = 'inbound' and from_number = p_from
                   and message_body = left(p_body, 1600) and created_at > now() - interval '2 minutes') then
    insert into public.sms_messages (business_id, customer_id, direction, status, from_number, message_body, metadata)
    values (p_business_id, v_cust, 'inbound', 'received', p_from, left(p_body, 1600), jsonb_build_object('keyword', nullif(k, ''), 'source', 'router'));
  end if;

  if k in ('STOP','STOPALL','UNSUBSCRIBE','CANCEL','END','QUIT') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'marketing', k);
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_out', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_out', 'keyword', k);
  elsif k in ('START','UNSTOP','YES') and exists (
      select 1 from public.contact_consents where business_id = p_business_id and phone_digits = public.zella_digits(p_from) and channel = 'sms' and status = 'opted_out') then
    perform public.zella_record_consent(p_business_id, 'sms', 'opted_in', 'inbound_sms_keyword', null, p_from, null, 'transactional', k);
    return jsonb_build_object('action', 'opted_in', 'keyword', k);
  elsif k = 'HELP' then
    if v_cust is not null then
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts) values (p_business_id, v_cust, 'reply_help', 'sms', now(), 2);
    end if;
    return jsonb_build_object('action', 'help', 'reply_queued', v_cust is not null);
  end if;

  perform public.zella_notify_owners(p_business_id, 'customer_reply', 'New text from ' || v_name, left(coalesce(p_body, ''), 300), 'info', 'inbox');
  return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null);
end $$;

-- 11. Only the service role (the public page's function and n8n) may call these.
do $$
declare f text;
begin
  foreach f in array array[
    'zella_reschedule_line(uuid)', 'zella_reschedule_lookup(text)', 'zella_reschedule_slots(text,integer)',
    'zella_reschedule_confirm(text,timestamptz)', 'zella_claim_reminders(integer,text)',
    'zella_handle_inbound_sms_keyword(uuid,text,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
