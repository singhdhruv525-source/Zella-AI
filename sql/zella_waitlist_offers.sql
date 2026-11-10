-- Zella - waitlist offers. Safe to run more than once.
-- Needs zella_run_all.sql (waitlist), zella_followup_emails.sql and zella_reschedule.sql first.
-- When an appointment is cancelled, the next person on the waitlist who fits is OFFERED the time (the database
-- already does this and queues a text). Nothing is reserved. This file makes the text go out with a private
-- button: the customer opens it, sees the time, and taps "Book this time" or "No thanks".
--   * the offer is held for the minutes the business chose (default 30); after that it moves to the next person
--   * a time that was taken in the meantime is never double-booked
--   * the text is sent straight away (no calling-hours delay) and never moved to email
--   * an offer that is no longer open is never sent
-- The page is /w/<code> on app_base_url (the same address as the Reschedule page). Until it is set, the text
-- tells the customer to contact the business instead of showing a link.

insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, 'waitlist_offer', 'sms', 'transactional', 'en-US', null,
       'Hi {{first_name}}, a time just opened at {{business}}: {{date}} at {{time}}.{{offer_line}} Reply STOP to opt out.', 1, 'active'
 where not exists (select 1 from public.message_templates t where t.business_id is null and t.industry_id is null and t.key = 'waitlist_offer' and t.channel = 'sms' and t.locale = 'en-US' and t.status = 'active');

create table if not exists public.waitlist_offer_links (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.waitlist_entries(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now()
);
create index if not exists waitlist_offer_links_entry_idx on public.waitlist_offer_links (entry_id);
alter table public.waitlist_offer_links enable row level security;
revoke all on public.waitlist_offer_links from anon, authenticated;

-- The sentence added to the text: a private link, or a plain "contact us" when no web address is set.
create or replace function public.zella_waitlist_offer_line(p_entry_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_base text := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
  v_token text; e record;
begin
  select id, business_id into e from public.waitlist_entries where id = p_entry_id;
  if e.id is null then return ''; end if;
  if v_base = '' or v_base !~ '^https://[^\s]+$' then return ' Contact us to take it.'; end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.waitlist_offer_links (entry_id, business_id, token_hash) values (e.id, e.business_id, encode(sha256(convert_to(v_token, 'utf8')), 'hex'));
  return ' Book it here: ' || v_base || '/w/' || v_token;
end $$;

-- What the page shows, or why the offer is no longer there.
create or replace function public.zella_waitlist_offer_lookup(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; e record; b record; c record;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into l from public.waitlist_offer_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into e from public.waitlist_entries where id = l.entry_id;
  select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = l.business_id;
  if e.id is null or b.id is null or b.suspended_at is not null or b.cancelled_at is not null then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  if e.status = 'booked' then return jsonb_build_object('ok', false, 'reason', 'booked', 'business', b.name); end if;
  if e.status <> 'offered' or e.offer_expires_at is null or e.offer_expires_at < now() or e.offered_start <= now() then
    return jsonb_build_object('ok', false, 'reason', 'gone', 'business', b.name);
  end if;
  select nullif(trim(coalesce(first_name, '')), '') as first_name into c from public.customers where id = e.customer_id;
  return jsonb_build_object('ok', true, 'business', b.name, 'timezone', b.tz, 'first_name', c.first_name,
    'offer', jsonb_build_object('title', coalesce(e.title, 'Appointment'), 'start', e.offered_start, 'end', e.offered_end, 'expires_at', e.offer_expires_at));
end $$;

-- The customer's answer. Yes books it (the calendar re-checks the time); no passes it to the next person.
create or replace function public.zella_waitlist_offer_answer(p_token text, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; v_info jsonb; v_appt uuid;
begin
  v_info := public.zella_waitlist_offer_lookup(p_token);
  if not coalesce((v_info ->> 'ok')::boolean, false) then return v_info; end if;
  select * into l from public.waitlist_offer_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  if not coalesce(p_accept, false) then
    perform public.zella_decline_waitlist_offer(l.entry_id);
    return jsonb_build_object('ok', true, 'result', 'declined');
  end if;
  begin
    v_appt := public.zella_accept_waitlist_offer(l.entry_id);
  exception when others then
    if sqlerrm in ('SLOT_TAKEN', 'OFFER_EXPIRED', 'BAD_TIME') then return jsonb_build_object('ok', false, 'reason', 'gone', 'business', v_info ->> 'business'); end if;
    raise;
  end;
  return jsonb_build_object('ok', true, 'result', 'booked', 'start', v_info #>> '{offer,start}');
end $$;

create or replace function public.zella_claim_followup_texts(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_task record; v_biz record; v_cust record; v_appt record; v_next timestamptz; v_reply boolean; v_offer record;
begin
  for v_task in
    select t.* from public.followup_tasks t
     where t.status = 'pending' and t.channel = 'sms' and t.due_at <= now()
       and (p_kinds is null or t.kind = any (p_kinds))
     order by t.due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked
  loop
    v_reply := v_task.kind like 'reply\_%' or v_task.kind = 'waitlist_offer';
    select b.id, b.name, coalesce(b.timezone, 'America/New_York') as timezone, b.is_active, b.suspended_at, b.cancelled_at
      into v_biz from public.businesses b where b.id = v_task.business_id;
    select c.id, c.first_name, c.last_name, c.phone, c.email, coalesce(c.do_not_contact, false) as do_not_contact,
           coalesce(c.do_not_email, false) as do_not_email, coalesce(c.do_not_sms, false) as do_not_sms
      into v_cust from public.customers c where c.id = v_task.customer_id;

    if v_biz.id is null or v_biz.suspended_at is not null or v_biz.cancelled_at is not null or not coalesce(v_biz.is_active, true) then
      update public.followup_tasks set status = 'skipped', outcome = 'business_inactive', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if v_cust.id is null or v_cust.do_not_contact then
      update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      continue;
    end if;
    if nullif(trim(coalesce(v_cust.phone, '')), '') is null or v_cust.do_not_sms then
      if not v_reply and public.zella_valid_email(v_cust.email) and not v_cust.do_not_email then
        update public.followup_tasks set channel = 'email', updated_at = now() where id = v_task.id;
      else
        update public.followup_tasks set status = 'skipped', outcome = 'do_not_contact', completed_at = now(), updated_at = now() where id = v_task.id;
      end if;
      continue;
    end if;
    if not v_reply then
      v_next := public.zella_next_call_time(now(), v_biz.timezone);
      if v_next > now() + interval '1 minute' then
        update public.followup_tasks set due_at = v_next, updated_at = now() where id = v_task.id;
        continue;
      end if;
    end if;

    -- A waitlist offer that is no longer open (taken, declined, expired) is never sent.
    if v_task.kind = 'waitlist_offer' then
      select e.id, e.title, e.status, e.offered_start, e.offered_end, e.offer_expires_at into v_offer from public.waitlist_entries e where e.id = v_task.entity_ref;
      if v_offer.id is null or v_offer.status <> 'offered' or v_offer.offer_expires_at < now() then
        update public.followup_tasks set status = 'skipped', outcome = 'offer_no_longer_open', completed_at = now(), updated_at = now() where id = v_task.id;
        continue;
      end if;
    end if;

    select a.id, a.title, a.start_time, a.end_time, a.staff_id into v_appt from public.appointments a where a.id = v_task.appointment_id;
    update public.followup_tasks set status = 'in_progress', attempts = attempts + 1, claimed_at = now(), updated_at = now() where id = v_task.id;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_id', v_task.id, 'kind', v_task.kind, 'channel', v_task.channel, 'entity_ref', v_task.entity_ref,
      'callback_reason', (select cb.reason from public.callbacks cb where cb.id = v_task.entity_ref and cb.business_id = v_task.business_id),
      'attempt', v_task.attempts + 1, 'max_attempts', v_task.max_attempts,
      'offer', case when v_task.kind = 'waitlist_offer' then jsonb_build_object('title', v_offer.title, 'start', v_offer.offered_start, 'end', v_offer.offered_end,
                      'expires_at', v_offer.offer_expires_at, 'line', public.zella_waitlist_offer_line(v_task.entity_ref)) end,
      'business', jsonb_build_object('id', v_biz.id, 'name', v_biz.name, 'timezone', v_biz.timezone),
      'customer', jsonb_build_object('id', v_cust.id, 'first_name', v_cust.first_name, 'last_name', v_cust.last_name, 'phone', v_cust.phone, 'email', v_cust.email),
      'appointment', case when v_appt.id is null then null else jsonb_build_object(
        'id', v_appt.id, 'title', v_appt.title, 'start_time', v_appt.start_time, 'end_time', v_appt.end_time, 'staff_id', v_appt.staff_id) end));
  end loop;
  return v_result;
end $$;


do $$
declare f text;
begin
  foreach f in array array['zella_waitlist_offer_line(uuid)', 'zella_waitlist_offer_lookup(text)', 'zella_waitlist_offer_answer(text,boolean)', 'zella_claim_followup_texts(integer,text[])'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
